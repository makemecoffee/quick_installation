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

---

## Xray 轻量双协议管理脚本

- **一键安装** - 自动安装 Xray 及所有依赖
- **双协议支持** - Shadowsocks-2022、VLESS-Reality
- **多系统兼容** - Debian 10+、Ubuntu 20.04+、Alpine 3.14+
- **交互式配置** - 支持自动生成或手动输入密钥/UUID
- **自动生成分享** - 生成分享链接和 Clash YAML 配置
- **出口代理切换** - 支持直连和 SS2022 出口
- **配置管理** - 节点元数据持久化存储
- **自动更新** - 支持检测和升级 Xray 版本
- 全局命令：安装后使用 `xrm` 快速管理

### 一键安装

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/xray_mini.sh)
```

### 快速开始

安装完成后，使用全局命令 `xrm` 打开管理菜单：

```sh
xrm
```

### 主要功能

#### 节点管理
1. **添加 Shadowsocks 2022 节点**
   - 固定使用 `2022-blake3-aes-128-gcm` 加密
   - 支持自定义端口、标签、密码
   - 自动生成分享链接和 Clash 配置

2. **添加 VLESS Reality 节点**
   - 自动生成 UUID 和 Reality 密钥对
   - 支持自定义回落目标和 SNI
   - 可选手动输入或自动生成 Short ID

3. **查看节点**
   - 显示所有已添加的节点信息
   - 包含分享链接和 Clash YAML 配置

4. **删除节点**
   - 交互式选择要删除的节点
   - 二次确认防止误删
   - 自动重启服务应用更改

#### 出口配置
5. **修改出口**
   - **直连模式** - 直接访问互联网
   - **SS2022 代理** - 通过上游 Shadowsocks 服务器中转
   - 自动验证服务器地址和端口
   - 配置完成后自动重启服务

#### 系统管理
6. **升级 Xray**
   - 自动检测最新版本
   - 显示当前版本和最新版本对比
   - 可选是否升级

7. **重启 Xray**
   - 手动重启服务应用配置更改
   - 自动检测服务状态

8. **查看状态**
   - 显示 Xray 服务运行状态
   - 查看最近的日志输出

9. **卸载 Xray**
   - 完全清理 Xray 及所有配置
   - 删除全局命令 `xrm`
   - 二次确认防止误操作

### 文件位置

- **Xray 二进制**: `/usr/local/bin/xray`
- **配置文件**: `/usr/local/etc/xray/config.json`
- **Clash YAML**: `/usr/local/etc/xray/clash_nodes.yaml`
- **节点元数据**: `/usr/local/etc/xray/nodes_meta.json`
- **GeoIP/GeoSite**: `/usr/local/share/xray/`
- **全局命令**: `/usr/local/bin/xrm`

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

### 配置示例

#### 添加 SS2022 节点流程
```
1. 选择 "1) 添加 Shadowsocks 2022 节点"
2. 选择使用 IP 或域名
3. 输入端口 (默认: 443)
4. 输入标签 (默认: ss-端口)
5. 输入密码 (留空自动生成)
6. 自动生成分享链接和 Clash 配置
7. 自动重启服务
```

#### 添加 Reality 节点流程
```
1. 选择 "2) 添加 VLESS Reality 节点"
2. 选择使用 IP 或域名
3. 输入端口 (默认: 443)
4. 输入标签 (默认: vvr-端口)
5. 输入 UUID (留空自动生成)
6. 自动生成 Reality 密钥对
7. 输入回落目标 (默认: www.microsoft.com:443)
8. 输入 SNI (默认: www.microsoft.com)
9. 输入 Short ID (留空自动生成)
10. 自动生成分享链接和 Clash 配置
11. 自动重启服务
```

#### 切换出口代理流程
```
1. 选择 "5) 修改出口"
2. 选择出口类型:
   - 1) 直连
   - 2) SS2022 代理
3. 如果选择 SS2022:
   - 输入上游服务器地址
   - 输入上游服务器端口
   - 输入上游服务器密码
4. 自动重启服务应用配置
```

### 注意事项

 **重要提示**:
- 首次运行需要 root 权限
- 确保网络连接正常（需要从 GitHub 下载）
- 端口不要与现有服务冲突
- Reality 节点的 SNI 域名需要能够正常访问
- 删除节点前请确认备份重要配置
- 卸载会删除所有配置和节点数据

### 常见问题

**Q: 如何更新全局命令？**  
A: 重新运行安装脚本，会自动更新 `xrm` 命令

**Q: 如何手动编辑配置？**  
A: 编辑 `/usr/local/etc/xray/config.json`，然后运行 `xrm` 选择 "7) 重启 Xray"

**Q: 节点无法连接？**  
A: 检查防火墙是否开放端口，查看服务状态 `xrm` -> "8) 查看状态"

**Q: 如何备份配置？**  
A: 备份以下文件：
```sh
/usr/local/etc/xray/config.json
/usr/local/etc/xray/nodes_meta.json
/usr/local/etc/xray/clash_nodes.yaml
```

**Q: Alpine 系统日志在哪？**  
A: `/var/log/xray/access.log` 和 `/var/log/xray/error.log`

---

## 📄 免责声明

本项目仅用于学习和交流用途。用户需对使用这些脚本产生的所有后果负责。

---
