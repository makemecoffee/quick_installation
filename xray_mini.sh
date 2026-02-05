#!/usr/bin/env bash

# --- 颜色定义 ---
readonly red='\e[91m' green='\e[92m' yellow='\e[93m'
readonly magenta='\e[95m' cyan='\e[96m' none='\e[0m'
# --- 提示函数 ---
error() { echo -e "\n${red}$1${none}\n" >&2; }
info() { echo -e "\n${yellow}$1${none}\n"; }
success() { echo -e "\n${green}$1${none}\n"; }
# --- 全局变量 ---
SERVER_IP=""
OS_TYPE=""
# ---路径常量 ---
readonly XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"
readonly XRAY_BINARY_PATH="/usr/local/bin/xray"
readonly YAML_NODES_FILE="/usr/local/etc/xray/clash_nodes.yaml"
readonly NODES_META_FILE="/usr/local/etc/xray/nodes_meta.json"

# --- 检查是否为 root 用户 ---
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "错误: 需要 root 权限运行此脚本"
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
        info "正在安装缺失的依赖: ${missing_deps[*]}"
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
        success "依赖安装完成"
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
    info "正在获取 Xray 最新版本..."
    local version
    version=$(curl -s --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name | sed 's/^v//')
    
    if [ -z "$version" ] || [ "$version" = "null" ]; then
        error "获取 Xray 版本号失败，请检查网络连接"
        return 1
    fi

    info "最新版本: v${version}"
    
    # 调用下载和安装函数
    download_and_install_xray "$version" || return 1
    
    # 下载 GeoIP / GeoSite 数据文件
    info "正在下载 GeoIP / GeoSite 数据文件..."
    
    if ! curl -fsSL --max-time 120 -o /usr/local/share/xray/geoip.dat \
        https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat; then
        error "下载 geoip.dat 失败"
        return 1
    fi
    
    if ! curl -fsSL --max-time 120 -o /usr/local/share/xray/geosite.dat \
        https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat; then
        error "下载 geosite.dat 失败"
        return 1
    fi
    
    # 创建系统服务
    create_service || return 1
    
    success "Xray 安装完成！"
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

    # 下载 - 使用 curl
    local url="https://github.com/XTLS/Xray-core/releases/download/v${version}/Xray-linux-${arch}.zip"
    info "正在下载 Xray-core v${version} ..."
    
    if ! curl -fL --progress-bar --max-time 300 -o "$tmpdir/xray.zip" "$url"; then
        error "下载失败: $url"
        rm -rf "$tmpdir"
        return 1
    fi
    
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
        error "无法获取当前版本，请先安装 Xray"
        return 1
    fi
    
    info "当前版本: v${current_version}"
    
    # 获取最新版本
    info "正在获取最新版本..."
    local latest_version
    latest_version=$(curl -s --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name | sed 's/^v//')
    
    if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
        error "获取最新版本失败，请检查网络连接"
        return 1
    fi
    
    info "最新版本: v${latest_version}"
    
    # 比较版本
    if [ "$current_version" = "$latest_version" ]; then
        success "已经是最新版本 v${current_version}"
        return 0
    fi
    
    # 确认升级
    read -p "发现新版本 v${latest_version}，是否升级? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        info "已取消升级"
        return 0
    fi
    
    info "开始升级 Xray 从 v${current_version} 到 v${latest_version} ..."
    
    # 停止服务
    if [ "$OS_TYPE" = "debian" ]; then
        if systemctl is-active --quiet xray 2>/dev/null; then
            info "正在停止 Xray 服务..."
            systemctl stop xray
        fi
    elif [ "$OS_TYPE" = "alpine" ]; then
        if rc-service xray status >/dev/null 2>&1; then
            info "正在停止 Xray 服务..."
            rc-service xray stop 2>/dev/null || true
        fi
    fi
    
    # 下载并安装新版本
    if download_and_install_xray "$latest_version"; then
        success "升级成功！"
        
        # 询问是否重启服务
        read -p "是否重启 Xray 服务? [Y/n]: " restart_choice
        if [[ ! "$restart_choice" =~ ^[Nn]$ ]]; then
            restart_xray
        fi
    else
        error "升级失败"
        return 1
    fi
}

# --- 获取服务器地址（IP 或域名）---
get_server_address() {
    if [ -n "$SERVER_IP" ]; then
        # 如果已经设置过，询问是否继续使用
        read -p "继续使用之前的地址 ($SERVER_IP)? [Y/n]: " reuse
        if [[ ! "$reuse" =~ ^[Nn]$ ]]; then
            return 0
        fi
    fi
    
    info "正在获取出口 IP..."
    local detected_ip
    detected_ip=$(curl -s4 --max-time 3 ip.sb 2>/dev/null || curl -s4 --max-time 3 ifconfig.me 2>/dev/null || echo "")
    
    if [ -z "$detected_ip" ]; then
        detected_ip=$(curl -s6 --max-time 3 ip.sb 2>/dev/null || curl -s6 --max-time 3 ifconfig.me 2>/dev/null || echo "")
    fi
    
    if [ -n "$detected_ip" ]; then
        info "检测到服务器 IP: $detected_ip"
    fi
    
    read -p "使用 1)IP , 2)域名  [1/2]: " use_domain
    
    if [ "$use_domain" = "2" ]; then
        read -p "请输入域名: " DOMAIN
        
        if [ -z "$DOMAIN" ]; then
            error "域名不能为空"
            return 1
        fi
        
        SERVER_IP="$DOMAIN"
        success "使用域名: $SERVER_IP"
    else
        if [ -n "$detected_ip" ]; then
            read -p "使用检测到的 IP ($detected_ip)? [Y/n]: " use_detected
            if [[ ! "$use_detected" =~ ^[Nn]$ ]]; then
                SERVER_IP="$detected_ip"
            else
                read -p "请输入服务器 IP: " SERVER_IP
                if [ -z "$SERVER_IP" ]; then
                    error "IP 地址不能为空"
                    return 1
                fi
            fi
        else
            read -p "请输入服务器 IP: " SERVER_IP
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
    read -p "使用 1)IP , 2)域名  [1/2]: " use_domain
    
    if [ "$use_domain" = "2" ]; then
        read -p "请输入域名: " DOMAIN
        
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
        error "未知的操作系统类型: $OS_TYPE"
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
    
    cat > /etc/systemd/system/xray.service <<'EOF'
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

    systemctl daemon-reload
    systemctl enable xray
    
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
    mkdir -p /var/log/xray
    
    cat > /etc/init.d/xray <<'EOF'
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

    chmod +x /etc/init.d/xray
    rc-update add xray default
    
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
                "protocol": "freedom",
                "settings": {
                    "domainStrategy": "AsIs"
                }
            }
        ]
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
# Clash 节点配置
# 复制下方节点配置到 Clash 配置文件的 proxies 部分

EOF
        success "YAML 节点文件已创建: $YAML_NODES_FILE"
    fi
    
    # 初始化节点元数据文件
    if [ ! -f "$NODES_META_FILE" ]; then
        echo '{"nodes":[]}' > "$NODES_META_FILE"
        success "节点元数据文件已创建: $NODES_META_FILE"
    fi
}

# --- 保存节点元数据 ---
save_node_meta() {
    local tag="$1"
    local share_link="$2"
    local yaml_config="$3"
    
    # 确保元数据文件存在
    if [ ! -f "$NODES_META_FILE" ]; then
        echo '{"nodes":[]}' > "$NODES_META_FILE"
    fi
    
    local temp
    temp=$(mktemp) || {
        error "创建临时文件失败"
        return 1
    }
    
    jq --arg tag "$tag" \
       --arg link "$share_link" \
       --arg yaml "$yaml_config" \
       --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.nodes += [{
           "tag": $tag,
           "share_link": $link,
           "yaml_config": $yaml,
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

# --- 生成随机端口 ---
generate_port() {
    local port
    while true; do
        port=$((RANDOM % 55535 + 10000))
        if ! ss -tuln 2>/dev/null | grep -q ":$port "; then
            echo "$port"
            return 0
        fi
    done
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
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 16 2>/dev/null
    else
        head -c 16 /dev/urandom | base64 | tr -d '\n'
    fi
}

# --- 生成 Reality 密钥对 ---
generate_reality_keypair() {
    local output
    local exit_code
    
    set +e
    output=$("$XRAY_BINARY_PATH" x25519 2>&1)
    exit_code=$?
    set -e
    
    if [ $exit_code -ne 0 ]; then
        error "生成 Reality 密钥失败 (退出码: $exit_code)"
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

# --- 添加 Shadowsocks 2022 节点 ---
add_ss2022_node() {
    # 获取服务器地址
    get_server_address || return 1
    
    local tag port password method
    
    # 端口自定义
    read -p "请输入端口 (默认: 443): " port
    if [ -z "$port" ]; then
        port=443
        info "使用默认端口: $port"
    else
        # 验证端口号
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            error "无效的端口号"
            return 1
        fi
        info "使用自定义端口: $port"
    fi
    
    # 节点标签
    read -p "请输入节点标签 (默认: ss-${port}): " tag
    [ -z "$tag" ] && tag="ss-${port}"
    
    # 密码自定义
    read -p "请输入密码 (留空自动生成): " password
    if [ -z "$password" ]; then
        password=$(generate_ss2022_key)
        info "自动生成密码: $password"
    else
        info "使用自定义密码"
    fi
    
    method="2022-blake3-aes-128-gcm"
    info "加密方法: $method"
    
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
    temp=$(mktemp)
    jq --argjson inbound "$inbound" \
        '.inbounds += [$inbound]' "$XRAY_CONFIG_PATH" > "$temp" && \
        mv "$temp" "$XRAY_CONFIG_PATH"
    
    # 生成分享链接
    local share_link="ss://$(echo -n "${method}:${password}" | base64 -w 0)@${SERVER_IP}:${port}#${tag}"
    
    # 生成 YAML 配置 - 单行紧凑格式
    local yaml_config="- {name: ${tag}, type: ss, server: ${SERVER_IP}, port: ${port}, cipher: ${method}, password: ${password}, udp: true}"
    
    # 保存节点信息
    save_node_meta "$tag" "$share_link" "$yaml_config"
    
    # 追加到 YAML 文件
    echo "$yaml_config" >> "$YAML_NODES_FILE"
    
    success "Shadowsocks 2022 节点添加成功！"
    echo -e "\n${cyan}分享链接:${none}\n${share_link}\n"
    echo -e "${cyan}Clash 配置:${none}\n${yaml_config}\n"
}

# --- 添加 VLESS Reality 节点 ---
add_reality_node() {
    # 获取服务器地址
    get_server_address || return 1
    
    local tag port uuid dest sni private_key public_key short_id
    
    # 端口自定义
    read -p "端口 (默认: 443): " port
    if [ -z "$port" ]; then
        port=443
        info "默认端口: $port"
    else
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            error "无效的端口号"
            return 1
        fi
        info "自定义端口: $port"
    fi
    
    # 节点标签
    read -p "请输入节点标签 (默认: vvr-${port}): " tag
    [ -z "$tag" ] && tag="vvr-${port}"
    
    # UUID 自定义
    read -p "请输入 UUID (留空自动生成): " uuid
    if [ -z "$uuid" ]; then
        set +e
        uuid=$(generate_uuid)
        local uuid_exit=$?
        set -e
        
        if [ $uuid_exit -ne 0 ] || [ -z "$uuid" ]; then
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
    
    set +e
    local keypair
    keypair=$("$XRAY_BINARY_PATH" x25519 2>&1)
    local keypair_exit=$?
    set -e
    
    if [ $keypair_exit -ne 0 ] || [ -z "$keypair" ]; then
        error "xray x25519 命令执行失败"
        return 1
    fi
    
    # 从输出中提取所有字段
    # xray x25519 输出格式:
    # PrivateKey: xxx
    # Password: xxx  (这实际上是服务端需要用的)
    # Hash32: xxx    (这实际上是客户端需要的公钥)
    
    private_key=$(echo "$keypair" | grep "^PrivateKey:" | awk '{print $2}')
    
    # Reality 中，客户端使用的 PublicKey 实际上对应 xray x25519 输出的某个字段
    # 尝试多种可能的字段名
    public_key=$(echo "$keypair" | grep -E "^(PublicKey|Password):" | tail -n 1 | awk '{print $2}')
    
    if [ -z "$public_key" ]; then
        # 如果还是没有，使用 Password 字段
        public_key=$(echo "$keypair" | grep "^Password:" | awk '{print $2}')
    fi
    
    if [ -z "$private_key" ]; then
        error "无法解析 PrivateKey"
        echo "原始输出:"
        echo "$keypair"
        return 1
    fi
    
    if [ -z "$public_key" ]; then
        error "无法解析 PublicKey/Password"
        echo "原始输出:"
        echo "$keypair"
        return 1
    fi
    
    info "私钥 (PrivateKey): $private_key"
    info "公钥 (PublicKey): $public_key"
    
    # 域名自定义
    read -p "SNI (默认: www.microsoft.com): " domain
    [ -z "$domain" ] && domain="www.microsoft.com"
    
    # Short ID 自定义
    read -p "请输入 Short ID (留空自动生成): " short_id
    if [ -z "$short_id" ]; then
        if command -v openssl >/dev/null 2>&1; then
            short_id=$(openssl rand -hex 4)
        else
            short_id=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
        fi
        info "Short ID: $short_id"
    else
        # 验证 Short ID 格式：1-16位十六进制字符
        if ! [[ "$short_id" =~ ^[0-9a-f]{1,16}$ ]]; then
            error "无效的 Short ID  (需要1-16位十六进制字符)"
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
        --arg private_key "$private_key" \
        --arg short_id "$short_id" \
        '{
            "tag": $tag,
            "listen": "::",
            "port": ($port | tonumber),
            "protocol": "vless",
            "settings": {
                "clients": [{
                    "id": $uuid,
                    "flow": "xtls-rprx-vision"
                }],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": ($domain + ":443"),
                    "xver": 0,
                    "serverNames": [$domain],
                    "privateKey": $private_key,
                    "shortIds": [$short_id]
                }
            }
        }')
    
    # 添加到配置文件
    local temp
    temp=$(mktemp)
    jq --argjson inbound "$inbound" \
        '.inbounds += [$inbound]' "$XRAY_CONFIG_PATH" > "$temp" && \
        mv "$temp" "$XRAY_CONFIG_PATH"
    
    # 生成分享链接
    local share_link="vless://${uuid}@${SERVER_IP}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#${tag}"
    
    # 生成 YAML 配置 - 单行紧凑格式
    local yaml_config="- {name: ${tag}, type: vless, server: ${SERVER_IP}, port: ${port}, uuid: ${uuid}, udp: true, tls: true, network: tcp, flow: xtls-rprx-vision, servername: ${domain}, client-fingerprint: chrome, reality-opts: {public-key: ${public_key}, short-id: ${short_id}}}"
    
    # 保存节点信息
    save_node_meta "$tag" "$share_link" "$yaml_config"
    
    # 追加到 YAML 文件
    echo "$yaml_config" >> "$YAML_NODES_FILE"
    
    success "VLESS Reality 节点添加成功！"
    echo -e "\n${cyan}分享链接:${none}\n${share_link}\n"
    echo -e "${cyan}Clash 配置:${none}\n${yaml_config}\n"
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
        echo -e "${cyan}分享链接:${none}"
        echo "$share_link"
        echo -e "${cyan}Clash 配置:${none}"
        echo "$yaml_config"
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
    read -p "请输入要删除的节点序号: " choice
    
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
    read -p "确认删除节点 '${delete_tag}' ? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        info "已取消删除"
        return 0
    fi
    
    info "正在删除节点 '${delete_tag}'..."
    
    # 从 Xray 配置中删除 inbound
    local temp
    temp=$(mktemp)
    
    jq --arg tag "$delete_tag" \
        'del(.inbounds[] | select(.tag == $tag))' \
        "$XRAY_CONFIG_PATH" > "$temp" && mv "$temp" "$XRAY_CONFIG_PATH"
    
    if [ $? -ne 0 ]; then
        error "从 Xray 配置删除失败"
        rm -f "$temp"
        return 1
    fi
    
    # 从元数据文件中删除节点
    temp=$(mktemp)
    
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
# Clash 节点配置
# 复制下方节点配置到 Clash 配置文件的 proxies 部分

EOF
    
    jq -r '.nodes[].yaml_config' "$NODES_META_FILE" 2>/dev/null >> "$YAML_NODES_FILE"
    
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
    
    read -p "确认完全卸载 Xray? [Y/n]: " confirm
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
change_outbound() {
    echo -e "\n${cyan}=== 修改出口配置 ===${none}\n"
    echo "1) 直连 (Freedom)"
    echo "2) Shadowsocks 2022"
    echo "0) 返回主菜单"
    echo
    
    read -p "请选择出口类型 [0-2]: " outbound_choice
    
    case $outbound_choice in
        1)
            # 直连出口
            info "正在配置直连出口..."
            local temp
            temp=$(mktemp)
            
            jq '.outbounds = [{
                "protocol": "freedom",
                "settings": {
                    "domainStrategy": "AsIs"
                }
            }]' "$XRAY_CONFIG_PATH" > "$temp" && mv "$temp" "$XRAY_CONFIG_PATH"
            
            if [ $? -eq 0 ]; then
                success "已切换到直连出口"
                restart_xray
            else
                error "配置失败"
                rm -f "$temp"
                return 1
            fi
            ;;
        2)
            # SS2022 出口
            info "配置 Shadowsocks 2022 出口"
            echo
            
            local ss_server ss_port ss_password ss_method
            
            read -p "服务器地址: " ss_server
            if [ -z "$ss_server" ]; then
                error "服务器地址不能为空"
                return 1
            fi
            
            read -p "请输入端口: " ss_port
            if [ -z "$ss_port" ] || ! [[ "$ss_port" =~ ^[0-9]+$ ]] || [ "$ss_port" -lt 1 ] || [ "$ss_port" -gt 65535 ]; then
                error "无效的端口号"
                return 1
            fi
            
            read -p "请输入密码: " ss_password
            if [ -z "$ss_password" ]; then
                error "密码不能为空"
                return 1
            fi
            
            # 固定使用 2022-blake3-aes-128-gcm
            ss_method="2022-blake3-aes-128-gcm"
            info "加密方法: $ss_method"
            
            info "正在配置 SS2022 出口..."
            local temp
            temp=$(mktemp)
            
            jq --arg server "$ss_server" \
               --arg port "$ss_port" \
               --arg password "$ss_password" \
               --arg method "$ss_method" \
               '.outbounds = [{
                   "protocol": "shadowsocks",
                   "settings": {
                       "servers": [{
                           "address": $server,
                           "port": ($port | tonumber),
                           "method": $method,
                           "password": $password
                       }]
                   }
               }]' "$XRAY_CONFIG_PATH" > "$temp" && mv "$temp" "$XRAY_CONFIG_PATH"
            
            if [ $? -eq 0 ]; then
                success "已切换到 SS2022 出口"
                info "上游服务器: $ss_server:$ss_port"
                restart_xray
            else
                error "配置失败"
                rm -f "$temp"
                return 1
            fi
            ;;
        0)
            info "返回主菜单"
            return 0
            ;;
        *)
            error "无效的选择"
            return 1
            ;;
    esac
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
    
    # 下载脚本到 /usr/local/bin/xrm
    if curl -fsSL "$script_url" -o "$target"; then
        # 确保有执行权限
        chmod +x "$target"
        # 验证权限
        if [ -x "$target" ]; then
            success "✓ 全局命令 xrm 安装成功！"
            info "现在可以在任何目录使用 xrm 命令"
        else
            error "设置执行权限失败"
            return 1
        fi
    else
        error "全局命令安装失败"
        return 1
    fi
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
    
    echo "1) 添加 Shadowsocks 2022 节点"
    echo "2) 添加 VLESS Reality 节点"
    echo "------------------------------------"
    echo "3) 查看节点"
    echo "4) 删除节点"
    echo "------------------------------------"
    echo "5) 出口配置"
    echo "------------------------------------"
    echo "6) 升级 Xray"
    echo "7) 重启 Xray"
    echo "8) 查看状态"
    echo "9) 卸载 Xray"
    echo "------------------------------------"
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
    check_root
    detect_os
    check_dependencies
    
    # 安装 Xray
    install_xray || exit 1
    
    # 初始化配置
    init_config || exit 1
    
    # 第一次运行时安装全局命令
    if [ ! -f "/usr/local/bin/xrm" ]; then
        install_global_command
    fi
    
    # 主循环
    while true; do
        show_menu
        read -p "请选择操作 [0-9]: " choice
        
        case $choice in
            1)
                add_ss2022_node && restart_xray
                ;;
            2)
                add_reality_node && restart_xray
                ;;
            3)
                list_nodes
                ;;
            4)
                delete_node
                ;;
            5)
                change_outbound
                ;;
            6)
                upgrade_xray
                ;;
            7)
                restart_xray
                ;;
            8)
                show_status
                ;;
            9)
                uninstall_xray
                ;;
            0)
                success "退出脚本"
                exit 0
                ;;
            *)
                error "无效的选择"
                ;;
        esac
        
        read -p "按回车键继续..." 
    done
}

# --- 脚本入口 ---
main "$@"