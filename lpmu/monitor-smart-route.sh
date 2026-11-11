#!/bin/bash

# 智能路由监控脚本
# 持续监控网络状态，自动切换最优路由

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
source "$SCRIPT_DIR/lpmu-network.sh" || exit 1
PRIMARY_IFACE=$(lpmu_internal_interface) || exit 1
TEST_HOST="8.8.8.8"
CHECK_INTERVAL=30  # 检查间隔（秒）
TIMEOUT=3

# 获取当前默认路由的接口
get_current_default_interface() {
    ip route show default | head -1 | awk '{print $5}'
}

# 获取接口的网关
get_gateway() {
    local iface=$1
    ip route show dev "$iface" | grep -oP 'default via \K[0-9.]+' | head -1
}

# 测试接口是否能访问互联网
test_internet() {
    local iface=$1
    ping -c 2 -W $TIMEOUT -I "$iface" "$TEST_HOST" &>/dev/null
    return $?
}

# 切换到指定接口
switch_to_interface() {
    local iface=$1
    local gateway=$2
    
    echo "[$(date)] 切换路由到 $iface (网关: $gateway)"
    
    # 删除所有默认路由
    while sudo ip route del default 2>/dev/null; do
        :
    done
    
    # 添加新的默认路由
    sudo ip route add default via "$gateway" dev "$iface" metric 100
    
    # 重新配置 NAT
    echo "[$(date)] 重新配置 NAT..."
    if [ -f /usr/local/bin/lpmu-setup-nat.sh ]; then
        /usr/local/bin/lpmu-setup-nat.sh 2>&1 | grep -E "(MASQUERADE|FORWARD|接口)"
    else
        # 如果服务未安装，尝试本地脚本
        if [ -f "$SCRIPT_DIR/setup-nat.sh" ]; then
            sudo "$SCRIPT_DIR/setup-nat.sh" 2>&1 | grep -E "(MASQUERADE|FORWARD|接口)"
        fi
    fi
}

echo "=== LPMU 智能路由监控启动 ==="
echo "优先接口: $PRIMARY_IFACE"
echo "检查间隔: ${CHECK_INTERVAL}秒"
echo "测试主机: $TEST_HOST"
echo ""

while true; do
    CURRENT_IFACE=$(get_current_default_interface)
    
    if [ -z "$CURRENT_IFACE" ]; then
        echo "[$(date)] 警告: 没有默认路由，尝试配置..."
        /usr/local/bin/lpmu-setup-smart-route.sh
    else
        # 测试当前接口
        if ! test_internet "$CURRENT_IFACE"; then
            echo "[$(date)] 当前接口 $CURRENT_IFACE 无法访问互联网"
            
            # 如果当前不是主接口，尝试主接口
            if [ "$CURRENT_IFACE" != "$PRIMARY_IFACE" ]; then
                PRIMARY_GATEWAY=$(get_gateway "$PRIMARY_IFACE")
                if [ -n "$PRIMARY_GATEWAY" ] && test_internet "$PRIMARY_IFACE"; then
                    echo "[$(date)] 主接口 $PRIMARY_IFACE 恢复，切换回主接口"
                    switch_to_interface "$PRIMARY_IFACE" "$PRIMARY_GATEWAY"
                fi
            else
                # 主接口失败，查找备用接口
                echo "[$(date)] 查找备用接口..."
                /usr/local/bin/lpmu-setup-smart-route.sh
            fi
        else
            # 当前接口正常，如果不是主接口，检查主接口是否恢复
            if [ "$CURRENT_IFACE" != "$PRIMARY_IFACE" ]; then
                PRIMARY_GATEWAY=$(get_gateway "$PRIMARY_IFACE")
                if [ -n "$PRIMARY_GATEWAY" ] && test_internet "$PRIMARY_IFACE"; then
                    echo "[$(date)] 主接口 $PRIMARY_IFACE 已恢复，切换回主接口"
                    switch_to_interface "$PRIMARY_IFACE" "$PRIMARY_GATEWAY"
                fi
            fi
        fi
    fi
    
    sleep "$CHECK_INTERVAL"
done
