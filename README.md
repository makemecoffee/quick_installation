# quick_installation

## 📦 安装前置要求

确保系统已安装 `bash` 和 `curl`：

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

## ⚠️ 前提须知

- 未提示有默认值的均需要手动输入

---

## sing-box 轻量化四协议管理脚本

-  **一键安装** - 自动安装 sing-box 及所有依赖
-  **多协议支持** - VLESS-REALITY、Hysteria2、TUICv5、Shadowsocks-2022
-  **多系统兼容** - Debian 10+、Ubuntu 20.04+、Alpine 3.14+
-  **交互式菜单** - 简洁友好的操作界面
-  **自动生成分享** - 同时生成 URI 分享链接和 Clash YAML 配置
-  **配置持久化** - 自动保存节点元数据，方便查看和管理
- **全局命令** - 安装后可使用 `sbm` 命令快速管理

### 📥 一键安装

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/singbox_mini.sh)
```

### 🎮 快速使用

安装完成后，使用全局命令 `sbm` 即可打开管理菜单：

```sh
sbm
```

---

## 🚀 单一协议脚本

### Debian/Ubuntu 系列

#### VLESS-VISION-REALITY（Xray）
```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/debian_vvr.sh)
```

#### Hysteria2（Hysteria）
```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/debian_hy2.sh)
```

---

### Alpine 系列

#### VLESS-VISION-REALITY（Xray）
```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/alpine_vvr.sh)
```

**查看配置信息：**
```sh
cat /usr/local/etc/xray/sublink.txt
```

#### Hysteria2（Hysteria）
```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/alpine_hy2.sh)
```

**查看配置信息：**
```sh
cat /etc/hysteria/sublink.txt
```

---

## 📄 声明

本项目仅供学习交流使用，使用本脚本所产生的一切后果由使用者自行承担。

---
