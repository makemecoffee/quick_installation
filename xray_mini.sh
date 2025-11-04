#!/bin/bash

# ==============================================
# Xray 轻量化一键安装脚本
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
YAML_NODES_FILE="${XRAY_DIR}/clash_nodes.yaml"
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
        # 检查 Alpine 依赖
        local missing_deps=()
        for pkg in curl jq openssl wget xz bash xxd; do
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
        # 检查 Debian/Ubuntu 依赖
        local missing_deps=()
        for pkg in curl jq openssl wget xz-utils xxd; do
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
    if command -v xray >/dev/null 2>&1; then
        _info "Xray 已安装: $(xray version | head -n1 | awk '{print $2}')"
        return
    fi

    _info "安装 Xray..."
    
    if [ "$OS_TYPE" = "alpine" ]; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/alpinelinux/install-release.sh)"
    else
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi
    
    if [ ! -x "$XRAY_BIN" ]; then
        _error "Xray 安装失败"
    fi
    
    _success "Xray 安装完成: $(xray version | head -n1 | awk '{print $2}')"
}

_create_service() {
    if [ "$OS_TYPE" = "alpine" ]; then
        # 为 Alpine 创建 OpenRC 服务文件
        local openrc_file="/etc/init.d/xray"
        
        if [ -f "$openrc_file" ]; then
            _success "OpenRC 服务文件已存在"
        else
            cat > "$openrc_file" << 'EOF'
#!/sbin/openrc-run

name="xray"
description="Xray proxy service"
command="/usr/local/bin/xray"
command_args="run -c /usr/local/etc/xray/config.json"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/xray.log"
error_log="/var/log/xray.err"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --file --mode 0644 --owner root:root "$output_log" "$error_log"
}
EOF
            chmod +x "$openrc_file"
            _success "OpenRC 服务已创建"
        fi
        
        rc-update add xray default 2>/dev/null || true
        _success "已设置为开机自启"
        return
    fi

    # systemd 配置（Debian/Ubuntu）
    if [ -f "$SERVICE_FILE" ]; then
        _success "systemd 服务文件已存在"
        # 确保配置文件权限正确
        chmod 644 "$CONFIG_FILE"
        [ -f "$NODES_META_FILE" ] && chmod 644 "$NODES_META_FILE"
        [ -f "$YAML_NODES_FILE" ] && chmod 644 "$YAML_NODES_FILE"
        return
    fi
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Xray service
Documentation=https://github.com/xtls/xray-core
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${XRAY_BIN} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    # 确保配置文件权限正确
    chmod 644 "$CONFIG_FILE"
    [ -f "$NODES_META_FILE" ] && chmod 644 "$NODES_META_FILE"
    [ -f "$YAML_NODES_FILE" ] && chmod 644 "$YAML_NODES_FILE"
    
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
    "loglevel": "warning"
  },
  "inbounds": [],
  "outbounds": [
    {
      "protocol": "freedom",
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
    
    # 设置正确的权限
    chmod 755 "$XRAY_DIR"
    chmod 644 "$CONFIG_FILE"
    [ -f "$YAML_NODES_FILE" ] && chmod 644 "$YAML_NODES_FILE"
    [ -f "$NODES_META_FILE" ] && chmod 644 "$NODES_META_FILE"
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
    jq ".nodes += [{
        \"tag\": \"${tag}\",
        \"share_link\": \"${share_link}\",
        \"yaml_config\": \"${yaml_config}\",
        \"created_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
    }]" "$NODES_META_FILE" > "$temp" && mv "$temp" "$NODES_META_FILE"
}

_add_vless_reality() {
    clear
    _info "=== 添加 VLESS-REALITY 节点 ==="
    
    read -p "节点名称 (默认: vless-reality-端口): " custom_tag
    
    read -p "监听端口 (默认: 443): " port
    port=${port:-443}
    
    # 如果用户没有输入 tag，使用默认格式
    local tag="${custom_tag:-vless-reality-${port}}"
    
    read -p "SNI/伪装域名 (默认: www.microsoft.com): " sni
    sni=${sni:-www.microsoft.com}
    
    read -p "UUID (留空自动生成): " uuid
    if [ -z "$uuid" ]; then
        uuid=$(cat /proc/sys/kernel/random/uuid)
    fi
    
    read -p "shortID (留空自动生成): " short_id
    if [ -z "$short_id" ]; then
        short_id=$(head -c 4 /dev/urandom | xxd -p)
    fi
    
    # 生成密钥对 - 修复版本
    _info "正在生成密钥对..."
    local keys=$($XRAY_BIN x25519)
    
    # 调试输出（可选）
    # echo "DEBUG: keys output = $keys"
    
    # 更健壮的密钥提取方式
    local priv_key=$(echo "$keys" | grep -i "private key" | awk '{print $NF}')
    local pub_key=$(echo "$keys" | grep -i "public key" | awk '{print $NF}')
    
    # 如果第一种方式失败，尝试其他格式
    if [ -z "$priv_key" ] || [ -z "$pub_key" ]; then
        priv_key=$(echo "$keys" | sed -n 's/.*[Pp]rivate.*: *\([^ ]*\).*/\1/p' | head -1)
        pub_key=$(echo "$keys" | sed -n 's/.*[Pp]ublic.*: *\([^ ]*\).*/\1/p' | head -1)
    fi
    
    # 验证密钥是否成功生成
    if [ -z "$priv_key" ] || [ -z "$pub_key" ]; then
        _error "密钥生成失败，请检查 xray 是否正确安装"
    fi
    
    _success "密钥对生成成功"
    
    # 添加 inbound
    local temp=$(mktemp)
    jq ".inbounds += [{
        \"port\": ${port},
        \"protocol\": \"vless\",
        \"tag\": \"${tag}\",
        \"settings\": {
            \"clients\": [{
                \"id\": \"${uuid}\",
                \"email\": \"admin@xray.com\",
                \"flow\": \"xtls-rprx-vision\"
            }],
            \"decryption\": \"none\"
        },
        \"streamSettings\": {
            \"network\": \"tcp\",
            \"security\": \"reality\",
            \"realitySettings\": {
                \"show\": false,
                \"dest\": \"${sni}:443\",
                \"xver\": 0,
                \"serverNames\": [\"${sni}\"],
                \"privateKey\": \"${priv_key}\",
                \"shortIds\": [\"${short_id}\"]
            }
        }
    }]" "$CONFIG_FILE" > "$temp" && mv "$temp" "$CONFIG_FILE"
    
    # 生成分享链接和 YAML
    local share_link="vless://${uuid}@${SERVER_IP}:${port}?type=tcp&security=reality&flow=xtls-rprx-vision&sni=${sni}&fp=chrome&pbk=${pub_key}&sid=${short_id}#${tag}"
    local yaml_config="- {name: ${tag}, type: vless, server: ${SERVER_IP}, port: ${port}, uuid: ${uuid}, udp: true, tls: true, network: tcp, flow: xtls-rprx-vision, servername: ${sni}, client-fingerprint: chrome, reality-opts: {public-key: ${pub_key}, short-id: ${short_id}}}"
    
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

_add_shadowsocks2022() {
    clear
    _info "=== 添加 Shadowsocks-2022 节点 ==="
    
    read -p "节点名称 (默认: ss2022-端口): " custom_tag
    
    read -p "监听端口: " port
    [ -z "$port" ] && _error "端口不能为空"
    
    local tag="${custom_tag:-ss2022-${port}}"
    
    # 固定使用 2022-blake3-aes-128-gcm 加密方法
    local method="2022-blake3-aes-128-gcm"
    local key_length=16
    
    # 生成密码 (base64 编码的随机字节)
    local password=$(openssl rand -base64 $key_length)
    
    # 添加 inbound
    local temp=$(mktemp)
    jq ".inbounds += [{
        \"port\": ${port},
        \"protocol\": \"shadowsocks\",
        \"tag\": \"${tag}\",
        \"settings\": {
            \"method\": \"${method}\",
            \"password\": \"${password}\",
            \"network\": \"tcp,udp\"
        }
    }]" "$CONFIG_FILE" > "$temp" && mv "$temp" "$CONFIG_FILE"
    
    # 生成分享链接和 YAML
    local userinfo="${method}:${password}"
    local encoded_userinfo=$(echo -n "$userinfo" | base64 -w0 2>/dev/null || echo -n "$userinfo" | base64)
    local share_link="ss://${encoded_userinfo}@${SERVER_IP}:${port}#${tag}"
    local yaml_config="- {name: ${tag}, type: ss, server: ${SERVER_IP}, port: ${port}, cipher: ${method}, password: ${password}, udp: true}"
    
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
        local tag=$(echo "$inbound" | jq -r '.tag // empty')
        local protocol=$(echo "$inbound" | jq -r '.protocol')
        local port=$(echo "$inbound" | jq -r '.port')
        
        # 如果没有 tag，跳过（可能是旧配置）
        [ -z "$tag" ] && tag="${protocol}-${port}"
        
        # 从元数据文件获取分享链接
        local share_link=""
        local yaml_config=""
        
        if [ -f "$NODES_META_FILE" ]; then
            local meta=$(jq -r ".nodes[] | select(.tag == \"${tag}\")" "$NODES_META_FILE" 2>/dev/null || echo "")
            share_link=$(echo "$meta" | jq -r '.share_link // empty' 2>/dev/null || echo "")
            yaml_config=$(echo "$meta" | jq -r '.yaml_config // empty' 2>/dev/null || echo "")
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
            echo ""
            _info "Clash YAML:"
            echo -e "${GREEN}${yaml_config}${NC}"
        else
            _warning "⚠️  旧版本节点，缺少分享链接"
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
        local tag=$(echo "$inbound" | jq -r '.tag // empty')
        local protocol=$(echo "$inbound" | jq -r '.protocol')
        local port=$(echo "$inbound" | jq -r '.port')
        
        [ -z "$tag" ] && tag="${protocol}-${port}"
        
        echo "  [${index}] ${tag} - ${protocol} - 端口:${port}"
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
    local tag=$(jq -r ".inbounds[${array_index}].tag // empty" "$CONFIG_FILE")
    local protocol=$(jq -r ".inbounds[${array_index}].protocol" "$CONFIG_FILE")
    local port=$(jq -r ".inbounds[${array_index}].port" "$CONFIG_FILE")
    
    [ -z "$tag" ] && tag="${protocol}-${port}"
    
    # 二次确认
    echo ""
    _warning "确定要删除节点 [${tag}] 吗？"
    read -p "输入 y 确认删除，其他键取消: " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        _info "已取消删除"
        return
    fi
    
    # 删除 xray 配置中的节点
    local temp=$(mktemp)
    jq "del(.inbounds[${array_index}])" "$CONFIG_FILE" > "$temp" && mv "$temp" "$CONFIG_FILE"
    
    # 删除元数据文件中的节点（如果文件存在）
    if [ -f "$NODES_META_FILE" ]; then
        local temp_meta=$(mktemp)
        jq "del(.nodes[] | select(.tag == \"${tag}\"))" "$NODES_META_FILE" > "$temp_meta" && mv "$temp_meta" "$NODES_META_FILE"
    fi
    
    _success "节点 ${tag} 已删除"
    _restart_service
}

_create_global_command() {
    _info "正在创建全局命令 'xm'..."
    
    # 检查当前脚本是否是通过管道执行（如 bash <(curl ...)）
    if [[ "$0" =~ ^/dev/fd/ ]] || [[ "$0" == "bash" ]] || [[ ! -f "$0" ]]; then
        # 通过管道执行，需要重新下载脚本
        local script_url="https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/xray_mini.sh"
        _info "检测到通过管道执行，正在下载脚本..."
        
        if curl -fsSL "$script_url" -o "$SCRIPT_PATH" 2>/dev/null; then
            chmod +x "$SCRIPT_PATH"
            _success "全局命令已创建！现在可以使用 'xm' 命令"
        else
            _warning "警告: 下载脚本失败，无法创建全局命令"
            _info "你可以手动运行: curl -fsSL $script_url -o $SCRIPT_PATH && chmod +x $SCRIPT_PATH"
        fi
    else
        # 直接执行脚本文件
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
    _warning "即将删除以下内容："
    echo "  • Xray 程序: ${XRAY_BIN}"
    echo "  • 配置目录: ${XRAY_DIR}"
    echo "  • 所有节点配置"
    echo "  • 全局命令: ${SCRIPT_PATH}"
    if [ "$OS_TYPE" = "alpine" ]; then
        echo "  • OpenRC 服务: /etc/init.d/xray"
        echo "  • 日志文件: /var/log/xray.*"
    else
        echo "  • systemd 服务: ${SERVICE_FILE}"
    fi
    _warning "============================================"
    echo ""
    read -p "$(echo -e ${RED}"确定要完全卸载 Xray 吗? (输入 YES 确认): "${NC})" confirm
    
    if [ "$confirm" != "YES" ]; then
        _info "卸载已取消"
        return
    fi
    
    _info "开始卸载..."
    
    # 停止并禁用服务
    if [ "$OS_TYPE" = "alpine" ]; then
        rc-service xray stop 2>/dev/null || true
        rc-update del xray default 2>/dev/null || true
        rm -f /etc/init.d/xray
        rm -f /var/log/xray.log /var/log/xray.err
        _info "✓ OpenRC 服务已删除"
    else
        systemctl stop xray 2>/dev/null || true
        systemctl disable xray 2>/dev/null || true
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        _info "✓ systemd 服务已删除"
    fi
    
    # 删除二进制文件和配置
    rm -f "$XRAY_BIN"
    _info "✓ Xray 程序已删除"
    
    # 删除配置目录
    rm -rf "$XRAY_DIR"
    _info "✓ 配置目录已删除"
    
    # 删除其他相关文件
    rm -rf /usr/local/share/xray
    rm -rf /var/log/xray
    
    # 删除全局命令
    rm -f "$SCRIPT_PATH"
    _info "✓ 全局命令已删除"
    
    # 删除 PID 文件（如果存在）
    rm -f /run/xray.pid
    
    _success "============================================"
    _success "卸载完成！Xray 已从系统中完全移除。"
    _success "============================================"
    
    exit 0
}

_restart_service() {
    if [ "$OS_TYPE" = "alpine" ]; then
        rc-service xray restart 2>/dev/null || {
            # 如果服务未启动，则启动它
            rc-service xray start
        }
        _success "Xray 服务已重启"
    else
        systemctl restart xray
        _success "Xray 服务已重启"
    fi
}

_view_status() {
    if [ "$OS_TYPE" = "alpine" ]; then
        rc-service xray status
    else
        systemctl status xray --no-pager -l
    fi
}

_enable_bbr() {
    clear
    _info "=== 启用 BBR 加速 ==="
    
    # 检查当前 TCP 拥塞控制算法
    local current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    
    if [ "$current" = "bbr" ]; then
        _success "BBR 已经启用，无需重复配置"
        return
    fi
    
    _info "当前拥塞控制算法: ${current:-未知}"
    
    # 检查内核是否支持 BBR
    if ! modprobe tcp_bbr 2>/dev/null; then
        _warning "警告: 内核可能不支持 BBR"
    fi
    
    # 配置 BBR
    if [ "$OS_TYPE" = "alpine" ]; then
        # Alpine 使用 /etc/sysctl.d/
        cat > /etc/sysctl.d/99-bbr.conf << EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
        sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null
    else
        # Debian/Ubuntu
        sed -i '/^net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/^net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        
        sysctl -p >/dev/null
    fi
    
    # 验证 BBR 是否启用
    local new_current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    
    if [ "$new_current" = "bbr" ]; then
        _success "BBR 已成功启用"
    else
        _warning "BBR 配置完成，但可能需要重启系统生效"
    fi
}

_main_menu() {
    while true; do
        clear
        echo "============================================"
        _info "  Xray 轻量化管理脚本 v${SCRIPT_VERSION}"
        
        # 显示 Xray 版本信息或未安装状态
        if command -v xray >/dev/null 2>&1; then
            local xray_version=$(xray version 2>/dev/null | head -n1 | awk '{print $2}')
            if [ -n "$xray_version" ]; then
                echo -e "  ${GREEN}Xray ${xray_version}${NC}"
            fi
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
        echo " 7) 启用 BBR 加速"
        echo "--------------------------------------------"
        echo " 8) 完全卸载 Xray"
        echo " 0) 退出"
        echo "============================================"
        read -p "请选择 [0-8]: " choice
        
        case $choice in
            1) _add_vless_reality; _restart_service ;;
            2) _add_shadowsocks2022; _restart_service ;;
            3) _view_nodes ;;
            4) _delete_node ;;
            5) _restart_service ;;
            6) _view_status ;;
            7) _enable_bbr ;;
            8) _uninstall ;;
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
    
    # 检查是否已安装 Xray
    if command -v xray >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
        # 已安装，更新全局命令（确保是最新版本）
        _create_global_command
        # 获取 IP 后直接进入菜单
        _get_public_ip
        _main_menu
    else
        # 未安装，执行完整安装流程
        _get_public_ip
        _install_dependencies
        _install_xray
        _init_config
        _create_service
        
        # 创建全局命令
        _create_global_command
        
        # 启动服务
        if [ "$OS_TYPE" = "alpine" ]; then
            rc-service xray start 2>/dev/null || true
        else
            systemctl start xray 2>/dev/null || true
        fi
        
        _main_menu
    fi
}

main
