#!/bin/bash

install_deps_alpine() {
    echo "检测并安装依赖 (Alpine)..."
    local deps=(wget git openssh openssl openrc)
    local missing=()

    for pkg in "${deps[@]}"; do
        if ! apk info -e "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        echo "缺少依赖: ${missing[*]}"
        echo "开始安装..."
        apk add --no-cache "${missing[@]}"
    else
        echo "所有依赖已安装"
    fi
}


echo "==================== Hysteria2 安装程序 ===================="
install_deps_alpine
read -rp "节点备注: " REMARK
read -p "请输入监听端口 [默认443]：" PORT
PORT=${PORT:-443}

read -p "请输入连接密码（留空则自动生成）：" PASS
if [ -z "$PASS" ]; then
  PASS=$(dd if=/dev/random bs=18 count=1 status=none | base64)
fi

read -p "请输入伪装域名（SNI，用于证书 CN）[默认 bing.com]：" SNI
SNI=${SNI:-bing.com}

read -p "请输入伪装网站地址（Masquerade）[默认 https://bing.com/]：" MASQ
MASQ=${MASQ:-https://bing.com/}

echo ""
echo "端口：$PORT"
echo "密码：$PASS"
echo "SNI 域名：$SNI"
echo "伪装网址：$MASQ"
echo "============================================================"
sleep 1

echo "[1/5] 下载 Hysteria2 主程序..."
wget -O /usr/local/bin/hysteria https://download.hysteria.network/app/latest/hysteria-linux-amd64 --no-check-certificate
chmod +x /usr/local/bin/hysteria

mkdir -p /etc/hysteria

generate_cert() {
    local cert_dir=$1
    local cn_name=$2

    echo "[2/5] 生成自签名 TLS 证书..."
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
      -keyout "$cert_dir/server.key" -out "$cert_dir/server.crt" \
      -subj "/CN=$cn_name" -days 36500
}

generate_cert /etc/hysteria "$SNI"

write_config() {
    local config_file=$1
    local port=$2
    local password=$3
    local masquerade=$4

    cat > "$config_file" <<EOF
listen: :$port

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $password

masquerade:
  type: proxy
  proxy:
    url: $masquerade
    rewriteHost: true
EOF
}

write_config /etc/hysteria/config.yaml "$PORT" "$PASS" "$MASQ"

echo "[4/5] 写入自启动服务 /etc/init.d/hysteria ..."
cat > /etc/init.d/hysteria <<EOF
#!/sbin/openrc-run

name="hysteria"
command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"
pidfile="/var/run/\${name}.pid"
command_background="yes"

depend() {
    need networking
}
EOF

chmod +x /etc/init.d/hysteria
rc-update add hysteria

echo "[5/5] 启动 Hysteria2 服务..."
service hysteria start

echo ""
echo "=================== 安装完成  ==================="
echo "Hysteria2 已成功安装并自动启动"
echo ""
echo "配置文件: /etc/hysteria/config.yaml"
echo "连接密码: $PASS"
echo "伪装域名(SNI): $SNI"
echo "监听端口: $PORT"
echo "伪装网址(Masquerade): $MASQ"
echo ""
echo "查看节点配置：cat /etc/hysteria/sublink.txt"
echo "查看状态：service hysteria status"
echo "重启服务：service hysteria restart"
echo "务必查看状态正常才是搭建完成"
echo "如无法正常启动，请DD一个alpine3.19系统重试"
echo "==================================================="
IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)
LINK="hysteria2://$PASS@$IP:$PORT/?insecure=1&sni=$SNI#$REMARK"
YAML="- {name: $REMARK, type: hysteria2, server: $IP, port: $PORT, password: $PASS, udp: true, skip-cert-verify: true }"
# 保存到文件（覆盖模式）
SAVE_PATH="/etc/hysteria/sublink.txt"
{
  echo "URI链接:"
  echo "$LINK"
  echo
  echo "YAML (proxies):"
  echo "$YAML"
  } > "$SAVE_PATH"
cat /etc/hysteria/sublink.txt
