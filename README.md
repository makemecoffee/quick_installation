# quick_installation
## 安装之前请确保bash和curl已经安装
### Alpine
```sh
apk update
apk add --no-cache bash curl
```
### Debian
```sh
apt update
apt install -y bash curl
```
## 前提声明
- 本脚本只是简单的部署，出现其他问题与作者无关
- 未提示有默认值的均需要手动输入
- 无默认sni需要自备，sni默认指向443
- vvr脚本可支持安装配置卸载
- alpine_hy2安装不成功请自行DD系统再用，无DD教程
---
## 一键安装
### Debian系列
- VLESS-VISION-REALITY
```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/debian_vvr.sh)
```
---
- hysteria2
```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/debian_hy2.sh)
```
---
### Alpine系列
- VLESS-VISION-REALITY 
```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/alpine_vvr.sh)
```
- 查看URI与YAML命令
```sh
cat /usr/local/etc/xray/sublink.txt
```
---
- hysteria2
```sh
bash <(curl -fsSL https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/alpine_hy2.sh)
```
- 查看URI与YAML命令
```sh
cat /etc/hysteria/sublink.txt
```
---
