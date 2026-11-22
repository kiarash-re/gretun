# Changelog

## 1.5.0 — 2026-11-22

Menu and prompts only; the CLI, its flags and the networking logic are unchanged.

- Dashboard at the top of the menu: this server's role (Iran / foreign), IPs, each tunnel
  with up/down and ping (pinged in parallel), forwarded ports (TCP/UDP), PasarGuard node,
  exit, alerts, and a notice with the time left when a change waits for confirmation.
  On a new server it says where to start.
- Menus are grouped (e.g. "Iran server" / "Foreign server" in PasarGuard), each item has a
  short dim hint, and items that cannot work here are shown with the reason
  (e.g. "needs an Iran-side tunnel") instead of failing after you choose them.
  Tunnel menu order: new tunnel (1-3), list, key, edit, forward ports, remove, import, alerts.
  PasarGuard menu: set up (1-2), check, panel, Iran items (5-7), foreign items (8-9).
- Keys and ports are checked as you type and asked again: a bad connection key, exit key,
  port list or ntfy URL no longer ends the action; Enter on an empty prompt cancels.
- Summaries before applying (new tunnel, forwarded ports) and a "What to do next" block after
  creating a tunnel, forwarding ports, setting up a node or an exit.
- Narrow screens (Termius): menus fit 60 columns; tunnel status and forwarder status are
  printed as short blocks on terminals narrower than the table (piped output keeps the table).
- Tables line up with `NO_COLOR` / `--no-color` and when piped (coloured cells were padded
  as if the colour codes had width).
- `fwd remove` with a non-numeric port now warns instead of stopping with a shell error.

## 1.4.0 — 2026-11-22

- Removed: forwarding a port straight to a foreign IPv6 address without a tunnel (menu and
  `fwd add --dest IPV6`). Port forwarding now always goes through a GRE tunnel to the foreign
  server; with one Iran-side tunnel nothing is asked except the ports.
- Rules that already point to an IPv6 address (e.g. imported from haproxy-forwarder) keep
  working and can still be listed and removed.

## 1.3.1 — 2026-11-22

- Menu 1) GRE tunnel: new item "Iran server: forward ports through a tunnel to the foreign
  server". It asks only for the tunnel (if there are several) and the ports. CLI:
  `gretun tunnel forward [NAME] --ports 6000`.
- Menu 2) is now "Port forwarding": the tunnel destinations are listed first, a foreign IPv6
  without a tunnel last. It was named "IPv6 port forwarder ... no tunnel", which hid that it
  can use a tunnel.

## 1.3.0 — 2026-11-21

- Fix: PasarGuard setup assumed the WireGuard interface was `wg0`. With a panel core named
  `wg1` (or anything else) the IPv6 rule was bound to a missing interface and clients had no
  IPv6. The interface is now detected (the node's own `iif X lookup TABLE` rule, else the only
  WireGuard interface, else a question) and its addresses are offered as the client subnets.
  The node's current routing table from `.env` is kept.
- Setup warns before applying when the chosen interface is missing while others exist, or when
  the interface's networks are not in the subnets entered (default answer then: no).
- `pg verify` and `doctor`: a missing interface is an error that names the right one and the fix.
- New `gretun tunnel edit`: change MTU, either public address, tunnel network or role of a
  tunnel (prints the matching command for the other server; rollback timer as usual).
- New `gretun pg edit`: change WireGuard interface, client subnets, routing table or tunnel of
  a node setup. New `gretun exit edit`: change client subnets and WAN interfaces of an exit.
  All three also in the menu, as an editor that applies nothing until "Apply".

## 1.2.6 — 2026-11-21

- Fix: the heal timer replaced gretun's nft tables every minute although nothing had
  changed (the saved copy lost its final newline, so it never compared equal). Rules
  are now applied only when they change, and the journal no longer fills with
  "run: nft -f -" every minute.

## 1.2.5 — 2026-11-21

- Fix: at "Keep this change?" pressing Enter alone undid the change immediately.
  Now an explicit answer is needed: `yes` keeps, `no` undoes, `later` returns and leaves
  the safety timer running (confirm with `gretun confirm`). Anything else asks again,
  with the remaining time shown. If the terminal goes away (SSH dropped), the timer
  decides instead of an immediate undo.

## 1.2.4 — 2026-11-21

- Fix (important for nodes installed without docker): after `<name> restart`, gretun
  stopped the whole process group, which could also stop a node that the command had
  started in the background. Now only the log follower and the command itself are stopped.
- Node restart order: systemd unit (`systemctl restart <name>`) first, then
  `docker compose up -d --force-recreate`, then `<name> restart`.
- The restart log moved from /run (RAM) to /var/log/gretun/, and a progress line is
  printed every 15 s while waiting. Verification also reads `journalctl -u <unit>`.

## 1.2.3 — 2026-11-21

- Fix: PasarGuard setup hung after the subnet questions on a server without any
  PasarGuard setup yet. Choosing the routing table ran `cat` on an empty file list,
  which then waited for keyboard input. Nothing had been changed at that point.
- Tests: commands now run with an open stdin, so a command that wrongly reads it
  fails the test instead of passing.

## 1.2.2 — 2026-11-21

- Fix: after a tunnel was created on the foreign server, the key screen stopped with
  "C[FAMILY]: unbound variable" (the tunnel itself was created correctly).
- The key screen now also prints the complete line to paste on the Iran server:
  `gretun tunnel add --key '...'`.

## 1.2.1 — 2026-11-21

- Fix: the menu rejected every answer ("Type a number from the list"), and address,
  subnet, destination and WAN prompts never accepted a value (also with CLI flags such
  as `--peer`/`--local`). A local variable in the prompt helper had the same name as the
  caller's variable. Tested through a real terminal.
- Main menu shows "0) Exit" instead of "0) Back".

## 1.2.0 — 2026-11-21

- New `gretun update`: downloads the latest version from GitHub, or takes a copied
  file with `--file PATH` (for Iran servers). Checks that the file is a complete gretun
  script, shows both versions, refuses silent downgrades, replaces the program
  atomically and re-applies the configuration. Also in the menu (Tools).
- An older copy of the script no longer overwrites a newer installed version when it runs.

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
