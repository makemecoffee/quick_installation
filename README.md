# Xray 轻量双协议管理脚本

基于 Bash 的 Xray 管理脚本，提供 Shadowsocks 2022 和 VLESS + REALITY + Vision 节点管理，以及直连和 SS2022 出口切换。

## 功能

- 安装和升级 Xray，管理系统服务及 GeoIP / GeoSite 数据。
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

## 更新脚本与核心

运行 `xrm`，选择主菜单的 **5) 更新脚本**，从 GitHub 下载并更新全局命令；下次执行 `xrm` 时使用更新后的脚本。脚本更新和 Xray 核心升级是两个操作：升级核心请在 **管理 Xray → 升级 Xray** 中进行。

升级前建议备份 `/usr/local/etc/xray/` 和已有的 `/usr/local/bin/xrm`。已有配置文件会跳过初始化；脚本不会自动将旧节点迁移到新配置结构。若配置文件没有 `routing`，启动脚本时会补充默认路由。

## 创建节点

在主菜单选择 **新增节点**，再选择 SS2022 或 VLESS REALITY Vision。按提示输入地址、端口和标签；同时创建两种节点时请选择不同端口。

### SS2022

脚本提供 `2022-blake3-aes-128-gcm`、`2022-blake3-aes-256-gcm` 和 `2022-blake3-chacha20-poly1305` 三种方式。密码留空时自动生成。默认监听 TCP 和 UDP；如需调整，请查看配置中的入站 `settings.network`。

### VLESS + REALITY + Vision

UUID 和 Short ID 可以自动生成或按提示输入。REALITY 密钥由 `xray x25519` 自动生成；脚本根据明确标签提取密钥，若输出无法唯一识别会停止。SNI 需填写所选目标接受的名称，`target` 默认使用该名称和 443 端口，也可自定义。Short ID 为最多 16 位的偶数位十六进制；留空时自动生成。

### 客户端导入

创建节点后，脚本输出：

- **Shadowrocket URI**：用于在 Shadowrocket 中导入。
- **Clash YAML**：将节点行粘贴到现有 YAML 的 `proxies` 列表下。
- **Xray 客户端出站片段**：在管理节点菜单中查看，需要合并到客户端配置。

VLESS 的 Clash 输出包含 `reality-opts.support-x25519mlkem768: true`。指定的 Xray 官方文档没有定义该第三方字段、其位置或分享 URI 参数，**文档未提及，不能确认**；请自行确认客户端版本的支持情况。节点分享信息包含连接凭据，请妥善保存。

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
