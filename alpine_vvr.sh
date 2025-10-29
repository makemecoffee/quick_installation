#!/bin/bash
set -e

green() { echo -e "\033[32m$1\033[0m"; }
red()   { echo -e "\033[31m$1\033[0m"; }
yellow(){ echo -e "\033[33m$1\033[0m"; }

# ===== 依赖安装 =====
install_dependencies() {
  green "检测并安装依赖（Alpine）..."

  deps=(curl xz jq bash openssl xxd)
  apk update >/dev/null 2>&1
  for d in "${deps[@]}"; do
    if ! command -v "$d" >/dev/null 2>&1; then
      yellow "缺少 $d，正在安装..."
      apk add --no-cache "$d" >/dev/null 2>&1
      green "$d 安装完成"
    else
      green "$d 已安装"
    fi
  done
  green "依赖检测完成"
}

# ===== 检测并安装 Xray =====
check_and_install_xray() {
  if command -v xray >/dev/null 2>&1; then
    green "Xray 已安装，跳过安装"
  else
    red "Xray 未安装，正在安装..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/alpinelinux/install-release.sh)"
    XRAY_BIN=$(command -v xray || echo "/usr/local/bin/xray")
    if [ ! -x "$XRAY_BIN" ]; then
      red "Xray 安装失败"
      exit 1
    fi
    green "Xray 安装完成"
  fi
}

# ===== 创建 VLESS Reality 节点配置 =====
create_vless_reality_vision() {
  XRAY_BIN=$(command -v xray || echo "/usr/local/bin/xray")

  read -rp "监听端口: " PORT
  read -rp "节点备注: " REMARK
  read -rp "SNI: " SNI
  read -rp "UUID（留空自动生成）: " UUID
  read -rp "shortID（留空自动生成）: " SHORT_ID

  UUID=${UUID:-$($XRAY_BIN uuid)}
  SHORT_ID=${SHORT_ID:-$(head -c 4 /dev/urandom | xxd -p)}

  KEYS=$($XRAY_BIN x25519)
  PRIV_KEY=$(echo "$KEYS" | awk '/PrivateKey:/ {print $2}')
  PUB_KEY=$(echo "$KEYS" | awk '/Password/ {print $2}')

  mkdir -p /usr/local/etc/xray
  cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$UUID", "email": "admin@xray.com", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$SNI:443",
        "xver": 0,
        "serverNames": ["$SNI"],
        "privateKey": "$PRIV_KEY",
        "shortIds": ["$SHORT_ID"]
      },
      "tag": "vless"
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

  # 检测是否已加入自启
  if rc-update show default | grep -qw xray; then
    green "Xray 已在开机自启列表中，跳过添加"
  else
    rc-update add xray default
    green "已添加 Xray 至开机自启"
  fi
  
  rc-service xray restart

  IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)
  LINK="vless://$UUID@$IP:$PORT?type=tcp&security=reality&flow=xtls-rprx-vision&sni=$SNI&fp=chrome&pbk=$PUB_KEY&sid=$SHORT_ID#$REMARK"
  YAML="- {name: $REMARK, type: vless, server: $IP, port: $PORT, uuid: $UUID, udp: true, tls: true, network: tcp, flow: xtls-rprx-vision, servername: $SNI, client-fingerprint: chrome, reality-opts: {public-key: $PUB_KEY, short-id: $SHORT_ID}}"

  # 保存到文件（覆盖模式）
  SAVE_PATH="/usr/local/etc/xray/sublink.txt"
  {
    echo "URI链接:"
    echo "$LINK"
    echo
    echo "YAML (proxies):"
    echo "$YAML"
  } > "$SAVE_PATH"

  cat /usr/local/etc/xray/sublink.txt
  echo ""
  echo "查看节点配置：cat /usr/local/etc/xray/sublink.txt"
}

# ===== 卸载 Xray =====
uninstall_xray() {
  if ! command -v xray >/dev/null 2>&1; then
    red "Xray 未安装"
    return
  fi

  red "正在卸载 Xray..."

  if rc-service xray stop >/dev/null 2>&1; then
    green "已停止 Xray 服务"
  else
    yellow "警告：停止 Xray 服务失败或 Xray 未运行"
  fi

  if rc-update del xray default >/dev/null 2>&1; then
    green "已移除 Xray 开机自启"
  else
    yellow "警告：移除自启失败或未添加"
  fi

  if rm -rf /usr/local/bin/xray /usr/local/etc/xray /usr/local/share/xray /var/log/xray /etc/init.d/xray 2>/dev/null; then
    green "已删除 Xray 所有相关文件"
  else
    red "警告：删除某些文件失败，请手动检查以下路径："
    echo "  /usr/local/bin/xray"
    echo "  /usr/local/etc/xray"
    echo "  /usr/local/share/xray"
    echo "  /var/log/xray"
    echo "  /etc/init.d/xray"
  fi

  green "Xray 卸载完成"
  echo "提示：如无其他用途，可执行：apk del curl xz jq bash openssl xxd"
}


# ===== 菜单主程序 =====
main_menu() {
  while true; do
    clear
    echo "===================="
    green "  Xray 管理脚本菜单"
    echo "===================="
    echo "1) 安装Xray并配置vless_reality_vision "
    echo "2) 重启 Xray"
    echo "3) 卸载 Xray"
    echo "4) 查看节点信息"
    echo "0) 退出"
    echo "===================="
    read -rp "请输入选项 [0-4]: " choice

    case "$choice" in
      1)
        install_dependencies
        check_and_install_xray
        create_vless_reality_vision
        read -rp "按任意键返回菜单..."
        ;;
      2)
        if command -v xray >/dev/null 2>&1; then
          if rc-service xray restart >/dev/null 2>&1; then
            green "Xray 已重启"
          else
            red "重启失败，请检查服务状态"
          fi
        else
          red "Xray 未安装，无法重启"
        fi
        read -rp "按任意键返回菜单..."
        ;;
      3)
        uninstall_xray
        read -rp "按任意键返回菜单..."
        ;;
      4)
        if [ -f /usr/local/etc/xray/sublink.txt ]; then
          cat /usr/local/etc/xray/sublink.txt
        else
          red "未找到节点信息文件"
        fi
        read -rp "按任意键返回菜单..."
        ;;
      0)
        exit 0
        ;;
      *)
        red "无效选项，请重新选择"
        sleep 1
        ;;
    esac
  done
}

# ===== 启动菜单 =====
main_menu
