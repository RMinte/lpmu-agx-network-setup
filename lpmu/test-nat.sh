#!/bin/bash
# 本机规则检查；端到端验收仍需从上层网络与容器实际请求服务。
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "请使用 sudo 执行" >&2; exit 1; }
[[ $(sysctl -n net.ipv4.ip_forward) == 1 ]]
ip -4 rule show priority 34 | grep -Fq 'from 10.10.99.0/24 fwmark 0x40000000/0x40000000 lookup main suppress_prefixlength 0'
iptables -w 10 -t mangle -C PREROUTING -j LPMU_CONNMARK
iptables -w 10 -t nat -C PREROUTING -j LPMU_PREROUTING
iptables -w 10 -t nat -C POSTROUTING -j LPMU_POSTROUTING
iptables -w 10 -C FORWARD -j LPMU_FORWARD
iptables -w 10 -t nat -C LPMU_PREROUTING -m addrtype --dst-type LOCAL -p tcp --dport 57080 -j DNAT --to-destination 10.10.99.97:80
iptables -w 10 -t nat -C LPMU_PREROUTING -m addrtype --dst-type LOCAL -p tcp --dport 58022 -j DNAT --to-destination 10.10.99.98:22
for protocol in tcp udp; do
    iptables -w 10 -t nat -C LPMU_PREROUTING -m addrtype --dst-type LOCAL -p "$protocol" --dport 58000:58999 -j DNAT --to-destination 10.10.99.98
done
echo "项目规则检查通过。当前路由与规则命中数："
ip route show default
iptables -w 10 -t nat -nvL LPMU_PREROUTING
iptables -w 10 -nvL LPMU_FORWARD
echo "这只证明规则已安装，不代表 98 的所有端口都在运行服务。"
