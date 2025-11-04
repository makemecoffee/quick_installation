#!/bin/bash

# ==============================================
# Xray-core 轻量化一键安装脚本
# 支持协议: VLESS-REALITY, Shadowsocks-2022
# 支持系统: Debian, Ubuntu, Alpine
# ==============================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 路径常量 ---
XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/usr/local/etc/xray"
CONFIG_FILE="${XRAY_DIR}/config.json"
NODES_META_FILE="${XRAY_DIR}/nodes_meta.json"
SERVICE_FILE="/etc/systemd/system/xray.service"
SCRIPT_VERSION="1.0"
SCRIPT_PATH="/usr/local/bin/xm"

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

_install_dependencies() {
    _info "检查依赖..."
    
    if [ "$OS_TYPE" = "alpine" ]; then
        local missing_deps=()
        for pkg in curl jq openssl wget unzip; do
            if ! apk info -e "$pkg" &>/dev/null; then
                missing_deps+=("$pkg")
            fi
        done
        
        if [ ${#missing_deps[@]} -eq 0 ]; then
            _success "所有依赖已安装"
            return
        fi
        
        _info "需要安装: ${missing_deps[*]}"
        apk update
        apk add --no-cache "${missing_deps[@]}"
    else
        local missing_deps=()
        for pkg in curl jq openssl wget unzip; do
            if ! dpkg -l | grep -qw "^ii.*$pkg"; then
                missing_deps+=("$pkg")
            fi
        done
        
        if [ ${#missing_deps[@]} -eq 0 ]; then
            _success "所有依赖已安装"
            return
        fi
        
        _info "需要安装: ${missing_deps[*]}"
        apt-get update
        apt-get install -y "${missing_deps[@]}"
    fi
    
    _success "依赖安装完成"
}

_install_xray() {
    if [ -f "$XRAY_BIN" ]; then
        _info "Xray 已安装: $($XRAY_BIN version | head -n1)"
        return
    fi

    _info "安装 Xray-core..."
    local arch=$(uname -m)
    local arch_tag=""
    case $arch in
        x86_64|amd64) arch_tag="64" ;;
        aarch64|arm64) arch_tag="arm64-v8a" ;;
        armv7l) arch_tag="arm32-v7a" ;;
        *) _error "不支持的架构: $arch" ;;
    esac

    local download_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch_tag}.zip"
    
    wget -qO /tmp/xray.zip "$download_url" || _error "下载失败"
    unzip -qo /tmp/xray.zip -d /tmp/xray
    mv /tmp/xray/xray "$XRAY_BIN"
    chmod +x "$XRAY_BIN"
    rm -rf /tmp/xray.zip /tmp/xray
    
    _success "Xray 安装完成: $($XRAY_BIN version | head -n1)"
}

_create_service() {
    if [ "$OS_TYPE" = "alpine" ]; then
        local openrc_file="/etc/init.d/xray"
        cat > "$openrc_file" << 'EOF'
#!/sbin/openrc-run

name="xray"
description="Xray proxy service"
command="/usr/local/bin/xray"
command_args="run -c /usr/local/etc/xray/config.json"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need net
    after firewall
}
EOF
        chmod +x "$openrc_file"
        rc-update add xray default
        _success "OpenRC 服务已创建"
        return
    fi

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Xray service
After=network.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray
    _success "systemd 服务已创建"
}

_init_config() {
    mkdir -p "$XRAY_DIR"
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << 'EOF'
{
  "log": {
    "loglevel": "none"
  },
  "inbounds": [],
  "outbounds": [{
    "protocol": "freedom",
    "tag": "direct"
  }]
}
EOF
        _success "配置文件已初始化"
    fi
    
    if [ ! -f "$NODES_META_FILE" ]; then
        echo '{"nodes":[]}' > "$NODES_META_FILE"
    fi
}

_save_node_meta() {
    local tag="$1"
    local share_link="$2"
    
    if [ ! -f "$NODES_META_FILE" ]; then
        echo '{"nodes":[]}' > "$NODES_META_FILE"
    fi
    
    local temp=$(mktemp)
    jq ".nodes += [{
        \"tag\": \"${tag}\",
        \"share_link\": \"${share_link}\",
        \"created_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
    }]" "$NODES_META_FILE" > "$temp" && mv "$temp" "$NODES_META_FILE"
}

_generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}

_generate_x25519() {
    $XRAY_BIN x25519
}

_add_vless_reality() {
    clear
    _info "=== 添加 VLESS-REALITY 节点 ==="
    
    read -p "节点名称 (默认: vless-reality-443): " custom_tag
    read -p "监听端口 (默认: 443): " port
    port=${port:-443}
    local tag="${custom_tag:-vless-reality-${port}}"
    
    read -p "伪装域名 (默认: www.microsoft.com): " dest
    dest=${dest:-www.microsoft.com}
    
    read -p "SNI (默认同伪装域名): " sni
    sni=${sni:-$dest}
    
    local uuid=$(_generate_uuid)
    local keys=$(_generate_x25519)
    local private_key=$(echo "$keys" | awk '/Private key:/ {print $3}')
    local public_key=$(echo "$keys" | awk '/Public key:/ {print $3}')
    local short_id=$(openssl rand -hex 8)
    
    # 修复：使用正确的 Xray 配置格式
    local temp=$(mktemp)
    jq ".inbounds += [{
        \"tag\": \"${tag}\",
        \"listen\": \"0.0.0.0\",
        \"port\": ${port},
        \"protocol\": \"vless\",
        \"settings\": {
            \"clients\": [{
                \"id\": \"${uuid}\",
                \"flow\": \"xtls-rprx-vision\"
            }],
            \"decryption\": \"none\"
        },
        \"streamSettings\": {
            \"network\": \"tcp\",
            \"security\": \"reality\",
            \"realitySettings\": {
                \"show\": false,
                \"dest\": \"${dest}:443\",
                \"serverNames\": [\"${sni}\"],
                \"privateKey\": \"${private_key}\",
                \"shortIds\": [\"${short_id}\"]
            }
        }
    }]" "$CONFIG_FILE" > "$temp" && mv "$temp" "$CONFIG_FILE"
    
    local share_link="vless://${uuid}@${SERVER_IP}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#${tag}"
    
    _save_node_meta "$tag" "$share_link"
    
    _success "VLESS-REALITY 节点添加成功!"
    echo ""
    _info "节点名称: ${tag}"
    _info "分享链接:"
    echo -e "${YELLOW}${share_link}${NC}"
}

_add_shadowsocks2022() {
    clear
    _info "=== 添加 Shadowsocks-2022 节点 ==="
    
    read -p "节点名称 (默认: ss2022-端口): " custom_tag
    read -p "监听端口: " port
    [ -z "$port" ] && _error "端口不能为空"
    
    local tag="${custom_tag:-ss2022-${port}}"
    local password=$(openssl rand -base64 16)
    
    # 修复：使用正确的 Xray Shadowsocks-2022 配置格式
    local temp=$(mktemp)
    jq ".inbounds += [{
        \"tag\": \"${tag}\",
        \"listen\": \"0.0.0.0\",
        \"port\": ${port},
        \"protocol\": \"shadowsocks\",
        \"settings\": {
            \"method\": \"2022-blake3-aes-128-gcm\",
            \"password\": \"${password}\"
        }
    }]" "$CONFIG_FILE" > "$temp" && mv "$temp" "$CONFIG_FILE"
    
    local share_link="ss://$(echo -n "2022-blake3-aes-128-gcm:${password}" | base64 -w0)@${SERVER_IP}:${port}#${tag}"
    
    _save_node_meta "$tag" "$share_link"
    
    _success "Shadowsocks-2022 节点添加成功!"
    echo ""
    _info "节点名称: ${tag}"
    _info "分享链接:"
    echo -e "${YELLOW}${share_link}${NC}"
}

_view_nodes() {
    clear
    _info "=== 当前节点列表 ==="
    
    local index=1
    
    while IFS= read -r inbound; do
        local tag=$(echo "$inbound" | jq -r '.tag')
        local protocol=$(echo "$inbound" | jq -r '.protocol')
        local port=$(echo "$inbound" | jq -r '.port')
        
        local share_link=""
        if [ -f "$NODES_META_FILE" ]; then
            local meta=$(jq -r ".nodes[] | select(.tag == \"${tag}\")" "$NODES_META_FILE" 2>/dev/null || echo "")
            share_link=$(echo "$meta" | jq -r '.share_link // empty' 2>/dev/null || echo "")
        fi
        
        echo ""
        echo "============================================"
        _info "[${index}] ${tag}"
        echo "协议: ${protocol}"
        echo "端口: ${port}"
        echo ""
        
        if [ -n "$share_link" ]; then
            _info "分享链接:"
            echo -e "${YELLOW}${share_link}${NC}"
        fi
        
        index=$((index + 1))
    done < <(jq -c '.inbounds[]' "$CONFIG_FILE" 2>/dev/null)
    
    echo ""
    echo "============================================"
    [ $index -eq 1 ] && _warning "暂无节点" || _success "共 $((index - 1)) 个节点"
}

_delete_node() {
    clear
    _info "=== 删除节点 ==="
    
    local index=1
    echo ""
    while IFS= read -r inbound; do
        local tag=$(echo "$inbound" | jq -r '.tag')
        local protocol=$(echo "$inbound" | jq -r '.protocol')
        local port=$(echo "$inbound" | jq -r '.port')
        echo "  [${index}] ${tag} - ${protocol} - 端口:${port}"
        index=$((index + 1))
    done < <(jq -c '.inbounds[]' "$CONFIG_FILE" 2>/dev/null)
    
    echo ""
    [ $index -eq 1 ] && { _warning "暂无节点"; return; }
    
    read -p "输入要删除的节点序号 (按回车取消): " input_index
    [ -z "$input_index" ] && { _info "已取消删除"; return; }
    
    if ! [[ "$input_index" =~ ^[0-9]+$ ]]; then
        _warning "无效的序号"
        return
    fi
    
    local total=$(jq '.inbounds | length' "$CONFIG_FILE")
    if [ "$input_index" -lt 1 ] || [ "$input_index" -gt "$total" ]; then
        _warning "序号超出范围 (1-${total})"
        return
    fi
    
    local array_index=$((input_index - 1))
    local tag=$(jq -r ".inbounds[${array_index}].tag" "$CONFIG_FILE")
    
    echo ""
    _warning "确定要删除节点 [${tag}] 吗？"
    read -p "输入 y 确认删除: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { _info "已取消删除"; return; }
    
    local temp=$(mktemp)
    jq "del(.inbounds[${array_index}])" "$CONFIG_FILE" > "$temp" && mv "$temp" "$CONFIG_FILE"
    
    if [ -f "$NODES_META_FILE" ]; then
        local temp_meta=$(mktemp)
        jq ".nodes |= map(select(.tag != \"${tag}\"))" "$NODES_META_FILE" > "$temp_meta" && mv "$temp_meta" "$NODES_META_FILE"
    fi
    
    _success "节点 ${tag} 已删除"
    _restart_service
}

_create_global_command() {
    _info "正在创建全局命令 'xm'..."
    
    if [[ "$0" =~ ^/dev/fd/ ]] || [[ "$0" == "bash" ]] || [[ ! -f "$0" ]]; then
        local script_url="https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/xray_mini.sh"
        if curl -fsSL "$script_url" -o "$SCRIPT_PATH" 2>/dev/null; then
            chmod +x "$SCRIPT_PATH"
            _success "全局命令已创建！现在可以使用 'xm' 命令"
        else
            _warning "下载脚本失败"
        fi
    else
        if [ ! -f "$SCRIPT_PATH" ] || ! diff -q "$0" "$SCRIPT_PATH" &>/dev/null; then
            cp -f "$0" "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"
            _success "全局命令已创建！现在可以使用 'xm' 命令"
        fi
    fi
}

_uninstall() {
    clear
    _warning "============================================"
    _warning "           ⚠️  卸载确认  ⚠️"
    _warning "============================================"
    _warning "即将删除:"
    echo "  • Xray 程序: ${XRAY_BIN}"
    echo "  • 配置目录: ${XRAY_DIR}"
    echo "  • 全局命令: ${SCRIPT_PATH}"
    [ "$OS_TYPE" = "alpine" ] && echo "  • OpenRC 服务" || echo "  • systemd 服务"
    _warning "============================================"
    echo ""
    read -p "$(echo -e ${RED}"确定卸载? (输入 YES 确认): "${NC})" confirm
    
    [ "$confirm" != "YES" ] && { _info "已取消"; return; }
    
    _info "开始卸载..."
    
    if [ "$OS_TYPE" = "alpine" ]; then
        rc-service xray stop 2>/dev/null || true
        rc-update del xray default 2>/dev/null || true
        rm -f /etc/init.d/xray
    else
        systemctl stop xray 2>/dev/null || true
        systemctl disable xray 2>/dev/null || true
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
    fi
    
    rm -f "$XRAY_BIN" "$SCRIPT_PATH"
    rm -rf "$XRAY_DIR"
    
    _success "卸载完成！"
    exit 0
}

_restart_service() {
    if [ "$OS_TYPE" = "alpine" ]; then
        rc-service xray restart 2>/dev/null || rc-service xray start
    else
        systemctl restart xray
    fi
    _success "Xray 服务已重启"
}

_view_status() {
    [ "$OS_TYPE" = "alpine" ] && rc-service xray status || systemctl status xray --no-pager -l
}

_main_menu() {
    while true; do
        clear
        echo "============================================"
        _info "  Xray-core 轻量化管理脚本 v${SCRIPT_VERSION}"
        
        if [ -f "$XRAY_BIN" ]; then
            local xray_ver=$($XRAY_BIN version 2>/dev/null | head -n1 | awk '{print $2}')
            [ -n "$xray_ver" ] && echo -e "  ${GREEN}Xray ${xray_ver}${NC}"
        else
            echo -e "  ${YELLOW}Xray 未安装${NC}"
        fi
        
        echo "============================================"
        echo " 1) 添加 VLESS-REALITY 节点"
        echo " 2) 添加 Shadowsocks-2022 节点"
        echo "--------------------------------------------"
        echo " 3) 查看所有节点"
        echo " 4) 删除节点"
        echo " 5) 重启服务"
        echo " 6) 查看运行状态"
        echo "--------------------------------------------"
        echo " 9) 完全卸载 Xray"
        echo " 0) 退出"
        echo "============================================"
        read -p "请选择 [0-9]: " choice
        
        case $choice in
            1) _add_vless_reality; _restart_service ;;
            2) _add_shadowsocks2022; _restart_service ;;
            3) _view_nodes ;;
            4) _delete_node ;;
            5) _restart_service ;;
            6) _view_status ;;
            9) _uninstall ;;
            0) exit 0 ;;
            *) _warning "无效选项" ;;
        esac
        echo ""
        read -n 1 -s -r -p "按任意键继续..."
    done
}

main() {
    _check_root
    _detect_os
    
    if [ -f "$XRAY_BIN" ] && [ -f "$CONFIG_FILE" ]; then
        _create_global_command
        _get_public_ip
        _main_menu
    else
        _get_public_ip
        _install_dependencies
        _install_xray
        _init_config
        _create_service
        _create_global_command
        
        [ "$OS_TYPE" = "alpine" ] && rc-service xray start 2>/dev/null || systemctl start xray 2>/dev/null
        
        _main_menu
    fi
}

main
