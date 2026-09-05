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

## Xray 轻量双协议管理脚本

- **一键安装** - 自动安装 Xray 及所有依赖
- **双协议支持** - Shadowsocks-2022、VLESS-Reality
- **多系统兼容** - Debian 10+、Ubuntu 20.04+、Alpine 3.14+
- **交互式配置** - 支持自动生成或手动输入密钥/UUID
- **自动生成分享** - 生成分享链接和 Clash YAML 配置
- **出口代理切换** - 支持直连和 切换SS2022 出口
- **配置管理** - 节点元数据持久化存储
- **自动更新** - 支持检测和升级 Xray 版本
- **全局命令** - 安装后使用 `xrm` 快速管理

### 一键安装

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/xray_mini.sh)
```

### 快速开始

安装完成后，使用全局命令 `xrm` 打开管理菜单：

```sh
xrm
```

### 更新脚本

如果 GitHub 上发布了新版本，可以通过以下方式更新脚本：

**更新全局命令**
```sh
curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/xray_mini.sh -o /usr/local/bin/xrm
chmod +x /usr/local/bin/xrm
```

> 💡 更新脚本不会影响已有的配置和节点，所有数据都安全保留在 `/usr/local/etc/xray/` 目录下。

### 文件位置

- **Xray 二进制**: `/usr/local/bin/xray`
- **配置文件**: `/usr/local/etc/xray/config.json`
- **Clash YAML**: `/usr/local/etc/xray/clash_nodes.yaml`
- **节点元数据**: `/usr/local/etc/xray/nodes_meta.json`
- **GeoIP/GeoSite**: `/usr/local/share/xray/`
- **全局命令**: `/usr/local/bin/xrm`

### 特别提示

若只希望tcp入站请在**配置文件**: `/usr/local/etc/xray/config.json`修改"network"方式

### 系统服务

**Debian/Ubuntu (systemd)**:

```sh
systemctl status xray    # 查看状态
systemctl restart xray   # 重启服务
systemctl stop xray      # 停止服务
journalctl -u xray -f    # 查看日志
```

**Alpine (OpenRC)**:

```sh
rc-service xray status   # 查看状态
rc-service xray restart  # 重启服务
rc-service xray stop     # 停止服务
tail -f /var/log/xray/   # 查看日志
```
### AI 分流

1. 编辑配置文件：

```sh
nano /usr/local/etc/xray/config.json
```

2. 在 `routing` 中添加 AI 站点分流规则：

```json
{
  "domain": [
    "geosite:category-ai-!cn"
  ],
  "outboundTag": "ai"
},
```

3. 在 `outbounds` 中添加 `ai` 出口：

```json
{
  "tag": "ai",
  "protocol": "shadowsocks",
  "settings": {
    "servers": [
      {
        "address": "ip",
        "port": 1-65535,
        "method": "2022-blake3-aes-128-gcm",
        "password": "password"
      }
    ]
  }
},
```

## 📄 免责声明

本项目仅用于学习和交流用途。用户需对使用这些脚本产生的所有后果负责。

---
