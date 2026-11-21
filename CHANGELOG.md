# Changelog

## 1.1.0 — 2026-11-21

- Menu: "advanced settings" step in PasarGuard setup (routing table, WireGuard interface)
  and in exit setup (IPv4/IPv6 WAN interface). Off by default; the automatic values stay.
  A chosen table that is already in use triggers a warning and a question.
- CLI: table numbers are validated the same way (1–251 or 256 and up).
- README: table of the Section 3 advanced flags.

## 1.0.0 — 2026-11-21

First release.

### Section 1: GRE tunnel
- IPv4 (`gre`, MTU 1476) or IPv6 (`ip6gre`, `encaplimit none`, MTU 1450) transport; MTU override.
- Every tunnel carries IPv4 (`10.X.Y.0/30`, random, collision-checked) and IPv6
  (`fd47:4752:…/64` ULA derived from the IPv4 network, so both sides agree).
- Multiple tunnels (`gre1`, `gre2`, …), one file each in `/etc/gretun/tunnels/`,
  `gretun@<name>.service` at boot.
- Two-step pairing with a checksummed connection key (`gretun://…`); keys from
  HAProxy-GRE6.sh (`gre6://…`) are accepted too. Manual entry supported.
- GRE allowed from the peer (nft `inet gretun`, iptables/ip6tables chain `GRETUN-IN`, ufw).
- MSS clamping to PMTU for IPv4 and IPv6; gso/gro/tso off on tunnel interfaces.
- Status with RTT/loss for both inner families and traffic counters.
- Heal timer (every minute) recreates dead tunnels; optional ntfy alerts.
- Import without downtime: a manual `gre1` (`gre-up.sh` + `gre.service` +
  `/etc/cron.d/wg-offload`) and haproxy-forwarder tunnels/rules.

### Section 2: IPv6 forwarder
- Feature parity with haproxy-ipv6-forwarder: HAProxy (splice, hitless reload) for TCP,
  dedicated nginx-stream unit `gretun-udp` for UDP, PROXY v2, health checks,
  `443,8443` and `4040=443` syntax, add/list/remove/status/monitor/rebuild/uninstall.
- Rules file as the single source of truth; validate → backup (10 kept) → apply →
  automatic restore on failure; per-port nft counters; heal timer.
- An unrelated `haproxy.cfg` is never replaced silently (backup + question, or
  `--replace-haproxy-cfg`); installing the nginx stream module next to an existing
  nginx backs up `/etc/nginx` and asks first.

### Section 3: PasarGuard WireGuard node via GRE
- Detects nodes (`/opt/*/.env`, docker, `<name>` CLI); edits `.env` in place
  (backup, comments kept, old values remembered for `pg remove`).
- Restarts the node without hanging (`<name> restart` in its own process group,
  stopped after the node logs its routing line; docker compose fallback).
- Adds the IPv6 part the node lacks: `ip -6 rule from <subnet> iif wg0 lookup <table>`,
  `default dev <tunnel>` for IPv4 and IPv6, plus an `unreachable` default so the
  table is never empty (clients never leak out of the Iran server).
- Offload off on `wg0` again after every node restart (udev rule + heal timer).
- Foreign exit: forwarding (accept_ra=2 on the WAN **before** forwarding=1),
  MASQUERADE (nft `ip/ip6 gretun_nat`), return routes; paired with an exit key.
- End-to-end verification, panel instructions (Address, MTU 1420, AllowedIPs).

### Extras
- `gretun bench` (iperf3, 1 and 16 streams, both directions), `gretun doctor`,
  reversible `gretun tune` (BBR + fq, buffers, conntrack).
- Automatic rollback timer (systemd-run) for routing changes; `gretun confirm`.
- `--dry-run` everywhere, journald logging (`journalctl -t gretun`), shellcheck-clean.
- Network-namespace test suite `tests/netns-test.sh`.
