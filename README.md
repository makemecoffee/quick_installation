# Xray 轻量双协议管理脚本

基于 Bash 的 Xray 管理脚本，提供 Shadowsocks（SS，含 SS2022）和 VLESS + REALITY + Vision 节点管理，以及直连和 SS 出口切换。

## 功能

- 默认安装 Xray 最新正式版，支持核心升级、系统服务及 GeoIP / GeoSite 数据管理。
- 创建、查看和删除 SS（含 SS2022）、VLESS + REALITY + Vision 节点。
- SS 入站和出口均支持传统 AEAD `aes-128-gcm`、`aes-256-gcm`，以及 SS2022 的 `2022-blake3-aes-128-gcm`、`2022-blake3-aes-256-gcm`、`2022-blake3-chacha20-poly1305`。
- 输出 Shadowrocket 分享 URI 和 Clash YAML 节点行，另保存 Xray 客户端出站片段。
- 自动生成 UUID、传统 SS 密码、SS2022 密钥、REALITY 密钥及 Short ID，也可按提示自定义部分参数。
- 保存多个 SS 出口配置（含 SS2022），按需切换直连或代理出口。
- 安装 `xrm` 全局命令，并通过菜单从 GitHub 更新脚本。

新增节点和手动添加出口时，加密方式菜单原有的 1–3 项保持为三种 SS2022，追加第 4 项 `aes-128-gcm`、第 5 项 `aes-256-gcm`；默认仍为第 1 项 `2022-blake3-aes-128-gcm`。传统 SS 可使用普通非空密码，SS2022 仍校验 Base64 密钥及解码后的长度。

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

## 更新与兼容性

更新脚本会保留已有 Xray 主配置、节点密钥、节点元数据及出口档案，不要求重建节点。节点和出口档案继续使用原有文件结构，菜单顺序及上述五种 SS 加密方式保持不变。缺失的辅助文件会补建，已有主配置和自定义路由不会因此被重置。

新增或删除节点、切换出口时，脚本会先用已安装的 Xray 核心预检候选配置，再提交文件并重启服务，备份保留到服务重启成功后再清理。预检不通过时保留原配置；提交或重启失败时恢复变更前的文件。重启失败后，原先运行的服务会尝试重新启动旧配置，原先停止的服务则恢复为停止。服务重启会短暂中断连接；核心预检只检查配置能否加载，不代表客户端导入或端到端连接已验证。

脚本使用以 `.json` 结尾的真实临时副本进行预检，并显式指定 JSON 格式，以兼容 Xray 26.3.27 和 26.10.21。手动预检时也应使用受支持的文件后缀：26.10.21 会检查解析软链接后的真实文件后缀，仅传入 `-format json` 不能绕过该检查，详见 [Xray-core 配置加载源码](https://github.com/XTLS/Xray-core/blob/v26.10.21/main/confloader/external/external.go)。

仓库回归检查需要 Bash、jq、OpenSSL 和一个可执行的 Xray 核心：

```bash
bash tests/run.sh /usr/local/bin/xray
```

检查使用临时目录和模拟服务操作，真实核心只用于配置预检及生成 UUID / REALITY 密钥，不会启动代理监听。Linux 上还会检查配置权限与软链接保留；实际 systemd / OpenRC 启停和客户端连通性仍需在服务器验证。

## 出口管理

选择 **管理出口**，可切换直连，或通过 SS URI / 手动输入保存 SS 出口（支持上述两种传统 AEAD 和三种 SS2022），再选择并应用。切换出口会将所选出口置于出站列表首项，作为未命中路由时的默认出口；保留其他出站及已有路由规则。已有规则显式指定出口时，仍按该规则转发，不会随默认出口一起切换。

脚本默认路由会将匹配 `geoip:private` 和 `geoip:cn` 的流量送往 `block` 出站；相关分类依赖服务器上的 Geo 数据文件。Xray 官方文档也说明 Freedom 在服务器端对某些目标有默认安全策略。

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
