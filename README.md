# Xray 轻量双协议管理脚本

基于 Bash 的 Xray 管理脚本，提供 Shadowsocks 2022 和 VLESS + REALITY + Vision 节点管理，以及直连和 SS2022 出口切换。

## 功能

- 默认安装 Xray 最新正式版，支持核心升级、系统服务及 GeoIP / GeoSite 数据管理。
- 创建、查看和删除 SS2022、VLESS + REALITY + Vision 节点。
- 输出 Shadowrocket 分享 URI 和 Clash YAML 节点行，另保存 Xray 客户端出站片段。
- 自动生成 UUID、SS2022 密钥、REALITY 密钥及 Short ID，也可按提示自定义部分参数。
- 保存多个 SS2022 出口配置，按需切换直连或代理出口。
- 安装 `xrm` 全局命令，并通过菜单从 GitHub 更新脚本。

## 运行环境

- Debian、Ubuntu 或 Alpine；需要 root 权限、Bash 和 curl。
- 脚本会检查并尝试安装 `unzip`、`jq`、`openssl` 等依赖。
- 支持脚本中列出的 `x86_64`、`aarch64` 和 `armv7l` 架构。
- 安装核心、数据文件及更新脚本需要访问相应下载地址。

如果系统还没有 Bash 和 curl，可以先安装：

```bash
# Debian / Ubuntu
apt update
apt install -y bash curl
```

```sh
# Alpine
apk update
apk add --no-cache bash curl
```

## 安装

以 root 身份运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/xray_mini.sh)
```

安装完成后，通过全局命令进入菜单：

```bash
xrm
```

从 GitHub 安装或更新时，使用的是仓库 `master` 分支上的脚本。尚未推送的本地修改需要先上传到服务器运行；若服务器已有 `xrm`，直接运行上传的脚本不会自动替换已有的全局命令。

## 出口管理

选择 **管理出口**，可切换直连，或通过 SS2022 URI / 手动输入保存 SS2022 出口，再选择并应用。切换出口会修改 Xray 配置中的出站列表，并尝试重启服务；有自定义出站或路由时，请先备份并留意其引用关系。

脚本默认路由会将匹配 `geoip:private` 和 `geoip:cn` 的流量送往 `block` 出站；相关分类依赖服务器上的 Geo 数据文件。Xray 官方文档也说明 Freedom 在服务器端对某些目标有默认安全策略。

## 文件位置

| 内容 | 服务器路径 |
| --- | --- |
| Xray 核心 | `/usr/local/bin/xray` |
| Xray 配置 | `/usr/local/etc/xray/config.json` |
| Clash 节点 | `/usr/local/etc/xray/clash_nodes.yaml` |
| 节点元数据 | `/usr/local/etc/xray/nodes_meta.json` |
| SS2022 出口档案 | `/usr/local/etc/xray/outbound_profiles.json` |
| GeoIP / GeoSite | `/usr/local/share/xray/` |
| 管理命令 | `/usr/local/bin/xrm` |

带注释的双协议服务端示例见 [examples/server.jsonc](examples/server.jsonc)，使用前需要替换其中的占位值。

## 服务管理

Debian / Ubuntu：

```bash
systemctl status xray
systemctl restart xray
journalctl -u xray -n 50 --no-pager
```

Alpine：

```sh
rc-service xray status
rc-service xray restart
```

## 

感谢 [Xray-core](https://github.com/XTLS/Xray-core) 项目及其贡献者提供的核心程序和文档。
