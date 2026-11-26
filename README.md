# Xray 轻量双协议管理脚本

基于 Bash 的 Xray 管理脚本，提供 Shadowsocks（SS，含 SS2022）和 VLESS + REALITY + Vision 节点管理，以及直连和 SS 出口切换。

## 功能

- 默认安装 Xray 最新正式版，支持核心升级、系统服务及 GeoIP / GeoSite 手动和定时更新。
- 创建、查看和删除 SS（含 SS2022）、VLESS + REALITY + Vision 节点。
- SS 入站和出口均支持传统 AEAD `aes-128-gcm`、`aes-256-gcm`，以及 SS2022 的 `2022-blake3-aes-128-gcm`、`2022-blake3-aes-256-gcm`、`2022-blake3-chacha20-poly1305`。
- 输出 Shadowrocket 分享 URI 和 Clash YAML 节点行，另保存 Xray 客户端出站片段。
- 自动生成 UUID、传统 SS 密码、SS2022 密钥、REALITY 密钥及 Short ID，也可按提示自定义部分参数。
- 保存多个 SS 出口配置（含 SS2022），选择普通出口，并为 AI 服务单独选择直连或代理出口。
- 安装 `xrm` 全局命令，并通过菜单从 GitHub 更新脚本。

新增节点和手动添加出口时，选择第 4 项使用 `aes-128-gcm`，第 5 项使用 `aes-256-gcm`；默认第 1 项为 `2022-blake3-aes-128-gcm`。传统 SS 可使用普通非空密码，SS2022 需要符合要求的 Base64 密钥。新增节点时密码留空可自动生成。

## 运行环境

- Debian、Ubuntu 或 Alpine；需要 root 权限、Bash 和 curl。
- 脚本会检查并尝试安装 `unzip`、`jq`、`openssl`、`flock` 等依赖。
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

## 节点管理

- 新增节点：主菜单选择 **1）新增节点**，再选择 SS 或 VLESS + REALITY + Vision，按提示填写服务器地址、端口及其他参数。
- 查看节点：主菜单选择 **2）管理节点 → 1）查看节点**，可查看分享 URI、Clash YAML 和 Xray 客户端出站片段。
- 删除节点：选择 **2）管理节点 → 2）删除节点**，输入节点序号并确认。

将分享 URI 导入客户端，或把 Clash 节点行复制到现有配置的 `proxies` 部分。Xray 客户端出站片段需要合并到自己的客户端配置中。

新增、删除节点和切换出口会重启 Xray，现有连接会短暂中断。

## 更新脚本

主菜单顶部会分别显示脚本版本和 Xray 核心版本。也可单独查看脚本版本：

```bash
xrm --version
```

运行 `xrm`，选择 **5）更新脚本**，会显示已安装版本和 GitHub 上的版本。有新版本时进行更新，版本相同时提示“已是最新版本”；已安装版本更高时会保留，不会降级。更新成功后会显示更新前后的版本号，退出菜单后再次运行 `xrm` 使用新版。

没有版本号的旧脚本可按原方式更新一次，之后即可查看版本号和检查更新。

更新脚本会保留已有节点、密钥和出口档案，不需要重建节点，也不会自动升级已有 Xray 核心。升级核心请选择 **4）管理 Xray → 1）升级 Xray**。

## Geo 数据更新

选择 **4）管理 Xray → 4）更新 Geo 数据**，查看当前自动更新状态并选择操作：

- **1）手动更新**：立即检查并更新 Geo 数据。
- **2）每周更新**：每周日 04:00 自动更新。
- **3）每日更新**：每天 04:00 自动更新。
- **4）关闭自动更新**：移除本脚本的定时任务。
- **0）返回**：回到管理 Xray 菜单。

定时更新按服务器本地时区执行。

手动和定时更新都只在数据发生变化时应用更新。Xray 正在运行时会重启以加载新数据，连接会短暂中断；原先停止时保持停止。更新失败会保留或恢复原数据。

使用自定义 Geo 数据目录时，按 Xray 服务实际加载的位置更新，完成后显示两份数据的路径。无法确认自定义服务环境时会停止更新并提示原因；停止状态的复杂自定义服务可先启动 Xray 后重试。

请先更新全局命令到 `v1.1.3` 或更高版本，以使用最新 Geo 更新功能。仅上传并运行新脚本时，全局命令仍可能是旧版；可用 `xrm --version` 确认。

Debian / Ubuntu 使用 systemd 定时器，可通过 `journalctl -u xrm-geo-update.service -n 30 --no-pager` 查看执行日志。Alpine 使用 root 的 cron，日志在 `/var/log/xrm-geo-update.log`。关闭定时更新只移除本脚本的任务，不会关闭其他 cron 任务。

## 出口管理

主菜单选择 **3）管理出口**。页面顶部显示当前普通出口和 AI 分流状态，切换后自动刷新。普通出口会显示直连，或已应用节点的名称、地址、端口和加密方式；档案已删除或修改时，仍显示实际配置中的出口地址。

子菜单选项：

- **1）添加出口**：通过 SS URI 或手动填写保存出口，支持上述两种传统 AEAD 和三种 SS2022。
- **2）查看出口**：查看已保存的出口列表。
- **3）删除出口**：删除已保存的档案。
- **4）选择出口**：第 1 项为直连，第 2 项起为已保存出口。
- **5）AI 分流**：查看当前 AI 出口并进行选择。
- **0）返回主菜单**。

“选择出口”设置未命中路由规则时的默认出口，保留已有路由和其他出站。显式指向 `proxy` 的规则也会使用所选 SS 节点。支持标准 SS2022 的百分号编码认证信息及既有 Base64 / Base64URL 链接；无法识别的 URI 可改用手动填写。

### AI 分流

先将全局命令更新到 `v1.2.0` 或更高版本。AI 分流页面提供：

- **1）直连**：AI 请求从服务器本机出口发出。
- **2）跟随选择出口（默认）**：不设置专用 AI 路由，按已有路由及普通出口处理。
- **第 3 项起为已保存出口**：AI 请求独立使用选定节点，普通出口切换不影响它。
- **0）返回**；直接回车也只返回，不会自动选择直连。

AI 初始状态为“跟随选择出口”。添加档案后，需要在普通出口或 AI 分流页面选择一次才会应用；修改、删除档案不会自动更改已经应用的出口，更换节点请重新选择。

AI 域名使用 `geosite:category-ai-!cn` 分类，包含 ChatGPT/OpenAI、Claude、Gemini、Copilot 等，随现有 Geo 数据一起更新。启用前会检查本机数据是否支持该分类；旧数据缺少分类时，可先在 **管理 Xray → 更新 Geo 数据** 中手动更新。

现有前置拦截规则继续生效。分流依赖目标域名：脚本会为自身管理且尚未配置嗅探的节点启用仅用于路由的 HTTP/TLS/QUIC 域名识别，并保留已有嗅探设置。恢复“跟随”时会清理仍保持原样的自动添加项。无法获取域名的纯 IP 或加密域名流量仍按普通路由处理。

有前置 IP 拦截时，启用 AI 分流会按需将 `IPIfNonMatch` 切换为 `IPOnDemand`，让域名请求先经过 IP 检查。恢复“跟随”时还原未被手动修改的解析策略。

脚本默认阻止访问私有 IP 和中国大陆 IP，分类依赖服务器上的 Geo 数据文件。

## 文件位置

| 内容 | 服务器路径 |
| --- | --- |
| Xray 核心 | `/usr/local/bin/xray` |
| Xray 配置 | `/usr/local/etc/xray/config.json` |
| Clash 节点 | `/usr/local/etc/xray/clash_nodes.yaml` |
| 节点元数据 | `/usr/local/etc/xray/nodes_meta.json` |
| SS 出口档案（含 SS2022） | `/usr/local/etc/xray/outbound_profiles.json` |
| GeoIP / GeoSite（默认） | `/usr/local/share/xray/` |
| 管理命令 | `/usr/local/bin/xrm` |

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

感谢 [Xray-core](https://github.com/XTLS/Xray-core) 项目及其贡献者提供的核心程序和文档。
