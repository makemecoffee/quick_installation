#!/bin/bash

# --- 颜色定义 ---
readonly red='\e[91m' green='\e[92m' yellow='\e[93m'
readonly magenta='\e[95m' cyan='\e[96m' none='\e[0m'
# --- 提示函数 ---
error() { echo -e "\n${red}$1${none}\n" >&2; }
info() { echo -e "\n${yellow}$1${none}\n"; }
success() { echo -e "\n${green}$1${none}\n"; }
# --- 全局变量 ---
SERVER_IP=""
TEMP_FILES=()

register_temp_file() {
    TEMP_FILES+=("$1")
}

cleanup_temp_files() {
    local temp_file
    for temp_file in "${TEMP_FILES[@]}"; do
        [ -e "$temp_file" ] && rm -rf -- "$temp_file"
    done
}

url_encode() {
    jq -sRr @uri
}

yaml_quote() {
    jq -Rn --arg value "$1" '$value'
}

# URI 地址中 IPv6 需要方括号；YAML / Xray 地址使用不带方括号的形式。
uri_host() {
    local address="${1#[}"
    address="${address%]}"
    if [[ "$address" == *:* ]]; then
        printf '[%s]' "$address"
    else
        printf '%s' "$address"
    fi
}
# ---路径常量 ---
readonly XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"
readonly XRAY_BINARY_PATH="/usr/local/bin/xray"
readonly YAML_NODES_FILE="/usr/local/etc/xray/clash_nodes.yaml"
readonly NODES_META_FILE="/usr/local/etc/xray/nodes_meta.json"
readonly OUTBOUND_PROFILES_FILE="/usr/local/etc/xray/outbound_profiles.json"

# --- 检查是否为 root 用户 ---
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "需root权限运行脚本"
        exit 1
    fi
}

# --- 检查操作系统类型 ---
detect_os() {
    if [ -f /etc/alpine-release ]; then
        OS_TYPE="alpine"
    elif [ -f /etc/os-release ] && grep -qi "debian\|ubuntu" /etc/os-release; then
        OS_TYPE="debian"
    else
        error "不支持的操作系统"
        exit 1
    fi
    info "检测到系统: ${OS_TYPE}"
}

# --- 检查必要依赖 ---
check_dependencies() {
    local missing_deps=()
    
    for cmd in curl unzip jq openssl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        info "安装缺失的依赖: ${missing_deps[*]}"
        if [ "$OS_TYPE" = "alpine" ]; then
            apk add --no-cache "${missing_deps[@]}" || {
                error "依赖安装失败"
                return 1
            }
        elif [ "$OS_TYPE" = "debian" ]; then
            apt-get update -qq && apt-get install -y -qq "${missing_deps[@]}" || {
                error "依赖安装失败"
                return 1
            }
        fi
        success "安装完成"
    fi
}

# --- 校验 Xray Release 资产摘要 ---
verify_release_asset_digest() {
    local version="$1"
    local asset_name="$2"
    local file_path="$3"
    local release_json expected_digest actual_digest

    release_json=$(curl -fsSL --max-time 30 \
        "https://api.github.com/repos/XTLS/Xray-core/releases/tags/v${version}") || {
        error "获取Xray Release校验信息失败"
        return 1
    }

    expected_digest=$(printf '%s' "$release_json" | jq -r --arg asset "$asset_name" \
        '.assets[] | select(.name == $asset) | .digest // empty' | head -n 1)
    expected_digest=${expected_digest#sha256:}

    if ! [[ "$expected_digest" =~ ^[0-9a-fA-F]{64}$ ]]; then
        error "未找到 ${asset_name} 的有效 SHA256 校验值"
        return 1
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        actual_digest=$(sha256sum "$file_path" | awk '{print $1}')
    else
        actual_digest=$(openssl dgst -sha256 "$file_path" | awk '{print $NF}')
    fi

    if [ "${actual_digest,,}" != "${expected_digest,,}" ]; then
        error "${asset_name} SHA256 校验失败"
        return 1
    fi

    return 0
}

# --- 校验 GitHub Contents 文件摘要 ---
verify_github_file_digest() {
    local file_path="$1"
    local metadata_url="$2"
    local metadata expected_sha actual_sha file_size

    metadata=$(curl -fsSL --max-time 30 "$metadata_url") || {
        error "获取全局命令校验信息失败"
        return 1
    }

    expected_sha=$(printf '%s' "$metadata" | jq -r '.sha // empty')
    if ! [[ "$expected_sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
        error "未找到全局命令的有效校验值"
        return 1
    fi

    file_size=$(wc -c < "$file_path")
    actual_sha=$(printf 'blob %s\0' "$file_size" | cat - "$file_path" | openssl dgst -sha1 | awk '{print $NF}')

    if [ "${actual_sha,,}" != "${expected_sha,,}" ]; then
        error "全局命令 SHA1 校验失败"
        return 1
    fi

    return 0
}

# --- 检查端口是否可用 ---
check_port_available() {
    local port="$1"

    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        error "无效端口: ${port} (应为 1-65535 的整数)"
        return 1
    fi

    # 检查是否与已有 Xray 入站端口冲突
    if [ -f "$XRAY_CONFIG_PATH" ]; then
        if jq -e --argjson port "$port" '.inbounds[]? | select((.port? // -1) == $port)' "$XRAY_CONFIG_PATH" >/dev/null 2>&1; then
            error "端口 ${port} 已占用，请选择其他端口"
            return 1
        fi
    fi

    # 优先使用 ss 检查系统监听端口
    if command -v ss >/dev/null 2>&1; then
        if ss -H -lntu 2>/dev/null | awk -v p=":${port}" '$5 ~ p"$" {found=1; exit} END {exit !found}'; then
            error "端口 ${port} 已占用，请选择其他端口"
            return 1
        fi
    else
        # 兜底: 直接读取 /proc/net，避免依赖额外工具
        local port_hex proc_file
        port_hex=$(printf '%04X' "$port")

        for proc_file in /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6; do
            [ -r "$proc_file" ] || continue
            if awk -v p=":${port_hex}" 'NR>1 {if (toupper($2) ~ p"$") {found=1; exit}} END {exit !found}' "$proc_file"; then
                error "端口 ${port} 已占用，请选择其他端口"
                return 1
            fi
        done
    fi

    return 0
}

# 文档要求非空 tag 唯一；同时检查入站和出站，避免覆盖或删除错误节点。
check_tag_available() {
    local tag="$1"
    if [ -z "$tag" ]; then
        error "节点标签不能为空"
        return 1
    fi
    if jq -e --arg tag "$tag" \
        'any((.inbounds[]?, .outbounds[]?); .tag == $tag)' \
        "$XRAY_CONFIG_PATH" >/dev/null; then
        error "标签已存在: $tag"
        return 1
    fi
    # jq 出错时不继续写入，以免把异常配置当成标签可用。
    if ! jq -e --arg tag "$tag" \
        'all((.inbounds[]?, .outbounds[]?); .tag != $tag)' \
        "$XRAY_CONFIG_PATH" >/dev/null; then
        error "无法读取配置或检查标签"
        return 1
    fi
}

# --- Xray 自动安装函数 ---
install_xray() {
    # 检查是否已安装
    if [ -f "$XRAY_BINARY_PATH" ]; then
        local current_version
        current_version=$("$XRAY_BINARY_PATH" version 2>/dev/null | head -n 1 | awk '{print $2}' || echo "未知")
        success "Xray 已安装 (版本: ${current_version})"
        return 0
    fi

    info "未检测到 Xray，开始安装..."
    
    # 检查并安装依赖
    check_dependencies || return 1
    
    # 获取最新版本号
    info "获取 Xray 最新版本"
    local version
    version=$(curl -s --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name | sed 's/^v//')
    
    if [ -z "$version" ] || [ "$version" = "null" ]; then
        error "获取 Xray 版本号失败，请检查网络连接"
        return 1
    fi

    info "最新版本: v${version}"
    
    # 调用下载和安装函数
    download_and_install_xray "$version" || return 1

    # 下载基础 Geo 数据文件
    update_geo_data || return 1
    
    # 创建系统服务
    create_service || return 1
    
    success "Xray 安装完成"
}

# --- 下载/更新 GeoIP 与 GeoSite 数据文件 ---
update_geo_data() {
    local geo_dir="/usr/local/share/xray"
    local geoip_url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
    local geosite_url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
    local tmp_geoip tmp_geosite staged_geoip staged_geosite

    info "正在下载 GeoIP / GeoSite 数据文件..."

    mkdir -p "$geo_dir" || {
        error "创建目录失败: $geo_dir"
        return 1
    }

    tmp_geoip=$(mktemp) || {
        error "创建临时文件失败 (geoip.dat)"
        return 1
    }
    register_temp_file "$tmp_geoip"

    tmp_geosite=$(mktemp) || {
        rm -f "$tmp_geoip"
        error "创建临时文件失败 (geosite.dat)"
        return 1
    }
    register_temp_file "$tmp_geosite"

    staged_geoip=$(mktemp "$geo_dir/.geoip.dat.XXXXXX") || {
        error "创建临时文件失败 (geoip.dat)"
        return 1
    }
    register_temp_file "$staged_geoip"

    staged_geosite=$(mktemp "$geo_dir/.geosite.dat.XXXXXX") || {
        error "创建临时文件失败 (geosite.dat)"
        return 1
    }
    register_temp_file "$staged_geosite"

    if ! curl -fsSL --max-time 120 -o "$tmp_geoip" "$geoip_url"; then
        rm -f "$tmp_geoip" "$tmp_geosite"
        error "下载 geoip.dat 失败"
        return 1
    fi

    if ! curl -fsSL --max-time 120 -o "$tmp_geosite" "$geosite_url"; then
        rm -f "$tmp_geoip" "$tmp_geosite"
        error "下载 geosite.dat 失败"
        return 1
    fi

    if ! install -m 644 "$tmp_geoip" "$staged_geoip" || \
       ! install -m 644 "$tmp_geosite" "$staged_geosite" || \
       ! mv -f "$staged_geoip" "$geo_dir/geoip.dat" || \
       ! mv -f "$staged_geosite" "$geo_dir/geosite.dat"; then
        rm -f "$tmp_geoip" "$tmp_geosite"
        error "写入 Geo 数据文件失败"
        return 1
    fi

    rm -f "$tmp_geoip" "$tmp_geosite"
    success "GeoIP / GeoSite 数据文件已更新"
}

# --- 下载并安装 Xray 核心 ---
download_and_install_xray() {
    local version="$1"
    
    # 检测架构
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="64" ;;
        aarch64) arch="arm64-v8a" ;;
        armv7l)  arch="arm32-v7a" ;;
        *) 
            error "不支持的架构: $arch"
            return 1
            ;;
    esac

    info "检测到架构: $arch"
    
    # 创建临时目录
    local tmpdir
    tmpdir=$(mktemp -d) || {
        error "创建临时目录失败"
        return 1
    }
    register_temp_file "$tmpdir"

    # 下载 - 使用 curl
    local url="https://github.com/XTLS/Xray-core/releases/download/v${version}/Xray-linux-${arch}.zip"
    info "正在下载 Xray-core v${version} ..."
    
    if ! curl -fL --progress-bar --max-time 300 -o "$tmpdir/xray.zip" "$url"; then
        error "下载失败: $url"
        rm -rf "$tmpdir"
        return 1
    fi

    verify_release_asset_digest "$version" "Xray-linux-${arch}.zip" "$tmpdir/xray.zip" || {
        rm -rf "$tmpdir"
        return 1
    }
    
    # 验证下载的文件大小
    local filesize
    filesize=$(stat -c%s "$tmpdir/xray.zip" 2>/dev/null || stat -f%z "$tmpdir/xray.zip" 2>/dev/null || wc -c < "$tmpdir/xray.zip" 2>/dev/null || echo 0)
    
    if [ "$filesize" -lt 1000000 ]; then
        error "下载的文件太小 ($filesize 字节)，可能下载失败"
        info "文件内容前10行:"
        head -n 10 "$tmpdir/xray.zip" 2>/dev/null || true
        info ""
        info "如果上面显示 HTML 内容，说明遇到了 GitHub 的防火墙或限制"
        info "建议: 1) 使用代理 2) 手动下载后再安装"
        rm -rf "$tmpdir"
        return 1
    fi
    
    info "下载完成，文件大小: $((filesize / 1024 / 1024)) MB"

    # 解压
    info "正在解压..."
    if ! unzip -qo "$tmpdir/xray.zip" -d "$tmpdir" 2>&1; then
        error "解压失败"
        info "尝试使用 -t 参数测试压缩包:"
        unzip -t "$tmpdir/xray.zip" 2>&1 || true
        rm -rf "$tmpdir"
        return 1
    fi

    # 检查解压出的文件
    if [ ! -f "$tmpdir/xray" ]; then
        error "解压后未找到 xray 可执行文件"
        rm -rf "$tmpdir"
        return 1
    fi

    # 安装二进制文件
    info "正在安装 Xray 到 $XRAY_BINARY_PATH ..."
    install -m 755 "$tmpdir/xray" "$XRAY_BINARY_PATH" || {
        error "安装二进制文件失败"
        rm -rf "$tmpdir"
        return 1
    }
    
    # 创建必要目录
    mkdir -p /usr/local/etc/xray /usr/local/share/xray
    
    rm -rf "$tmpdir"
    success "Xray v${version} 已安装到 $XRAY_BINARY_PATH"
    
    return 0
}

# --- 升级 Xray ---
upgrade_xray() {
    info "正在检查 Xray 版本..."
    
    # 获取当前版本
    local current_version
    if [ -f "$XRAY_BINARY_PATH" ]; then
        current_version=$("$XRAY_BINARY_PATH" version 2>/dev/null | head -n 1 | awk '{print $2}' | sed 's/^v//' || echo "")
    fi
    
    if [ -z "$current_version" ]; then
        error "无法获取版本，请先安装 Xray"
        return 1
    fi
    
    info "当前版本: v${current_version}"
    
    # 获取最新版本
    info "获取最新版本"
    local latest_version
    latest_version=$(curl -s --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name | sed 's/^v//')
    
    if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
        error "获取最新版本失败，请检查网络连接"
        return 1
    fi
    
    info "最新版本: v${latest_version}"
    
    # 比较版本
    if [ "$current_version" = "$latest_version" ]; then
        success "已是最新版本 v${current_version}"
        return 0
    fi
    
    # 确认升级
    read -r -p "发现新版本 v${latest_version}，是否升级? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        info "已取消升级"
        return 0
    fi
    
    info "开始升级 Xray 从 v${current_version} 到 v${latest_version} ..."

    local binary_backup service_was_active=false
    binary_backup=$(mktemp "${XRAY_BINARY_PATH}.backup.XXXXXX") || {
        error "创建 Xray 备份失败"
        return 1
    }
    register_temp_file "$binary_backup"
    if ! cp -p "$XRAY_BINARY_PATH" "$binary_backup"; then
        rm -f "$binary_backup"
        error "备份当前 Xray 失败"
        return 1
    fi
    
    # 停止服务
    if [ "$OS_TYPE" = "debian" ]; then
        if systemctl is-active --quiet xray 2>/dev/null; then
            service_was_active=true
            info "正在停止 Xray 服务..."
            systemctl stop xray
        fi
    elif [ "$OS_TYPE" = "alpine" ]; then
        if rc-service xray status >/dev/null 2>&1; then
            service_was_active=true
            info "正在停止 Xray 服务..."
            rc-service xray stop 2>/dev/null || true
        fi
    fi
    
    # 下载并安装新版本
    if ! download_and_install_xray "$latest_version"; then
        install -m 755 "$binary_backup" "$XRAY_BINARY_PATH" || true
        if [ "$service_was_active" = true ]; then
            restart_xray || true
        fi
        error "升级失败"
        return 1
    fi

    # 询问是否重启服务
    read -r -p "是否重启 Xray 服务? [Y/n]: " restart_choice
    if [[ ! "$restart_choice" =~ ^[Nn]$ ]]; then
        if restart_xray; then
            success "升级成功"
        else
            error "新版本启动失败，正在恢复旧版本..."
            install -m 755 "$binary_backup" "$XRAY_BINARY_PATH" || {
                error "恢复旧版本失败"
                return 1
            }
            restart_xray || true
            return 1
        fi
    else
        success "Xray 已升级，但服务尚未重启"
    fi
}

# --- 获取服务器地址（IP 或域名）---
get_server_address() {
    if [ -n "$SERVER_IP" ]; then
        # 如果已经设置过，询问是否继续使用
        read -r -p "继续使用之前的地址 ($SERVER_IP)? [Y/n]: " reuse
        if [[ ! "$reuse" =~ ^[Nn]$ ]]; then
            return 0
        fi
    fi
    
    info "正在获取出口 IP"
    local detected_ip
    detected_ip=$(curl -s4 --max-time 3 ip.sb 2>/dev/null || curl -s4 --max-time 3 ifconfig.me 2>/dev/null || echo "")
    
    if [ -z "$detected_ip" ]; then
        detected_ip=$(curl -s6 --max-time 3 ip.sb 2>/dev/null || curl -s6 --max-time 3 ifconfig.me 2>/dev/null || echo "")
    fi
    
    if [ -n "$detected_ip" ]; then
        info "检测到服务器 IP: $detected_ip"
    fi
    
    read -r -p "使用 1)IP , 2)域名  [1/2]: " use_domain
    
    if [ "$use_domain" = "2" ]; then
        read -r -p "请输入域名: " DOMAIN
        
        if [ -z "$DOMAIN" ]; then
            error "域名不能为空"
            return 1
        fi
        
        SERVER_IP="$DOMAIN"
        success "使用域名: $SERVER_IP"
    else
        if [ -n "$detected_ip" ]; then
            read -r -p "使用检测到的 IP ($detected_ip)? [Y/n]: " use_detected
            if [[ ! "$use_detected" =~ ^[Nn]$ ]]; then
                SERVER_IP="$detected_ip"
            else
                read -r -p "请输入服务器 IP: " SERVER_IP
                if [ -z "$SERVER_IP" ]; then
                    error "IP 地址不能为空"
                    return 1
                fi
            fi
        else
            read -r -p "请输入服务器 IP: " SERVER_IP
            if [ -z "$SERVER_IP" ]; then
                error "IP 地址不能为空"
                return 1
            fi
        fi
        success "使用 IP: $SERVER_IP"
    fi
}

# --- 选择使用 IP 还是域名 ---
get_domain() {
    read -r -p "使用 1)IP , 2)域名  [1/2]: " use_domain
    
    if [ "$use_domain" = "2" ]; then
        read -r -p "请输入域名: " DOMAIN
        
        if [ -z "$DOMAIN" ]; then
            error "域名不能为空"
            exit 1
        fi

        SERVER_IP="$DOMAIN"
        success "使用域名: $SERVER_IP"
    else
        success "使用 IP: $SERVER_IP"
    fi
}

# --- 创建系统服务 ---
create_service() {
    # 根据操作系统类型创建对应服务
    if [ "$OS_TYPE" = "debian" ]; then
        create_systemd_service
    elif [ "$OS_TYPE" = "alpine" ]; then
        create_openrc_service
    else
        error "未知的操作系统: $OS_TYPE"
        return 1
    fi
}

# --- 创建 systemd 服务 ---
create_systemd_service() {
    if [ -f /etc/systemd/system/xray.service ]; then
        success "systemd 服务已存在"
        return 0
    fi

    info "正在创建 systemd 服务..."

    local service_file
    service_file=$(mktemp /etc/systemd/system/xray.service.tmp.XXXXXX) || {
        error "创建 systemd 临时服务文件失败"
        return 1
    }
    register_temp_file "$service_file"

    cat > "$service_file" <<'EOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    if ! chmod 644 "$service_file" || ! mv -f "$service_file" /etc/systemd/system/xray.service || \
       ! systemctl daemon-reload || ! systemctl enable xray; then
        rm -f "$service_file"
        error "创建或启用 systemd 服务失败"
        return 1
    fi
    
    success "systemd 服务已创建并设置为开机自启"
}

# --- 创建 OpenRC 服务 ---
create_openrc_service() {
    if [ -x /etc/init.d/xray ]; then
        success "OpenRC 服务已存在"
        return 0
    fi

    info "正在创建 OpenRC 服务..."
    
    # 创建日志目录
    mkdir -p /var/log/xray || {
        error "创建 Xray 日志目录失败"
        return 1
    }

    local service_file
    service_file=$(mktemp /etc/init.d/xray.tmp.XXXXXX) || {
        error "创建 OpenRC 临时服务文件失败"
        return 1
    }
    register_temp_file "$service_file"

    cat > "$service_file" <<'EOF'
#!/sbin/openrc-run
name="Xray"
description="Xray service"

command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
supervisor="supervise-daemon"
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"
output_log="/var/log/xray/access.log"
error_log="/var/log/xray/error.log"

depend() {
    need net
    use dns logger
}
EOF

    if ! chmod 755 "$service_file" || ! mv -f "$service_file" /etc/init.d/xray || \
       ! rc-update add xray default; then
        rm -f "$service_file"
        error "创建或启用 OpenRC 服务失败"
        return 1
    fi
    
    success "OpenRC 服务已创建并设置为开机自启"
}

# --- 初始化配置文件 ---
init_config() {
    # 检查配置文件是否已存在
    if [ -f "$XRAY_CONFIG_PATH" ]; then
        success "配置文件已存在，跳过初始化: $XRAY_CONFIG_PATH"
        return 0
    fi
    
    info "正在创建初始配置文件..."
    
    mkdir -p "$(dirname "$XRAY_CONFIG_PATH")"
    
    jq -n '{
        "log": {
            "loglevel": "none"
        },
        "inbounds": [],
        "outbounds": [
            {
                "tag": "direct",
                "protocol": "freedom"
            },
            {
                "tag": "block",
                "protocol": "blackhole"
            }
        ],
        "routing": {
            "domainStrategy": "IPIfNonMatch",
            "rules": [
                {
                    "ip": ["geoip:private"],
                    "outboundTag": "block"
                },
                {
                    "ip": ["geoip:cn"],
                    "outboundTag": "block"
                }
            ]
        }
    }' > "$XRAY_CONFIG_PATH"
    
    if [ $? -eq 0 ]; then
        success "配置文件已创建: $XRAY_CONFIG_PATH"
    else
        error "配置文件创建失败"
        return 1
    fi
    
    # 初始化 YAML 节点文件
    if [ ! -f "$YAML_NODES_FILE" ]; then
        cat > "$YAML_NODES_FILE" << 'EOF'
# Clash 节点列表：复制节点到现有 YAML 的 proxies 部分
# 客户端字段与 URI 格式按用户要求保留，兼容性需在客户端自行验证

EOF
        success "YAML 节点文件已创建: $YAML_NODES_FILE"
    fi
    
    # 初始化节点元数据文件
    if [ ! -f "$NODES_META_FILE" ]; then
        echo '{"nodes":[]}' > "$NODES_META_FILE"
        success "节点元数据文件已创建: $NODES_META_FILE"
    fi
}

# --- 初始化/补齐路由策略（仅执行一次）---
ensure_routing_policy() {
    if [ ! -f "$XRAY_CONFIG_PATH" ]; then
        error "配置文件不存在: $XRAY_CONFIG_PATH"
        return 1
    fi

    # 已存在 routing 则不覆盖，避免改动用户自定义分流。
    if jq -e '.routing != null' "$XRAY_CONFIG_PATH" >/dev/null 2>&1; then
        return 0
    fi

    local temp
    temp=$(mktemp) || return 1
    register_temp_file "$temp"

    jq '.routing = {
           "domainStrategy": "IPIfNonMatch",
           "rules": [
               {
                   "ip": ["geoip:private"],
                   "outboundTag": "block"
               },
               {
                   "ip": ["geoip:cn"],
                   "outboundTag": "block"
               }
           ]
       }' "$XRAY_CONFIG_PATH" > "$temp" && mv "$temp" "$XRAY_CONFIG_PATH"

    if [ $? -eq 0 ]; then
        success "已初始化路由策略（禁止回国流量）"
        return 0
    else
        error "初始化路由策略失败"
        rm -f "$temp"
        return 1
    fi
}

# --- 保存节点元数据 ---
save_node_meta() {
    local tag="$1"
    local share_link="$2"
    local yaml_config="$3"
    # client_config 是本脚本的元数据，不是 Xray 配置字段。
    local client_config="${4:-null}"
    
    # 确保元数据文件存在
    if [ ! -f "$NODES_META_FILE" ]; then
        echo '{"nodes":[]}' > "$NODES_META_FILE"
    fi
    
    local temp
    temp=$(mktemp) || {
        error "创建临时文件失败"
        return 1
    }
    register_temp_file "$temp"
    
    jq --arg tag "$tag" \
       --arg link "$share_link" \
       --arg yaml "$yaml_config" \
       --argjson client "$client_config" \
       --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.nodes += [{
           "tag": $tag,
           "share_link": $link,
           "yaml_config": $yaml,
           "client_config": $client,
           "created_at": $time
       }]' "$NODES_META_FILE" > "$temp" && mv "$temp" "$NODES_META_FILE"
    
    if [ $? -eq 0 ]; then
        info "节点元数据已保存"
    else
        rm -f "$temp"
        error "保存节点元数据失败"
        return 1
    fi
}

# --- 生成 UUID ---
generate_uuid() {
    "$XRAY_BINARY_PATH" uuid 2>/dev/null || {
        error "生成 UUID 失败"
        return 1
    }
}

# --- 生成 SS2022 密钥 ---
generate_ss2022_key() {
    local method="$1"
    local key_length

    case "$method" in
        2022-blake3-aes-128-gcm)
            key_length=16
            ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
            key_length=32
            ;;
        *)
            error "不支持的 SS2022 加密方式: $method"
            return 1
            ;;
    esac

    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 "$key_length" 2>/dev/null
    else
        head -c "$key_length" /dev/urandom | base64 | tr -d '\n'
    fi
}

# --- 检查 SS2022 密码 ---
validate_ss2022_password() {
    local method="$1"
    local password="$2"
    local key_length decoded_file decoded_length

    case "$method" in
        2022-blake3-aes-128-gcm)
            key_length=16
            ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
            key_length=32
            ;;
        *)
            error "不支持的 SS2022 加密方式: $method"
            return 1
            ;;
    esac

    if ! [[ "$password" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || [ $(( ${#password} % 4 )) -ne 0 ]; then
        error "密码必须是合法的 Base64 字符串"
        return 1
    fi

    decoded_file=$(mktemp) || {
        error "创建临时文件失败"
        return 1
    }
    register_temp_file "$decoded_file"

    if ! printf '%s' "$password" | openssl base64 -d -A -out "$decoded_file" 2>/dev/null; then
        rm -f "$decoded_file"
        error "密码不是合法的 Base64 字符串"
        return 1
    fi

    decoded_length=$(wc -c < "$decoded_file")
    rm -f "$decoded_file"

    # 官方 SS 文档注明：Go 实现中 32 字节密钥始终工作，AES-128 也接受此长度。
    if [ "$decoded_length" -ne "$key_length" ] && [ "$decoded_length" -ne 32 ]; then
        error "密码解码后必须是 ${key_length} 字节（Go 实现也支持 32 字节）"
        return 1
    fi
}

# --- 解析 SS2022 URI ---
parse_ss2022_uri() {
    local uri="$1"
    local body encoded_credentials endpoint decoded_credentials

    URI_SERVER=""
    URI_PORT=""
    URI_METHOD=""
    URI_PASSWORD=""

    case "$uri" in
        ss://*)
            body="${uri#ss://}"
            ;;
        *)
            error "无效的 SS2022 URI，应以 ss:// 开头"
            return 1
            ;;
    esac

    if [[ "$body" != *@* ]]; then
        error "无效的 SS2022 URI，缺少服务器地址"
        return 1
    fi

    encoded_credentials="${body%@*}"
    endpoint="${body#*@}"
    endpoint="${endpoint%%#*}"

    if ! decoded_credentials=$(printf '%s' "$encoded_credentials" | base64 -d 2>/dev/null); then
        error "URI 中的认证信息不是有效 Base64"
        return 1
    fi

    URI_METHOD="${decoded_credentials%%:*}"
    URI_PASSWORD="${decoded_credentials#*:}"

    if [[ "$endpoint" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        URI_SERVER="${BASH_REMATCH[1]}"
        URI_PORT="${BASH_REMATCH[2]}"
    elif [[ "$endpoint" =~ ^([^:]+):([0-9]+)$ ]]; then
        URI_SERVER="${BASH_REMATCH[1]}"
        URI_PORT="${BASH_REMATCH[2]}"
    else
        error "URI 中的服务器地址或端口格式无效"
        return 1
    fi

    if ! [[ "$URI_METHOD" =~ ^2022-blake3-(aes-128-gcm|aes-256-gcm|chacha20-poly1305)$ ]]; then
        error "URI 使用了不支持的 SS2022 加密方式: $URI_METHOD"
        return 1
    fi

    if [ "$URI_PORT" -lt 1 ] || [ "$URI_PORT" -gt 65535 ]; then
        error "URI 中的端口应为 1-65535"
        return 1
    fi
    validate_ss2022_password "$URI_METHOD" "$URI_PASSWORD" || return 1
}

# --- 生成 Reality 密钥对 ---
generate_reality_keypair() {
    local output
    if ! output=$("$XRAY_BINARY_PATH" x25519 2>&1); then
        error "生成 Reality 密钥失败"
        if [ -n "$output" ]; then
            echo "错误输出: $output" >&2
        fi
        return 1
    fi
    
    if [ -z "$output" ]; then
        error "命令执行成功但无输出"
        return 1
    fi
    
    echo "$output"
}

# --- 添加 SS2022 节点 ---
add_ss2022_node() {
    # 获取服务器地址
    get_server_address || return 1
    
    local tag port password method port_source
    local config_backup meta_backup yaml_backup meta_existed=false yaml_existed=false
    
    # 端口自定义
    read -r -p "请输入端口 (默认: 443): " port
    if [ -z "$port" ]; then
        port=443
        port_source="default"
    else
        port_source="custom"
    fi

    check_port_available "$port" || return 1

    if [ "$port_source" = "default" ]; then
        info "使用默认端口: $port"
    else
        info "使用自定义端口: $port"
    fi
    
    # 节点标签
    read -r -p "请输入节点标签 (默认: ss-${port}): " tag
    [ -z "$tag" ] && tag="ss-${port}"
    check_tag_available "$tag" || return 1

    # 选择加密方式
    echo "1) 2022-blake3-aes-128-gcm"
    echo "2) 2022-blake3-aes-256-gcm"
    echo "3) 2022-blake3-chacha20-poly1305"
    read -r -p "请选择加密方式 [1-3，默认: 1]: " method
    case "${method:-1}" in
        1)
            method="2022-blake3-aes-128-gcm"
            ;;
        2)
            method="2022-blake3-aes-256-gcm"
            ;;
        3)
            method="2022-blake3-chacha20-poly1305"
            ;;
        *)
            error "无效的加密方式，请输入 1-3"
            return 1
            ;;
    esac
    info "加密方法: $method"
    
    # 密码自定义
    read -r -s -p "请输入密码 (留空自动生成): " password
    echo
    if [ -z "$password" ]; then
        password=$(generate_ss2022_key "$method") || { error "生成 SS2022 密钥失败"; return 1; }
        [ -n "$password" ] || { error "生成 SS2022 密钥为空"; return 1; }
        info "自动生成密码: $password"
    else
        validate_ss2022_password "$method" "$password" || return 1
        info "使用自定义密码"
    fi
    
    # 构建 inbound 配置
    local inbound
    inbound=$(jq -n \
        --arg tag "$tag" \
        --arg port "$port" \
        --arg password "$password" \
        --arg method "$method" \
        '{
            "tag": $tag,
            "listen": "::",
            "port": ($port | tonumber),
            "protocol": "shadowsocks",
            "settings": {
                "method": $method,
                "password": $password,
                "network": "tcp,udp"
            }
        }')
    
    # 添加到配置文件
    local temp
    config_backup=$(mktemp) || return 1
    register_temp_file "$config_backup"
    cp -p "$XRAY_CONFIG_PATH" "$config_backup" || return 1
    if [ -f "$NODES_META_FILE" ]; then
        meta_existed=true
        meta_backup=$(mktemp) || return 1
        register_temp_file "$meta_backup"
        cp -p "$NODES_META_FILE" "$meta_backup" || return 1
    fi
    if [ -f "$YAML_NODES_FILE" ]; then
        yaml_existed=true
        yaml_backup=$(mktemp) || return 1
        register_temp_file "$yaml_backup"
        cp -p "$YAML_NODES_FILE" "$yaml_backup" || return 1
    fi
    temp=$(mktemp) || {
        error "创建临时文件失败"
        return 1
    }
    register_temp_file "$temp"
    if ! jq --argjson inbound "$inbound" \
        '.inbounds += [$inbound]' "$XRAY_CONFIG_PATH" > "$temp" || \
        ! mv "$temp" "$XRAY_CONFIG_PATH"; then
        rm -f "$temp"
        restore_node_state "$config_backup" "$meta_backup" "$yaml_backup" "$meta_existed" "$yaml_existed"
        error "写入 SS2022 配置失败"
        return 1
    fi
    
    # Clash 节点和分享链接沿用原脚本格式；Xray 文档未确认第三方客户端格式。
    local share_link="" yaml_config="" client_config
    local encoded_tag yaml_name yaml_server yaml_password uri_address raw_address
    encoded_tag=$(printf '%s' "$tag" | url_encode) || return 1
    uri_address=$(uri_host "$SERVER_IP")
    yaml_name=$(yaml_quote "$tag")
    raw_address="${SERVER_IP#[}"
    raw_address="${raw_address%]}"
    yaml_server=$(yaml_quote "$raw_address")
    yaml_password=$(yaml_quote "$password")
    share_link="ss://$(printf '%s' "${method}:${password}" | base64 | tr -d '\n')@${uri_address}:${port}#${encoded_tag}"
    yaml_config="- {name: ${yaml_name}, type: ss, server: ${yaml_server}, port: ${port}, cipher: ${method}, password: ${yaml_password}, udp: true}"
    client_config=$(jq -n --arg tag "$tag" --arg address "${SERVER_IP#[}" \
        --arg port "$port" --arg method "$method" --arg password "$password" '
        {outbounds: [{tag: $tag, protocol: "shadowsocks", settings: {
            address: ($address | rtrimstr("]")), port: ($port | tonumber),
            method: $method, password: $password
        }}]}') || {
        restore_node_state "$config_backup" "$meta_backup" "$yaml_backup" "$meta_existed" "$yaml_existed"
        return 1
    }
    
    # 保存节点信息
    if ! save_node_meta "$tag" "$share_link" "$yaml_config" "$client_config"; then
        restore_node_state "$config_backup" "$meta_backup" "$yaml_backup" "$meta_existed" "$yaml_existed"
        return 1
    fi
    
    # 追加到 YAML 文件
    if ! echo "$yaml_config" >> "$YAML_NODES_FILE"; then
        error "写入 YAML 节点文件失败"
        restore_node_state "$config_backup" "$meta_backup" "$yaml_backup" "$meta_existed" "$yaml_existed"
        return 1
    fi

    rm -f "$config_backup" "$meta_backup" "$yaml_backup"
    
    success "SS2022 节点添加成功！"
    echo -e "\n${cyan}Shadowrocket 分享链接:${none}"
    printf '%s\n' "$share_link"
    echo -e "${cyan}Clash 节点（复制到 proxies）:${none}"
    printf '%s\n' "$yaml_config"
}

# --- 添加 vless reality vision 节点 ---
add_reality_node() {
    # 获取服务器地址
    get_server_address || return 1
    
    local tag port uuid target domain private_key public_key short_id port_source
    local config_backup meta_backup yaml_backup meta_existed=false yaml_existed=false
    
    # 端口自定义
    read -r -p "端口 (默认: 443): " port
    if [ -z "$port" ]; then
        port=443
        port_source="default"
    else
        port_source="custom"
    fi

    check_port_available "$port" || return 1

    if [ "$port_source" = "default" ]; then
        info "默认端口: $port"
    else
        info "自定义端口: $port"
    fi
    
    # 节点标签
    read -r -p "请输入节点标签 (默认: vvr-${port}): " tag
    [ -z "$tag" ] && tag="vvr-${port}"
    check_tag_available "$tag" || return 1
    
    # UUID 自定义
    read -r -p "请输入 UUID (留空自动生成): " uuid
    if [ -z "$uuid" ]; then
        if ! uuid=$(generate_uuid) || [ -z "$uuid" ]; then
            error "UUID 生成失败"
            return 1
        fi
        info "自动生成 UUID: $uuid"
    else
        if ! [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
            error "无效的 UUID 格式"
            return 1
        fi
        info "使用自定义 UUID"
    fi
    
    # 生成 Reality 密钥对
    info "正在生成 Reality 密钥对..."
    
    local keypair
    if ! keypair=$("$XRAY_BINARY_PATH" x25519 2>&1) || [ -z "$keypair" ]; then
        error "xray x25519 命令执行失败"
        return 1
    fi
    
    # 命令输出标签沿用原脚本已处理的名称；官方文档未定义完整输出格式。
    # 只接受明确标识的单个值，不使用 Hash32，也不把密钥输出到屏幕。
    private_key=$(printf '%s\n' "$keypair" | awk '
        index($0, ":") {
            label = tolower(substr($0, 1, index($0, ":") - 1))
            gsub(/[[:space:]]/, "", label)
            if (label == "privatekey") {
                value = substr($0, index($0, ":") + 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                if (value != "" && value !~ /[[:space:]]/) { result = value; count++ }
            }
        }
        END { if (count == 1) print result; else exit 1 }
    ') || { error "无法识别唯一的 REALITY 私钥输出，未写入配置"; return 1; }

    # 按文档从该私钥生成对应的客户端 password，再提取明确标识的值。
    if ! keypair=$("$XRAY_BINARY_PATH" x25519 -i "$private_key" 2>&1); then
        error "按私钥生成对应公钥失败"
        return 1
    fi
    public_key=$(printf '%s\n' "$keypair" | awk '
        index($0, ":") {
            label = tolower(substr($0, 1, index($0, ":") - 1))
            gsub(/[[:space:]]/, "", label)
            if (label == "publickey" || label == "password" || label == "password(publickey)") {
                value = substr($0, index($0, ":") + 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                if (value != "" && value !~ /[[:space:]]/) { result = value; count++ }
            }
        }
        END { if (count == 1) print result; else exit 1 }
    ') || { error "无法识别唯一的 REALITY 公钥输出，未写入配置"; return 1; }
    success "REALITY 密钥已自动生成，将写入配置和客户端节点"
    
    # SNI 域名自定义
    # 不把某个具体网站当成已确认可用的目标；由用户在服务器选择。
    read -r -p "SNI（目标接受的域名，必填，不支持 * 通配符）: " domain
    if [ -z "$domain" ] || [[ "$domain" == *'*'* ]]; then
        error "请填写非空且不含 * 的 SNI"
        return 1
    fi

    # 官方现名 target；dest 仍被文档列为别名。这里采用现名。
    read -r -p "target（默认: ${domain}:443）: " target
    [ -z "$target" ] && target="${domain}:443"
    
    # Short ID 自定义
    read -r -p "请输入 Short ID (留空自动生成): " short_id
    if [ -z "$short_id" ]; then
        if command -v openssl >/dev/null 2>&1; then
            short_id=$(openssl rand -hex 4)
        else
            short_id=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
        fi
        info "Short ID: $short_id"
    else
        # 官方要求十六进制位数为偶数，最多 16 位；留空用于自动生成。
        if ! [[ "$short_id" =~ ^([0-9a-f]{2}){1,8}$ ]]; then
            error "无效的 Short ID（需要 2、4、6、8、10、12、14 或 16 位小写十六进制字符）"
            return 1
        fi
        info "使用自定义 Short ID"
    fi
    
    # 构建 inbound 配置
    local inbound
    inbound=$(jq -n \
        --arg tag "$tag" \
        --arg port "$port" \
        --arg uuid "$uuid" \
        --arg domain "$domain" \
        --arg target "$target" \
        --arg private_key "$private_key" \
        --arg short_id "$short_id" \
        '{
            "tag": $tag,
            "listen": "::",
            "port": ($port | tonumber),
            "protocol": "vless",
            "settings": {
                "users": [{
                    "id": $uuid,
                    "flow": "xtls-rprx-vision"
                }],
                "decryption": "none"
            },
            "streamSettings": {
                "method": "raw",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "target": $target,
                    "xver": 0,
                    "serverNames": [$domain],
                    "privateKey": $private_key,
                    "shortIds": [$short_id]
                }
            }
        }')
    
    # 添加到配置文件
    local temp
    config_backup=$(mktemp) || return 1
    register_temp_file "$config_backup"
    cp -p "$XRAY_CONFIG_PATH" "$config_backup" || return 1
    if [ -f "$NODES_META_FILE" ]; then
        meta_existed=true
        meta_backup=$(mktemp) || return 1
        register_temp_file "$meta_backup"
        cp -p "$NODES_META_FILE" "$meta_backup" || return 1
    fi
    if [ -f "$YAML_NODES_FILE" ]; then
        yaml_existed=true
        yaml_backup=$(mktemp) || return 1
        register_temp_file "$yaml_backup"
        cp -p "$YAML_NODES_FILE" "$yaml_backup" || return 1
    fi
    temp=$(mktemp) || {
        error "创建临时文件失败"
        return 1
    }
    register_temp_file "$temp"
    if ! jq --argjson inbound "$inbound" \
        '.inbounds += [$inbound]' "$XRAY_CONFIG_PATH" > "$temp" || \
        ! mv "$temp" "$XRAY_CONFIG_PATH"; then
        rm -f "$temp"
        restore_node_state "$config_backup" "$meta_backup" "$yaml_backup" "$meta_existed" "$yaml_existed"
        error "写入 vless reality vision 配置失败"
        return 1
    fi
    
    # 仅使用指定文档中的 VLESS 出站和 RealityObject 字段。
    local share_link="" yaml_config="" client_config
    local encoded_tag encoded_domain encoded_public_key uri_address raw_address
    local yaml_name yaml_server yaml_domain yaml_public_key yaml_short_id yaml_uuid
    encoded_tag=$(printf '%s' "$tag" | url_encode) || return 1
    encoded_domain=$(printf '%s' "$domain" | url_encode) || return 1
    encoded_public_key=$(printf '%s' "$public_key" | url_encode) || return 1
    uri_address=$(uri_host "$SERVER_IP")
    yaml_name=$(yaml_quote "$tag")
    raw_address="${SERVER_IP#[}"
    raw_address="${raw_address%]}"
    yaml_server=$(yaml_quote "$raw_address")
    yaml_domain=$(yaml_quote "$domain")
    yaml_public_key=$(yaml_quote "$public_key")
    yaml_short_id=$(yaml_quote "$short_id")
    yaml_uuid=$(yaml_quote "$uuid")
    # support-x25519mlkem768 的拼写按用户指定；位置沿用原脚本 reality-opts。
    share_link="vless://${uuid}@${uri_address}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${encoded_domain}&fp=chrome&pbk=${encoded_public_key}&sid=${short_id}&type=tcp&headerType=none#${encoded_tag}"
    yaml_config="- {name: ${yaml_name}, type: vless, server: ${yaml_server}, port: ${port}, uuid: ${yaml_uuid}, udp: true, tls: true, network: tcp, flow: xtls-rprx-vision, servername: ${yaml_domain}, client-fingerprint: chrome, reality-opts: {public-key: ${yaml_public_key}, short-id: ${yaml_short_id}, support-x25519mlkem768: true}}"
    client_config=$(jq -n --arg tag "$tag" --arg address "${SERVER_IP#[}" \
        --arg port "$port" --arg uuid "$uuid" --arg domain "$domain" \
        --arg password "$public_key" --arg short_id "$short_id" '
        {outbounds: [{tag: $tag, protocol: "vless", settings: {
            address: ($address | rtrimstr("]")), port: ($port | tonumber),
            id: $uuid, encryption: "none", flow: "xtls-rprx-vision"
        }, streamSettings: {method: "raw", security: "reality", realitySettings: {
            serverName: $domain, fingerprint: "chrome", password: $password,
            shortId: $short_id
        }}}]}') || {
        restore_node_state "$config_backup" "$meta_backup" "$yaml_backup" "$meta_existed" "$yaml_existed"
        return 1
    }
    
    # 保存节点信息
    if ! save_node_meta "$tag" "$share_link" "$yaml_config" "$client_config"; then
        restore_node_state "$config_backup" "$meta_backup" "$yaml_backup" "$meta_existed" "$yaml_existed"
        return 1
    fi
    
    # 追加到 YAML 文件
    if ! echo "$yaml_config" >> "$YAML_NODES_FILE"; then
        error "写入 YAML 节点文件失败"
        restore_node_state "$config_backup" "$meta_backup" "$yaml_backup" "$meta_existed" "$yaml_existed"
        return 1
    fi

    rm -f "$config_backup" "$meta_backup" "$yaml_backup"
    
    success "vless reality vision 节点添加成功！"
    echo -e "\n${cyan}Shadowrocket 分享链接:${none}"
    printf '%s\n' "$share_link"
    echo -e "${cyan}Clash 节点（复制到 proxies）:${none}"
    printf '%s\n' "$yaml_config"
}

# --- 列出所有节点 ---
list_nodes() {
    if [ ! -f "$NODES_META_FILE" ]; then
        info "暂无节点信息"
        return 0
    fi
    
    local node_count
    node_count=$(jq '.nodes | length' "$NODES_META_FILE" 2>/dev/null || echo 0)
    
    if [ "$node_count" -eq 0 ]; then
        info "暂无节点"
        return 0
    fi
    
    echo -e "\n${cyan}=== 节点列表 (共 $node_count 个) ===${none}\n"
    
    local index=1
    local nodes_json
    nodes_json=$(jq -r '.nodes[] | @json' "$NODES_META_FILE")
    
    while IFS= read -r node; do
        local tag=$(echo "$node" | jq -r '.tag')
        local share_link=$(echo "$node" | jq -r '.share_link')
        local yaml_config=$(echo "$node" | jq -r '.yaml_config')
        
        echo -e "${green}[$index]${none} ${magenta}$tag${none}"
        if [ -n "$share_link" ] && [ "$share_link" != null ]; then
            echo -e "${cyan}Shadowrocket URI:${none}"
            printf '%s\n' "$share_link"
        fi
        if [ -n "$yaml_config" ] && [ "$yaml_config" != null ]; then
            echo -e "${cyan}Clash YAML:${none}"
            printf '%s\n' "$yaml_config"
        fi
        if echo "$node" | jq -e '.client_config != null' >/dev/null 2>&1; then
            echo -e "${cyan}Xray 客户端出站片段:${none}"
            echo "$node" | jq '.client_config'
        fi
        echo "---"
        echo
        
        ((index++))
    done <<< "$nodes_json"
}

# --- 删除节点 ---
delete_node() {
    if [ ! -f "$NODES_META_FILE" ]; then
        info "暂无节点信息"
        return 0
    fi
    
    local node_count
    node_count=$(jq '.nodes | length' "$NODES_META_FILE" 2>/dev/null || echo 0)
    
    if [ "$node_count" -eq 0 ]; then
        info "暂无节点"
        return 0
    fi
    
    # 显示节点列表
    echo -e "\n${cyan}=== 选择要删除的节点 ===${none}\n"
    
    local index=1
    local tags=()
    
    while IFS= read -r node; do
        local tag=$(echo "$node" | jq -r '.tag')
        tags+=("$tag")
        echo -e "${green}[$index]${none} ${magenta}$tag${none}"
        ((index++))
    done < <(jq -r '.nodes[] | @json' "$NODES_META_FILE")
    
    echo -e "${red}[0]${none} 取消"
    echo
    
    # 读取用户输入
    local choice
    read -r -p "请输入要删除的节点序号: " choice
    
    # 验证输入
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 0 ] || [ "$choice" -gt "$node_count" ]; then
        error "无效的选择，请输入 0-${node_count} 之间的数字"
        return 1
    fi
    
    if [ "$choice" -eq 0 ]; then
        info "已取消删除"
        return 0
    fi
    
    # 获取要删除的节点标签
    local delete_tag="${tags[$((choice-1))]}"
    
    # 二次确认
    read -r -p "确认删除节点 '${delete_tag}' ? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        info "已取消删除"
        return 0
    fi
    
    info "正在删除节点 '${delete_tag}'..."
    
    # 从 Xray 配置中删除 inbound
    local temp
    temp=$(mktemp) || { error "创建临时文件失败"; return 1; }
    register_temp_file "$temp"
    
    jq --arg tag "$delete_tag" \
        'del(.inbounds[] | select(.tag == $tag))' \
        "$XRAY_CONFIG_PATH" > "$temp" && mv "$temp" "$XRAY_CONFIG_PATH"
    
    if [ $? -ne 0 ]; then
        error "从 Xray 配置删除失败"
        rm -f "$temp"
        return 1
    fi
    
    # 从元数据文件中删除节点
    temp=$(mktemp) || { error "创建临时文件失败"; return 1; }
    register_temp_file "$temp"
    
    jq --arg tag "$delete_tag" \
        'del(.nodes[] | select(.tag == $tag))' \
        "$NODES_META_FILE" > "$temp" && mv "$temp" "$NODES_META_FILE"
    
    if [ $? -ne 0 ]; then
        error "从元数据删除失败"
        rm -f "$temp"
        return 1
    fi
    
    # 重新生成 YAML 文件
    cat > "$YAML_NODES_FILE" << 'EOF'
# Clash 节点列表：复制节点到现有 YAML 的 proxies 部分
# 客户端字段与 URI 格式按用户要求保留，兼容性需在客户端自行验证

EOF
    
    jq -r '.nodes[].yaml_config // empty | select(length > 0)' "$NODES_META_FILE" 2>/dev/null >> "$YAML_NODES_FILE"
    
    success "节点 '${delete_tag}' 已删除"
    
    # 直接重启服务
    restart_xray
}

# --- 卸载 Xray ---
uninstall_xray() {
    echo -e "\n${red}=== 卸载 Xray ===${none}\n"
    echo -e "${yellow}警告: 此操作将完全删除以下内容:${none}"
    echo "  - Xray 二进制文件"
    echo "  - Xray 配置文件"
    echo "  - Xray 系统服务"
    echo "  - 所有节点配置和元数据"
    echo "  - GeoIP/GeoSite 数据文件"
    echo "  - 全局命令 xrm"
    echo
    
    read -r -p "确认完全卸载 Xray? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        info "已取消卸载"
        return 0
    fi
    
    info "开始卸载 Xray..."
    
    # 停止并删除系统服务
    if [ "$OS_TYPE" = "debian" ]; then
        if systemctl is-active --quiet xray 2>/dev/null; then
            info "正在停止 Xray 服务..."
            systemctl stop xray
        fi
        
        if systemctl is-enabled --quiet xray 2>/dev/null; then
            info "正在禁用 Xray 服务..."
            systemctl disable xray
        fi
        
        if [ -f /etc/systemd/system/xray.service ]; then
            info "正在删除 systemd 服务文件..."
            rm -f /etc/systemd/system/xray.service
            systemctl daemon-reload
        fi
    elif [ "$OS_TYPE" = "alpine" ]; then
        if rc-service xray status >/dev/null 2>&1; then
            info "正在停止 Xray 服务..."
            rc-service xray stop 2>/dev/null || true
        fi
        
        if [ -x /etc/init.d/xray ]; then
            info "正在删除 OpenRC 服务..."
            rc-update del xray default 2>/dev/null || true
            rm -f /etc/init.d/xray
        fi
        
        # 删除日志目录
        if [ -d /var/log/xray ]; then
            rm -rf /var/log/xray
        fi
    fi
    
    # 删除 Xray 二进制文件
    if [ -f "$XRAY_BINARY_PATH" ]; then
        info "正在删除 Xray 二进制文件..."
        rm -f "$XRAY_BINARY_PATH"
    fi
    
    # 删除配置文件
    if [ -f "$XRAY_CONFIG_PATH" ]; then
        info "正在删除配置文件..."
        rm -f "$XRAY_CONFIG_PATH"
    fi
    
    if [ -f "$YAML_NODES_FILE" ]; then
        info "正在删除 YAML 节点文件..."
        rm -f "$YAML_NODES_FILE"
    fi
    
    if [ -f "$NODES_META_FILE" ]; then
        info "正在删除节点元数据..."
        rm -f "$NODES_META_FILE"
    fi
    
    # 删除配置目录（如果为空）
    if [ -d "$(dirname "$XRAY_CONFIG_PATH")" ]; then
        rmdir --ignore-fail-on-non-empty "$(dirname "$XRAY_CONFIG_PATH")" 2>/dev/null || true
    fi
    
    # 删除 GeoIP/GeoSite 数据文件
    if [ -d /usr/local/share/xray ]; then
        info "正在删除 GeoIP/GeoSite 数据文件..."
        rm -rf /usr/local/share/xray
    fi
    
    # 删除全局命令
    if [ -f /usr/local/bin/xrm ]; then
        info "正在删除全局命令 xrm..."
        rm -f /usr/local/bin/xrm
    fi
    
    success "Xray 已完全卸载！"
    success "再见！"
    exit 0
}

# --- 重启服务 ---
restart_xray() {
    info "正在重启 Xray 服务..."
    
    if [ "$OS_TYPE" = "debian" ]; then
        systemctl restart xray
        sleep 2
        if systemctl is-active --quiet xray; then
            success "Xray 服务已重启"
        else
            error "Xray 服务启动失败，请检查配置"
            journalctl -u xray -n 20 --no-pager
            return 1
        fi
    elif [ "$OS_TYPE" = "alpine" ]; then
        rc-service xray restart
        sleep 2
        if rc-service xray status >/dev/null 2>&1; then
            success "Xray 服务已重启"
        else
            error "Xray 服务启动失败，请检查配置"
            return 1
        fi
    fi
}

# --- 修改出口配置 ---
# --- 初始化出口配置文件 ---
init_outbound_profiles() {
    if [ ! -f "$OUTBOUND_PROFILES_FILE" ]; then
        echo '[]' > "$OUTBOUND_PROFILES_FILE"
    fi
}

# --- 保存 SS2022 出口配置 ---
save_ss2022_profile() {
    local name="$1" server="$2" port="$3" password="$4"
    local method="${5:-2022-blake3-aes-128-gcm}"
    
    init_outbound_profiles
    
    local temp
    temp=$(mktemp) || { error "创建临时文件失败"; return 1; }
    register_temp_file "$temp"
    
    # 检查是否已存在同名配置
    # 名称通过 jq 参数传入，避免引号等字符被当作 jq 代码。
    if jq -e --arg name "$name" '.[] | select(.name == $name)' "$OUTBOUND_PROFILES_FILE" >/dev/null 2>&1; then
        # 更新已存在的配置
        jq --arg name "$name" \
           --arg server "$server" \
           --arg port "$port" \
           --arg password "$password" \
           --arg method "$method" \
           'map(if .name == $name then {
               "name": $name,
               "server": $server,
               "port": $port,
               "password": $password,
               "method": $method
           } else . end)' "$OUTBOUND_PROFILES_FILE" > "$temp" && mv "$temp" "$OUTBOUND_PROFILES_FILE"
    else
        # 添加新配置
        jq --arg name "$name" \
           --arg server "$server" \
           --arg port "$port" \
           --arg password "$password" \
           --arg method "$method" \
           '. += [{
               "name": $name,
               "server": $server,
               "port": $port,
               "password": $password,
               "method": $method
           }]' "$OUTBOUND_PROFILES_FILE" > "$temp" && mv "$temp" "$OUTBOUND_PROFILES_FILE"
    fi
    
    if [ $? -eq 0 ]; then
        success "配置 '$name' 已保存"
    else
        error "保存配置失败"
        rm -f "$temp"
        return 1
    fi
}

# --- 应用 直连出口 配置 ---
apply_direct_outbound() {
    local temp
    temp=$(mktemp) || { error "创建临时文件失败"; return 1; }
    register_temp_file "$temp"

    jq '.outbounds = [
           {
               "tag": "direct",
               "protocol": "freedom"
           },
           {
               "tag": "block",
               "protocol": "blackhole"
           }
       ]' "$XRAY_CONFIG_PATH" > "$temp" && mv "$temp" "$XRAY_CONFIG_PATH"

    if [ $? -eq 0 ]; then
        success "已切换到直连出口"
        return 0
    else
        error "配置失败"
        rm -f "$temp"
        return 1
    fi
}

# --- 应用 SS2022 出口配置 ---
apply_ss2022_outbound() {
    local server="$1" port="$2" password="$3" method="${4:-2022-blake3-aes-128-gcm}"
    
    local temp
    temp=$(mktemp) || { error "创建临时文件失败"; return 1; }
    register_temp_file "$temp"
    
    jq --arg server "$server" \
       --arg port "$port" \
       --arg password "$password" \
       --arg method "$method" \
       '.outbounds = [
           {
               "tag": "proxy",
               "protocol": "shadowsocks",
               "settings": {
                   "address": $server,
                   "port": ($port | tonumber),
                   "method": $method,
                   "password": $password
               }
           },
           {
               "tag": "block",
               "protocol": "blackhole"
           }
       ]' "$XRAY_CONFIG_PATH" > "$temp" && mv "$temp" "$XRAY_CONFIG_PATH"
    
    if [ $? -eq 0 ]; then
        success "已切换到 SS2022 出口"
        info "服务器: $server:$port"
        return 0
    else
        error "配置失败"
        rm -f "$temp"
        return 1
    fi
}

# --- 查看已保存的 SS2022 配置 ---
list_ss2022_profiles() {
    init_outbound_profiles
    
    local count
    count=$(jq 'length' "$OUTBOUND_PROFILES_FILE")
    
    if [ "$count" -eq 0 ]; then
        info "暂无已保存的出口配置"
        return 1
    fi
    
    echo -e "\n${cyan}=== 已保存的 SS2022 出口配置 ===${none}\n"
    
    jq -r 'to_entries[] | "\(.key + 1)) \(.value.name) - \(.value.server):\(.value.port)"' "$OUTBOUND_PROFILES_FILE"
    
    return 0
}

# --- 选择并应用已保存的配置 ---
select_and_apply_profile() {
    if ! list_ss2022_profiles; then
        return 1
    fi
    
    local count
    count=$(jq 'length' "$OUTBOUND_PROFILES_FILE")
    
    echo
    read -r -p "请选择配置编号 [1-$count] (0 返回): " choice
    
    if [ "$choice" = "0" ]; then
        return 0
    fi
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
        error "无效的选择"
        return 1
    fi
    
    local index=$((choice - 1))
    local profile
    profile=$(jq -r ".[$index]" "$OUTBOUND_PROFILES_FILE")
    
    local name server port password method
    name=$(echo "$profile" | jq -r '.name')
    server=$(echo "$profile" | jq -r '.server')
    port=$(echo "$profile" | jq -r '.port')
    password=$(echo "$profile" | jq -r '.password')
    method=$(echo "$profile" | jq -r '.method // "2022-blake3-aes-128-gcm"')
    
    info "正在应用配置: $name"
    
    if apply_ss2022_outbound "$server" "$port" "$password" "$method"; then
        restart_xray
    fi
}

# --- 删除已保存的 SS2022 配置 ---
delete_ss2022_profile() {
    if ! list_ss2022_profiles; then
        return 1
    fi
    
    local count
    count=$(jq 'length' "$OUTBOUND_PROFILES_FILE")
    
    echo
    read -r -p "请选择要删除的配置编号 [1-$count] (0 返回): " choice
    
    if [ "$choice" = "0" ]; then
        return 0
    fi
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
        error "无效的选择"
        return 1
    fi
    
    local index=$((choice - 1))
    local profile
    profile=$(jq -r ".[$index]" "$OUTBOUND_PROFILES_FILE")
    
    local name
    name=$(echo "$profile" | jq -r '.name')
    
    # 二次确认
    read -r -p "确认删除配置 '$name'? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        info "已取消删除"
        return 0
    fi
    
    local temp
    temp=$(mktemp) || { error "创建临时文件失败"; return 1; }
    register_temp_file "$temp"
    
    jq "del(.[$index])" "$OUTBOUND_PROFILES_FILE" > "$temp" && mv "$temp" "$OUTBOUND_PROFILES_FILE"
    
    if [ $? -eq 0 ]; then
        success "配置 '$name' 已删除"
    else
        error "删除失败"
        rm -f "$temp"
        return 1
    fi
}

change_outbound() {
    while true; do
        echo -e "\n${cyan}=== 修改出口配置 ===${none}\n"
        echo
        echo "1) 直连出口"
        echo "=========================="
        echo "2) 添加出口"
        echo "3) 选择出口"
        echo "=========================="
        echo "4) 查看出口"
        echo "5) 删除出口"
        echo "0) 返回主菜单"
        echo

        read -r -p "请选择操作 [0-5]: " outbound_choice

        case "$outbound_choice" in
        1)
            # 直连出口
            info "正在配置直连出口..."
            if apply_direct_outbound; then
                restart_xray
            else
                return 1
            fi
            ;;
        2)
            # 添加新的 SS2022 出口
            info "添加 SS2022 出口"
            echo

            echo "1) 粘贴 SS2022 URI"
            echo "2) 手动填写"
            read -r -p "请选择配置方式 [1-2]: " profile_input_mode

            local ss_name ss_server ss_port ss_password ss_method
            if [ "$profile_input_mode" = "1" ]; then
                read -r -p "请粘贴 SS2022 URI: " ss_uri
                parse_ss2022_uri "$ss_uri" || continue
                ss_server="$URI_SERVER"
                ss_port="$URI_PORT"
                ss_password="$URI_PASSWORD"
                ss_method="$URI_METHOD"
                read -r -p "配置名称 (用于保存，默认: ss-${ss_port}): " ss_name
                [ -z "$ss_name" ] && ss_name="ss-${ss_port}"
            elif [ "$profile_input_mode" = "2" ]; then
                read -r -p "配置名称 (用于保存): " ss_name
                if [ -z "$ss_name" ]; then
                    error "配置名称不能为空"
                    continue
                fi
                read -r -p "服务器地址: " ss_server
                if [ -z "$ss_server" ]; then
                    error "服务器地址不能为空"
                    continue
                fi

                echo "1) 2022-blake3-aes-128-gcm"
                echo "2) 2022-blake3-aes-256-gcm"
                echo "3) 2022-blake3-chacha20-poly1305"
                read -r -p "请选择加密方式 [1-3，默认: 1]: " ss_method
                case "${ss_method:-1}" in
                    1)
                        ss_method="2022-blake3-aes-128-gcm"
                        ;;
                    2)
                        ss_method="2022-blake3-aes-256-gcm"
                        ;;
                    3)
                        ss_method="2022-blake3-chacha20-poly1305"
                        ;;
                    *)
                        error "无效的加密方式，请输入 1-3"
                        continue
                        ;;
                esac

                read -r -p "端口: " ss_port
                if [ -z "$ss_port" ] || ! [[ "$ss_port" =~ ^[0-9]+$ ]] || [ "$ss_port" -lt 1 ] || [ "$ss_port" -gt 65535 ]; then
                    error "无效的端口号"
                    continue
                fi
                read -r -s -p "密码: " ss_password
                echo
                if [ -z "$ss_password" ]; then
                    error "密码不能为空"
                    continue
                fi
                validate_ss2022_password "$ss_method" "$ss_password" || continue
            else
                error "无效的配置方式"
                continue
            fi

            info "加密方法: $ss_method"
            if save_ss2022_profile "$ss_name" "$ss_server" "$ss_port" "$ss_password" "$ss_method"; then
                info "配置已保存，请使用选项 3 选择并应用配置"
            fi
            ;;
        3)
            # 选择已保存的配置
            select_and_apply_profile
            ;;
        4)
            # 查看已保存的配置
            list_ss2022_profiles
            ;;
        5)
            # 删除已保存的配置
            delete_ss2022_profile
            ;;
        0)
            return 0
            ;;
        *)
            error "无效的选择"
            ;;
        esac
    done
}

# --- 节点管理菜单 ---
manage_nodes() {
    while true; do
        echo -e "\n${cyan}=== 管理节点 ===${none}\n"
        echo "1) 查看节点"
        echo "2) 删除节点"
        echo "0) 返回主菜单"
        echo

        local node_management_choice
        read -r -p "请选择操作 [0-2]: " node_management_choice

        case "$node_management_choice" in
        1)
            list_nodes
            ;;
        2)
            delete_node
            ;;
        0)
            return 0
            ;;
        *)
            error "无效的选择"
            ;;
        esac
    done
}

# --- 新增节点菜单 ---
add_node_menu() {
    while true; do
        echo -e "\n${cyan}=== 新增节点 ===${none}\n"
        echo "1) SS2022 节点"
        echo "2) vless reality vision 节点"
        echo "0) 返回主菜单"
        echo

        local node_choice
        read -r -p "请选择节点类型 [0-2]: " node_choice

        case "$node_choice" in
        1)
            add_ss2022_node && restart_xray
            ;;
        2)
            add_reality_node && restart_xray
            ;;
        0)
            return 0
            ;;
        *)
            error "无效的选择"
            ;;
        esac
    done
}

# --- Xray 管理菜单 ---
manage_xray() {
    while true; do
        echo -e "\n${cyan}=== 管理 Xray ===${none}\n"
        echo "1) 升级 Xray"
        echo "2) 重启 Xray"
        echo "3) 查看状态"
        echo "4) 更新 GeoIP&GeoSite"
        echo "5) 卸载 Xray"
        echo "0) 返回主菜单"
        echo

        local management_choice
        read -r -p "请选择操作 [0-5]: " management_choice

        case "$management_choice" in
            1)
                upgrade_xray
                ;;
            2)
                restart_xray
                ;;
            3)
                show_status
                ;;
            4)
                update_geo_data && restart_xray
                ;;
            5)
                uninstall_xray
                ;;
            0)
                return 0
                ;;
            *)
                error "无效的选择"
                ;;
        esac
    done
}

# --- 安装全局命令 ---
install_global_command() {
    local target="/usr/local/bin/xrm"
    local script_url="https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/xray_mini.sh"
    
    # 检查是否已安装
    if [ -f "$target" ] && [ -x "$target" ]; then
        success "全局命令 xrm 已安装"
        return 0
    fi
    
    info "正在安装全局命令 xrm..."
    
    local tmpfile
    tmpfile=$(mktemp "${target}.tmp.XXXXXX") || {
        error "创建临时文件失败"
        return 1
    }
    register_temp_file "$tmpfile"

    # 先下载并校验，成功后再替换目标文件
    if ! curl -fsSL "$script_url" -o "$tmpfile"; then
        rm -f "$tmpfile"
        error "全局命令安装失败"
        return 1
    fi

    if ! verify_github_file_digest "$tmpfile" \
        "https://api.github.com/repos/makemecoffee/quick_installation/contents/xray_mini.sh?ref=master"; then
        rm -f "$tmpfile"
        return 1
    fi

    if ! chmod 755 "$tmpfile" || ! mv -f "$tmpfile" "$target"; then
        rm -f "$tmpfile"
        error "安装全局命令失败"
        return 1
    fi

    rm -f "$tmpfile"
    success "全局命令安装成功！"
    info "现在可以在任何目录使用 xrm 命令"
}

# --- 更新全局脚本 ---
update_script() {
    local target="/usr/local/bin/xrm"
    local script_url="https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/xray_mini.sh"
    local tmpfile

    info "正在检查并更新全局命令 xrm..."

    tmpfile=$(mktemp "${target}.tmp.XXXXXX") || {
        error "创建临时文件失败"
        return 1
    }
    register_temp_file "$tmpfile"

    if ! curl -fsSL "$script_url" -o "$tmpfile"; then
        rm -f "$tmpfile"
        error "下载脚本失败"
        return 1
    fi

    if ! verify_github_file_digest "$tmpfile" \
        "https://api.github.com/repos/makemecoffee/quick_installation/contents/xray_mini.sh?ref=master"; then
        rm -f "$tmpfile"
        return 1
    fi

    if ! chmod 755 "$tmpfile" || ! mv -f "$tmpfile" "$target"; then
        rm -f "$tmpfile"
        error "更新全局命令失败"
        return 1
    fi

    rm -f "$tmpfile"
    success "全局命令 xrm 更新成功！"
    info "下次执行 xrm 时将使用最新脚本"
}

# --- 主菜单 ---
show_menu() {
    echo -e "\n${cyan}=== Xray 快速安装脚本 ===${none}"
    
    # 获取 Xray 版本并显示
    if [ -f "$XRAY_BINARY_PATH" ]; then
        local xray_version
        xray_version=$("$XRAY_BINARY_PATH" version 2>/dev/null | head -n 1 | awk '{print $2}')
        if [ -n "$xray_version" ]; then
            echo -e "${magenta}Xray 版本: ${xray_version}${none}\n"
        else
            echo ""
        fi
    else
        echo ""
    fi
    
    echo "1) 新增节点"
    echo "2) 管理节点"
    echo "3) 管理出口"
    echo "4) 管理 Xray"
    echo "5) 更新脚本"
    echo "0) 退出脚本"
    echo
}

# --- 查看服务状态 ---
show_status() {
    if [ "$OS_TYPE" = "debian" ]; then
        systemctl status xray --no-pager
    elif [ "$OS_TYPE" = "alpine" ]; then
        rc-service xray status
    fi
}

# --- 主函数 ---
main() {
    umask 077
    trap cleanup_temp_files EXIT
    trap 'cleanup_temp_files; exit 130' INT TERM

    check_root
    detect_os
    check_dependencies || exit 1
    
    # 安装 Xray
    install_xray || exit 1
    
    # 初始化配置
    init_config || exit 1

    chmod 600 "$XRAY_CONFIG_PATH" "$YAML_NODES_FILE" "$NODES_META_FILE" "$OUTBOUND_PROFILES_FILE" 2>/dev/null || true

    # 仅在启动时确保一次路由策略
    ensure_routing_policy || exit 1
    
    # 第一次运行时安装全局命令
    if [ ! -f "/usr/local/bin/xrm" ]; then
        install_global_command
    fi
    
    # 主循环
    while true; do
        show_menu
        read -r -p "请选择操作 [0-5]: " choice
        
        case $choice in
            1)
                add_node_menu
                ;;
            2)
                manage_nodes
                ;;
            3)
                change_outbound
                ;;
            4)
                manage_xray
                ;;
            5)
                update_script
                ;;
            0)
                success "退出脚本"
                exit 0
                ;;
            *)
                error "无效的选择"
                ;;
        esac
    done
}

# --- 脚本入口 ---
main "$@"
