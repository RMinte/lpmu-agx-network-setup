#!/bin/bash

# 安装智能路由系统服务

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== 安装 LPMU 智能路由服务 ==="
echo ""

# 1. 复制脚本到系统目录
echo "1. 复制脚本到 /usr/local/bin/..."
sudo cp "$SCRIPT_DIR/setup-smart-route.sh" /usr/local/bin/lpmu-setup-smart-route.sh
sudo cp "$SCRIPT_DIR/monitor-smart-route.sh" /usr/local/bin/lpmu-monitor-smart-route.sh
sudo chmod +x /usr/local/bin/lpmu-setup-smart-route.sh /usr/local/bin/lpmu-monitor-smart-route.sh
sudo "$SCRIPT_DIR/install-nat-service.sh"

# 2. 创建启动时路由配置服务
echo "2. 创建启动时路由配置服务..."
sudo tee /etc/systemd/system/lpmu-smart-route.service > /dev/null <<'EOF'
[Unit]
Description=LPMU Smart Route Configuration
After=network-online.target lpmu-nat.service
Wants=network-online.target lpmu-nat.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/lpmu-setup-smart-route.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# 3. 创建路由监控服务
echo "3. 创建路由监控服务..."
sudo tee /etc/systemd/system/lpmu-smart-route-monitor.service > /dev/null <<'EOF'
[Unit]
Description=LPMU Smart Route Monitor
After=lpmu-smart-route.service
Requires=lpmu-smart-route.service

[Service]
Type=simple
ExecStart=/usr/local/bin/lpmu-monitor-smart-route.sh
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# 4. 重载 systemd
echo "4. 重载 systemd..."
sudo systemctl daemon-reload

# 5. 启用并启动服务
echo "5. 启用服务..."
sudo systemctl enable lpmu-smart-route.service
sudo systemctl enable lpmu-smart-route-monitor.service

echo ""
echo "=== 安装完成 ==="
echo ""
echo "立即启动服务："
echo "  sudo systemctl start lpmu-nat.service"
echo "  sudo systemctl start lpmu-smart-route.service"
echo "  sudo systemctl start lpmu-smart-route-monitor.service"
echo ""
echo "查看服务状态："
echo "  sudo systemctl status lpmu-smart-route.service"
echo "  sudo systemctl status lpmu-smart-route-monitor.service"
echo ""
echo "查看实时日志："
echo "  sudo journalctl -u lpmu-smart-route-monitor.service -f"
echo ""
echo "禁用服务："
echo "  sudo systemctl stop lpmu-smart-route-monitor.service"
echo "  sudo systemctl disable lpmu-smart-route.service"
echo "  sudo systemctl disable lpmu-smart-route-monitor.service"
echo "  sudo systemctl disable --now lpmu-nat.service"
