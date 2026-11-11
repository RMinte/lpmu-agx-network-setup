#!/bin/bash

# 智能路由配置脚本
# 优先使用 LPMU 内网接口，如果无法联网则自动切换到其他接口

set -e

TEST_HOST="8.8.8.8"
TIMEOUT=3
MANUAL_MODE=false

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--manual)
            MANUAL_MODE=true
            shift
            ;;
        -h|--help)
            echo "用法: $0 [-m|--manual] [-h|--help]"
            echo ""
            echo "选项:"
            echo "  -m, --manual    手动选择网关接口"
            echo "  -h, --help      显示此帮助信息"
            echo ""
            echo "默认行为: 自动检测并选择可用的网关接口"
            exit 0
            ;;
        *)
            echo "未知选项: $1"
            echo "使用 -h 或 --help 查看帮助"
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lpmu-network.sh"
PRIMARY_IFACE=$(lpmu_internal_interface)

echo "=== LPMU 智能路由配置 ==="
echo ""

# 获取接口的网关
get_gateway() {
    local iface=$1
    ip route show dev "$iface" | grep -oP 'default via \K[0-9.]+' | head -1
}

# 测试接口是否能访问互联网
test_internet() {
    local iface=$1
    local gateway=$2
    
    if [ -z "$gateway" ]; then
        return 1
    fi
    
    # 通过特定接口 ping 测试
    ping -c 2 -W $TIMEOUT -I "$iface" "$TEST_HOST" &>/dev/null
    return $?
}

# 获取所有有网关的接口
get_all_interfaces_with_gateway() {
    ip route | grep '^default' | awk '{print $5}' | sort -u
}

# 获取所有物理网络接口（排除 lo 和虚拟接口）
get_all_network_interfaces() {
    ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | grep -v '@' | sort -u
}

# 获取接口的 IP 地址
get_ip_address() {
    local iface=$1
    ip -4 addr show dev "$iface" 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1
}

# 获取接口状态 (UP/DOWN)
get_iface_state() {
    local iface=$1
    ip link show dev "$iface" 2>/dev/null | grep -q 'state UP' && echo "UP" || echo "DOWN"
}

echo "1. 检测所有网络接口..."
ALL_INTERFACES=$(get_all_network_interfaces)
INTERFACES=$(get_all_interfaces_with_gateway)
echo "   发现接口: $ALL_INTERFACES"
echo ""

# 手动模式
if [ "$MANUAL_MODE" = true ]; then
    echo "2. 手动选择模式 - 检测所有接口..."
    echo ""
    
    # 收集所有接口信息
    declare -A IFACE_IP
    declare -A IFACE_GATEWAY
    declare -A IFACE_STATUS
    declare -A IFACE_STATE
    IFACE_LIST=()
    
    for iface in $ALL_INTERFACES; do
        IFACE_LIST+=("$iface")
        IFACE_STATE["$iface"]=$(get_iface_state "$iface")
        IFACE_IP["$iface"]=$(get_ip_address "$iface")
        IFACE_GATEWAY["$iface"]=$(get_gateway "$iface")
        
        echo -n "   检测 $iface "
        echo -n "[${IFACE_STATE[$iface]}]"
        
        if [ -n "${IFACE_IP[$iface]}" ]; then
            echo -n " IP: ${IFACE_IP[$iface]}"
        else
            echo -n " IP: 无"
        fi
        
        if [ -n "${IFACE_GATEWAY[$iface]}" ]; then
            echo -n " 网关: ${IFACE_GATEWAY[$iface]}"
            echo -n " ... "
            if test_internet "$iface" "${IFACE_GATEWAY[$iface]}"; then
                IFACE_STATUS["$iface"]="✓ 可联网"
                echo "✓ 可联网"
            else
                IFACE_STATUS["$iface"]="✗ 无法联网"
                echo "✗ 无法联网"
            fi
        else
            echo " 网关: 无"
            IFACE_STATUS["$iface"]="- 无网关"
        fi
    done
    
    if [ ${#IFACE_LIST[@]} -eq 0 ]; then
        echo ""
        echo "✗ 错误：没有找到网络接口"
        exit 1
    fi
    
    echo ""
    echo "┌────────────────────────────────────────────────────────────────┐"
    echo "│                      可用接口列表                              │"
    echo "├────┬──────────────┬────────┬─────────────────┬─────────────────┤"
    printf "│ %-2s │ %-12s │ %-6s │ %-15s │ %-15s │\n" "#" "接口" "状态" "IP 地址" "网关"
    echo "├────┼──────────────┼────────┼─────────────────┼─────────────────┤"
    for i in "${!IFACE_LIST[@]}"; do
        iface="${IFACE_LIST[$i]}"
        ip_addr="${IFACE_IP[$iface]:-无}"
        gateway="${IFACE_GATEWAY[$iface]:-无}"
        state="${IFACE_STATE[$iface]}"
        printf "│ %-2s │ %-12s │ %-6s │ %-15s │ %-15s │\n" "$((i+1))" "$iface" "$state" "$ip_addr" "$gateway"
    done
    echo "└────┴──────────────┴────────┴─────────────────┴─────────────────┘"
    
    echo ""
    echo "连接状态:"
    for i in "${!IFACE_LIST[@]}"; do
        iface="${IFACE_LIST[$i]}"
        echo "  $((i+1)). $iface: ${IFACE_STATUS[$iface]}"
    done
    
    echo ""
    read -p "请选择接口编号 [1-${#IFACE_LIST[@]}]: " choice
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#IFACE_LIST[@]} ]; then
        echo "✗ 无效的选择"
        exit 1
    fi
    
    CHOSEN_IFACE="${IFACE_LIST[$((choice-1))]}"
    CHOSEN_GATEWAY="${IFACE_GATEWAY[$CHOSEN_IFACE]}"
    
    if [ -z "$CHOSEN_GATEWAY" ]; then
        echo ""
        echo "⚠ 警告: $CHOSEN_IFACE 没有配置网关"
        read -p "请输入网关地址 (或按回车取消): " manual_gateway
        if [ -z "$manual_gateway" ]; then
            echo "✗ 取消操作"
            exit 1
        fi
        CHOSEN_GATEWAY="$manual_gateway"
    fi
    
    echo ""
    echo "已选择: $CHOSEN_IFACE (网关: $CHOSEN_GATEWAY)"
    echo ""
fi

# 自动模式
if [ "$MANUAL_MODE" = false ]; then
    # 测试主接口
    echo "2. 测试主接口 $PRIMARY_IFACE..."
PRIMARY_GATEWAY=$(get_gateway "$PRIMARY_IFACE")

if [ -n "$PRIMARY_GATEWAY" ]; then
    echo "   网关: $PRIMARY_GATEWAY"
    if test_internet "$PRIMARY_IFACE" "$PRIMARY_GATEWAY"; then
        echo "   ✓ $PRIMARY_IFACE 可以访问互联网"
        CHOSEN_IFACE="$PRIMARY_IFACE"
        CHOSEN_GATEWAY="$PRIMARY_GATEWAY"
    else
        echo "   ✗ $PRIMARY_IFACE 无法访问互联网"
    fi
else
    echo "   ✗ $PRIMARY_IFACE 没有配置网关"
fi

echo ""

# 如果主接口不可用，尝试其他接口
if [ -z "$CHOSEN_IFACE" ]; then
    echo "3. 主接口不可用，测试备用接口..."
    
    for iface in $INTERFACES; do
        if [ "$iface" = "$PRIMARY_IFACE" ]; then
            continue
        fi
        
        echo "   测试 $iface..."
        gateway=$(get_gateway "$iface")
        
        if [ -n "$gateway" ]; then
            echo "     网关: $gateway"
            if test_internet "$iface" "$gateway"; then
                echo "     ✓ $iface 可以访问互联网"
                CHOSEN_IFACE="$iface"
                CHOSEN_GATEWAY="$gateway"
                break
            else
                echo "     ✗ $iface 无法访问互联网"
            fi
        fi
    done
    echo ""
fi
fi

# 如果找到可用接口，配置路由
if [ -n "$CHOSEN_IFACE" ]; then
    echo "4. 配置路由 - 使用接口: $CHOSEN_IFACE (网关: $CHOSEN_GATEWAY)"
    
    lpmu_select_default_route "$CHOSEN_IFACE" "$CHOSEN_GATEWAY"
    
    echo ""
    echo "5. 当前路由表："
    ip route show
    
    echo ""
    echo "6. 测试互联网连接："
    if ping -c 3 "$TEST_HOST"; then
        echo ""
        echo "✓ 互联网连接正常！"
        echo ""
        echo "当前使用接口: $CHOSEN_IFACE"
        echo "网关: $CHOSEN_GATEWAY"
        
        # 自动配置 NAT
        echo ""
        echo "7. 自动配置 NAT..."
        if [ -f "$SCRIPT_DIR/setup-nat.sh" ]; then
            sudo "$SCRIPT_DIR/setup-nat.sh"
        elif [ -f "$SCRIPT_DIR/lpmu-setup-nat.sh" ]; then
            sudo "$SCRIPT_DIR/lpmu-setup-nat.sh"
        else
            echo "找不到配套 NAT 脚本，请重新安装" >&2
            exit 1
        fi
        
        # 97/98 的端口转发由配套 NAT 脚本统一配置，与所选出口地址无关。
        echo "97 网页入口：99 当前地址:57080 → 10.10.99.97:80"
    else
        echo ""
        echo "✗ 互联网连接失败"
        exit 1
    fi
else
    echo "✗ 错误：没有找到可用的互联网连接"
    echo ""
    echo "当前路由表："
    ip route show
    exit 1
fi

echo ""
echo "=== 配置完成 ==="
