#!/bin/bash

# ==============================================
# sing-box 轻量化一键安装脚本
# 支持协议: VLESS-REALITY, Hysteria2, TUICv5, Shadowsocks-2022
# 支持系统: Debian, Ubuntu, Alpine
# ==============================================

set -e

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
SERVICE_FILE="/etc/systemd/system/sing-box.service"
SCRIPT_VERSION="1.0"
SCRIPT_PATH="/usr/local/bin/sbl"  # 添加脚本路径常量

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
    SERVER_IP=$(curl -s4 --max-time 3 ip.sb || curl -s4 --max-time 3 ifconfig.me)
    [ -z "$SERVER_IP" ] && SERVER_IP=$(curl -s6 --max-time 3 ip.sb || curl -s6 --max-time 3 ifconfig.me)
    [ -z "$SERVER_IP" ] && _error "无法获取公网 IP"
    _success "公网 IP: ${SERVER_IP}"
}

_install_dependencies() {
    _info "安装依赖..."
    if [ "$OS_TYPE" = "alpine" ]; then
        apk update
        apk add --no-cache curl jq openssl wget tar
    else
        apt-get update
        apt-get install -y curl jq openssl wget
    fi
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
    
    wget -qO /tmp/singbox.tar.gz "$download_url"
    tar -xzf /tmp/singbox.tar.gz -C /tmp
    mv /tmp/sing-box-*/sing-box "$SINGBOX_BIN"
    chmod +x "$SINGBOX_BIN"
    rm -rf /tmp/singbox.tar.gz /tmp/sing-box-*
    
    _success "sing-box 安装完成: $(${SINGBOX_BIN} version | head -n1)"
}

_create_service() {
    if [ "$OS_TYPE" = "alpine" ]; then
        # 为 Alpine 创建 OpenRC 服务文件
        local openrc_file="/etc/init.d/sing-box"
        cat > "$openrc_file" << 'EOF'
#!/sbin/openrc-run

name="sing-box"
description="sing-box proxy service"
command="/usr/local/bin/sing-box"
command_args="run -c /usr/local/etc/sing-box/config.json"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --file --mode 0644 --owner root:root "$output_log" "$error_log"
}
EOF
        chmod +x "$openrc_file"
        rc-update add sing-box default
        _success "OpenRC 服务已创建并设置为开机自启"
        return
    fi

    # systemd 配置（Debian/Ubuntu）
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=sing-box service
After=network.target

[Service]
Type=simple
ExecStart=${SINGBOX_BIN} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s

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
    "level": "info"
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
}

_add_vless_reality() {
    clear
    _info "=== 添加 VLESS-REALITY 节点 ==="
    
    read -p "监听端口 (默认: 443): " port
    port=${port:-443}
    
    read -p "伪装域名 (默认: www.microsoft.com): " sni
    sni=${sni:-www.microsoft.com}
    
    local uuid=$(${SINGBOX_BIN} generate uuid)
    local keypair=$(${SINGBOX_BIN} generate reality-keypair)
    local private_key=$(echo "$keypair" | awk '/PrivateKey/ {print $2}')
    local public_key=$(echo "$keypair" | awk '/PublicKey/ {print $2}')
    local short_id=$(${SINGBOX_BIN} generate rand --hex 8)
    
    # 添加 inbound
    local temp=$(mktemp)
    jq ".inbounds += [{
        \"type\": \"vless\",
        \"tag\": \"vless-reality-${port}\",
        \"listen\": \"::\",
        \"listen_port\": ${port},
        \"users\": [{
            \"uuid\": \"${uuid}\",
            \"flow\": \"xtls-rprx-vision\"
        }],
        \"tls\": {
            \"enabled\": true,
            \"server_name\": \"${sni}\",
            \"reality\": {
                \"enabled\": true,
                \"handshake\": {
                    \"server\": \"${sni}\",
                    \"server_port\": 443
                },
                \"private_key\": \"${private_key}\",
                \"short_id\": [\"${short_id}\"]
            }
        }
    }]" "$CONFIG_FILE" > "$temp" && mv "$temp" "$CONFIG_FILE"
    
    # 生成分享链接
    local share_link="vless://${uuid}@${SERVER_IP}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#VLESS-REALITY-${port}"
    
    _success "VLESS-REALITY 节点添加成功!"
    echo ""
    _info "分享链接:"
    echo -e "${YELLOW}${share_link}${NC}"  # ← 这里会输出 URI
    echo ""
    _info "Clash YAML 配置:"
    echo -e "${GREEN}${yaml_config}${NC}"
    echo ""
    _info "YAML 配置已保存到: ${YAML_NODES_FILE}"
}

_add_hysteria2() {
    clear
    _info "=== 添加 Hysteria2 节点 ==="
    
    read -p "监听端口: " port
    [ -z "$port" ] && _error "端口不能为空"
    
    read -p "密码 (回车随机生成): " password
    password=${password:-$(${SINGBOX_BIN} generate rand --hex 16)}
    
    read -p "伪装域名 (默认: bing.com): " sni
    sni=${sni:-bing.com}
    
    # 生成自签名证书
    local cert_path="${SINGBOX_DIR}/hy2-${port}.crt"
    local key_path="${SINGBOX_DIR}/hy2-${port}.key"
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "$key_path" -out "$cert_path" -subj "/CN=${sni}" \
        -days 3650 &>/dev/null
    
    # 添加 inbound
    local temp=$(mktemp)
    jq ".inbounds += [{
        \"type\": \"hysteria2\",
        \"tag\": \"hy2-${port}\",
        \"listen\": \"::\",
        \"listen_port\": ${port},
        \"users\": [{\"password\": \"${password}\"}],
        \"tls\": {
            \"enabled\": true,
            \"alpn\": [\"h3\"],
            \"certificate_path\": \"${cert_path}\",
            \"key_path\": \"${key_path}\"
        }
    }]" "$CONFIG_FILE" > "$temp" && mv "$temp" "$CONFIG_FILE"
    
    local share_link="hysteria2://${password}@${SERVER_IP}:${port}?sni=${sni}&insecure=1#Hysteria2-${port}"
    
    _success "Hysteria2 节点添加成功!"
    echo ""
    _info "分享链接:"
    echo -e "${YELLOW}${share_link}${NC}"  # ← 这里会输出 URI
    echo ""
    _info "Clash YAML 配置:"
    echo -e "${GREEN}${yaml_config}${NC}"
    echo ""
    _info "YAML 配置已保存到: ${YAML_NODES_FILE}"
}

_add_tuic() {
    clear
    _info "=== 添加 TUICv5 节点 ==="
    
    read -p "监听端口: " port
    [ -z "$port" ] && _error "端口不能为空"
    
    local uuid=$(${SINGBOX_BIN} generate uuid)
    local password=$(${SINGBOX_BIN} generate rand --hex 16)
    
    read -p "伪装域名 (默认: bing.com): " sni
    sni=${sni:-bing.com}
    
    # 生成自签名证书
    local cert_path="${SINGBOX_DIR}/tuic-${port}.crt"
    local key_path="${SINGBOX_DIR}/tuic-${port}.key"
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "$key_path" -out "$cert_path" -subj "/CN=${sni}" \
        -days 3650 &>/dev/null
    
    # 添加 inbound
    local temp=$(mktemp)
    jq ".inbounds += [{
        \"type\": \"tuic\",
        \"tag\": \"tuic-${port}\",
        \"listen\": \"::\",
        \"listen_port\": ${port},
        \"users\": [{
            \"uuid\": \"${uuid}\",
            \"password\": \"${password}\"
        }],
        \"congestion_control\": \"bbr\",
        \"tls\": {
            \"enabled\": true,
            \"alpn\": [\"h3\"],
            \"certificate_path\": \"${cert_path}\",
            \"key_path\": \"${key_path}\"
        }
    }]" "$CONFIG_FILE" > "$temp" && mv "$temp" "$CONFIG_FILE"
    
    local share_link="tuic://${uuid}:${password}@${SERVER_IP}:${port}?sni=${sni}&congestion_control=bbr&alpn=h3&allow_insecure=1#TUICv5-${port}"
    
    _success "TUICv5 节点添加成功!"
    echo ""
    _info "分享链接:"
    echo -e "${YELLOW}${share_link}${NC}"  # ← 这里会输出 URI
    echo ""
    _info "Clash YAML 配置:"
    echo -e "${GREEN}${yaml_config}${NC}"
    echo ""
    _info "YAML 配置已保存到: ${YAML_NODES_FILE}"
}

_add_shadowsocks2022() {
    clear
    _info "=== 添加 Shadowsocks-2022 节点 ==="
    
    read -p "监听端口: " port
    [ -z "$port" ] && _error "端口不能为空"
    
    local password=$(${SINGBOX_BIN} generate rand --base64 16)
    
    # 添加 inbound
    local temp=$(mktemp)
    jq ".inbounds += [{
        \"type\": \"shadowsocks\",
        \"tag\": \"ss2022-${port}\",
        \"listen\": \"::\",
        \"listen_port\": ${port},
        \"method\": \"2022-blake3-aes-128-gcm\",
        \"password\": \"${password}\"
    }]" "$CONFIG_FILE" > "$temp" && mv "$temp" "$CONFIG_FILE"
    
    local share_link="ss://$(echo -n "2022-blake3-aes-128-gcm:${password}" | base64 -w0)@${SERVER_IP}:${port}#SS2022-${port}"
    
    _success "Shadowsocks-2022 节点添加成功!"
    echo ""
    _info "分享链接:"
    echo -e "${YELLOW}${share_link}${NC}"  # ← 这里会输出 URI
    echo ""
    _info "Clash YAML 配置:"
    echo -e "${GREEN}${yaml_config}${NC}"
    echo ""
    _info "YAML 配置已保存到: ${YAML_NODES_FILE}"
}

_view_nodes() {
    clear
    _info "=== 当前节点列表 ==="
    jq -r '.inbounds[] | "\(.tag) - 端口: \(.listen_port) - 类型: \(.type)"' "$CONFIG_FILE" 2>/dev/null || _warning "暂无节点"
    echo ""
    echo "--------------------------------------------"
    _info "Clash YAML 配置文件: ${YAML_NODES_FILE}"
    if [ -f "$YAML_NODES_FILE" ]; then
        echo ""
        cat "$YAML_NODES_FILE"  # 这里会输出整个 YAML 文件内容
    fi
}

_delete_node() {
    clear
    _view_nodes
    echo ""
    read -p "输入要删除的节点 tag (例如: vless-reality-443): " tag
    [ -z "$tag" ] && return
    
    local temp=$(mktemp)
    jq "del(.inbounds[] | select(.tag == \"${tag}\"))" "$CONFIG_FILE" > "$temp" && mv "$temp" "$CONFIG_FILE"
    
    _success "节点 ${tag} 已删除"
    _restart_service
}

_create_global_command() {
    _info "正在创建全局命令 'sbl'..."
    
    # 获取当前脚本的绝对路径
    local current_script="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null)"
    
    # 如果当前脚本已经是 /usr/local/bin/sbl,则跳过
    if [ "$current_script" = "$SCRIPT_PATH" ]; then
        _info "全局命令已存在"
        return
    fi
    
    # 复制脚本到目标位置
    cp "$current_script" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    
    _success "全局命令已创建！"
    _info "现在你可以在任何位置输入 'sbl' 来打开管理菜单"
}

_uninstall() {
    clear
    _warning "============================================"
    _warning "           ⚠️  卸载确认  ⚠️"
    _warning "============================================"
    _warning "即将删除以下内容："
    echo "  • sing-box 程序: ${SINGBOX_BIN}"
    echo "  • 配置目录: ${SINGBOX_DIR}"
    echo "  • 所有配置文件和证书"
    echo "  • Clash YAML 配置: ${YAML_NODES_FILE}"
    echo "  • 全局命令: ${SCRIPT_PATH}"  # 添加这一行
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
    _get_public_ip
    _install_dependencies
    _install_singbox
    _init_config
    _create_service
    
    # 创建全局命令（每次运行都检查并创建,确保是最新版本）
    _create_global_command
    
    # 启动服务（兼容 Alpine 和 Debian/Ubuntu）
    if [ "$OS_TYPE" = "alpine" ]; then
        rc-service sing-box start 2>/dev/null || true
    else
        systemctl start sing-box 2>/dev/null || true
    fi
    
    _main_menu
}

main
