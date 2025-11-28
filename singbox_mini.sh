#!/bin/bash

# ==============================================
# sing-box 轻量化一键安装脚本
# 支持协议: VLESS-REALITY, Hysteria2, TUICv5, Shadowsocks-2022
# 支持系统: Debian, Ubuntu, Alpine
# ==============================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 路径常量 ---
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_DIR="/usr/local/etc/sing-box"
CONFIG_FILE="${SINGBOX_DIR}/config.json"
YAML_NODES_FILE="${SINGBOX_DIR}/clash_nodes.yaml"
NODES_META_FILE="${SINGBOX_DIR}/nodes_meta.json" 
SERVICE_FILE="/etc/systemd/system/sing-box.service"
SCRIPT_VERSION="1.1"
SCRIPT_PATH="/usr/local/bin/sbm" 

# --- 全局变量 ---
SERVER_IP=""
OS_TYPE=""

# --- 工具函数 ---
_info() { echo -e "${CYAN}$1${NC}"; }
_success() { echo -e "${GREEN}$1${NC}"; }
_warning() { echo -e "${YELLOW}$1${NC}"; }
_error() { echo -e "${RED}$1${NC}"; exit 1; }

_check_root() {
    [ "$(id -u)" -ne 0 ] && _error "错误: 需要 root 权限运行此脚本"
}

_detect_os() {
    if [ -f /etc/alpine-release ]; then
        OS_TYPE="alpine"
    elif grep -qi "debian\|ubuntu" /etc/os-release; then
        OS_TYPE="debian"
    else
        _error "不支持的操作系统"
    fi
    _info "检测到系统: ${OS_TYPE}"
}

_get_public_ip() {
    _info "正在获取公网 IP..."
    SERVER_IP=$(curl -s4 --max-time 3 ip.sb 2>/dev/null || curl -s4 --max-time 3 ifconfig.me 2>/dev/null || true)
    [ -z "$SERVER_IP" ] && SERVER_IP=$(curl -s6 --max-time 3 ip.sb 2>/dev/null || curl -s6 --max-time 3 ifconfig.me 2>/dev/null || true)
    
    if [ -z "$SERVER_IP" ]; then
        _warning "警告: 无法自动获取公网 IP"
        read -p "请手动输入服务器公网 IP: " SERVER_IP
        [ -z "$SERVER_IP" ] && _error "IP 地址不能为空"
    fi
    
    _success "公网 IP: ${SERVER_IP}"
}


# 验证端口号
_validate_port() {
    local port="$1"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        _error "无效的端口号: ${port} (有效范围: 1-65535)"
    fi
    
    # 检查端口是否已被占用
    if jq -e ".inbounds[] | select(.listen_port == ${port})" "$CONFIG_FILE" >/dev/null 2>&1; then
        _error "端口 ${port} 已被使用，请选择其他端口"
    fi
}

# 验证 UUID 格式
_validate_uuid() {
    local uuid="$1"
    if ! [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        _error "无效的 UUID 格式: ${uuid}"
    fi
}

# 跨平台 base64 编码（无换行）
_base64_encode() {
    if command -v base64 &>/dev/null; then
        if base64 --help 2>&1 | grep -q -- '-w'; then
            # GNU base64
            echo -n "$1" | base64 -w0
        else
            # BSD/Alpine base64
            echo -n "$1" | base64 | tr -d '\n'
        fi
    else
        _error "base64 命令不可用"
    fi
}

_install_dependencies() {
    _info "检查依赖..."
    
    if [ "$OS_TYPE" = "alpine" ]; then
        # 检查 Alpine 依赖
        local missing_deps=()
        for pkg in curl jq openssl wget tar; do
            if ! apk info -e "$pkg" &>/dev/null; then
                missing_deps+=("$pkg")
            fi
        done
        
        if [ ${#missing_deps[@]} -eq 0 ]; then
            _success "所有依赖已安装"
            return
        fi
        
        _info "需要安装: ${missing_deps[*]}"
        apk update || _error "apk update 失败"
        apk add --no-cache "${missing_deps[@]}" || _error "依赖安装失败"
    else
        # 检查 Debian/Ubuntu 依赖
        local missing_deps=()
        for pkg in curl jq openssl wget; do
            if ! dpkg -l | grep -qw "^ii.*$pkg"; then
                missing_deps+=("$pkg")
            fi
        done
        
        if [ ${#missing_deps[@]} -eq 0 ]; then
            _success "所有依赖已安装"
            return
        fi
        
        _info "需要安装: ${missing_deps[*]}"
        apt-get update || _error "apt-get update 失败"
        apt-get install -y "${missing_deps[@]}" || _error "依赖安装失败"
    fi
    
    _success "依赖安装完成"
}

_install_singbox() {
    if [ -f "$SINGBOX_BIN" ]; then
        _info "sing-box 已安装: $(${SINGBOX_BIN} version | head -n1)"
        return
    fi

    _info "安装 sing-box..."
    local arch=$(uname -m)
    local arch_tag=""
    case $arch in
        x86_64|amd64) arch_tag="amd64" ;;
        aarch64|arm64) arch_tag="arm64" ;;
        armv7l) arch_tag="armv7" ;;
        *) _error "不支持的架构: $arch" ;;
    esac

    local download_url=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest \
        | jq -r ".assets[] | select(.name | contains(\"linux-${arch_tag}.tar.gz\")) | .browser_download_url")
    
    [ -z "$download_url" ] && _error "无法获取下载链接"
    
    wget -qO /tmp/singbox.tar.gz "$download_url" || _error "下载失败"
    tar -xzf /tmp/singbox.tar.gz -C /tmp || _error "解压失败"
    mv /tmp/sing-box-*/sing-box "$SINGBOX_BIN" || _error "安装失败"
    chmod +x "$SINGBOX_BIN"
    rm -rf /tmp/singbox.tar.gz /tmp/sing-box-*
    
    _success "sing-box 安装完成: $(${SINGBOX_BIN} version | head -n1)"
}

_create_service() {
    if [ "$OS_TYPE" = "alpine" ]; then
        # Alpine create OpenRC
        local openrc_file="/etc/init.d/sing-box"
        cat > "$openrc_file" << 'EOF'
#!/sbin/openrc-run

name="sing-box"
description="sing-box proxy service"

command="/usr/local/bin/sing-box"
command_args="run -c /usr/local/etc/sing-box/config.json"

supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() {
    need net
    after firewall
}

EOF
        chmod +x "$openrc_file"
        rc-update add sing-box default
        _success "OpenRC 服务已创建"
        return
    fi

    # create systemd （Debian/Ubuntu）
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=sing-box service
After=network.target

[Service]
Type=simple
User=root
ExecStart=${SINGBOX_BIN} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box
    _success "systemd 服务已创建"
}

_init_config() {
    mkdir -p "$SINGBOX_DIR"
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << 'EOF'
{
  "log": {
    "disabled": true
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
        _success "配置文件已初始化"
    fi
    
    # 初始化 YAML 节点文件
    if [ ! -f "$YAML_NODES_FILE" ]; then
        echo "# Clash 节点配置" > "$YAML_NODES_FILE"
        echo "# 复制下方节点配置到 Clash 配置文件的 proxies 部分" >> "$YAML_NODES_FILE"
        echo "" >> "$YAML_NODES_FILE"
    fi
    
    # 初始化节点元数据文件
    if [ ! -f "$NODES_META_FILE" ]; then
        echo '{"nodes":[]}' > "$NODES_META_FILE"
    fi
}

# 保存节点元数据
_save_node_meta() {
    local tag="$1"
    local share_link="$2"
    local yaml_config="$3"
    
    # 确保元数据文件存在
    if [ ! -f "$NODES_META_FILE" ]; then
        echo '{"nodes":[]}' > "$NODES_META_FILE"
    fi
    
    local temp=$(mktemp)
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
}

# 生成自签名证书（兼容方式）
_generate_self_signed_cert() {
    local cert_path="$1"
    local key_path="$2"
    local sni="$3"
    
    # 先生成 EC 参数文件
    local param_file=$(mktemp)
    openssl ecparam -name prime256v1 -out "$param_file" || {
        rm -f "$param_file"
        _error "生成 EC 参数失败"
    }
    
    # 使用参数文件生成证书
    openssl req -x509 -nodes -newkey ec:"$param_file" \
        -keyout "$key_path" -out "$cert_path" \
        -subj "/CN=${sni}" -days 3650 2>/dev/null || {
        rm -f "$param_file"
        _error "生成证书失败"
    }
    
    rm -f "$param_file"
}

_add_vless_reality() {
    clear
    _info "=== 添加 VLESS-REALITY 节点 ==="
    
    read -p "节点名称 (默认: vless-reality-443): " custom_tag
    
    read -p "监听端口 (默认: 443): " port
    port=${port:-443}
    _validate_port "$port"
    
    # 如果用户没有输入 tag，使用默认格式
    local tag="${custom_tag:-vless-reality-${port}}"
    
    read -p "伪装域名 (默认: www.microsoft.com): " sni
    sni=${sni:-www.microsoft.com}
    
    # UUID 可选手动输入
    local uuid=""
    while true; do
        read -p "UUID (回车自动生成): " uuid
        if [ -z "$uuid" ]; then
            uuid=$(${SINGBOX_BIN} generate uuid)
            _info "已自动生成 UUID: ${uuid}"
            break
        else
            if _validate_uuid "$uuid" 2>/dev/null; then
                break
            else
                _warning "UUID 格式错误，请重新输入或直接回车自动生成"
            fi
        fi
    done
    
    local keypair=$(${SINGBOX_BIN} generate reality-keypair)
    local private_key=$(echo "$keypair" | awk '/PrivateKey/ {print $2}')
    local public_key=$(echo "$keypair" | awk '/PublicKey/ {print $2}')
    local short_id=$(${SINGBOX_BIN} generate rand --hex 8)
    
    # 添加 inbound
    local temp=$(mktemp)
    jq --arg tag "$tag" \
       --argjson port "$port" \
       --arg uuid "$uuid" \
       --arg sni "$sni" \
       --arg priv_key "$private_key" \
       --arg short_id "$short_id" \
       '.inbounds += [{
           "type": "vless",
           "tag": $tag,
           "listen": "::",
           "listen_port": $port,
           "users": [{
               "uuid": $uuid,
               "flow": "xtls-rprx-vision"
           }],
           "tls": {
               "enabled": true,
               "server_name": $sni,
               "reality": {
                   "enabled": true,
                   "handshake": {
                       "server": $sni,
                       "server_port": 443
                   },
                   "private_key": $priv_key,
                   "short_id": [$short_id]
               }
           }
       }]' "$CONFIG_FILE" > "$temp" && mv "$temp" "$CONFIG_FILE"
    
    # 生成分享链接和 YAML（使用用户自定义的 tag）
    local share_link="vless://${uuid}@${SERVER_IP}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#${tag}"
    local yaml_config="- {name: ${tag}, type: vless, server: ${SERVER_IP}, port: ${port}, uuid: ${uuid}, udp: true, tls: true, network: tcp, flow: xtls-rprx-vision, servername: ${sni}, client-fingerprint: chrome, reality-opts: {public-key: ${public_key}, short-id: ${short_id}}}"
    
    _save_node_meta "$tag" "$share_link" "$yaml_config"
    echo "$yaml_config" >> "$YAML_NODES_FILE"
    
    _success "VLESS-REALITY 节点添加成功!"
    echo ""
    _info "节点名称: ${tag}"
    _info "分享链接:"
    echo -e "${YELLOW}${share_link}${NC}"
    echo ""
    _info "Clash YAML 配置:"
    echo -e "${GREEN}${yaml_config}${NC}"
    echo ""
    _info "配置已保存到: ${NODES_META_FILE}"
}

_add_hysteria2() {
    clear
    _info "=== 添加 Hysteria2 节点 ==="
    
    read -p "节点名称 (默认: hy2-端口): " custom_tag
    
    read -p "监听端口: " port
    [ -z "$port" ] && _error "端口不能为空"
    _validate_port "$port"
    
    local tag="${custom_tag:-hy2-${port}}"
    
    # 密码可选手动输入
    read -p "密码 (回车自动生成): " password
    if [ -z "$password" ]; then
        password=$(${SINGBOX_BIN} generate rand --hex 16)
        _info "已自动生成密码: ${password}"
    fi
    
    read -p "伪装域名 (默认: bing.com): " sni
    sni=${sni:-bing.com}
    
    local cert_path="${SINGBOX_DIR}/hy2-${port}.crt"
    local key_path="${SINGBOX_DIR}/hy2-${port}.key"
    
    _generate_self_signed_cert "$cert_path" "$key_path" "$sni"
    
    # 添加 inbound
    local temp=$(mktemp)
    jq --arg tag "$tag" \
       --argjson port "$port" \
       --arg password "$password" \
       --arg cert "$cert_path" \
       --arg key "$key_path" \
       '.inbounds += [{
           "type": "hysteria2",
           "tag": $tag,
           "listen": "::",
           "listen_port": $port,
           "users": [{"password": $password}],
           "tls": {
               "enabled": true,
               "alpn": ["h3"],
               "certificate_path": $cert,
               "key_path": $key
           }
       }]' "$CONFIG_FILE" > "$temp" && mv "$temp" "$CONFIG_FILE"
    
    local share_link="hysteria2://${password}@${SERVER_IP}:${port}?sni=${sni}&insecure=1#${tag}"
    local yaml_config="- {name: ${tag}, type: hysteria2, server: ${SERVER_IP}, port: ${port}, password: ${password}, udp: true, skip-cert-verify: true, sni: ${sni}}"
    
    _save_node_meta "$tag" "$share_link" "$yaml_config"
    echo "$yaml_config" >> "$YAML_NODES_FILE"
    
    _success "Hysteria2 节点添加成功!"
    echo ""
    _info "节点名称: ${tag}"
    _info "分享链接:"
    echo -e "${YELLOW}${share_link}${NC}"
    echo ""
    _info "Clash YAML 配置:"
    echo -e "${GREEN}${yaml_config}${NC}"
}

_add_tuic() {
    clear
    _info "=== 添加 TUICv5 节点 ==="
    
    read -p "节点名称 (默认: tuic-端口): " custom_tag
    
    read -p "监听端口: " port
    [ -z "$port" ] && _error "端口不能为空"
    _validate_port "$port"
    
    local tag="${custom_tag:-tuic-${port}}"
    
    # UUID 可选手动输入
    local uuid=""
    while true; do
        read -p "UUID (回车自动生成): " uuid
        if [ -z "$uuid" ]; then
            uuid=$(${SINGBOX_BIN} generate uuid)
            _info "已自动生成 UUID: ${uuid}"
            break
        else
            if _validate_uuid "$uuid" 2>/dev/null; then
                break
            else
                _warning "UUID 格式错误，请重新输入或直接回车自动生成"
            fi
        fi
    done
    
    # 密码可选手动输入
    read -p "密码 (回车自动生成): " password
    if [ -z "$password" ]; then
        password=$(${SINGBOX_BIN} generate rand --hex 16)
        _info "已自动生成密码: ${password}"
    fi
    
    read -p "伪装域名 (默认: bing.com): " sni
    sni=${sni:-bing.com}
    
    local cert_path="${SINGBOX_DIR}/tuic-${port}.crt"
    local key_path="${SINGBOX_DIR}/tuic-${port}.key"
    
    _generate_self_signed_cert "$cert_path" "$key_path" "$sni"
    
    # 添加 inbound
    local temp=$(mktemp)
    jq --arg tag "$tag" \
       --argjson port "$port" \
       --arg uuid "$uuid" \
       --arg password "$password" \
       --arg cert "$cert_path" \
       --arg key "$key_path" \
       '.inbounds += [{
           "type": "tuic",
           "tag": $tag,
           "listen": "::",
           "listen_port": $port,
           "users": [{
               "uuid": $uuid,
               "password": $password
           }],
           "congestion_control": "bbr",
           "tls": {
               "enabled": true,
               "alpn": ["h3"],
               "certificate_path": $cert,
               "key_path": $key
           }
       }]' "$CONFIG_FILE" > "$temp" && mv "$temp" "$CONFIG_FILE"
    
    local share_link="tuic://${uuid}:${password}@${SERVER_IP}:${port}?sni=${sni}&congestion_control=bbr&alpn=h3&allow_insecure=1#${tag}"
    local yaml_config="- {name: ${tag}, type: tuic, server: ${SERVER_IP}, port: ${port}, uuid: ${uuid}, password: ${password}, udp: true, sni: ${sni}, skip-cert-verify: true, congestion-controller: bbr, alpn: [h3]}"
    
    _save_node_meta "$tag" "$share_link" "$yaml_config"
    echo "$yaml_config" >> "$YAML_NODES_FILE"
    
    _success "TUICv5 节点添加成功!"
    echo ""
    _info "节点名称: ${tag}"
    _info "分享链接:"
    echo -e "${YELLOW}${share_link}${NC}"
    echo ""
    _info "Clash YAML 配置:"
    echo -e "${GREEN}${yaml_config}${NC}"
}

_add_shadowsocks2022() {
    clear
    _info "=== 添加 Shadowsocks-2022 节点 ==="
    
    read -p "节点名称 (默认: ss2022-端口): " custom_tag
    
    read -p "监听端口: " port
    [ -z "$port" ] && _error "端口不能为空"
    _validate_port "$port"
    
    local tag="${custom_tag:-ss2022-${port}}"
    
    # 密码可选手动输入
    read -p "密码 (回车自动生成): " password
    if [ -z "$password" ]; then
        password=$(${SINGBOX_BIN} generate rand --base64 16)
        _info "已自动生成密码: ${password}"
    fi
    
    # 添加 inbound
    local temp=$(mktemp)
    jq --arg tag "$tag" \
       --argjson port "$port" \
       --arg password "$password" \
       '.inbounds += [{
           "type": "shadowsocks",
           "tag": $tag,
           "listen": "::",
           "listen_port": $port,
           "method": "2022-blake3-aes-128-gcm",
           "password": $password
       }]' "$CONFIG_FILE" > "$temp" && mv "$temp" "$CONFIG_FILE"
    
    local encoded_config=$(_base64_encode "2022-blake3-aes-128-gcm:${password}")
    local share_link="ss://${encoded_config}@${SERVER_IP}:${port}#${tag}"
    local yaml_config="- {name: ${tag}, type: ss, server: ${SERVER_IP}, port: ${port}, cipher: 2022-blake3-aes-128-gcm, password: ${password}, udp: true}"
    
    _save_node_meta "$tag" "$share_link" "$yaml_config"
    echo "$yaml_config" >> "$YAML_NODES_FILE"
    
    _success "Shadowsocks-2022 节点添加成功!"
    echo ""
    _info "节点名称: ${tag}"
    _info "分享链接:"
    echo -e "${YELLOW}${share_link}${NC}"
    echo ""
    _info "Clash YAML 配置:"
    echo -e "${GREEN}${yaml_config}${NC}"
}

_view_nodes() {
    clear
    _info "=== 当前节点列表 ==="
    
    if [ -z "$SERVER_IP" ]; then
        _get_public_ip
    fi
    
    local index=1
    
    # 从 CONFIG_FILE 读取节点列表
    while IFS= read -r inbound; do
        local tag=$(echo "$inbound" | jq -r '.tag')
        local type=$(echo "$inbound" | jq -r '.type')
        local port=$(echo "$inbound" | jq -r '.listen_port')
        
        # 从元数据文件获取分享链接（检查文件是否存在）
        local share_link=""
        local yaml_config=""
        
        if [ -f "$NODES_META_FILE" ]; then
            local meta=$(jq --arg tag "$tag" '.nodes[] | select(.tag == $tag)' "$NODES_META_FILE" 2>/dev/null || echo "")
            share_link=$(echo "$meta" | jq -r '.share_link // empty' 2>/dev/null || echo "")
            yaml_config=$(echo "$meta" | jq -r '.yaml_config // empty' 2>/dev/null || echo "")
        fi
        
        echo ""
        echo "============================================"
        _info "[${index}] ${tag}"
        echo "类型: ${type}"
        echo "端口: ${port}"
        echo ""
        
        if [ -n "$share_link" ]; then
            _info "分享链接:"
            echo -e "${YELLOW}${share_link}${NC}"
            echo ""
            _info "Clash YAML:"
            echo -e "${GREEN}${yaml_config}${NC}"
        else
            _warning "⚠️  旧版本节点,缺少分享链接"
            _info "建议: 删除后重新添加"
        fi
        
        index=$((index + 1))
    done < <(jq -c '.inbounds[]' "$CONFIG_FILE" 2>/dev/null)
    
    echo ""
    echo "============================================"
    if [ $index -eq 1 ]; then
        _warning "暂无节点"
    else
        _success "共 $((index - 1)) 个节点"
    fi
    
    echo ""
    if [ -f "$NODES_META_FILE" ]; then
        _info "元数据文件: ${NODES_META_FILE}"
    else
        _warning "元数据文件不存在（旧版本节点）"
    fi
}

_delete_node() {
    clear
    _info "=== 删除节点 ==="
    
    local index=1
    
    # 简化显示，只显示关键信息
    echo ""
    while IFS= read -r inbound; do
        local tag=$(echo "$inbound" | jq -r '.tag')
        local type=$(echo "$inbound" | jq -r '.type')
        local port=$(echo "$inbound" | jq -r '.listen_port')
        
        echo "  [${index}] ${tag} - ${type} - 端口:${port}"
        index=$((index + 1))
    done < <(jq -c '.inbounds[]' "$CONFIG_FILE" 2>/dev/null)
    
    echo ""
    
    if [ $index -eq 1 ]; then
        _warning "暂无节点"
        return
    fi
    
    read -p "输入要删除的节点序号 (按回车取消): " input_index
    
    # 如果用户直接回车，取消删除
    if [ -z "$input_index" ]; then
        _info "已取消删除"
        return
    fi
    
    # 验证输入是否为数字
    if ! [[ "$input_index" =~ ^[0-9]+$ ]]; then
        _warning "无效的序号，已取消删除"
        return
    fi
    
    local total=$(jq '.inbounds | length' "$CONFIG_FILE")
    
    # 验证序号是否在有效范围内
    if [ "$input_index" -lt 1 ] || [ "$input_index" -gt "$total" ]; then
        _warning "序号超出范围 (1-${total})，已取消删除"
        return
    fi
    
    # 获取要删除的节点信息
    local array_index=$((input_index - 1))
    local tag=$(jq -r ".inbounds[${array_index}].tag" "$CONFIG_FILE")
    
    # 二次确认
    echo ""
    _warning "确定要删除节点 [${tag}] 吗？"
    read -p "输入 y 确认删除，其他键取消: " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        _info "已取消删除"
        return
    fi
    
    # 删除 sing-box 配置中的节点
    local temp=$(mktemp)
    jq "del(.inbounds[${array_index}])" "$CONFIG_FILE" > "$temp" && mv "$temp" "$CONFIG_FILE"
    
    # 删除元数据文件中的节点（如果文件存在）
    if [ -f "$NODES_META_FILE" ]; then
        local temp_meta=$(mktemp)
        jq --arg tag "$tag" 'del(.nodes[] | select(.tag == $tag))' "$NODES_META_FILE" > "$temp_meta" && mv "$temp_meta" "$NODES_META_FILE"
    fi
    
    _success "节点 ${tag} 已删除"
    _restart_service
}

_create_global_command() {
    _info "正在创建全局命令 'sbm'..."
    
    # 检查当前脚本是否是通过管道执行（如 bash <(curl ...)）
    if [[ "$0" =~ ^/dev/fd/ ]] || [[ "$0" == "bash" ]] || [[ ! -f "$0" ]]; then
        # 通过管道执行，需要重新下载脚本
        local script_url="https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/singbox_mini.sh"
        _info "检测到通过管道执行，正在下载脚本..."
        
        if curl -fsSL "$script_url" -o "$SCRIPT_PATH" 2>/dev/null; then
            chmod +x "$SCRIPT_PATH"
            _success "全局命令已创建！现在可以使用 'sbm' 命令"
        else
            _warning "警告: 下载脚本失败，无法创建全局命令"
            _info "你可以手动运行: curl -fsSL $script_url -o $SCRIPT_PATH && chmod +x $SCRIPT_PATH"
        fi
    else
        # 直接执行脚本文件
        if [ ! -f "$SCRIPT_PATH" ] || ! diff -q "$0" "$SCRIPT_PATH" &>/dev/null; then
            cp -f "$0" "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"
            _success "全局命令已创建！现在可以使用 'sbm' 命令"
        fi
    fi
}

_uninstall() {
    clear
    _warning "============================================"
    _warning "           ⚠️  卸载确认  ⚠️"
    _warning "============================================"
    _warning "即将删除以下内容："
    echo "  • sing-box 程序: ${SINGBOX_BIN}"
    echo "  • 配置目录: ${SINGBOX_DIR}"
    echo "  • 所有节点配置和证书"
    echo "  • 全局命令: ${SCRIPT_PATH}"
    if [ "$OS_TYPE" = "alpine" ]; then
        echo "  • OpenRC 服务: /etc/init.d/sing-box"
        echo "  • 日志文件: /var/log/sing-box.*"
    else
        echo "  • systemd 服务: ${SERVICE_FILE}"
    fi
    _warning "============================================"
    echo ""
    read -p "$(echo -e ${RED}"确定要完全卸载 sing-box 吗? (输入 YES 确认): "${NC})" confirm
    
    if [ "$confirm" != "YES" ]; then
        _info "卸载已取消"
        return
    fi
    
    _info "开始卸载..."
    
    # 停止并禁用服务
    if [ "$OS_TYPE" = "alpine" ]; then
        rc-service sing-box stop 2>/dev/null || true
        rc-update del sing-box default 2>/dev/null || true
        rm -f /etc/init.d/sing-box
        rm -f /var/log/sing-box.log /var/log/sing-box.err
        _info "✓ OpenRC 服务已删除"
    else
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        _info "✓ systemd 服务已删除"
    fi
    
    # 删除二进制文件
    rm -f "$SINGBOX_BIN"
    _info "✓ sing-box 程序已删除"
    
    # 删除配置目录（包括所有配置文件和证书）
    rm -rf "$SINGBOX_DIR"
    _info "✓ 配置目录已删除"
    
    # 删除全局命令
    rm -f "$SCRIPT_PATH"
    _info "✓ 全局命令已删除"
    
    # 删除 PID 文件（如果存在）
    rm -f /run/sing-box.pid
    
    _success "============================================"
    _success "卸载完成！sing-box 已从系统中完全移除。"
    _success "============================================"
    
    exit 0
}

_restart_service() {
    if [ "$OS_TYPE" = "alpine" ]; then
        rc-service sing-box restart 2>/dev/null || {
            # 如果服务未启动，则启动它
            rc-service sing-box start
        }
        _success "sing-box 服务已重启"
    else
        systemctl restart sing-box
        _success "sing-box 服务已重启"
    fi
}

_view_status() {
    if [ "$OS_TYPE" = "alpine" ]; then
        rc-service sing-box status
    else
        systemctl status sing-box --no-pager -l
    fi
}

_main_menu() {
    while true; do
        clear
        echo "============================================"
        _info "  sing-box 轻量化管理脚本 v${SCRIPT_VERSION}"
        
        # 显示 sing-box 版本信息或未安装状态
        if [ -f "$SINGBOX_BIN" ]; then
            local sb_version=$(${SINGBOX_BIN} version 2>/dev/null | head -n1 | awk '{print $3}')
            if [ -n "$sb_version" ]; then
                echo -e "  ${GREEN}sing-box ${sb_version}${NC}"
            fi
        else
            echo -e "  ${YELLOW}sing-box 未安装${NC}"
        fi
        
        echo "============================================"
        echo " 1) 添加 VLESS-REALITY 节点"
        echo " 2) 添加 Hysteria2 节点"
        echo " 3) 添加 TUICv5 节点"
        echo " 4) 添加 Shadowsocks-2022 节点"
        echo "--------------------------------------------"
        echo " 5) 查看所有节点"
        echo " 6) 删除节点"
        echo " 7) 重启服务"
        echo " 8) 查看运行状态"
        echo "--------------------------------------------"
        echo " 9) 完全卸载 sing-box"
        echo " 0) 退出"
        echo "============================================"
        read -p "请选择 [0-9]: " choice
        
        case $choice in
            1) _add_vless_reality; _restart_service ;;
            2) _add_hysteria2; _restart_service ;;
            3) _add_tuic; _restart_service ;;
            4) _add_shadowsocks2022; _restart_service ;;
            5) _view_nodes ;;
            6) _delete_node ;;
            7) _restart_service ;;
            8) _view_status ;;
            9) _uninstall ;;
            0) exit 0 ;;
            *) _warning "无效选项" ;;
        esac
        echo ""
        read -n 1 -s -r -p "按任意键继续..."
    done
}

# --- 主函数 ---
main() {
    _check_root
    _detect_os
    
    # 检查是否已安装 sing-box
    if [ -f "$SINGBOX_BIN" ] && [ -f "$CONFIG_FILE" ]; then
        # 已安装,更新全局命令(确保是最新版本)
        _create_global_command
        # 获取 IP 后直接进入菜单
        _get_public_ip
        _main_menu
    else
        # 未安装,执行完整安装流程
        _get_public_ip
        _install_dependencies
        _install_singbox
        _init_config
        _create_service
        
        # 创建全局命令
        _create_global_command
        
        # 启动服务
        if [ "$OS_TYPE" = "alpine" ]; then
            rc-service sing-box start 2>/dev/null || true
        else
            systemctl start sing-box 2>/dev/null || true
        fi
        
        _main_menu
    fi
}

main
