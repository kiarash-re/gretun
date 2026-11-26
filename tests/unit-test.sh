#!/usr/bin/env bash
# Unit tests for gretun's pure logic. No root, no network: system commands
# (ip, ping, nft, systemd) are replaced by small stubs. Runs on Linux and on
# macOS (bash 5 needed: brew install bash).
#
#   bash tests/unit-test.sh            (or: /opt/homebrew/bin/bash tests/unit-test.sh)
# shellcheck disable=SC2016  # the test bodies and shims are single-quoted on purpose
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../gretun"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
sed '$d' "$SRC" >"$WORK/lib.sh"   # the last line is: main "$@"

# macOS lacks GNU base64 -w0, setsid and stat -c: tiny shims.
mkdir -p "$WORK/shim"
if ! base64 -w0 </dev/null >/dev/null 2>&1; then
    printf '#!/bin/sh\n[ "$1" = -w0 ] && shift\nexec /usr/bin/base64 "$@"\n' >"$WORK/shim/base64"
fi
command -v setsid >/dev/null || printf '#!/bin/sh\nexec "$@"\n' >"$WORK/shim/setsid"
stat -c %Y / >/dev/null 2>&1 || printf '#!/bin/sh\n[ "$1" = -c ] && shift 2\nexec /usr/bin/stat -f %%m "$@"\n' >"$WORK/shim/stat"
chmod +x "$WORK"/shim/* 2>/dev/null
export PATH="$WORK/shim:$PATH"

PASS=0 FAIL=0
# Each group runs in its own bash with a fresh copy of gretun loaded.
group() {  # group NAME <<'EOF' ... EOF
    local name="$1" out
    out=$(GRETUN_ROOT="$WORK/root-$name" LANG=en_US.UTF-8 bash -c '
        source "$1" 2>/dev/null; set +e +u
        pass=0 fail=0
        t() { local got; got=$(eval "$1" 2>&1); if [[ "$got" == *"$2"* ]]; then pass=$((pass+1)); else fail=$((fail+1)); printf "FAIL [%s] %s\n  got:  %s\n  want: *%s*\n" "$G" "$1" "$got" "$2"; fi; }
        teq() { local got; got=$(eval "$1" 2>&1); if [[ "$got" == "$2" ]]; then pass=$((pass+1)); else fail=$((fail+1)); printf "FAIL [%s] %s\n  got:  %s\n  want: %s\n" "$G" "$1" "$got" "$2"; fi; }
        jlog() { :; }; alert() { :; }
        mkdir -p "$TUN_DIR" "$PG_DIR" "$EXIT_DIR" "$STATE" "$RUNDIR"
        G="$2"
        eval "$(cat)"
        echo "RESULT $pass $fail"' _ "$WORK/lib.sh" "$name" 2>&1)
    printf '%s\n' "$out" | grep -v '^RESULT '
    local r
    r=$(printf '%s\n' "$out" | awk '/^RESULT /{print $2, $3}' | tail -n1)
    if [[ -z "$r" ]]; then echo "FAIL [$name] group crashed"; FAIL=$((FAIL + 1)); return; fi
    PASS=$((PASS + ${r% *})) FAIL=$((FAIL + ${r#* }))
    printf '%-10s %s passed, %s failed\n' "$name" "${r% *}" "${r#* }"
}

group addr <<'EOF'
teq 'compress6 2001:0db8:0000:0000:0000:0000:0000:0001' '2001:db8::1'
teq 'compress6 fd10:10::' 'fd10:10::'
teq 'compress6 1:0:0:2:0:0:0:3' '1:0:0:2::3'
teq 'is_ipv6 1::2::3 && echo y || echo n' 'n'
teq 'cidr_norm 10.0.5.7/16' '10.0.0.0/16'
teq 'cidr_norm fd10:10::5/64' 'fd10:10::/64'
teq 'cidr_overlap 10.0.0.0/16 10.0.3.0/30 && echo y || echo n' 'y'
teq 'cidr_overlap 10.1.0.0/16 10.0.3.0/30 && echo y || echo n' 'n'
teq 'ula_prefix 10.50.60.0/30' 'fd47:4752:a32:3c00::/64'
teq 'norm_tun_net 10.4.5' '10.4.5.0/30'
teq 'norm_tun_net 10.4.5.0/24 && echo y || echo n' 'n'
teq 'declare -A C=(); fill_inner iran 10.4.5.0/30; echo ${C[IN4_LOCAL]} ${C[IN4_PEER]} ${C[IN6_LOCAL]}' '10.4.5.1 10.4.5.2 fd47:4752:a04:500::1'
teq 'parse_ports "443, 8443,4040=443" | paste -sd";" -' '443 443;8443 8443;4040 443'
teq 'addr_arg 6 2001:0db8::0001 --peer' '2001:db8::1'
t '(addr_arg 4 2001:db8::1 --peer)' 'must be an IPv4'
EOF

group keys <<'EOF'
printf 'NAME=gre1\nFAMILY=6\nROLE=foreign\nLOCAL=2001:db8:2::2\nREMOTE=2001:db8:1::2\nMTU=1450\nIN4_LOCAL=10.4.5.2\nIN4_PEER=10.4.5.1\nIN4_PREFIX=30\n' >"$TUN_DIR/gre1.conf"
k=$(key_for gre1)
teq 'key_decode "$k" && echo "$K_FAMILY $K_IRAN $K_FOREIGN $K_NET $K_MTU"' '6 2001:db8:1::2 2001:db8:2::2 10.4.5.0/30 1450'
teq 'key_decode "${k}x" && echo ok || echo bad' 'bad'
printf 'IN4_LOCAL=10.4.5.1\nIN6_LOCAL=fd47::1\n' >"$TUN_DIR/gre9.conf"
ek=$(exit_key gre9 "10.0.0.0/16" "fd10:10::/64")
teq 'exit_key_decode "$ek" && echo "$E_IN4 $E_IN6 $E_V4 $E_V6"' '10.4.5.1 fd47::1 10.0.0.0/16 fd10:10::/64'
EOF

group wgdetect <<'EOF'
ip() { case "$*" in
    "-o link show type wireguard") echo "9: wg1: <UP>" ;;
    "-4 rule show") printf '32765:\tfrom all iif wg1 lookup 1470\n' ;;
    "-o -4 addr show dev wg1") echo "9: wg1    inet 10.0.0.1/16 scope global wg1" ;;
    "-o -6 addr show dev wg1 scope global") echo "9: wg1    inet6 fd10:10::1/64 scope global" ;;
    "link show dev wg1") return 0 ;; *) return 1 ;; esac; }
teq 'wg_by_table 1470' 'wg1'
teq 'wg_nets wg1 4' '10.0.0.0/16'
teq 'wg_nets wg1 6' 'fd10:10::/64'
teq 'wg_mismatch wg1 10.0.0.0/16 fd10:10::/64' ''
t 'wg_mismatch wg1 10.0.0.0/16 ""' 'not in the IPv6 subnets'
O_WG_IF="" HAVE_TTY=0
teq 'pg_pick_wg w 1470 wg0 >/dev/null; echo $w' 'wg1'
O_WG_IF=wg5
teq 'pg_pick_wg w 1470 wg0; echo $w' 'wg5'
EOF

group edits <<'EOF'
printf 'NAME=gre1\nFAMILY=6\nROLE=iran\nLOCAL=2a03:4000::1\nREMOTE=2a14:ec00::2\nMTU=1450\nIN4_LOCAL=10.20.30.2\nIN4_PEER=10.20.30.1\nIN4_PREFIX=30\nIN6_LOCAL=fd20:30::2\nIN6_PEER=fd20:30::1\nORIGIN=manual\n' >"$TUN_DIR/gre1.conf"
ip() { return 1; }; sync_all() { echo SYNC; }; tunnel_status() { :; }; rb_begin() { :; }; rb_arm() { echo ARM; }; rb_undo() { :; }
ufw_gre() { echo "UFW $*"; }; local_has_addr() { return 0; }; prefix_free() { return 0; }
ASSUME_YES=1 HAVE_TTY=0
t 'O_ROLE=foreign cmd_tunnel_edit' 'iran -> foreign'
teq 'grep ^ROLE= "$TUN_DIR/gre1.conf"' 'ROLE=foreign'
t 'O_MTU=1400 cmd_tunnel_edit' 'gretun tunnel edit gre1 --mtu 1400'
t 'O_MTU=1600 cmd_tunnel_edit' 'MTU must be'
teq 'grep ^MTU= "$TUN_DIR/gre1.conf"' 'MTU=1400'
t 'O_PEER=1.2.3.4 cmd_tunnel_edit' 'must be an IPv6'
t 'O_PEER=2a14:ec00::9 cmd_tunnel_edit' 'UFW allow 2a14:ec00::9'
t 'O_INNER_NET=10.9.9.0/30 cmd_tunnel_edit; grep -E "^IN4_(LOCAL|PEER)=" "$TUN_DIR/gre1.conf" | paste -sd" " -' 'IN4_LOCAL=10.9.9.2 IN4_PEER=10.9.9.1'
t 'cmd_tunnel_edit' 'Nothing to change'
printf 'TUNNEL=gre1\nV4_SUBNETS=10.0.0.0/16\nV6_SUBNETS=\nWAN4=auto\nWAN6=auto\n' >"$EXIT_DIR/gre1.conf"
exit_verify() { :; }; exit_subnets_free() { return 0; }
t 'O_V6=fd10:10::/64 cmd_exit_edit' 'none -> fd10:10::/64'
teq 'grep ^V6_SUBNETS= "$EXIT_DIR/gre1.conf"' 'V6_SUBNETS=fd10:10::/64'
t 'O_WAN=nope cmd_exit_edit' 'does not exist'
printf 'NODE=n2\nNODE_DIR=/opt/n2\nTUNNEL=gre1\nTABLE=1470\nWG_IF=wg0\nV4_SUBNETS=10.0.0.0/16\nV6_SUBNETS=fd10:10::/64\n' >"$PG_DIR/n2.conf"
pg_detect() { echo "n2|/opt/n2||"; }
cmd_pg_setup() { echo "SETUP tun=$O_TUNNEL v4=$O_V4 v6=$O_V6 tbl=$O_TABLE wg=$O_WG_IF"; }
t 'O_WG_IF=wg1 cmd_pg_edit' 'SETUP tun=gre1 v4=10.0.0.0/16 v6=fd10:10::/64 tbl=1470 wg=wg1'
t 'O_WG_IF=wg0 cmd_pg_edit' 'Nothing changed'
t 'O_V6=none cmd_pg_edit' 'v6=none'
EOF

group dest <<'EOF'
t 'O_DEST=""; ask_dest d; echo $d' 'create one first'
printf 'ROLE=iran\nIN4_PEER=10.1.1.2\n' >"$TUN_DIR/gre1.conf"
teq 'O_DEST=""; ask_dest d; echo $d' '10.1.1.2'
t 'O_DEST=2001:db8::1; ask_dest d' 'was removed'
t 'O_DEST=10.9.9.9; ask_dest d' 'not the foreign end'
printf 'ROLE=iran\nIN4_PEER=10.3.3.2\n' >"$TUN_DIR/gre3.conf"
t 'O_DEST=""; HAVE_TTY=0; ask_dest d' 'Several tunnels'
EOF

group traffic <<'EOF'
printf 'NAME=gre1\nROLE=iran\nREMOTE=2a01::2\n' >"$TUN_DIR/gre1.conf"
printf 'NODE=n2\nTUNNEL=gre1\nWG_IF=wg1\n' >"$PG_DIR/n2.conf"
RX=1000 TX=500 IDX=7
iface_index() { if [[ $1 == gre1 ]]; then echo $IDX; else echo 9; fi; }
iface_bytes() { if [[ $1 == gre1 ]]; then echo "$RX $TX"; else echo "100 50"; fi; }
teq 'traffic_ifaces | paste -sd" " -' 'gre1 wg1'
traffic_update 1 >/dev/null
# first sight: only a baseline, the lifetime counters are not "today"
teq 'grep ^gre1 "$TRAFFIC_DB" | cut -d"|" -f7,8,12,13' '0|0|0|0'
RX=3000 TX=900; traffic_update 1 >/dev/null
teq 'grep ^gre1 "$TRAFFIC_DB" | cut -d"|" -f7,8,12,13' '2000|400|2000|400'
IDX=8 RX=200 TX=100; traffic_update 1 >/dev/null
teq 'grep ^gre1 "$TRAFFIC_DB" | cut -d"|" -f12,13' '2200|500'
RX=50 TX=20; traffic_update 1 >/dev/null
teq 'grep ^gre1 "$TRAFFIC_DB" | cut -d"|" -f12,13' '2250|520'
sed -i.bak 's/|20[0-9-]*|\([0-9]*\)|\([0-9]*\)|\(20[0-9]*-[0-9]*\)|/|2026-11-01|\1|\2|\3|/' "$TRAFFIC_DB"
RX=60 TX=20; traffic_update 1 >/dev/null
teq 'cat "$TRAFFIC_DAYS"' '2026-11-01|gre1|2250|520'
rows=$(traffic_update 0)
teq 'traffic_sum "$rows" 12 13 tunnels' '2780'
t 'NO_COLOR=1; set_colors; cmd_traffic' 'days with traffic'
EOF

group routes <<'EOF'
LOG="$RUNDIR/iplog"
ip() { echo "ip $*" >>"$LOG"; case "$*" in *" route add "*) return 2 ;; *"show table main exact 10.0.0.0/16") echo "10.0.0.0/16 via 10.1.1.1 dev gre1" ;; *"show table main exact 10.5.0.0/16") echo "10.5.0.0/16 dev wg0 proto kernel" ;; *) return 0 ;; esac; }
teq 'route_cmd add "4|unicast|10.0.0.0/16|main|10.1.1.1|gre1"; grep -c "route replace 10.0.0.0/16" "$LOG"' '1'
t 'route_cmd add "4|unicast|10.5.0.0/16|main|10.1.1.1|gre1"' 'Could not add route'
ip() { case "$*" in "-4 -o addr show") echo "3: wg0 inet 10.5.0.1/16 scope global wg0" ;; "-4 route show table main") printf '10.0.0.0/16 via 10.1.1.1 dev gre1\n10.5.0.0/16 dev wg0 proto kernel scope link\n10.5.0.7 via 10.1.1.1 dev gre1 proto 147\n' ;; "-4 route show table all proto 147") echo "10.0.0.5 via 10.1.1.1 dev gre1 proto 147" ;; *) return 0 ;; esac; }
t 'exit_subnets_free gre1 10.0.0.0/16 "" && echo free' 'free'
t 'exit_subnets_free gre2 10.0.0.0/16 ""' 'overlaps'
t 'exit_subnets_free gre1 10.5.0.0/16 ""' 'overlaps 10.5.0.0/16'
# a host route is printed without /32 by ip; it must still compare equal
t 'routes_current' '4|unicast|10.0.0.5/32|main|10.1.1.1|gre1'
EOF

group firewall <<'EOF'
DRY=1
printf 'NAME=gre1\nFAMILY=6\nROLE=foreign\nLOCAL=2a01::1\nREMOTE=2a14::2\nMTU=1450\nIN4_LOCAL=10.1.1.2\nIN4_PEER=10.1.1.1\nIN4_PREFIX=30\nIN6_LOCAL=fd47::2\nIN6_PEER=fd47::1\n' >"$TUN_DIR/gre1.conf"
printf 'TUNNEL=gre1\nV4_SUBNETS=10.0.0.0/16\nV6_SUBNETS=fd10:10::/64\nWAN4=eth0\nWAN6=eth0\n' >"$EXIT_DIR/gre1.conf"
nft() { return 1; }; iptables() { return 1; }; ip6tables() { return 1; }; ufw_active() { return 1; }
have() { [[ $1 == nft ]]; }
out=$(fw_sync 2>&1)
t 'printf "%s" "$out"' 'iifname "gre1" ip saddr 10.1.1.1 accept'
t 'printf "%s" "$out"' 'iifname "eth0" oifname "gre1" ct state established,related accept'
t 'printf "%s" "$out"' 'iifname "eth0" oifname "gre1" ct state new drop'
t 'printf "%s" "$out"' 'oifname "eth0" ip6 saddr fd10:10::/64 masquerade'
EOF

group rollback <<'EOF'
sync_all() { :; }
SELF=/usr/bin/true
echo NAME=gre1 >"$TUN_DIR/gre1.conf"
rb_begin "test change"
t 'cat "$RB_PENDING/label"' 'test change'
t 'echo $(( $(cat "$RB_PENDING/deadline") - $(date +%s) ))' '9'
echo NAME=changed >"$TUN_DIR/gre1.conf"
AUTO_CONFIRM=1 HAVE_TTY=0
t 'rb_arm 300 1' 'not kept automatically'
t 'rb_pending && echo pending' 'pending'
echo 1 >"$RB_PENDING/deadline"
take_lock() { :; }; watchdog() { :; }; fwd_heal() { :; }; traffic_update() { :; }
t 'cmd_heal' 'rolling it back'
teq 'cat "$TUN_DIR/gre1.conf"' 'NAME=gre1'
rb_begin "second"; t 'rb_arm 300 0' 'Confirmed'
rb_begin "third"; echo garbage >"$RB_PENDING/snapshot.tgz"; echo NAME=keep >"$TUN_DIR/gre1.conf"
t 'rb_fire' 'snapshot is damaged'
teq 'cat "$TUN_DIR/gre1.conf"' 'NAME=keep'
kill "$(cat "$RB_PENDING/timer.pid" 2>/dev/null)" 2>/dev/null
EOF

group writes <<'EOF'
f="$STATE/x.conf"
write_file "$f" 640 "hello"
teq 'cat "$f"' 'hello'
# a failing write must leave the old file as it is (and stop)
chmod 500 "$STATE"
t '(write_file "$f" 640 "new")' 'Could not write'
chmod 700 "$STATE"
teq 'cat "$f"' 'hello'
env="$STATE/.env"; printf 'A=1\n# PG_NODE_WG_ROUTE_TABLE=\nB=2\n' >"$env"
env_set "$env" PG_NODE_WG_ROUTE_TABLE 1470
t 'cat "$env"' 'PG_NODE_WG_ROUTE_TABLE=1470'
env_unset "$env" A
teq 'grep -c "^A=" "$env"' '0'
teq 'grep -c "^B=2" "$env"' '1'
EOF

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
