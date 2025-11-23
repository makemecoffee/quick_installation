# quick_installation

Chinese : [README](README_zh.md)

##  Prerequisites

Ensure your system has `bash` and `curl` installed:

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

##  Notice

- Manual input is required for options without default values

---

##  sing-box Lightweight Four-Protocol Management Script

-  **One-Click Installation** - Automatically install sing-box and all dependencies
-  **Multi-Protocol Support** - VLESS-REALITY, Hysteria2, TUICv5, Shadowsocks-2022
-  **Multi-System Compatible** - Debian 10+, Ubuntu 20.04+, Alpine 3.14+
-  **Interactive Menu** - Clean and user-friendly interface
-  **Auto-Generate Shares** - Generate both URI share links and Clash YAML configs
-  **Config Persistence** - Automatically save node metadata for easy viewing and management
-  **Global Command** - Use `sbm` command for quick management after installation

###  One-Click Installation

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/singbox_mini.sh)
```

###  Quick Start

After installation, use the global command `sbm` to open the management menu:

```sh
sbm
```

###  Daemon Script (Auto-Restart on Crash)

**Install daemon monitoring:**
```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/daemon_sb.sh) install
```

**Remove daemon monitoring:**
```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/daemon_sb.sh) remove
```

> The daemon script automatically checks sing-box status every minute and restarts it if crashed. Supports only Alpine  systems.

---

##  Single Protocol Scripts

### Debian/Ubuntu Series

#### VLESS-VISION-REALITY (Xray)
```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/single_protocol/debian_vvr.sh)
```

#### Hysteria2 (Hysteria)
```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/single_protocol/debian_hy2.sh)
```

---

### Alpine Series

#### VLESS-VISION-REALITY (Xray)
```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/single_protocol/alpine_vvr.sh)
```

**View configuration:**
```sh
cat /usr/local/etc/xray/sublink.txt
```

#### Hysteria2 (Hysteria)
```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/single_protocol/alpine_hy2.sh)
```

**View configuration:**
```sh
cat /etc/hysteria/sublink.txt
```

---

## 📄 Disclaimer

This project is for educational and communication purposes only. Users are responsible for all consequences arising from the use of these scripts.

---
