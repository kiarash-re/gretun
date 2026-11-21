#!/usr/bin/env bash
#
# netns-test.sh - tests gretun Sections 1-3 with Linux network namespaces.
# No real servers needed. Run as root on a disposable Debian/Ubuntu VM:
#
#   sudo bash tests/netns-test.sh [--install-deps] [--keep]
#
# Topology (all inside this machine):
#
#   gt-client --(veth "wg0")-- gt-iran --eth0-- gt-inet --eth0-- gt-foreign
#   10.0.0.2/16                198.51.100.2     router           203.0.113.2
#   fd10:10::2/64              2001:db8:1::2    192.0.2.1        2001:db8:2::2
#                                               2001:db8:ff::1 (an "internet" host)
#
# Each namespace keeps gretun's files under its own GRETUN_ROOT, so the two
# "servers" do not share configuration. GRETUN_ROOT also makes gretun run
# haproxy/nginx directly instead of through systemd.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
G="${GRETUN:-$HERE/../gretun}"
G=$(readlink -f "$G")
T=$(mktemp -d /tmp/gretun-test.XXXXXX)
KEEP=0
PASS=0 FAIL=0
NS=(gt-iran gt-foreign gt-inet gt-client)

for a in "$@"; do
    case "$a" in
        --install-deps)
            apt-get update -q
            DEBIAN_FRONTEND=noninteractive apt-get install -y -q iproute2 nftables iptables haproxy \
                nginx libnginx-mod-stream socat ethtool iputils-ping kmod iperf3 ;;
        --keep) KEEP=1 ;;
        *) echo "Usage: $0 [--install-deps] [--keep]"; exit 2 ;;
    esac
done

[[ "$(id -u)" == 0 ]] || { echo "Run as root."; exit 2; }
for c in ip nft iptables haproxy nginx socat ethtool ping; do
    command -v "$c" >/dev/null || { echo "Missing: $c (use --install-deps)"; exit 2; }
done
[[ -x "$G" ]] || chmod +x "$G"
modprobe ip6_gre 2>/dev/null; modprobe ip_gre 2>/dev/null

c_ok()  { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
c_bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check() {  # check "description" command...
    local d="$1"
    shift
    if "$@" >/dev/null 2>&1; then c_ok "$d"; else c_bad "$d"; fi
}
section() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
nsx() { local n="$1"; shift; ip netns exec "gt-$n" "$@"; }
# gretun inside a "server": gt NS ARGS...
# stdin is a pipe that stays open (not /dev/null): a command that wrongly reads
# stdin then hangs and is caught by the timeout, as it would hang over SSH.
gt() {
    local n="$1"
    shift
    ip netns exec "gt-$n" env GRETUN_ROOT="$T/$n" GRETUN_SELF="$G" NO_COLOR=1 \
        timeout 240 "$G" "$@" < <(exec sleep 6001)
}
cleanup() {
    local p
    for p in "$T"/*/run/gretun/*.pid; do kill "$(cat "$p")" 2>/dev/null; done
    pkill -f "gretun-test" 2>/dev/null
    pkill -x -f "sleep 6001" 2>/dev/null
    for p in "${NS[@]}"; do
        ip netns pids "$p" 2>/dev/null | xargs -r kill 2>/dev/null
        ip netns del "$p" 2>/dev/null
    done
    if (( KEEP )); then echo "Files kept in $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT

# ------------------------------------------------------------------ topology
section "Building the test network"
for n in "${NS[@]}"; do ip netns del "$n" 2>/dev/null; ip netns add "$n"; ip -n "$n" link set lo up; done
ip link add i-wan type veth peer name r-iran
ip link add f-wan type veth peer name r-for
ip link add wgv type veth peer name c0
ip link set i-wan netns gt-iran name eth0
ip link set wgv netns gt-iran name wg0
ip link set f-wan netns gt-foreign name eth0
ip link set r-iran netns gt-inet
ip link set r-for netns gt-inet
ip link set c0 netns gt-client name eth0

nsx inet sysctl -qw net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1
nsx inet ip addr add 198.51.100.1/24 dev r-iran
nsx inet ip addr add 2001:db8:1::1/64 dev r-iran nodad
nsx inet ip addr add 203.0.113.1/24 dev r-for
nsx inet ip addr add 2001:db8:2::1/64 dev r-for nodad
nsx inet ip addr add 192.0.2.1/32 dev lo
nsx inet ip addr add 2001:db8:ff::1/128 dev lo
nsx inet ip link set r-iran up
nsx inet ip link set r-for up

nsx iran ip addr add 198.51.100.2/24 dev eth0
for a in 2 3 4; do nsx iran ip addr add "2001:db8:1::$a/64" dev eth0 nodad; done
nsx iran ip link set eth0 up
nsx iran ip route add default via 198.51.100.1
nsx iran ip -6 route add default via 2001:db8:1::1
nsx iran ip addr add 10.0.0.1/16 dev wg0
nsx iran ip addr add fd10:10::1/64 dev wg0 nodad
nsx iran ip link set wg0 up

nsx foreign ip addr add 203.0.113.2/24 dev eth0
for a in 2 3 4; do nsx foreign ip addr add "2001:db8:2::$a/64" dev eth0 nodad; done
nsx foreign ip link set eth0 up
nsx foreign ip route add default via 203.0.113.1
nsx foreign ip -6 route add default via 2001:db8:2::1

nsx client ip addr add 10.0.0.2/16 dev eth0
nsx client ip addr add fd10:10::2/64 dev eth0 nodad
nsx client ip link set eth0 up
nsx client ip route add default via 10.0.0.1
nsx client ip -6 route add default via fd10:10::1
# Like a host that learns IPv6 from router advertisements.
nsx iran sysctl -qw net.ipv6.conf.eth0.accept_ra=1
nsx foreign sysctl -qw net.ipv6.conf.eth0.accept_ra=1
sleep 1
check "iran reaches the internet host" nsx iran ping -c1 -W2 192.0.2.1
check "foreign reaches 2001:db8:2::1" nsx foreign ping -6 -c1 -W2 2001:db8:2::1
IRAN_DEFAULT=$(nsx iran ip route show default)

# Services on the "internet": echo the caller's address back.
# shellcheck disable=SC2016  # $SOCAT_PEERADDR is expanded by socat's shell
nsx inet socat TCP4-LISTEN:7000,fork,reuseaddr SYSTEM:'echo $SOCAT_PEERADDR' >/dev/null 2>&1 &
# shellcheck disable=SC2016
nsx inet socat TCP6-LISTEN:7000,fork,reuseaddr SYSTEM:'echo $SOCAT_PEERADDR' >/dev/null 2>&1 &
# Services on the foreign server for the forwarder tests.
nsx foreign socat TCP6-LISTEN:8080,fork,reuseaddr,ipv6only=0 SYSTEM:'echo hello-from-foreign' >/dev/null 2>&1 &
nsx foreign socat UDP6-LISTEN:5353,fork,reuseaddr EXEC:cat >/dev/null 2>&1 &
sleep 0.5

# ------------------------------------------------------------------ Section 1
section "Section 1: GRE tunnels"
out=$(gt foreign --dry-run -y tunnel add --role foreign --family 6 --peer 2001:db8:1::2)
check "--dry-run prints commands" grep -q 'dry-run' <<<"$out"
check "--dry-run creates nothing" test ! -e "$T/foreign/etc/gretun/tunnels/gre1.conf"

gt foreign -y tunnel add --role foreign --family 6 --peer 2001:db8:1::2 --local 2001:db8:2::2 >"$T/foreign-add.log" 2>&1
check "foreign: ip6gre tunnel gre1 created" nsx foreign ip link show gre1
KEY=$(gt foreign tunnel key gre1 --raw)
check "foreign: connection key printed" grep -q '^gretun://' <<<"$KEY"
out=$(gt foreign tunnel key gre1)
check "key screen shows the ready Iran command" grep -qF "gretun tunnel add --key '$KEY'" <<<"$out"
check "key screen shows the manual values" grep -q 'Tunnel network:' <<<"$out"
gt iran -y tunnel add --key "$KEY" >"$T/iran-add.log" 2>&1
check "iran: tunnel from key" nsx iran ip link show gre1
P4=$(grep '^IN4_PEER=' "$T/iran/etc/gretun/tunnels/gre1.conf" | cut -d= -f2)
P6=$(grep '^IN6_PEER=' "$T/iran/etc/gretun/tunnels/gre1.conf" | cut -d= -f2)
check "IPv4 inside the tunnel ($P4)" nsx iran ping -c2 -W2 "$P4"
check "IPv6 inside the tunnel ($P6)" nsx iran ping -6 -c2 -W2 "$P6"
check "ip6gre MTU 1450" bash -c "ip -n gt-iran link show gre1 | grep -q 'mtu 1450'"
check "ip6gre encaplimit none" bash -c "ip -n gt-iran -d link show gre1 | grep -q 'encaplimit none'"
check "offload off on gre1" bash -c "! ip netns exec gt-iran ethtool -k gre1 | grep -E '^(generic-segmentation-offload|generic-receive-offload|tcp-segmentation-offload): on'"
check "MSS clamp rule (nft inet gretun)" bash -c "ip netns exec gt-iran nft list table inet gretun | grep -q 'maxseg size set rt mtu'"
check "GRE accept from peer (nft)" bash -c "ip netns exec gt-iran nft list table inet gretun | grep -q 'l4proto 47'"
check "GRE accept from peer (ip6tables GRETUN-IN)" bash -c "ip netns exec gt-iran ip6tables -S GRETUN-IN | grep -q -- '-p 47'"
check "iptables jump INPUT -> GRETUN-IN" ip netns exec gt-iran iptables -C INPUT -m comment --comment gretun -j GRETUN-IN
check "tunnel recorded as owned" grep -qx gre1 "$T/iran/var/lib/gretun/owned"
check "status shows the tunnel" bash -c "GRETUN_ROOT=$T/iran ip netns exec gt-iran $G tunnel status | grep -q gre1"

# idempotency: a second sync changes nothing (same ifindex)
IDX=$(nsx iran cat /sys/class/net/gre1/ifindex)
gt iran sync >/dev/null 2>&1
check "sync is idempotent (gre1 not recreated)" test "$IDX" == "$(nsx iran cat /sys/class/net/gre1/ifindex)"

# IPv4 transport
gt foreign -y tunnel add --role foreign --family 4 --peer 198.51.100.2 --local 203.0.113.2 --name gre2 >/dev/null 2>&1
KEY2=$(gt foreign tunnel key gre2 --raw)
gt iran -y tunnel add --key "$KEY2" --name gre2 >/dev/null 2>&1
P4b=$(grep '^IN4_PEER=' "$T/iran/etc/gretun/tunnels/gre2.conf" | cut -d= -f2)
check "IPv4 GRE tunnel gre2 works" nsx iran ping -c2 -W2 "$P4b"
check "gre MTU 1476" bash -c "ip -n gt-iran link show gre2 | grep -q 'mtu 1476'"
check "inner networks do not collide" test "$P4" != "$P4b"

# watchdog/heal: a deleted tunnel comes back
nsx iran ip link del gre1
gt iran heal >/dev/null 2>&1
check "heal recreates a deleted tunnel" nsx iran ping -c2 -W2 "$P4"

# manual tunnel import (no downtime)
nsx iran ip link add gre7 type ip6gre local 2001:db8:1::3 remote 2001:db8:2::3 ttl 255 encaplimit none
nsx iran ip addr add 10.77.0.1/30 dev gre7
nsx iran ip link set gre7 mtu 1450 up
nsx foreign ip link add gre7 type ip6gre local 2001:db8:2::3 remote 2001:db8:1::3 ttl 255 encaplimit none
nsx foreign ip addr add 10.77.0.2/30 dev gre7
nsx foreign ip link set gre7 mtu 1450 up
mkdir -p "$T/iran/usr/local/bin" "$T/iran/etc/cron.d"
printf '#!/bin/sh\nip link add gre7 type ip6gre ...\n' >"$T/iran/usr/local/bin/gre-up.sh"
printf '@reboot root ethtool -K wg0 gso off gro off tso off\n' >"$T/iran/etc/cron.d/wg-offload"
IDX7=$(nsx iran cat /sys/class/net/gre7/ifindex)
gt iran -y --confirm tunnel import manual --if gre7 --role iran >"$T/import.log" 2>&1
check "manual import: config written" test -f "$T/iran/etc/gretun/tunnels/gre7.conf"
check "manual import: interface kept (no downtime)" test "$IDX7" == "$(nsx iran cat /sys/class/net/gre7/ifindex)"
check "manual import: tunnel still works" nsx iran ping -c2 -W2 10.77.0.2
check "manual import: cron job replaced by udev rule" test -f "$T/iran/etc/gretun/legacy/cron.d-wg-offload" -a -f "$T/iran/etc/udev/rules.d/90-gretun-offload.rules"

# ------------------------------------------------------------------ Section 2
section "Section 2: IPv6 forwarder"
gt iran -y fwd add --dest 2001:db8:2::2 --ports 9090=8080 --proto tcp >"$T/fwd.log" 2>&1 || cat "$T/fwd.log"
check "TCP 198.51.100.2:9090 -> [2001:db8:2::2]:8080" bash -c "ip netns exec gt-inet socat -T3 - TCP4:198.51.100.2:9090 </dev/null | grep -q hello-from-foreign"
gt iran -y fwd add --dest 2001:db8:2::2 --ports 5353 --proto udp >>"$T/fwd.log" 2>&1 || cat "$T/fwd.log"
check "UDP 198.51.100.2:5353 -> [2001:db8:2::2]:5353" bash -c "echo ping-udp | ip netns exec gt-inet socat -T3 - UDP4:198.51.100.2:5353 | grep -q ping-udp"
check "rules file is the source of truth" grep -q '^9090 2001:db8:2::2 8080 tcp' "$T/iran/etc/gretun/forward.rules"
check "per-port counters (nft inet gretun_fwd)" ip netns exec gt-iran nft list table inet gretun_fwd
check "fwd status runs" gt iran fwd status
check "backups kept" bash -c "ls -d $T/iran/etc/gretun/backups/forward/* | grep -q ."
gt iran -y fwd add --dest 2001:db8:2::2 --ports 9092 --proto tcp >/dev/null 2>&1
gt iran -y fwd remove 9092 >/dev/null 2>&1
check "fwd remove" bash -c "! grep -q '^9092 ' $T/iran/etc/gretun/forward.rules"
check "removed port stops listening" bash -c "! ip netns exec gt-iran ss -Hltn 'sport = :9092' | grep -q ."
check "invalid port is rejected" bash -c "! GRETUN_ROOT=$T/iran ip netns exec gt-iran $G -y fwd add --dest 2001:db8:2::2 --ports 70000"

# ------------------------------------------------------------------ Section 3
section "Section 3: PasarGuard WireGuard node via GRE"
mkdir -p "$T/iran/opt/pgnode"
cat >"$T/iran/opt/pgnode/.env" <<'EOF'
# PasarGuard node
SERVICE_PORT=62050
API_KEY=test
# PG_NODE_WG_ROUTE_TABLE=100
EOF
printf 'services:\n  node:\n    image: pasarguard/node:latest\n    network_mode: host\n' >"$T/iran/opt/pgnode/docker-compose.yml"
# Fake node CLI: applies the IPv4 policy routing + NAT like the real node,
# re-enables offload on wg0 (as a re-created interface would have), prints
# the node's log line and then follows "logs" forever.
cat >"$T/iran/usr/local/bin/pgnode" <<EOF
#!/bin/bash
envf="$T/iran/opt/pgnode/.env"
get() { grep -E "^\$1=" "\$envf" | tail -n1 | cut -d= -f2; }
[ "\$1" = restart ] || exit 0
tbl=\$(get PG_NODE_WG_ROUTE_TABLE); out=\$(get PG_NODE_WG_ROUTE_OUT_INTERFACE); nat=\$(get PG_NODE_WG_NAT_OUTPUT_INTERFACE)
while ip rule del iif wg0 lookup "\$tbl" 2>/dev/null; do :; done
ip rule add iif wg0 lookup "\$tbl" pref 30000
ip route replace default dev "\$out" table "\$tbl"
iptables -t nat -C POSTROUTING -s 10.0.0.0/16 -o "\$nat" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s 10.0.0.0/16 -o "\$nat" -j MASQUERADE
ethtool -K wg0 gso on gro on tso on 2>/dev/null
echo "policy routing iif wg0 -> table \$tbl default dev \$out"
exec sleep 600
EOF
chmod +x "$T/iran/usr/local/bin/pgnode"

start=$(date +%s)
# First node on this server: no pg/*.conf yet (1.2.2 hung here reading stdin).
gt iran -y --confirm pg setup --node pgnode --tunnel gre1 --v4 10.0.0.0/16 --v6 fd10:10::/64 >"$T/pg.log" 2>&1
check "pg setup did not hang on '<name> restart' (< 120 s)" test $(( $(date +%s) - start )) -lt 120
ENV="$T/iran/opt/pgnode/.env"
for kv in PG_NODE_WG_HOST_ROUTING=1 PG_NODE_WG_NAT_OUTPUT_INTERFACE=gre1 PG_NODE_WG_NAT_EGRESS_ONLY=0 \
    PG_NODE_WG_NAT_DISABLE=0 PG_NODE_WG_ROUTE_OUT_INTERFACE=gre1; do
    check ".env $kv" grep -qx "$kv" "$ENV"
done
TBL=$(grep '^TABLE=' "$T/iran/etc/gretun/pg/pgnode.conf" | cut -d= -f2)
check ".env PG_NODE_WG_ROUTE_TABLE=$TBL" grep -qx "PG_NODE_WG_ROUTE_TABLE=$TBL" "$ENV"
check ".env comments kept" grep -q '^# PasarGuard node' "$ENV"
check ".env backed up" test -f "$T/iran/etc/gretun/backups/pg/pgnode/env.original"
check "ip -6 rule from fd10:10::/64 -> table $TBL" bash -c "ip -n gt-iran -6 rule | grep -q 'from fd10:10::/64 iif wg0 lookup $TBL'"
check "table $TBL IPv4: default dev gre1" bash -c "ip -n gt-iran route show table $TBL | grep -q '^default dev gre1'"
check "table $TBL IPv6: default dev gre1" bash -c "ip -n gt-iran -6 route show table $TBL | grep -q '^default dev gre1'"
check "offload off on wg0 after the node restart" bash -c "! ip netns exec gt-iran ethtool -k wg0 | grep -E '^(generic-segmentation-offload|generic-receive-offload|tcp-segmentation-offload): on'"
check "iran: accept_ra=2 on eth0" test "$(nsx iran sysctl -n net.ipv6.conf.eth0.accept_ra)" == 2
check "iran: IPv6 forwarding on" test "$(nsx iran sysctl -n net.ipv6.conf.all.forwarding)" == 1
check "iran: sysctl file lists accept_ra before forwarding" bash -c "grep -n . $T/iran/etc/sysctl.d/90-gretun-forward.conf | awk -F: '/accept_ra/ {a=\$1} /forwarding/ {f=\$1} END {exit !(a && a < f)}'"
check "panel instructions printed" grep -q 'MTU: 1420' "$T/pg.log"
EKEY=$(grep -o 'gretun-exit://[A-Za-z0-9_-]*' "$T/pg.log" | head -n1)
check "exit key printed" test -n "$EKEY"

gt foreign -y --confirm exit add --key "$EKEY" >"$T/exit.log" 2>&1
check "foreign: accept_ra=2 on eth0" test "$(nsx foreign sysctl -n net.ipv6.conf.eth0.accept_ra)" == 2
check "foreign: forwarding on" test "$(nsx foreign sysctl -n net.ipv4.ip_forward)$(nsx foreign sysctl -n net.ipv6.conf.all.forwarding)" == 11
check "foreign: MASQUERADE (nft ip gretun_nat)" bash -c "ip netns exec gt-foreign nft list table ip gretun_nat | grep -q masquerade"
check "foreign: return route 10.0.0.0/16 via gre1" bash -c "ip -n gt-foreign route show 10.0.0.0/16 | grep -q 'dev gre1'"
check "foreign: return route fd10:10::/64 via gre1" bash -c "ip -n gt-foreign -6 route show fd10:10::/64 | grep -q 'dev gre1'"

check "WG client: IPv4 internet" nsx client ping -c2 -W2 192.0.2.1
check "WG client: IPv6 internet" nsx client ping -6 -c2 -W2 2001:db8:ff::1
SRC4=$(nsx client socat -T3 - TCP4:192.0.2.1:7000 </dev/null 2>/dev/null)
SRC6=$(nsx client socat -T3 - 'TCP6:[2001:db8:ff::1]:7000' </dev/null 2>/dev/null)
check "WG client IPv4 exits from the foreign server (seen as $SRC4)" test "$SRC4" == 203.0.113.2
check "WG client IPv6 exits from the foreign server (seen as $SRC6)" test "$SRC6" == 2001:db8:2::2
check "iran's own traffic still goes direct" bash -c "test \"\$(ip netns exec gt-iran socat -T3 - TCP4:192.0.2.1:7000 </dev/null)\" == 198.51.100.2"
check "iran's default route unchanged" test "$IRAN_DEFAULT" == "$(nsx iran ip route show default)"
check "pg verify passes" gt iran pg verify

# kill switch: tunnel gone -> clients get unreachable, never leak via Iran
nsx iran ip link del gre1
check "table never empty (unreachable default stays)" bash -c "ip -n gt-iran route show table $TBL | grep -q unreachable"
check "no leak through Iran while the tunnel is down" bash -c "! ip netns exec gt-client socat -T2 - TCP4:192.0.2.1:7000 </dev/null"
gt iran heal >/dev/null 2>&1
nsx iran ip route replace default dev gre1 table "$TBL"   # the real node re-adds its route too
check "after heal: client works again" nsx client ping -c2 -W2 192.0.2.1
check "after heal: IPv6 default in table $TBL" bash -c "ip -n gt-iran -6 route show table $TBL | grep -q '^default dev gre1'"

# rollback: an unconfirmed change is undone by the timer
gt foreign -y --rollback-secs 3 exit remove gre1 >/dev/null 2>&1
check "exit removed (pending)" test ! -f "$T/foreign/etc/gretun/exit/gre1.conf"
sleep 7
check "rollback timer restored the exit" test -f "$T/foreign/etc/gretun/exit/gre1.conf"
check "rollback restored NAT" bash -c "ip netns exec gt-foreign nft list table ip gretun_nat | grep -q masquerade"
check "client works after rollback" nsx client ping -c2 -W2 192.0.2.1

# ------------------------------------------------------------------ legacy import
section "Import from haproxy-forwarder"
nsx iran ip -6 tunnel add gre6_88_1 mode ip6gre local 2001:db8:1::4 remote 2001:db8:2::4 ttl 255 encaplimit none
nsx iran ip addr add 10.88.1.1/30 dev gre6_88_1
nsx iran ip link set gre6_88_1 mtu 1400 up
nsx foreign ip -6 tunnel add gre6_88_1 mode ip6gre local 2001:db8:2::4 remote 2001:db8:1::4 ttl 255 encaplimit none
nsx foreign ip addr add 10.88.1.2/30 dev gre6_88_1
nsx foreign ip link set gre6_88_1 mtu 1400 up
mkdir -p "$T/iran/etc/haproxy"
printf '# Managed by haproxy-forwarder\ngre6_88_1 iran 2001:db8:1::4 2001:db8:2::4 10.88.1.1 10.88.1.2 1400\n' >"$T/iran/etc/haproxy/forwarder-tunnels"
printf '# Managed by haproxy-forwarder\n9191 10.88.1.2 8080 tcp\n' >"$T/iran/etc/haproxy/forwarder.rules"
check "legacy setup blocks other commands" bash -c "! GRETUN_ROOT=$T/iran ip netns exec gt-iran $G -y fwd add --dest 2001:db8:2::2 --ports 9300 </dev/null"
IDX8=$(nsx iran cat /sys/class/net/gre6_88_1/ifindex)
gt iran -y --confirm tunnel import legacy >"$T/legacy.log" 2>&1
check "legacy tunnel imported, name kept" test -f "$T/iran/etc/gretun/tunnels/gre6_88_1.conf"
check "legacy tunnel not recreated" test "$IDX8" == "$(nsx iran cat /sys/class/net/gre6_88_1/ifindex)"
check "legacy rule merged (9191 + 9090 kept)" bash -c "grep -q '^9191 10.88.1.2 8080' $T/iran/etc/gretun/forward.rules && grep -q '^9090 ' $T/iran/etc/gretun/forward.rules"
check "legacy rule forwards through the tunnel" bash -c "ip netns exec gt-inet socat -T3 - TCP4:198.51.100.2:9191 </dev/null | grep -q hello-from-foreign"

# ------------------------------------------------------------------ extras
section "Extras"
check "doctor runs" gt iran doctor
check "status runs" gt iran status
if command -v iperf3 >/dev/null; then
    FL4=$(grep '^IN4_LOCAL=' "$T/foreign/etc/gretun/tunnels/gre1.conf" | cut -d= -f2)
    nsx foreign iperf3 -s -D -B "$FL4"
    sleep 0.5
    check "bench (iperf3 over the tunnel)" bash -c "GRETUN_ROOT=$T/iran ip netns exec gt-iran $G bench --tunnel gre1 --time 1 | grep -q 'bits/sec'"
fi
gt iran -y pg remove pgnode --confirm >/dev/null 2>&1
check "pg remove restores .env" bash -c "! grep -q '^PG_NODE_WG_HOST_ROUTING=' $T/iran/opt/pgnode/.env"
gt iran -y uninstall --purge >/dev/null 2>&1
check "uninstall removes gretun's nft tables" bash -c "! ip netns exec gt-iran nft list tables | grep -q gretun"
check "uninstall removes tunnels it owns" bash -c "! ip -n gt-iran link show gre1"
check "uninstall removes gretun's ip -6 rules" bash -c "! ip -n gt-iran -6 rule | grep -qE '^147[0-9]{2}:'"
check "uninstall leaves wg0 (not gretun's)" ip -n gt-iran link show wg0

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
