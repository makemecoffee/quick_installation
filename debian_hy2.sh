#!/bin/bash
set -e

green() { echo -e "\033[32m$1\033[0m"; }
red()   { echo -e "\033[31m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; } 

# 0. 检查并安装依赖
install_deps() {
    echo "[0/5] 检测并安装依赖..."
    local deps=(wget git openssh-client openssl curl)
    local missing=()

    for pkg in "${deps[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        echo "需要安装以下依赖: ${missing[*]}"
        apt update -y
        apt install -y "${missing[@]}"
    else
        echo "所有依赖已安装，跳过安装步骤。"
    fi
}

# 1. 获取用户配置
get_user_input() {
    read -rp "节点备注: " REMARK
    read -p "请输入监听端口(默认443):" PORT
    PORT=${PORT:-443}

    read -p "请输入连接密码(留空则自动生成):" PASS
    if [ -z "$PASS" ]; then
        PASS=$(dd if=/dev/random bs=18 count=1 status=none | base64)
    fi

    read -p "请输入伪装域名(SNI,用于证书 CN)(默认 bing.com):" SNI
    SNI=${SNI:-bing.com}

    read -p "请输入伪装网站地址(默认 https://bing.com/):" MASQ
    MASQ=${MASQ:-https://bing.com/}
}

# 2. 下载 Hysteria2 程序
download_hysteria() {
    echo "[1/5] 下载 Hysteria2 主程序..."
    wget -O /usr/local/bin/hysteria https://download.hysteria.network/app/latest/hysteria-linux-amd64 --no-check-certificate
    chmod +x /usr/local/bin/hysteria
    mkdir -p /etc/hysteria
}

# 3. 生成自签证书
generate_cert() {
    local cert_dir=$1
    local cn_name=$2

    echo "[2/5] 生成自签名 TLS 证书..."
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "$cert_dir/server.key" -out "$cert_dir/server.crt" \
        -subj "/CN=$cn_name" -days 36500
}

# 4. 写入配置文件
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

# 5. 写入 systemd 服务文件
write_service() {
    cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
}

# 6. 启动服务
start_service() {
    echo "[5/5] 启动并设置开机自启..."
    systemctl daemon-reload
    systemctl enable hysteria
    systemctl restart hysteria
}

# 7. 输出安装信息并生成订阅链接
show_info() {
    local remark=$1
    local port=$2
    local pass=$3
    local sni=$4
    local masq=$5

    echo ""
    echo "=================== 安装完成  ==================="
    echo "Hysteria2 已成功安装并自动启动"
    echo "配置文件: /etc/hysteria/config.yaml"
    echo "连接密码: $pass"
    echo "伪装域名(SNI): $sni"
    echo "监听端口: $port"
    echo "伪装网址(Masquerade): $masq"
    echo "查看状态：systemctl status hysteria"
    echo "重启服务：systemctl restart hysteria"
    echo "==================================================="

    local IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)
    local YAML="- {name: $remark, type: hysteria2, server: $IP, port: $port, password: $pass, udp: true, skip-cert-verify: true }"
    local LINK="hysteria2://$pass@$IP:$port/?insecure=1&sni=$sni#$remark"
    
    local SAVE_PATH="/etc/hysteria/sublink.txt"
    {
        echo "URI链接:"
        echo "$LINK"
        echo
        echo "YAML (proxies):"
        echo "$YAML"
    } > "$SAVE_PATH"
    cat "$SAVE_PATH"
}

# ----------------- 主程序 -----------------
main() {
    install_deps
    get_user_input
    download_hysteria
    generate_cert /etc/hysteria "$SNI"
    write_config /etc/hysteria/config.yaml "$PORT" "$PASS" "$MASQ"
    write_service
    start_service
    show_info "$REMARK" "$PORT" "$PASS" "$SNI" "$MASQ"
}

#====== MEUI======
while true; do
  clear
  echo "1) 安装并配置 Hysteria2"  
  echo "2) 查看节点配置"
  echo "3) 卸载 Hysteria"
  echo "0) 退出"
  echo
  read -rp "请选择操作: " choice

  case "$choice" in
    1)
      echo "==================== Hysteria2 安装程序 ===================="
      install_deps
      get_user_input
      download_hysteria
      generate_cert /etc/hysteria "$SNI"
      write_config /etc/hysteria/config.yaml "$PORT" "$PASS" "$MASQ"
      write_service
      start_service
      show_info "$REMARK" "$PORT" "$PASS" "$SNI" "$MASQ"
      read -rp "按任意键返回菜单..."
      ;;
    2)
      cat /etc/hysteria/sublink.txt
      read -rp "按任意键返回菜单..."
      ;;
    3)
      bash <(curl -fsSL https://get.hy2.sh/) --remove
      rm -rf /etc/hysteria
      if id "hysteria" &>/dev/null; then
          userdel -r hysteria
          echo "用户 hysteria 已删除"
      else
          echo "用户 hysteria 不存在，跳过删除"
      fi
      rm -f /etc/systemd/system/multi-user.target.wants/hysteria-server.service
      rm -f /etc/systemd/system/multi-user.target.wants/hysteria-server@*.service
      systemctl daemon-reload
      echo "卸载完成---以上指令已脚本执行完成无需再次执行"
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
