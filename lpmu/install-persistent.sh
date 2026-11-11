#!/bin/bash
# 安装并配置iptables持久化服务

set -e

echo "=== 安装iptables持久化 ==="

# 检测系统类型
if [ -f /etc/debian_version ]; then
    echo "检测到Debian/Ubuntu系统"
    apt-get update
    apt-get install -y iptables-persistent
    
    # 保存当前规则
    iptables-save > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6
    
    echo "规则已保存到 /etc/iptables/rules.v4"
    
elif [ -f /etc/redhat-release ]; then
    echo "检测到RedHat/CentOS系统"
    yum install -y iptables-services
    
    systemctl enable iptables
    systemctl start iptables
    
    # 保存当前规则
    service iptables save
    
    echo "规则已保存"
    
else
    echo "未知系统类型，请手动配置iptables持久化"
    exit 1
fi


# 仅补充本项目转发规则及回程策略的开机恢复，不启用智能路由或监控。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sudo "$SCRIPT_DIR/install-nat-service.sh"

echo "=== 安装完成 ==="
