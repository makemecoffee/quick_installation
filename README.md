# Xray 轻量双协议管理脚本

基于 Bash 的 Xray 管理脚本，提供 Shadowsocks（SS，含 SS2022）和 VLESS + REALITY + Vision 节点管理，以及直连和 SS 出口切换。

## 功能

- 默认安装 Xray 最新正式版，支持核心升级、系统服务及 GeoIP / GeoSite 手动和定时更新。
- 创建、查看和删除 SS（含 SS2022）、VLESS + REALITY + Vision 节点。
- SS 入站和出口均支持传统 AEAD `aes-128-gcm`、`aes-256-gcm`，以及 SS2022 的 `2022-blake3-aes-128-gcm`、`2022-blake3-aes-256-gcm`、`2022-blake3-chacha20-poly1305`。
- 输出 Shadowrocket 分享 URI 和 Clash YAML 节点行，另保存 Xray 客户端出站片段。
- 自动生成 UUID、传统 SS 密码、SS2022 密钥、REALITY 密钥及 Short ID，也可按提示自定义部分参数。
- 保存多个 SS 出口配置（含 SS2022），按需切换直连或代理出口。
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

手动更新请选择 **4）管理 Xray → 4）更新 GeoIP&GeoSite**。

定时更新请选择 **4）管理 Xray → 6）定时更新 Geo 数据**，可启用每周更新（默认每周日 04:00）或每天更新（每天 04:00），也可在该菜单查看当前设置或关闭。时间按服务器本地时区执行。

手动和定时更新都只在数据发生变化时应用更新。Xray 正在运行时会重启以加载新数据，连接会短暂中断；原先停止时保持停止。更新失败会保留或恢复原数据。

请先更新全局命令到 `v1.1.0` 或更高版本，再开启定时任务。仅上传并运行新脚本时，全局命令仍可能是旧版；可用 `xrm --version` 确认。

Debian / Ubuntu 使用 systemd 定时器，可通过 `journalctl -u xrm-geo-update.service -n 30 --no-pager` 查看执行日志。Alpine 使用 root 的 cron，日志在 `/var/log/xrm-geo-update.log`。关闭定时更新只移除本脚本的任务，不会关闭其他 cron 任务。

## 出口管理

选择 **管理出口**，可切换直连，或通过 SS URI / 手动输入保存 SS 出口（支持上述两种传统 AEAD 和三种 SS2022），再选择并应用。切换出口会将所选出口置于出站列表首项，作为未命中路由时的默认出口；保留其他出站及已有路由规则。已有规则显式指定出口时，仍按该规则转发，不会随默认出口一起切换。

添加出口后，需要再选择 **选择出口** 才会应用。若 URI 无法识别，可改用手动填写。

脚本默认阻止访问私有 IP 和中国大陆 IP，分类依赖服务器上的 Geo 数据文件。

## 文件位置

| 内容 | 服务器路径 |
| --- | --- |
| Xray 核心 | `/usr/local/bin/xray` |
| Xray 配置 | `/usr/local/etc/xray/config.json` |
| Clash 节点 | `/usr/local/etc/xray/clash_nodes.yaml` |
| 节点元数据 | `/usr/local/etc/xray/nodes_meta.json` |
| SS 出口档案（含 SS2022） | `/usr/local/etc/xray/outbound_profiles.json` |
| GeoIP / GeoSite | `/usr/local/share/xray/` |
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
