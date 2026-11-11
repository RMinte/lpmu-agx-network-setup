# LPMU / AGX 网络配置

99（LPMU）为 97 的网页和 98（AGX）的模型等服务提供对外入口，并作为 98 的上网网关。
固定内网地址保持为 `10.10.99.98/24`、`10.10.99.99/24`；上联网卡和上层 IPv4 地址可以变化。

## 访问约定

| 访问入口 | 实际服务 | 协议 |
| --- | --- | --- |
| 99 当前任意本机 IPv4 的 `57080` | 97 的网页 `80` | TCP |
| 99 当前任意本机 IPv4 的 `58000–58999` | 98 的相同端口 | TCP、UDP |
| 99 当前任意本机 IPv4 的 `58022` | 98 的 SSH `22` | TCP，优先于范围规则 |
| 99 当前上层 IPv4 + Docker 已发布端口 | 99 本机 Docker 应用 | 由 Docker 原有映射决定 |

UDP `58022` 仍到达 98 的 UDP `58022`。`59000` 不属于转给 98 的范围，仍可供 99 的应用使用。
映射不代表每个端口都有服务，98 必须实际启动相应监听。

上层网络和所有普通 Docker 网桥均可通过 99 的 `57080` 访问 97，并通过约定范围访问 98；规则不绑定 Octop、Docker 子网、USB 网卡名或某个上层 IP。
例如，当前上层地址是 `10.27.141.129` 时：

```text
97 网页入口：  http://10.27.141.129:57080
模型 Base URL：http://10.27.141.129:58000/v1
模型列表：     http://10.27.141.129:58000/v1/models
SSH 到 98：    ssh -p 58022 user@10.27.141.129
```

更换网络后，客户端改用 99 新获得的地址，端口约定保持一致，NAT 规则无需重建。
规则不会自动修改应用中已经保存的旧 IP；服务器之间的应用配置可使用固定内网服务地址。
`host` 模式共用 99 的网络，应直接使用 `10.10.99.97:80`、`10.10.99.98` 的服务端口或 SSH `22`；本项目不添加本地 OUTPUT 地址转换。

## 在 99 上配置

要求 Linux、Bash、iproute2、iptables（含 iptables-restore）、util-linux（flock）和 sudo/root。
先确认连接 97 和 98 的内网接口已配置 `10.10.99.99/24`。脚本按这个地址识别接口，要求地址只配置在一个接口上。

### 只配置转发，保留当前默认路由

```bash
cd lpmu
sudo ./setup-nat.sh
sudo ./test-nat.sh
```

`setup-nat.sh` 仅更新项目自己的 `LPMU_*` 链和跳转，不清空 NAT/FORWARD，不修改 FORWARD 默认策略或默认路由。
Docker 的发布端口、隔离规则和其他已有规则保持原样；97 的网页入口和 98 的端口范围仅针对已转换目的地址的连接独立放行。过滤链排在既有 Docker/主机规则之后，因此已有的用户拒绝和隔离规则先执行。未匹配请求明确 RETURN，不等于全部放行。
SNAT 保证 97/98 的转发服务回复经 99 返回；98 的外部访问使用 MASQUERADE。
只给本项目转发连接的回复增加连接标记 `0x40000000/0x40000000`，并通过优先级 34 查询 main 的具体路由，忽略其默认路由。
这使回复能找到所有动态 Docker 网桥；其他未标记流量和既有 `fwmark` 策略不受这条规则匹配。其他标记位保持原样；部署环境需为本项目保留该高位。
优先级 34 若已有非本版本的规则会报错并保留原规则，由管理员手动处理；不自动兼容或删除未发布中间版本的策略规则。

新脚本不自动删除历史转发规则。旧版错误方向的 `97:80 → 99:57080`、旧范围规则及快照冲突，在部署后手动处理。
97 正确方向为 `99 当前地址:57080 → 10.10.99.97:80`，由 NAT 脚本统一配置；智能路由脚本不再创建原来的反向规则。
脚本不会自动修复曾被旧版本清空的 Docker 规则。容器互联网访问仍由 Docker 原生的放行和 NAT 提供；首次部署时通过重启 Docker 等人工恢复操作重新生成，项目脚本负责保留这些规则。
普通容器按实际路由出网，不绑定上层 IP 或某张 USB 网卡；明确设置为隔离的 Docker 网络保留隔离，应用已发布端口保持原样。

### 智能选择默认出口（可选）

```bash
sudo ./setup-smart-route.sh           # 优先 LPMU 内网接口，不能联网时选择备用接口
sudo ./setup-smart-route.sh --manual  # 手动选择
```

智能路由的出口选择和切换代码保持仓库原有行为：切换时删除默认路由，再建立选中出口的 metric 100 默认路由。转发配置自身不执行这一操作。
端口转发的入口选择与默认出口分开：metric 100 即使仍走 `10.10.99.100`，USB 上层网络也能访问转发服务。
内网的 97、98、99、100 地址不变。97 的网页使用修正后的 `99:57080 → 97:80`，与选中的联网出口无关。

### 安装开机恢复

```bash
sudo ./install-smart-route-service.sh
sudo systemctl start lpmu-nat.service
sudo systemctl start lpmu-smart-route.service
sudo systemctl start lpmu-smart-route-monitor.service
```

安装器将本目录脚本复制到 `/usr/local/bin/lpmu-*.sh` 并启用服务。
后续修改仓库脚本后须重新运行安装器，才能更新服务所用的副本。

- `lpmu-nat.service`：独立建立端口转发，不依赖互联网 ping 成功；在 Docker 启动后执行，通过 `PartOf=docker.service` 在 Docker 由 systemd 重启时重新建立项目跳转顺序。
- `lpmu-smart-route.service`：按既有策略选择联网出口。
- `lpmu-smart-route-monitor.service`：监控并切换联网出口。

`setup-nat.sh` 不自动保存整张 iptables 表。只需要转发开机恢复时使用：

```bash
sudo ./install-nat-service.sh
sudo systemctl start lpmu-nat.service
```

这个入口只启用转发恢复，不启用智能路由或监控。
原 `install-persistent.sh` 的软件包安装、IPv4/IPv6 规则保存行为保留，另外调用上述转发恢复安装器，确保重启后连接标记对应的策略规则也能恢复。
保存全表快照仍可能包含 Docker 运行时地址；已有的 netfilter-persistent 和历史快照需由部署管理员核查，安装器不会擅自删除系统配置。

IPv4 转发持久化写入 `/etc/sysctl.d/90-lpmu-forward.conf`。
隔离测试可使用 `setup-nat.sh --runtime-only`，只修改当前网络命名空间的转发状态和规则，不写持久化配置。

## 在 98 上配置

98 的固定 IPv4 为 `10.10.99.98/24`，默认网关为 `10.10.99.99`。
先查看接口名并修改所选脚本中的 `NETWORK_IFACE`：

```bash
ip -br addr
cd agx
sudo ./setup-network-persistent-netplan.sh  # 使用 Netplan 的系统
# 或：sudo ./setup-network-persistent-nm.sh # 使用 NetworkManager 的系统
# 临时配置：sudo ./setup-network.sh
sudo ./test-connection.sh
```

这些 AGX 配置脚本会替换指定接口的地址/连接配置，请在部署阶段执行。
99 的转发脚本不会修改 98 的网络设置。

## 验收

本机 `test-nat.sh` 检查规则存在及命中数；实际连通性必须分别从上层网络和容器验证：

```bash
# 上层网络客户端：替换成 99 当前上层地址
curl --noproxy '*' http://LPMU_IP:57080/
curl --noproxy '*' http://LPMU_IP:58000/v1/models
ssh -p 58022 user@LPMU_IP

# 在普通 Docker 容器中验证（镜像需要有 curl）
docker exec CONTAINER curl --noproxy '*' http://LPMU_IP:58000/v1/models

# 99 的 host 模式/本机进程直接访问 98
curl --noproxy '*' http://10.10.99.98:58000/v1/models
```

上层网络必须允许客户端连接到 99；若客户端跨网段，还需现有路由策略提供正确回程。
本项目不替换设备已有的策略路由，新增的转发连接回程规则如上；上级网络防火墙由所在网络管理。IPv6 不在本次端口映射范围内。

### 隔离集成测试

在 Linux 上执行，要求 root、iproute2、iptables、Python 3：

```bash
sudo python3 tests/test_forwarding.py
```

测试创建临时网络命名空间，模拟 99、97、98、上层网络和两个任意名称的 Docker 网桥。
所有测试网卡、路由、防火墙规则均在隔离环境；退出时删除测试命名空间。
覆盖 97 网页转发、TCP/UDP 范围边界、SSH 特例、多网桥访问、改名/换网段后无需重建规则、重复执行、保留旧规则供手动迁移、既有标记策略不变、低 metric 路由下的原有出口切换、保留默认路由、Docker 用户拒绝/隔离规则与既有发布端口、避免劫持其他服务器的相同端口，以及 host 直接访问 98。
这是 Linux 网络栈集成测试，未自动启动真正的 Docker daemon，也不代替目标设备的重启验收。

## 停用

```bash
sudo systemctl disable --now lpmu-smart-route-monitor.service
sudo systemctl disable --now lpmu-smart-route.service
sudo systemctl disable --now lpmu-nat.service
```

停止服务不会主动清除当前规则。如需删除本项目的转发，只删除 `LPMU_*` 跳转与链以及项目添加的优先级 34 规则；不要全局清空 iptables，以免破坏 Docker 和其他服务。
