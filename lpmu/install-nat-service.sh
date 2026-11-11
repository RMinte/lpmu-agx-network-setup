#!/bin/bash
# 只安装转发规则的开机恢复，不启用联网出口选择或监控。
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sudo install -m 0644 "$SCRIPT_DIR/lpmu-network.sh" /usr/local/bin/lpmu-network.sh
sudo cp "$SCRIPT_DIR/setup-nat.sh" /usr/local/bin/lpmu-setup-nat.sh
sudo chmod +x /usr/local/bin/lpmu-setup-nat.sh
sudo tee /etc/systemd/system/lpmu-nat.service > /dev/null <<'UNIT'
[Unit]
Description=LPMU AGX port forwarding
After=network-online.target netfilter-persistent.service iptables.service docker.service
Wants=network-online.target
PartOf=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/lpmu-setup-nat.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable lpmu-nat.service
echo "已安装转发恢复服务；立即应用：sudo systemctl restart lpmu-nat.service"
