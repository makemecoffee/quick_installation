#!/bin/bash
set -e

green() { echo -e "\033[32m$1\033[0m"; }
red()   { echo -e "\033[31m$1\033[0m"; }
yellow(){ echo -e "\033[33m$1\033[0m"; }

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

install_dependencies
#====== Check if xray is installed =====
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

check_and_install_xray
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
      "clients": [{ "id": "$UUID", "email": "$REMARK", "flow": "xtls-rprx-vision" }],
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

rc-update add xray default
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
