# Routine checks

Confirming the host is healthy and actually doing what it claims. Nothing here changes
state, so all of it is safe to run any time.

The organising principle: **a config file describes intent, querying a running service
describes reality, and attempting the thing describes truth.** Those three answers are
not always the same, and this page prefers the third wherever it can get it.

---

## Sixty-second health check

**Run on: SERVER**

```bash
systemctl is-active caddy nftables wg-quick@wg0 fail2ban ssh cloudflare-ddns.timer
ip -br a
vcgencmd measure_temp; vcgencmd get_throttled
df -h / | tail -1
uptime
```

| Want | Meaning if wrong |
|---|---|
| six × `active` | A dead service. `journalctl -u <name> -b --no-pager \| tail -30` |
| `lo`, `eth0`, `wg0` only | An extra interface means the host is no longer single-homed |
| under 50 °C idle | Check the fan; see thermal below |
| `throttled=0x0` | Bits 16–19 are sticky since boot, not current state — decode before panicking |
| root well under 50% | The access log grows; check `/var/log/caddy` |

---

## Is the site actually serving?

**Run on: SERVER**

```bash
curl -s -o /dev/null -w 'status=%{http_code} bytes=%{size_download}\n' \
  --resolve justingarter.com:443:127.0.0.1 https://justingarter.com/
```

`--resolve` forces the hostname to loopback while presenting the correct SNI, so Caddy
serves the real certificate. Without it you get a TLS handshake failure, because there
is no certificate for `127.0.0.1` — and that failure looks like a server problem when
it is a client one.

**Run on: WORKSTATION**

```powershell
curl.exe -s -o NUL -w "status=%{http_code} bytes=%{size_download}`n" https://justingarter.com/
```

Local 200 plus external failure means DNS, Cloudflare, or your public IP — not the
server.

---

## Is SSH really key-only?

The config says so. That is not the same as it being true — the predecessor host ran
with password auth enabled for months while its documentation claimed otherwise.

**Config, then runtime, then behaviour:**

**Run on: SERVER**
```bash
sudo sshd -T | grep -iE '^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication) '
sudo ss -tlnp | grep sshd
```

`sshd -T` reports *parsed configuration* — what sshd would do on next start. `ss -tlnp`
reports what the running process is bound to. They can disagree, and when they do it
is usually because a config was written and the daemon never restarted.

**Run on: WORKSTATION** — the only test that proves anything:
```powershell
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 justin@192.168.54.180 -p 2222
```

Want `Permission denied (publickey)` **with no password prompt**. A prompt means the
server is accepting password auth regardless of what any file claims.

---

## Is the segmentation still holding?

The claim is that the DMZ and the trusted LAN cannot reach each other. Test both
directions; a rule can be removed from one side without the other noticing.

**Run on: SERVER** — DMZ → LAN, the direction that matters most:
```bash
ping -c2 -W2 192.168.50.1
```
**Must time out.** A reply means the segmentation is open and the host has become a
potential pivot into your trusted network.

**Run on: WORKSTATION** — LAN → DMZ, with **WireGuard deactivated**:
```powershell
ping -n 2 192.168.54.180
Test-NetConnection 192.168.54.180 -Port 2222
```
Both must fail. If the tunnel is up, all `192.168.54.x` traffic goes through it and you
are testing nothing.

Then reactivate WireGuard and confirm the legitimate path works:
```powershell
ssh WebServer 'hostname'
```

Run this trio after any router change, and always after closing a temporary rule.

---

## Is fail2ban actually enforcing?

Two jails should be loaded, and a ban should reach the kernel.

**Run on: SERVER**
```bash
sudo fail2ban-client status
sudo fail2ban-client status caddy-404
sudo nft list tables
```

**`f2b-table` will not exist on a freshly booted host with zero bans.** The table, set,
and chain are created lazily at the *first ban*, not at service start. So `nft list
tables` showing only `inet filter` while `fail2ban-client status` reports both jails is
**normal**, not broken. Do not diff a freshly booted ruleset against a snapshot from a
long-uptime host and conclude something is wrong.

To tell "not created yet" from "genuinely broken", force a ban and watch it appear:

```bash
sudo fail2ban-client set caddy-404 banip 198.51.100.42     # TEST-NET-2, safe
sudo nft list table inet f2b-table
sudo fail2ban-client set caddy-404 unbanip 198.51.100.42
```

The rule appearing in the ruleset is the proof. `fail2ban-client` reporting a ban is
not — that is the exact failure mode a wrong `banaction` produces, where every jail
looks healthy and bans nothing.

---

## Are visitor IPs resolving correctly?

If `trusted_proxies` is wrong, every log entry records a Cloudflare edge address
instead of the visitor — and the `caddy-404` jail starts banning Cloudflare.

**Run on: SERVER**
```bash
sudo tail -5 /var/log/caddy/access.log | jq -r '[.request.remote_ip, .request.client_ip, .status] | @tsv'
```

`remote_ip` should be a Cloudflare address; `client_ip` should be a plausible visitor.
If both are Cloudflare, the trusted-proxy list needs refreshing —
see [Making changes](making-changes.md).

---

## Is DDNS keeping up?

**Run on: SERVER**
```bash
systemctl list-timers cloudflare-ddns --all --no-pager
sudo journalctl -u cloudflare-ddns -b --no-pager | tail -10
curl -s https://api.ipify.org; echo
```

The timer runs every five minutes, so the worst case after an address change is five
minutes of stale DNS. Log lines read either `IP unchanged (x.x.x.x), skipping.` or
`IP changed from … updating Cloudflare…` followed by one success line per record.

Both `justingarter.com` and `vpn.justingarter.com` must update. The `vpn` record is
what your tunnel endpoint resolves to; if it stops updating, remote access breaks the
next time your ISP renumbers you.

---

## Certificates

**Run on: SERVER**
```bash
sudo ls -la /var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/*/
sudo journalctl -u caddy -b --no-pager | grep -iE 'certificate|obtain|renew' | tail -10
```

Routine operation shows `got renewal info` lines. `certificate obtained successfully`
means a *new* certificate was issued — expected after a rebuild, unexpected otherwise,
and worth investigating since Let's Encrypt allows only five duplicates per week.

---

## Thermal

**Run on: SERVER**
```bash
vcgencmd measure_temp
cat /sys/devices/platform/cooling_fan/hwmon/hwmon*/fan1_input
tail -5 /var/log/pi-thermal.log
vcgencmd get_throttled
```

**`fan1_input` reading 0 at idle is expected**, not a dead fan. The Pi 5 fan curve does
not spin up until roughly 50 °C. The only way to confirm the fan works is to drive the
SoC past that and watch the RPM go nonzero — the load test below does it.

Reference figures with the active cooler fitted: idle 34 °C, peak 64.2 °C under
sustained synthetic load, no throttle bits. Before the cooler, the same load reached
84.5 °C with throttling triggered.

Decoding `get_throttled`: bits 0–3 are *current* state, bits 16–19 are *sticky since
boot*. `0xe0000` means things happened at some point, nothing is happening now. Only a
reboot clears the sticky bits.

---

## Load test

Only when you want a number — this saturates the host for the duration.

**Run on: SERVER**

`wrk` cannot be pointed at loopback directly, because it takes SNI from the URL and
Caddy has no certificate for `127.0.0.1`. Add a temporary hosts entry so the name, SNI,
and destination all agree:

```bash
echo '127.0.0.1 justingarter.com' | sudo tee -a /etc/hosts

# validate ONE request before spending two minutes measuring a million
curl -s -o /dev/null -w 'status=%{http_code} bytes=%{size_download}\n' https://justingarter.com/
```

Only if that returns `200` with a real byte count:

```bash
wrk -t4 -c100 -d120s https://justingarter.com/
```

Watch conntrack in a second session. It should sit near your connection count:

```bash
watch -n2 'cat /proc/sys/net/netfilter/nf_conntrack_count'
```

**Always remove the hosts entry afterwards** — leaving it means the host resolves its
own domain to itself, which quietly breaks anything that later tries to reach the
public site from the Pi:

```bash
sudo sed -i '/justingarter.com/d' /etc/hosts
grep justingarter /etc/hosts || echo "reverted"
```

### Why the test fails if you improvise

Two traps, both of which produce *misleading* output rather than an obvious error:

**Never benchmark plain HTTP on port 80.** Caddy answers with a 308 redirect carrying
`Connection: close`, so `wrk` opens a fresh TCP connection per request instead of
reusing a hundred. At ~11k requests/second each leaves a conntrack entry in TIME_WAIT,
and `nf_conntrack_max` on this host is 8192 — exhausted in under a second. After that
the kernel drops new SYNs *before* nftables evaluates them, so the firewall's drop
counter stays at zero, `wrk` reports no socket errors, and the summary shows a healthy
per-thread rate beside a total two orders of magnitude too low. The only direct
evidence is `dmesg`:

```bash
sudo dmesg -T | grep -i conntrack | tail -3
```

8192 is fine for real Cloudflare-proxied traffic and has never been approached in
production. It is only a ceiling under connection-churning synthetic load. Fix the
test, not the limit.

**`-H 'Host: …'` is not the same as SNI.** Setting the Host header while connecting to
`https://127.0.0.1/` sends SNI `127.0.0.1`, every handshake fails, and you get zero
requests with tens of thousands of connect errors — which reads like a server fault and
is a client misconfiguration.

Reference figures: 11,952 req/s at 133 MB/s, `-t4 -c100 -d120s`, peak 64.2 °C, no
throttling. Measured over loopback with the generator sharing the host's four cores, so
it describes what Caddy and the CPU can do rather than what the network path can carry.

---

## Full state capture

For comparing against a known-good snapshot, or before making significant changes.

**Run on: SERVER**
```bash
mkdir -p ~/state-$(date +%Y%m%d) && cd ~/state-$(date +%Y%m%d)
dpkg-query -W -f='${Package} ${Version}\n' | sort > packages.txt
systemctl list-unit-files --state=enabled --no-pager | sort > units-enabled.txt
sudo nft list ruleset > nft.txt
ss -tulpn 2>/dev/null | sort > listening.txt
sudo sysctl -a 2>/dev/null | sort > sysctl.txt
wc -l *.txt
```

When diffing two captures, expect noise in `sysctl.txt` — a dozen or so keys are
memory-autotuned or per-boot (`kernel.random.uuid`, `fs.epoll.max_user_watches`,
`tcp_mem`, live conntrack count) and differ every time regardless of configuration.
The values that matter are the ones the playbook sets, `net.ipv4.ip_forward` chief
among them.
