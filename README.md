# gretun

**English** · [فارسی](#فارسی)

One Bash script for a VPN setup with an **Iran "entry" server** and a **foreign "exit" server**:

1. **GRE tunnel**: IPv4 (`gre`) or IPv6 (`ip6gre`) between the two servers. Every tunnel carries both IPv4 and IPv6 inside.
2. **IPv6 port forwarder** (no tunnel needed): users connect to the Iran server's IPv4. TCP goes through HAProxy, UDP through a dedicated nginx-stream service, to a foreign IPv6.
3. **PasarGuard WireGuard node via GRE**: WireGuard clients connect to the PasarGuard node on the Iran server, and all their traffic (IPv4 and IPv6) leaves to the internet from the foreign server.

Everything has an interactive menu **and** CLI flags, so you can paste commands over SSH (Termius).

Requirements: Debian/Ubuntu, systemd, root.

---

## Install

### Online (servers that can reach GitHub)

```bash
curl -fsSL -o /usr/local/sbin/gretun https://raw.githubusercontent.com/kiarash-re/gretun/main/gretun && chmod +x /usr/local/sbin/gretun
```

```bash
gretun
```

### Offline (Iran servers where GitHub is blocked)

At runtime gretun only needs `apt`; it never downloads anything else. Copy the file from your computer, or from the foreign server:

```bash
scp gretun root@IRAN_SERVER_IP:/root/gretun
```

Then on the Iran server:

```bash
bash /root/gretun install
```

`gretun install` copies the script to `/usr/local/sbin/gretun`. Any command that changes something does this too.

If `apt` is blocked as well, install the packages from a local mirror first. Sections 1 and 3 need `iproute2 nftables ethtool iputils-ping kmod`. Section 2 also needs `haproxy`, plus `nginx libnginx-mod-stream` for UDP. `gretun bench` needs `iperf3`, and alerts need `curl`.

### Taking over a server from the old scripts

If a server was set up with **HAProxy-GRE6.sh** or **HAProxy.sh** (haproxy-forwarder), gretun refuses to run next to it and offers to import it:

```bash
gretun tunnel import legacy
```

The import:
- keeps the tunnels up, keeps their names, and adds inner IPv6 to them;
- merges the port rules into gretun's rules;
- disables the old units, and moves the old script to `/etc/gretun/legacy/`.

The old UDP service is stopped right before gretun's own starts, so UDP drops for about a second.

To import a hand-made tunnel (`gre1` from `/usr/local/bin/gre-up.sh` + `gre.service` + `/etc/cron.d/wg-offload`):

```bash
gretun tunnel import manual --if gre1 --role iran
```

The interface is not recreated, so there is no downtime. `gre.service` is disabled but not stopped. The cron job is replaced by a udev rule.

---

## Safety

- gretun **never** changes the default route, SSH or the server's own traffic.
- It never flushes whole rulesets and never enables `nftables.service` (that service's default config flushes all rules).
- It only removes what it created, and everything it creates is tagged:

  | What | Tag |
  |---|---|
  | nft tables | `inet gretun`, `ip/ip6 gretun_nat`, `inet gretun_fwd` |
  | iptables chains | `GRETUN-IN`, `GRETUN-FWD`, jumps with comment `gretun` |
  | routes | `proto 147` |
  | ip rules | priority 14700–14799 |
  | interfaces | listed in `/var/lib/gretun/owned` |
  | files | `/etc/gretun/`, `gretun*` units, `90-gretun-*` / `99-gretun.conf` |

- **Routing changes are rolled back automatically** unless you confirm them. This covers the PasarGuard setup, adding or removing an exit, and imports. After a change you have a few minutes to check SSH and clients. Then answer `yes`, or run `gretun confirm`. If you don't, a systemd-run timer undoes everything, even if your SSH session died. Run `gretun rollback` to undo right away.
- Use `--dry-run` with any command to see what it would do without changing anything.
- Every action is logged to journald: `journalctl -t gretun`.

---

## Menu

```
gretun
```

| Menu | Item | What it does |
|---|---|---|
| **1) GRE tunnel** | Foreign server: create + key | Creates the tunnel and prints a connection key |
| | Iran server: paste a key | Builds the Iran end and pings through it |
| | Manual setup | Enter both addresses and the tunnel network by hand |
| | List / status | State, ping RTT/loss (IPv4 and IPv6), traffic |
| | Show key | Prints the key again (foreign side) |
| | Remove | Refuses if PasarGuard, an exit or forwarder rules still use the tunnel |
| | Import | Hand-made `gre1`, or haproxy-forwarder |
| | Alerts | ntfy URL for tunnel down/up messages |
| **2) IPv6 forwarder** | Add ports | Destination IPv6 (or a tunnel's inner IP), ports, TCP/UDP, PROXY v2, health check |
| | List / Remove | Shows or removes rules |
| | Status | Services, listening ports, connections, traffic, whether the destination is reachable |
| | Live monitor | Per-port rates every N seconds |
| | Rebuild | Regenerates the configs from the rules file |
| | Uninstall | Removes rules and services (restores the original `haproxy.cfg`) |
| **3) PasarGuard WG via GRE** | Iran: set up node | Edits `.env`, restarts the node, adds IPv6 policy routing, prints an exit key |
| | Foreign: add exit | Paste the exit key: forwarding, NAT, return routes |
| | Check everything | All checks, on either server |
| | Panel settings | What you still have to set in the panel |
| | Show exit key | Prints the exit key again |
| | Undo node / remove exit | Puts the old values back |
| **4) Status** | | Everything at a glance |
| **5) Doctor** | | Offloads, MTUs, rules, tables, NAT, pings, units, with plain-English hints |
| **6) Tools** | | Speed test, tuning, confirm/rollback, repair, update, uninstall |

---

## CLI

```
gretun help
```

Section 1:

```bash
gretun tunnel add --role foreign --family 6 --peer IRAN_IPV6
```
```bash
gretun tunnel add --key 'gretun://...'
```
```bash
gretun tunnel add --role iran --family 4 --peer FOREIGN_IPV4 --inner-net 10.45.12.0/30
```
```bash
gretun tunnel status
```
```bash
gretun tunnel key gre1
```
```bash
gretun tunnel remove gre2
```

Section 2:

```bash
gretun fwd add --dest 2001:db8::10 --ports 443,8443 --proto tcp
```
```bash
gretun fwd add --dest 2001:db8::10 --ports 4040=443 --proto both --proxy --check
```
```bash
gretun fwd status
```
```bash
gretun fwd monitor --interval 2
```
```bash
gretun fwd remove 8443
```
```bash
gretun fwd uninstall --purge
```

Section 3:

```bash
gretun pg setup --node pg-node --tunnel gre1 --v4 10.0.0.0/16 --v6 fd10:10::/64
```
```bash
gretun exit add --key 'gretun-exit://...'
```
```bash
gretun pg status
```

Tools:

```bash
gretun doctor
```
```bash
gretun bench --server
```
```bash
gretun bench --tunnel gre1
```
```bash
gretun tune apply
```
```bash
gretun alert set https://ntfy.example.com/my-topic
```
```bash
gretun confirm
```
```bash
gretun uninstall
```

Global options: `-y` (no questions, use defaults), `--dry-run`, `--confirm` (keep a routing change at once if its checks pass), `--rollback-secs N`, `--replace-haproxy-cfg`, `--no-color`.

---

## Worked example (a): PasarGuard WireGuard node on Iran, exit through ip6gre

Goal: WireGuard clients with addresses in `10.0.0.0/16` and `fd10:10::/64` connect to the PasarGuard node on the Iran server and leave the internet from a foreign server (for example in Germany).

**Step 1: foreign server.** Create the tunnel.

```bash
gretun tunnel add --role foreign --family 6 --peer IRAN_IPV6
```

It prints a key such as `gretun://djJ8NnwyMDAxOm...`. Copy it.

**Step 2: Iran server.** Paste the key.

```bash
gretun tunnel add --key 'gretun://djJ8NnwyMDAxOm...'
```

The tunnel `gre1` comes up and is pinged over IPv4 and IPv6.

**Step 3: Iran server.** Set up the node. The node is found automatically; use `--node NAME` if there are several.

```bash
gretun pg setup --tunnel gre1 --v4 10.0.0.0/16 --v6 fd10:10::/64
```

What happens:
- `.env` is backed up and these values are set: `PG_NODE_WG_HOST_ROUTING=1`, `PG_NODE_WG_NAT_OUTPUT_INTERFACE=gre1`, `PG_NODE_WG_NAT_EGRESS_ONLY=0`, `PG_NODE_WG_NAT_DISABLE=0`, `PG_NODE_WG_ROUTE_TABLE=1470`, `PG_NODE_WG_ROUTE_OUT_INTERFACE=gre1`.
- The node restarts. gretun stops following its logs by itself.
- IPv4 is handled by the node. gretun adds IPv6 itself: `ip -6 rule from fd10:10::/64 iif wg0 lookup 1470` and `default dev gre1` in table 1470 for IPv4 and IPv6. It also adds an `unreachable` default, so if the tunnel is down, clients get no internet instead of leaking out of the Iran server.
- Offload is turned off on `wg0` now and again every time the node re-creates it (udev rule).
- `accept_ra=2` is set on the WAN before forwarding is switched on, so the server keeps its IPv6.
- Checks run and an **exit key** is printed.

**Step 4: foreign server.** Add the exit.

```bash
gretun exit add --key 'gretun-exit://...'
```

This enables forwarding (accept_ra first), sets up MASQUERADE for the tunnel and client subnets out of the WAN, and adds return routes for the client subnets via the Iran inner IP. Answer `yes` when the checks pass.

**Step 5: PasarGuard panel.**
- Core → WireGuard → **Address**: `10.0.0.1/16, fd10:10::1/64`, i.e. both subnets as you use them.
- Hosts → **MTU 1420**. In field tests (Iran ↔ DE), MTU 1280 gave about 1 Mbps upload and 1420 gave about 120 Mbps.
- **AllowedIPs**: `0.0.0.0/0, ::/0`.

Clients download their config again. Then confirm on the Iran server:

```bash
gretun confirm
```

Check performance at any time. With offload off on `gre1` and `wg0`, the field test reached about 300 Mbps.

```bash
gretun doctor
```

## Worked example (b): one IPv6 forwarder rule

The foreign server has only IPv6 (`2001:db8:5::10`) and runs Xray on 443. Users should connect to the Iran server's IPv4 on port 443.

```bash
gretun fwd add --dest 2001:db8:5::10 --ports 443 --proto tcp
```

Check it:

```bash
gretun fwd status
```

Users now connect to `IRAN_IPV4:443`. Add `--proxy` if Xray expects PROXY protocol v2 (`acceptProxyProtocol`).

---

## Files

| Path | Content |
|---|---|
| `/etc/gretun/tunnels/<name>.conf` | One tunnel |
| `/etc/gretun/forward.rules` | Forwarder rules (source of truth) |
| `/etc/gretun/pg/<node>.conf`, `/etc/gretun/exit/<tunnel>.conf` | Section 3 |
| `/etc/gretun/backups/` | Forwarder backups (10 kept), `.env` backups, original `haproxy.cfg` |
| `/etc/systemd/system/gretun@.service`, `gretun-heal.timer`, `gretun-udp.service` | Units |
| `/etc/udev/rules.d/90-gretun-offload.rules` | Offload off on `wg0` |
| `/etc/sysctl.d/90-gretun-forward.conf`, `99-gretun.conf` | Forwarding (accept_ra first), optional tuning |

## Tests

`tests/netns-test.sh` checks Sections 1–3 with Linux network namespaces: tunnels over IPv4 and IPv6, key pairing, heal, manual and legacy import, TCP/UDP forwarding, a fake PasarGuard node, client traffic leaving from the foreign server over IPv4 and IPv6, the kill switch, the rollback timer and uninstall. Run it as root on a throwaway Debian/Ubuntu VM:

```bash
sudo bash tests/netns-test.sh --install-deps
```

---
---

<div dir="rtl">

## فارسی

**gretun** یک اسکریپت Bash است برای سرویس VPN با یک **سرور ایران (ورودی)** و یک **سرور خارج (خروجی)**. سه بخش دارد:

1. **تونل GRE** با IPv4 یا IPv6 بین دو سرور. داخل هر تونل هم IPv4 هست و هم IPv6.
2. **فوروارد پورت IPv6** بدون تونل. کاربر به IPv4 سرور ایران وصل می‌شود و ترافیک به IPv6 سرور خارج می‌رود: TCP با HAProxy و UDP با یک سرویس جداگانه‌ی nginx-stream.
3. **نود WireGuard پاسارگارد از طریق GRE**. کلاینت‌های WireGuard به نود پاسارگارد روی سرور ایران وصل می‌شوند و همه‌ی ترافیک‌شان (IPv4 و IPv6) از سرور خارج به اینترنت می‌رود.

همه‌چیز هم منوی تعاملی دارد و هم دستور خط فرمان. پس می‌توانید دستورها را در Termius کپی و paste کنید. محیط لازم: Debian یا Ubuntu با systemd و دسترسی root.

### نصب آنلاین

</div>

```bash
curl -fsSL -o /usr/local/sbin/gretun https://raw.githubusercontent.com/kiarash-re/gretun/main/gretun && chmod +x /usr/local/sbin/gretun
```

<div dir="rtl">

### نصب آفلاین (سرور ایران که GitHub را باز نمی‌کند)

ابزار در زمان اجرا فقط به `apt` نیاز دارد. فایل را از کامپیوتر خودتان یا از سرور خارج کپی کنید:

</div>

```bash
scp gretun root@IRAN_SERVER_IP:/root/gretun
```

<div dir="rtl">

بعد روی سرور ایران:

</div>

```bash
bash /root/gretun install
```

<div dir="rtl">

اگر `apt` هم بسته است، این بسته‌ها را از یک mirror داخلی نصب کنید:

- بخش ۱ و ۳: `iproute2 nftables ethtool iputils-ping kmod`
- بخش ۲: به‌علاوه‌ی `haproxy`، و برای UDP هم `nginx libnginx-mod-stream`
- تست سرعت: `iperf3`
- هشدارها: `curl`

### انتقال از اسکریپت‌های قبلی

اگر سرور با HAProxy-GRE6.sh یا HAProxy.sh راه‌اندازی شده، gretun کنار آن اجرا نمی‌شود و پیشنهاد import می‌دهد. با این کار:

- تونل‌ها با همان اسم بالا می‌مانند و IPv6 داخلی هم به آن‌ها اضافه می‌شود؛
- قانون‌های پورت به قانون‌های gretun اضافه می‌شوند؛
- سرویس‌های قدیمی غیرفعال می‌شوند.

سرویس UDP قدیمی درست قبل از روشن شدن سرویس gretun متوقف می‌شود، پس UDP حدود یک ثانیه قطع می‌شود.

</div>

```bash
gretun tunnel import legacy
```

<div dir="rtl">

برای تونل دستی `gre1` (فایل `gre-up.sh` و `gre.service` و cron به اسم `wg-offload`). اینترفیس دوباره ساخته نمی‌شود، پس قطعی ندارد:

</div>

```bash
gretun tunnel import manual --if gre1 --role iran
```

<div dir="rtl">

### ایمنی

- gretun هیچ‌وقت route پیش‌فرض، SSH و ترافیک خود سرور را تغییر نمی‌دهد.
- هیچ‌وقت همه‌ی قانون‌های فایروال را پاک نمی‌کند و `nftables.service` را فعال نمی‌کند.
- فقط چیزهایی را پاک می‌کند که خودش ساخته است: جدول‌های `gretun*`، زنجیره‌های `GRETUN-*`، routeهایی با `proto 147`، و ruleهایی با اولویت ۱۴۷۰۰ تا ۱۴۷۹۹.
- **هر تغییر در routing اگر تأیید نشود، خودکار برمی‌گردد.** بعد از تغییر چند دقیقه وقت دارید که SSH و کلاینت‌ها را چک کنید و بعد `yes` بزنید یا `gretun confirm` را اجرا کنید. اگر این کار را نکنید (یا SSH قطع شود)، تایمر همه‌چیز را برمی‌گرداند.
- با `--dry-run` می‌بینید هر دستور چه کاری می‌کند، بدون اینکه چیزی تغییر کند.
- همه‌ی کارها لاگ می‌شوند: `journalctl -t gretun`

### منو

با دستور `gretun` منو باز می‌شود:

- **۱) تونل GRE**
  - سرور خارج: ساخت تونل و نمایش کلید اتصال
  - سرور ایران: paste کردن کلید
  - تنظیم دستی
  - لیست تونل‌ها و وضعیت (پینگ، ترافیک)
  - نمایش دوباره‌ی کلید
  - حذف تونل
  - import
  - هشدار ntfy
- **۲) فوروارد IPv6**
  - افزودن پورت
  - لیست و حذف
  - وضعیت (سرویس‌ها، اتصال‌ها، ترافیک)
  - مانیتور زنده
  - ساخت دوباره‌ی کانفیگ
  - حذف کامل
- **۳) پاسارگارد WireGuard**
  - ایران: راه‌اندازی نود
  - خارج: افزودن exit با کلید
  - بررسی همه‌چیز
  - تنظیمات لازم در پنل
  - نمایش دوباره‌ی کلید exit
  - برگرداندن تنظیمات نود / حذف exit
- **۴) وضعیت کلی**
- **۵) Doctor:** پیدا کردن مشکل‌ها با راهنمایی ساده
- **۶) ابزارها:** تست سرعت، tuning، تأیید یا برگشت تغییر، تعمیر، به‌روزرسانی، حذف

### مثال (الف): نود WireGuard پاسارگارد در ایران با خروج از ip6gre

کلاینت‌ها آدرس‌هایی در `10.0.0.0/16` و `fd10:10::/64` می‌گیرند.

**۱. سرور خارج:** تونل را بسازید و کلیدی را که چاپ می‌شود کپی کنید.

</div>

```bash
gretun tunnel add --role foreign --family 6 --peer IRAN_IPV6
```

<div dir="rtl">

**۲. سرور ایران:** کلید را paste کنید. تونل `gre1` بالا می‌آید و پینگ IPv4 و IPv6 تست می‌شود.

</div>

```bash
gretun tunnel add --key 'gretun://...'
```

<div dir="rtl">

**۳. سرور ایران:** نود را تنظیم کنید.

</div>

```bash
gretun pg setup --tunnel gre1 --v4 10.0.0.0/16 --v6 fd10:10::/64
```

<div dir="rtl">

این دستور:

- از فایل `.env` نود backup می‌گیرد و شش متغیر `PG_NODE_WG_*` را تنظیم می‌کند. کامنت‌های فایل می‌مانند.
- نود را ری‌استارت می‌کند، بدون اینکه اسکریپت گیر کند.
- بخش IPv6 را اضافه می‌کند، چون نود فقط IPv4 را پشتیبانی می‌کند.
- یک route از نوع `unreachable` اضافه می‌کند تا اگر تونل قطع شد، ترافیک کلاینت‌ها از سرور ایران بیرون نرود.
- offload را روی `wg0` خاموش می‌کند. بعد از هر ری‌استارت نود هم دوباره خودکار خاموش می‌شود.
- قبل از روشن کردن forwarding، مقدار `accept_ra=2` را می‌گذارد تا IPv6 سرور از دست نرود.
- در آخر **کلید exit** را چاپ می‌کند.

**۴. سرور خارج:** کلید exit را paste کنید.

</div>

```bash
gretun exit add --key 'gretun-exit://...'
```

<div dir="rtl">

**۵. پنل پاسارگارد:**

- در Core و بخش WireGuard، فیلد Address را با هر دو subnet پر کنید.
- در Hosts مقدار **MTU را 1420** بگذارید. در تست واقعی ایران ↔ آلمان، با MTU 1280 آپلود حدود ۱ مگابیت بود و با 1420 حدود ۱۲۰ مگابیت.
- AllowedIPs را `0.0.0.0/0, ::/0` بگذارید.

بعد کلاینت‌ها کانفیگ را دوباره دانلود کنند و شما روی سرور ایران تأیید کنید:

</div>

```bash
gretun confirm
```

<div dir="rtl">

با خاموش بودن offload روی `gre1` و `wg0`، سرعت در تست واقعی به حدود ۳۰۰ مگابیت رسید. برای بررسی:

</div>

```bash
gretun doctor
```

<div dir="rtl">

### مثال (ب): یک قانون فوروارد IPv6

سرور خارج فقط IPv6 دارد (`2001:db8:5::10`) و Xray روی پورت 443 اجرا می‌شود:

</div>

```bash
gretun fwd add --dest 2001:db8:5::10 --ports 443 --proto tcp
```

<div dir="rtl">

حالا کاربرها به `IRAN_IPV4:443` وصل می‌شوند. برای دیدن وضعیت دستور `gretun fwd status` را بزنید. اگر Xray پروتکل PROXY را انتظار دارد، `--proxy` را هم اضافه کنید.

### تست

اسکریپت `tests/netns-test.sh` هر سه بخش را با network namespaceهای لینوکس، بدون سرور واقعی، تست می‌کند. آن را روی یک VM آزمایشی اجرا کنید:

</div>

```bash
sudo bash tests/netns-test.sh --install-deps
```
