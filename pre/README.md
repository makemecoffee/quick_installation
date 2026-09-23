## Xray 轻量双协议管理脚本（pre 版本）

这是主目录脚本的 pre 版本，用于跟进 Xray-core 的预发布版本变化。

- **一键安装** - 自动安装 Xray 及所有依赖
- **双协议支持** - Shadowsocks-2022、VLESS-Reality
- **多系统兼容** - Debian 10+、Ubuntu 20.04+、Alpine 3.14+
- **交互式配置** - 支持自动生成或手动输入密钥/UUID
- **自动生成分享** - 生成分享链接和 Clash YAML 配置
- **出口代理切换** - 支持直连和切换 SS2022 出口
- **配置管理** - 节点元数据持久化存储
- **自动更新** - 自动检查 Xray-core 最新 pre-release
- **全局命令** - 安装后使用 `xrm` 快速管理

## 与稳定版的区别

- 从 Xray-core Releases 中筛选最新的 pre-release，不固定某个版本号。
- REALITY 服务端最低客户端版本设置为 `1.0.0`，避免过于严格的版本限制。
- 生成的 Clash REALITY 节点启用 `support-x25519mlkem768: true`，适配新版 REALITY 的后量子密钥交换。

## 前提条件

请确保系统已安装 `bash` 和 `curl`：

### Alpine

```sh
apk update
apk add --no-cache bash curl
```

### Debian/Ubuntu

```sh
apt update
apt install -y bash curl
```

## 一键安装

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/pre/xray_mini.sh)
```

安装完成后，使用全局命令打开管理菜单：

```sh
xrm
```

## 更新脚本

```sh
curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/pre/xray_mini.sh -o /usr/local/bin/xrm
chmod +x /usr/local/bin/xrm
```

更新脚本不会影响已有配置和节点，数据保存在 `/usr/local/etc/xray/`。

## 文件位置

- **Xray 二进制**: `/usr/local/bin/xray`
- **配置文件**: `/usr/local/etc/xray/config.json`
- **Clash YAML**: `/usr/local/etc/xray/clash_nodes.yaml`
- **节点元数据**: `/usr/local/etc/xray/nodes_meta.json`
- **GeoIP/GeoSite**: `/usr/local/share/xray/`
- **全局命令**: `/usr/local/bin/xrm`

## 系统服务

### Debian/Ubuntu（systemd）

```sh
systemctl status xray
systemctl restart xray
systemctl stop xray
journalctl -u xray -f
```

### Alpine（OpenRC）

```sh
rc-service xray status
rc-service xray restart
rc-service xray stop
tail -f /var/log/xray/
```

## 免责声明

本项目仅用于学习和交流用途。用户需对使用这些脚本产生的所有后果负责。
