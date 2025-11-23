#!/bin/bash

set -e

# 安装守护进程监控
install_daemon() {
    echo "=== Sing-box 守护进程监控脚本安装 ==="
    
    # 检测系统类型
    if [ -f /etc/alpine-release ]; then
        SYSTEM="alpine"
        echo "检测到系统: Alpine Linux"
    elif [ -f /etc/debian_version ]; then
        SYSTEM="debian"
        echo "检测到系统: Debian/Ubuntu"
        exit 1
    else
        echo "错误: 不支持的系统类型"
        exit 1
    fi
    
    # 创建监控脚本
    echo "创建监控脚本 /root/check-sb.sh ..."
    
    if [ "$SYSTEM" = "alpine" ]; then
        cat > /root/check-sb.sh << 'EOF'
#!/bin/sh

if ! pidof sing-box >/dev/null 2>&1; then
    rc-service sing-box start >/dev/null 2>&1
fi
EOF
    else
        cat > /root/check-sb.sh << 'EOF'
#!/bin/bash

if ! pidof sing-box >/dev/null 2>&1; then
    systemctl start sing-box >/dev/null 2>&1
fi
EOF
    fi
    
    # 赋予执行权限
    echo "赋予执行权限..."
    chmod +x /root/check-sb.sh
    
    # 添加到 crontab
    echo "配置 crontab 定时任务..."
    (crontab -l 2>/dev/null | grep -v '/root/check-sb.sh'; echo "*/1 * * * * /root/check-sb.sh") | crontab -
    
    echo ""
    echo "安装完成！"
    echo ""
    echo "监控脚本已创建: /root/check-sb.sh"
    echo "定时任务已配置: 每分钟检查一次 sing-box 进程"
    echo ""
    echo "查看 crontab: crontab -l"
    echo "手动测试脚本: /root/check-sb.sh"
}

# 移除守护进程监控
remove_daemon() {
    echo "=== Sing-box 守护进程监控脚本移除 ==="
    
    # 从 crontab 移除定时任务
    echo "移除 crontab 定时任务..."
    crontab -l 2>/dev/null | grep -v '/root/check-sb.sh' | crontab - 2>/dev/null || true
    
    # 删除监控脚本
    if [ -f /root/check-sb.sh ]; then
        echo "删除监控脚本 /root/check-sb.sh ..."
        rm -f /root/check-sb.sh
    fi
    
    echo ""
    echo "移除完成！"
    echo ""
    echo "定时任务已移除"
    echo "监控脚本已删除"
}

# 主菜单
case "${1:-}" in
    install)
        install_daemon
        ;;
    remove)
        remove_daemon
        ;;
    *)
        echo "用法: $0 {install|remove}"
        echo ""
        echo "  install  - 安装 sing-box 守护进程监控"
        echo "  remove   - 移除 sing-box 守护进程监控"
        exit 1
        ;;
esac
