#!/bin/bash
# 在 99 上提供 97/98 的服务；保留默认路由和 Docker 规则。
set -euo pipefail

RUNTIME_ONLY=false
case "${1:-}" in
    '') ;;
    --runtime-only) RUNTIME_ONLY=true ;;
    *) echo "用法: $0 [--runtime-only]" >&2; exit 1 ;;
esac
[[ $# -le 1 ]] || { echo "参数过多" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "请使用 sudo 执行" >&2; exit 1; }

INTERNAL_IFACE="enp2s0"
INTERNAL_IP="10.10.99.99"
INTERNAL_NET="10.10.99.0/24"
AGX_IP="10.10.99.98"
WEB_IP="10.10.99.97"
AGX_LOCAL_RULE_PRIORITY=34
RETURN_MARK="0x40000000/0x40000000"

for command_name in ip iptables iptables-restore sysctl flock; do
    command -v "$command_name" >/dev/null || { echo "缺少命令: $command_name" >&2; exit 1; }
done
ip -4 -o addr show dev "$INTERNAL_IFACE" | awk '{print $4}' | grep -qx "$INTERNAL_IP/24" || {
    echo "$INTERNAL_IFACE 必须已配置 $INTERNAL_IP/24" >&2
    exit 1
}

# 防止开机服务与路由监控同时重建项目链。
exec 9>/run/lpmu-network-setup.lock
flock -x 9
# 仅对本项目转发连接的回复优先查询具体路由，避免影响其他流量。
# 标记只使用一个高位，保留既有 fwmark（例如 0x100）的其他位。
existing_rule=$(ip -4 rule show priority "$AGX_LOCAL_RULE_PRIORITY")
expected_rule="$AGX_LOCAL_RULE_PRIORITY:"*"from $INTERNAL_NET fwmark $RETURN_MARK lookup main suppress_prefixlength 0"
if [[ -n "$existing_rule" && ( "$existing_rule" == *$'\n'* || "$existing_rule" != $expected_rule ) ]]; then
    echo "策略路由优先级 $AGX_LOCAL_RULE_PRIORITY 已被占用，请先核实" >&2
    exit 1
fi
if [[ -z "$existing_rule" ]]; then
    ip -4 rule add priority "$AGX_LOCAL_RULE_PRIORITY" from "$INTERNAL_NET" fwmark "$RETURN_MARK" lookup main suppress_prefixlength 0
fi
sysctl -w net.ipv4.ip_forward=1 >/dev/null
if [[ "$RUNTIME_ONLY" == false ]]; then
    printf '%s\n' 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/90-lpmu-forward.conf
fi

# LOCAL 在每次新连接时判断本机当前地址，因此更换上联网段、USB 网卡和
# Docker 网桥均无需重写 DNAT。host 模式直接访问 97/98 的实际服务地址。
# SSH 规则必须排在端口范围之前；UDP 58022 保持同端口转发。
iptables-restore --wait 10 --noflush <<RULES
*mangle
:LPMU_CONNMARK - [0:0]
-F LPMU_CONNMARK
-A LPMU_CONNMARK -m conntrack --ctdir ORIGINAL -m addrtype --dst-type LOCAL -p tcp --dport 57080 -j CONNMARK --set-xmark $RETURN_MARK
-A LPMU_CONNMARK -m conntrack --ctdir ORIGINAL -m addrtype --dst-type LOCAL -p tcp --dport 58000:58999 -j CONNMARK --set-xmark $RETURN_MARK
-A LPMU_CONNMARK -m conntrack --ctdir ORIGINAL -m addrtype --dst-type LOCAL -p udp --dport 58000:58999 -j CONNMARK --set-xmark $RETURN_MARK
-A LPMU_CONNMARK -s $INTERNAL_NET -i $INTERNAL_IFACE -m conntrack --ctdir REPLY -m connmark --mark $RETURN_MARK -j CONNMARK --restore-mark --nfmask 0x40000000 --ctmask 0x40000000
COMMIT
*nat
:LPMU_PREROUTING - [0:0]
:LPMU_POSTROUTING - [0:0]
-F LPMU_PREROUTING
-F LPMU_POSTROUTING
-A LPMU_PREROUTING -m addrtype --dst-type LOCAL -p tcp --dport 57080 -j DNAT --to-destination $WEB_IP:80
-A LPMU_PREROUTING -m addrtype --dst-type LOCAL -p tcp --dport 58022 -j DNAT --to-destination $AGX_IP:22
-A LPMU_PREROUTING -m addrtype --dst-type LOCAL -p tcp --dport 58000:58999 -j DNAT --to-destination $AGX_IP
-A LPMU_PREROUTING -m addrtype --dst-type LOCAL -p udp --dport 58000:58999 -j DNAT --to-destination $AGX_IP
-A LPMU_POSTROUTING -d $WEB_IP -o $INTERNAL_IFACE -p tcp --dport 80 -m conntrack --ctstate DNAT -j SNAT --to-source $INTERNAL_IP
-A LPMU_POSTROUTING -d $AGX_IP -o $INTERNAL_IFACE -p tcp --dport 22 -m conntrack --ctstate DNAT -j SNAT --to-source $INTERNAL_IP
-A LPMU_POSTROUTING -d $AGX_IP -o $INTERNAL_IFACE -p tcp --dport 58000:58999 -m conntrack --ctstate DNAT -j SNAT --to-source $INTERNAL_IP
-A LPMU_POSTROUTING -d $AGX_IP -o $INTERNAL_IFACE -p udp --dport 58000:58999 -m conntrack --ctstate DNAT -j SNAT --to-source $INTERNAL_IP
-A LPMU_POSTROUTING -s $INTERNAL_NET ! -d $INTERNAL_NET -j MASQUERADE
-A LPMU_POSTROUTING -j RETURN
-A LPMU_PREROUTING -j RETURN
COMMIT
*filter
:LPMU_FORWARD - [0:0]
-F LPMU_FORWARD
-A LPMU_FORWARD -d $INTERNAL_NET -o $INTERNAL_IFACE -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A LPMU_FORWARD -d $WEB_IP -o $INTERNAL_IFACE -p tcp --dport 80 -m conntrack --ctstate DNAT -j ACCEPT
-A LPMU_FORWARD -d $AGX_IP -o $INTERNAL_IFACE -p tcp --dport 22 -m conntrack --ctstate DNAT -j ACCEPT
-A LPMU_FORWARD -d $AGX_IP -o $INTERNAL_IFACE -p tcp --dport 58000:58999 -m conntrack --ctstate DNAT -j ACCEPT
-A LPMU_FORWARD -d $AGX_IP -o $INTERNAL_IFACE -p udp --dport 58000:58999 -m conntrack --ctstate DNAT -j ACCEPT
-A LPMU_FORWARD -s $INTERNAL_NET -i $INTERNAL_IFACE -j ACCEPT
-A LPMU_FORWARD -j RETURN
COMMIT
RULES

# NAT 优先处理约定端口；filter 在既有规则之后运行，尊重 Docker 用户拒绝
# 和内部网络隔离。mangle 在现有标记之后运行。仅移动本项目的跳转。
attach_chain() {
    local table=$1 parent=$2 target=$3
    while iptables -w 10 -t "$table" -C "$parent" -j "$target" 2>/dev/null; do
        iptables -w 10 -t "$table" -D "$parent" -j "$target"
    done
    if [[ "$table" == mangle || "$table" == filter ]]; then
        iptables -w 10 -t "$table" -A "$parent" -j "$target"
    else
        iptables -w 10 -t "$table" -I "$parent" 1 -j "$target"
    fi
}
attach_chain mangle PREROUTING LPMU_CONNMARK
attach_chain nat PREROUTING LPMU_PREROUTING
attach_chain nat POSTROUTING LPMU_POSTROUTING
attach_chain filter FORWARD LPMU_FORWARD

# 旧转发冲突按部署约定由管理员手动处理；这里不自动删除历史转发。
echo "网页入口：99 当前任意本机 IPv4 的 TCP 57080 → $WEB_IP:80"
echo "已配置：99 当前任意本机 IPv4 的 TCP/UDP 58000–58999 → 98 同端口"
echo "SSH 特例：TCP 58022 → 98:22；入口包括上联网卡及所有普通 Docker 网桥"
echo "默认路由与其他防火墙规则已保留；host 模式请直接访问 97/98 实际服务地址"
if [[ "$RUNTIME_ONLY" == false ]]; then
    echo "只安装转发恢复：install-nat-service.sh；智能路由安装方式保持原有入口。"
fi
