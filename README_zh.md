# quick_installation（中文）

English: [README](README.md)

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

---

## 注意

- 对于没有默认值的选项，需要手动输入。

---

## sing-box 轻量四协议管理脚本

- **一键安装** - 自动安装 sing-box 及所有依赖
- **多协议支持** - VLESS-REALITY、Hysteria2、TUICv5、Shadowsocks-2022
- **多系统兼容** - Debian 10+、Ubuntu 20.04+、Alpine 3.14+
- **交互式菜单** - 简洁友好的界面
- **自动生成分享** - 生成 URI 分享链接和 Clash YAML 配置
- **配置持久化** - 自动保存节点元数据，便于查看与管理
- 全局命令：安装后使用 `sbm` 快速管理

### 一键安装

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/singbox_mini.sh)
```

### 快速开始

安装完成后，使用全局命令 `sbm` 打开管理菜单：

```sh
sbm
```

### 守护脚本（崩溃自动重启）

**安装守护监控：**
```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/daemon_sb.sh) install
```

**移除守护监控：**
```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/daemon_sb.sh) remove
```

> 该守护脚本会每分钟检查 sing-box 状态并在崩溃时重启，支持 Alpine 与 Debian/Ubuntu 系统。

---

## 单协议脚本

### Debian/Ubuntu 系列

#### VLESS-VISION-REALITY (Xray)
```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/debian_vvr.sh)
```

#### Hysteria2 (Hysteria)
```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/debian_hy2.sh)
```

---

### Alpine 系列

#### VLESS-VISION-REALITY (Xray)
```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/alpine_vvr.sh)
```

**查看配置：**
```sh
cat /usr/local/etc/xray/sublink.txt
```

#### Hysteria2 (Hysteria)
```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/alpine_hy2.sh)
```

**查看配置：**
```sh
cat /etc/hysteria/sublink.txt
```

---

## 📄 免责声明

本项目仅用于学习和交流用途。用户需对使用这些脚本产生的所有后果负责。

---
