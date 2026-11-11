#!/usr/bin/env python3
"""Linux/root integration test. All links, routes and iptables live in temporary netns."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
PREFIX = f"lpmutest-{os.getpid()}"
NAMES = {name: f"{PREFIX}-{name}" for name in ("gw", "switch", "agx", "web", "upper", "c1", "c2")}
PROCESSES = []
CREATED = []
LINK_INDEX = 0


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


def ns(name, *args):
    return run("ip", "netns", "exec", NAMES[name], *args)


def link(a, aname, b, bname):
    global LINK_INDEX
    LINK_INDEX += 1
    # Host udev may assign identical persistent MACs when temporary names are reused.
    # Give each simulated device a distinct name and MAC, as physical devices have.
    left, right = f"lt{os.getpid()}a{LINK_INDEX}", f"lt{os.getpid()}b{LINK_INDEX}"
    run("ip", "link", "add", left, "type", "veth", "peer", "name", right)
    run("ip", "link", "set", left, "netns", NAMES[a])
    run("ip", "link", "set", right, "netns", NAMES[b])
    for side, (name, old, new) in enumerate(((a, left, aname), (b, right, bname))):
        ns(name, "ip", "link", "set", old, "name", new)
        ns(name, "ip", "link", "set", new, "address", f"02:00:00:00:{LINK_INDEX:02x}:{side:02x}")
        ns(name, "ip", "link", "set", new, "up")


def addr(name, dev, address):
    ns(name, "ip", "addr", "add", address, "dev", dev)


SERVER = r'''
import json,socket,threading,time,sys
role=sys.argv[1]
ports=[22,58000,58022,58999] if role=='agx' else ([80] if role=='web' else [58000,57080,8899,59000])
def serve(port,udp):
 s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM if udp else socket.SOCK_STREAM)
 s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
 s.bind(('0.0.0.0',port))
 if not udp: s.listen()
 while True:
  if udp:
   _,peer=s.recvfrom(4096)
   s.sendto(json.dumps({'role':role,'port':port,'peer':peer[0]}).encode(),peer)
  else:
   c,peer=s.accept()
   c.recv(4096)
   c.sendall(json.dumps({'role':role,'port':port,'peer':peer[0]}).encode())
   c.close()
for p in ports:
 for u in (False,True): threading.Thread(target=serve,args=(p,u),daemon=True).start()
print('ready',flush=True)
while True: time.sleep(3600)
'''
CLIENT = r'''
import json,socket,sys
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM if sys.argv[3]=='udp' else socket.SOCK_STREAM)
s.settimeout(3)
s.connect((sys.argv[1],int(sys.argv[2])))
s.send(b'test')
print(s.recv(4096).decode())
'''


def request(source, target, port, role, actual_port=None, protocol="tcp"):
    value = json.loads(ns(source, "python3", "-c", CLIENT, target, str(port), protocol))
    assert (value["role"], value["port"]) == (role, actual_port or port), value
    return value


def install():
    ns("gw", "bash", str(ROOT / "lpmu/setup-nat.sh"), "--runtime-only")
    ns("gw", "bash", str(ROOT / "lpmu/test-nat.sh"))


def check_paths(target):
    for source in ("upper", "c1", "c2"):
        web=request(source, target, 57080, "web", 80)
        assert web["peer"] == "10.10.99.99", web
        for protocol in ("tcp", "udp"):
            for port in (58000, 58999):
                value = request(source, target, port, "agx", protocol=protocol)
                assert value["peer"] == "10.10.99.99", value
        request(source, target, 58022, "agx", 22)
        request(source, target, 58022, "agx", protocol="udp")
    print(f"PASS: upper network + two independent bridges, 97 web, TCP/UDP boundaries and SSH at {target}")


def main():
    if os.geteuid() != 0 or sys.platform != "linux":
        raise SystemExit("Run with sudo on Linux (iproute2, iptables, Python 3 required)")
    try:
        for name, full in NAMES.items():
            run("ip", "netns", "add", full)
            CREATED.append(full)
            ns(name, "ip", "link", "set", "lo", "up")
        # Model the physical LAN switch outside 99, keeping enp2s0 a routed NIC.
        ns("switch", "ip", "link", "add", "lan", "type", "bridge")
        ns("switch", "ip", "link", "set", "lan", "up")
        for name, hostdev, switchdev in (("gw", "enp2s0", "to-gw"), ("agx", "eth0", "to-agx"), ("web", "eth0", "to-web")):
            link(name, hostdev, "switch", switchdev)
            ns("switch", "ip", "link", "set", switchdev, "master", "lan")
        addr("gw", "enp2s0", "10.10.99.99/24")
        addr("web", "eth0", "10.10.99.97/24")
        ns("web", "ip", "route", "add", "default", "via", "10.10.99.99")
        addr("agx", "eth0", "10.10.99.98/24")
        addr("agx", "eth0", "10.10.99.100/24")
        ns("agx", "ip", "route", "add", "default", "via", "10.10.99.99")
        link("gw", "usb-test", "upper", "eth0")
        addr("gw", "usb-test", "192.0.2.1/24")
        addr("upper", "eth0", "192.0.2.10/24")
        ns("upper", "ip", "route", "add", "default", "via", "192.0.2.1")
        ns("gw", "ip", "route", "add", "default", "via", "10.10.99.100", "metric", "100")
        ns("gw", "ip", "route", "add", "default", "via", "192.0.2.10", "metric", "101")
        for index, name in enumerate(("c1", "c2"), 1):
            bridge = f"custom{index}"
            ns("gw", "ip", "link", "add", bridge, "type", "bridge")
            ns("gw", "ip", "link", "set", bridge, "up")
            addr("gw", bridge, f"172.30.{index}.1/24")
            link("gw", f"veth{index}", name, "eth0")
            ns("gw", "ip", "link", "set", f"veth{index}", "master", bridge)
            addr(name, "eth0", f"172.30.{index}.2/24")
            ns(name, "ip", "route", "add", "default", "via", f"172.30.{index}.1")
        # The real 99 uses a source policy forcing 98 traffic to a USB default.
        # Replies to every container bridge must use specific main-table routes first.
        ns("gw", "ip", "route", "add", "table", "100", "default", "via", "192.0.2.10", "dev", "usb-test")
        ns("gw", "ip", "rule", "add", "priority", "40", "from", "10.10.99.0/24", "to", "10.10.99.0/24", "lookup", "main")
        ns("gw", "ip", "rule", "add", "priority", "100", "from", "10.10.99.0/24", "lookup", "100")
        before_policy = ns("gw", "ip", "rule", "show", "priority", "100")
        # A pre-existing marked route to a specific prefix must remain authoritative.
        ns("gw", "ip", "route", "add", "198.18.0.0/24", "via", "10.10.99.100")
        ns("gw", "ip", "rule", "add", "priority", "60", "fwmark", "0x100", "lookup", "100")
        marked_query=("ip", "route", "get", "198.18.0.10", "from", "10.10.99.98", "iif", "enp2s0", "mark", "0x100")
        before_marked=ns("gw", *marked_query)
        # Representative legacy LPMU rules, Docker chains and unrelated 97 rule.
        ns("gw", "iptables-restore", "--version")
        rules = '''*mangle
-A PREROUTING -s 10.10.99.98 -m conntrack --ctdir REPLY -j CONNMARK --restore-mark --nfmask 0x100 --ctmask 0x100
-A PREROUTING -m conntrack --ctdir ORIGINAL -j CONNMARK --set-xmark 0x100/0xffffffff
COMMIT
*nat
:DOCKER - [0:0]
-A PREROUTING -i enp2s0 -p tcp --dport 58022 -j DNAT --to-destination 10.10.99.98:22
-A PREROUTING -i enp2s0 -p tcp --dport 58000:58999 -j DNAT --to-destination 10.10.99.98
-A PREROUTING -i enp2s0 -p udp --dport 58000:58999 -j DNAT --to-destination 10.10.99.98
-A PREROUTING -i unplugged0 -p tcp --dport 58000:58999 -j DNAT --to-destination 10.10.99.98
-A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER
-A DOCKER -p tcp --dport 8899 -j DNAT --to-destination 172.30.1.2:8899
-A DOCKER -p tcp --dport 59000 -j DNAT --to-destination 172.30.1.2:59000
-A PREROUTING -d 10.10.99.97 -p tcp --dport 80 -j DNAT --to-destination 10.10.99.99:57080
-A POSTROUTING -s 172.30.0.0/16 -o usb-test -j MASQUERADE
COMMIT
*filter
:FORWARD DROP [0:0]
:DOCKER-USER - [0:0]
:DOCKER-FORWARD - [0:0]
-A FORWARD -j DOCKER-USER
-A FORWARD -j DOCKER-FORWARD
-A DOCKER-FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A DOCKER-FORWARD -d 172.30.1.2 -p tcp --dport 8899 -j ACCEPT
-A DOCKER-FORWARD -d 172.30.1.2 -p tcp --dport 59000 -j ACCEPT
-A DOCKER-FORWARD -i custom1 ! -o custom1 -j ACCEPT
-A DOCKER-FORWARD -i custom2 ! -o custom2 -j ACCEPT
COMMIT
'''
        subprocess.run(["ip", "netns", "exec", NAMES["gw"], "iptables-restore"], input=rules, text=True, check=True)
        before_route = ns("gw", "ip", "route", "show")
        before_rules = {(table, chain): ns("gw", "iptables", "-t", table, "-S", chain)
                        for table, chain in (("nat", "DOCKER"), ("filter", "DOCKER-USER"), ("filter", "DOCKER-FORWARD"))}
        for role in ("agx", "web", "upper", "c1"):
            proc = subprocess.Popen(["ip", "netns", "exec", NAMES[role], "python3", "-u", "-c", SERVER, role],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            PROCESSES.append(proc)
            assert proc.stdout.readline().strip() == "ready"
        # Socket threads start before main prints ready; probe retries only on startup.
        time.sleep(0.2)
        # A conflicting administrator policy must be reported, never removed.
        ns("gw", "ip", "rule", "add", "priority", "34", "from", "198.51.100.0/24", "lookup", "100")
        conflict=ns("gw", "ip", "rule", "show", "priority", "34")
        denied=subprocess.run(["ip", "netns", "exec", NAMES["gw"], "bash", str(ROOT/"lpmu/setup-nat.sh"), "--runtime-only"], capture_output=True)
        assert denied.returncode != 0, "conflicting route priority silently accepted"
        assert conflict == ns("gw", "ip", "rule", "show", "priority", "34")
        ns("gw", "ip", "rule", "del", "priority", "34", "from", "198.51.100.0/24", "lookup", "100")
        print("PASS: conflicting administrator policy is preserved")
        install()
        install()
        assert before_route == ns("gw", "ip", "route", "show"), "routes changed"
        for (table, chain), expected in before_rules.items():
            assert expected == ns("gw", "iptables", "-t", table, "-S", chain), "Docker rules changed"
        for table, parent, target in (("mangle", "PREROUTING", "LPMU_CONNMARK"), ("nat", "PREROUTING", "LPMU_PREROUTING"), ("nat", "POSTROUTING", "LPMU_POSTROUTING"), ("filter", "FORWARD", "LPMU_FORWARD")):
            assert ns("gw", "iptables", "-t", table, "-S", parent).count(f"-j {target}") == 1
        assert ns("gw", "iptables", "-S", "FORWARD").startswith("-P FORWARD DROP")
        assert before_policy == ns("gw", "ip", "rule", "show", "priority", "100")
        assert before_marked == ns("gw", *marked_query), "unrelated marked policy changed"
        legacy=ns("gw", "iptables", "-t", "nat", "-S", "PREROUTING")
        assert "--to-destination 10.10.99.98" in legacy, legacy
        assert "--to-destination 10.10.99.99:57080" in legacy, legacy
        print("PASS: historical forwarding preserved for manual migration; unrelated marked route preserved")
        # Simulate the administrator's manual conflict cleanup after installing new scripts.
        for iface in ("enp2s0", "unplugged0"):
            for protocol in ("tcp", "udp"):
                args=("iptables", "-t", "nat", "-D", "PREROUTING", "-i", iface, "-p", protocol, "--dport", "58000:58999", "-j", "DNAT", "--to-destination", "10.10.99.98")
                if iface == "enp2s0" or protocol == "tcp": ns("gw", *args)
        ns("gw", "iptables", "-t", "nat", "-D", "PREROUTING", "-i", "enp2s0", "-p", "tcp", "--dport", "58022", "-j", "DNAT", "--to-destination", "10.10.99.98:22")
        ns("gw", "iptables", "-t", "nat", "-D", "PREROUTING", "-d", "10.10.99.97", "-p", "tcp", "--dport", "80", "-j", "DNAT", "--to-destination", "10.10.99.99:57080")
        internet_route = ns("gw", "ip", "route", "get", "203.0.113.1", "from", "10.10.99.98", "iif", "enp2s0")
        assert "via 192.0.2.10 dev usb-test" in internet_route, internet_route
        print("PASS: repeated install preserves default routes, existing USB policy, Docker chains, FORWARD policy and single hooks")
        # Existing Docker user policy must win over project forwarding.
        deny=("-s", "172.30.1.2", "-d", "10.10.99.97", "-p", "tcp", "--dport", "80", "-j", "REJECT")
        ns("gw", "iptables", "-I", "DOCKER-USER", "1", *deny)
        blocked=subprocess.run(["ip", "netns", "exec", NAMES["c1"], "python3", "-c", CLIENT, "192.0.2.1", "57080", "tcp"], capture_output=True)
        assert blocked.returncode != 0, "Docker user rejection bypassed"
        ns("gw", "iptables", "-D", "DOCKER-USER", *deny)
        # Docker network isolation must also win, including access via bridge IP.
        ns("gw", "iptables", "-I", "DOCKER-FORWARD", "1", *deny)
        blocked=subprocess.run(["ip", "netns", "exec", NAMES["c1"], "python3", "-c", CLIENT, "172.30.1.1", "57080", "tcp"], capture_output=True)
        assert blocked.returncode != 0, "Docker isolation bypassed"
        ns("gw", "iptables", "-D", "DOCKER-FORWARD", *deny)
        print("PASS: Docker user rejection and network isolation remain effective")
        check_paths("192.0.2.1")
        request("upper", "192.0.2.1", 8899, "c1")
        request("c2", "192.0.2.1", 8899, "c1")
        request("upper", "192.0.2.1", 59000, "c1")
        request("c2", "192.0.2.1", 59000, "c1")
        request("agx", "192.0.2.10", 58000, "upper")
        request("c1", "192.0.2.10", 57080, "upper")
        request("gw", "10.10.99.97", 80, "web")
        request("c1", "192.0.2.10", 58000, "upper")
        request("gw", "10.10.99.98", 58000, "agx")
        print("PASS: existing published app reachable externally and across bridges; unrelated server not hijacked; host direct access")
        # New uplink name and subnet, with no invocation of the NAT script.
        ns("gw", "ip", "addr", "del", "192.0.2.1/24", "dev", "usb-test")
        ns("gw", "ip", "link", "set", "usb-test", "name", "replacement0")
        addr("gw", "replacement0", "198.51.100.1/24")
        ns("upper", "ip", "addr", "del", "192.0.2.10/24", "dev", "eth0")
        addr("upper", "eth0", "198.51.100.10/24")
        ns("upper", "ip", "route", "replace", "default", "via", "198.51.100.1")
        check_paths("198.51.100.1")
        print("PASS: uplink address/interface change requires no NAT rebuild")
        # Execute the actual route-switch blocks with a lower-metric DHCP default.
        for filename, start_text, end_text in (
            ("setup-smart-route.sh", "    # 删除所有默认路由", '    echo "5. 当前路由表'),
            ("monitor-smart-route.sh", "    # 删除所有默认路由", "    # 重新配置 NAT"),
        ):
            ns("gw", "ip", "route", "add", "default", "via", "10.10.99.100", "metric", "50")
            source=(ROOT/"lpmu"/filename).read_text()
            block=source[source.index(start_text):source.index(end_text)]
            variables="CHOSEN_IFACE=replacement0; CHOSEN_GATEWAY=198.51.100.10; PRIMARY_IFACE=enp2s0; PRIMARY_GATEWAY=10.10.99.100; iface=replacement0; gateway=198.51.100.10; "
            ns("gw", "bash", "-ec", variables+block)
            assert "dev replacement0" in ns("gw", "ip", "route", "get", "8.8.8.8")
        print("PASS: original route switching succeeds even with a metric 50 DHCP default")
        print("All integration checks passed")
    finally:
        for proc in PROCESSES:
            proc.terminate()
        for proc in PROCESSES:
            proc.wait(timeout=5)
        for name in reversed(CREATED):
            subprocess.run(["ip", "netns", "del", name], check=True)


if __name__ == "__main__":
    main()
