#!/bin/bash
set -e

green() { echo -e "\033[32m$1\033[0m"; }
red()   { echo -e "\033[31m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; } 

install_dependencies() {
  green "检测并安装依赖..."

  deps=(curl wget xz-utils jq xxd)
  sudo apt update -y
  for d in "${deps[@]}"; do
    if ! command -v "$d" >/dev/null 2>&1; then
      yellow "缺少 $d，正在安装..."

      sudo apt install -y "$d"
    else
      green "$d 已安装"
    fi
  done

  green "依赖检测完成"
}

install_dependencies

#====== Check if xray is installed =====
check_and_install_xray() {
  if command -v xray >/dev/null 2>&1; then
    green "Xray 已安装，跳过安装"
  else
    red "Xray 未安装，正在安装..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

    XRAY_BIN=$(command -v xray || echo "/usr/local/bin/xray")
    if [ ! -x "$XRAY_BIN" ]; then
      red "Xray 安装失败"
      exit 1
    fi
    green "Xray 安装完成"
  fi
}


#====== enable TCP bbr =====
enable_bbr() {
  # check TCP bbr
  CURRENT=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
  if [ "$CURRENT" = "bbr" ]; then
    green "BBR 已经启用，无需重复配置"
  else
    sed -i '/^net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/^net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf

    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

    sysctl -p >/dev/null
    green "BBR 已启用"
  fi
}

#====== MEUI======
while true; do
  clear
  echo "1) 安装并配置 VLESS Reality Vision节点"  
  echo "2) 开启 BBR 加速"
  echo "3) 卸载 Xray"
  echo "4) 查看节点配置"
  echo "0) 退出"
  echo
  read -rp "请选择操作: " choice

  case "$choice" in
    1)
      check_and_install_xray
      XRAY_BIN=$(command -v xray || echo "/usr/local/bin/xray")
      read -rp "监听端口: " PORT
      read -rp "节点备注: " REMARK
      KEYS=$($XRAY_BIN x25519)
      PRIV_KEY=$(echo "$KEYS" | awk '/PrivateKey:/ {print $2}')
      PUB_KEY=$(echo "$KEYS" | awk '/Password/ {print $2}')
      read -rp "SNI: " SNI
      read -rp "UUID(留空随机): " UUID
      if [ -z "$UUID" ]; then
        UUID=$(cat /proc/sys/kernel/random/uuid)
      fi
      read -rp "shortID(留空随机): " SHORT_ID
      if [ -z "$SHORT_ID" ]; then
        SHORT_ID=$(head -c 4 /dev/urandom | xxd -p)
      fi

      mkdir -p /usr/local/etc/xray
      cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$UUID", "email": "$REMARK" , "flow": "xtls-rprx-vision"}],
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

	      systemctl daemon-reexec
        systemctl restart xray
        systemctl enable xray

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
      read -rp "按任意键返回菜单..."
      ;;
    2)
      enable_bbr
      read -rp "按任意键返回菜单..."
      ;;
    3)
      red "正在卸载 Xray..."
      bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge
      green "Xray 已卸载"
      read -rp "按任意键返回菜单..."
      ;;
    4)
      cat /usr/local/etc/xray/sublink.txt
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