# quick_installation (English)

Chinese: [README](README_zh.md)

## Prerequisites

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

## Notice

- Manual input is required for options without default values.

---

## sing-box Lightweight Four-Protocol Management Script

- **One-Click Installation** - Automatically install sing-box and all dependencies
- **Multi-Protocol Support** - VLESS-REALITY, Hysteria2, TUICv5, Shadowsocks-2022
- **Multi-System Compatible** - Debian 10+, Ubuntu 20.04+, Alpine 3.14+
- **Interactive Menu** - Clean and user-friendly interface
- **Auto-Generate Shares** - Generate URI share links and Clash YAML configs
- **Config Persistence** - Automatically save node metadata for easy viewing and management
- Global Command: Use `sbm` for quick management after installation

### One-Click Installation

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/singbox_mini.sh)
```

### Quick Start

After installation, use the global command `sbm` to open the management menu:

```sh
sbm
```

---

## Xray Lightweight Dual-Protocol Management Script

- **One-Click Installation** - Automatically install Xray and all dependencies
- **Dual-Protocol Support** - Shadowsocks-2022, VLESS-Reality
- **Multi-System Compatible** - Debian 10+, Ubuntu 20.04+, Alpine 3.14+
- **Interactive Configuration** - Support auto-generation or manual input of keys/UUIDs
- **Auto-Generate Shares** - Generate share links and Clash YAML configs
- **Outbound Proxy Switching** - Support direct connection and SS2022 outbound
- **Config Management** - Persistent storage of node metadata
- **Auto Update** - Support detection and upgrade of Xray versions
- Global Command: Use `xrm` for quick management after installation

### One-Click Installation

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/xray_mini.sh)
```

### Quick Start

After installation, use the global command `xrm` to open the management menu:

```sh
xrm
```

### Main Features

#### Node Management
1. **Add Shadowsocks 2022 Node**
   - Fixed encryption: `2022-blake3-aes-128-gcm`
   - Support custom port, tag, password
   - Auto-generate share links and Clash config

2. **Add VLESS Reality Node**
   - Auto-generate UUID and Reality keypair
   - Support custom fallback target and SNI
   - Optional manual input or auto-generate Short ID

3. **View Nodes**
   - Display all added node information
   - Include share links and Clash YAML configs

4. **Delete Node**
   - Interactive selection of node to delete
   - Double confirmation to prevent accidental deletion
   - Auto-restart service to apply changes

#### Outbound Configuration
5. **Modify Outbound**
   - **Direct Mode** - Direct internet access
   - **SS2022 Proxy** - Route through upstream Shadowsocks server
   - Auto-validate server address and port
   - Auto-restart service after configuration

#### System Management
6. **Upgrade Xray**
   - Auto-detect latest version
   - Display current and latest version comparison
   - Optional upgrade

7. **Restart Xray**
   - Manually restart service to apply config changes
   - Auto-detect service status

8. **View Status**
   - Display Xray service running status
   - View recent log output

9. **Uninstall Xray**
   - Completely remove Xray and all configs
   - Delete global command `xrm`
   - Double confirmation to prevent accidental operations

### File Locations

- **Xray Binary**: `/usr/local/bin/xray`
- **Config File**: `/usr/local/etc/xray/config.json`
- **Clash YAML**: `/usr/local/etc/xray/clash_nodes.yaml`
- **Node Metadata**: `/usr/local/etc/xray/nodes_meta.json`
- **GeoIP/GeoSite**: `/usr/local/share/xray/`
- **Global Command**: `/usr/local/bin/xrm`

### System Service

**Debian/Ubuntu (systemd)**:
```sh
systemctl status xray    # View status
systemctl restart xray   # Restart service
systemctl stop xray      # Stop service
journalctl -u xray -f    # View logs
```

**Alpine (OpenRC)**:
```sh
rc-service xray status   # View status
rc-service xray restart  # Restart service
rc-service xray stop     # Stop service
tail -f /var/log/xray/   # View logs
```

### Configuration Examples

#### Add SS2022 Node Process
```
1. Select "1) Add Shadowsocks 2022 Node"
2. Choose to use IP or domain
3. Enter port (default: 443)
4. Enter tag (default: ss-port)
5. Enter password (leave empty for auto-generation)
6. Auto-generate share link and Clash config
7. Auto-restart service
```

#### Add Reality Node Process
```
1. Select "2) Add VLESS Reality Node"
2. Choose to use IP or domain
3. Enter port (default: 443)
4. Enter tag (default: vvr-port)
5. Enter UUID (leave empty for auto-generation)
6. Auto-generate Reality keypair
7. Enter fallback target (default: www.microsoft.com:443)
8. Enter SNI (default: www.microsoft.com)
9. Enter Short ID (leave empty for auto-generation)
10. Auto-generate share link and Clash config
11. Auto-restart service
```

#### Switch Outbound Proxy Process
```
1. Select "5) Modify Outbound"
2. Select outbound type:
   - 1) Direct
   - 2) SS2022 Proxy
3. If SS2022 is selected:
   - Enter upstream server address
   - Enter upstream server port
   - Enter upstream server password
4. Auto-restart service to apply config
```

### Important Notes

⚠️ **Important**:
- Root privileges required for first run
