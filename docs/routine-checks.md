# Routine checks

Confirming the Pi is healthy and doing what the docs claim. Nothing here changes state
except the fail2ban test ban, which removes itself.

A config file is intent. A running service's report is reality. Attempting the thing is
truth. This page prefers the third.

All commands run on the **CONTROL NODE** (WSL) with the agent loaded, unless marked
otherwise. `P` below means `ssh -t justin@10.10.40.10`, so set it once per window:

```bash
P="ssh -t justin@10.10.40.10"
```

---

## Sixty-second health check

```bash
$P 'systemctl is-active caddy nftables fail2ban ssh cloudflare-ddns.timer pi-thermal.timer; ip -br a; nmcli -t -f NAME,DEVICE con show; vcgencmd measure_temp; vcgencmd get_throttled; df -h / | tail -1; uptime'
```

**Check:**

| Want | If wrong |
|---|---|
| six `active` | `sudo journalctl -u <name> -b --no-pager \| tail -30` |
| interfaces `lo` and `eth0` only, `eth0` on `10.10.40.10/24` | Anything else means the Pi is no longer single-homed |
| profiles `dmz:eth0` and `lo:lo` only | A second Ethernet profile can win at next boot. Rerun the playbook |
| under 50 C idle | See Thermal |
| `throttled=0x0` | Bits 16 to 19 are sticky since boot. Decode before acting ([Runbook](runbook.md) section 12) |
| root well under 50% | Check `/var/log/caddy` |

---

## Is the site serving?

```bash
$P "curl -sk -o /dev/null -w 'status=%{http_code}\n' --resolve justingarter.com:443:127.0.0.1 https://justingarter.com/"
```

**Run on: WORKSTATION**

```powershell
curl.exe -s -o NUL -w "status=%{http_code}`n" https://justingarter.com/
```

`-k` on the Pi is required: the Origin CA certificate is trusted by Cloudflare only.

**Check:** both print `status=200`. Local 200 with outside failure means the ingress path,
not the Pi: [Recovery](recovery.md).

---

## Is the origin reachable only through Cloudflare?

**Run on:** a phone on cellular, Wi-Fi off. Find the home IP first with
`$P 'curl -s -4 https://ifconfig.me; echo'`.

- `https://justingarter.com` loads with a valid padlock.
- `https://<home IP>` times out.

**Check:** both as listed. A response from the direct IP means OPNsense's `CLOUDFLARE_V4`
source restriction is gone (`opnsense-vm.md` 5.5).

---

## Is SSH really key-only?

Config, then runtime, then behaviour.

```bash
$P "sudo sshd -T | grep -iE '^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication) '; sudo ss -tlnp | grep sshd"
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 justin@10.10.40.10
```

`sshd -T` is parsed config, what sshd would do on next start. `ss` is what the running
daemon is bound to. Only the login attempt proves behaviour.

**Check:** `port 22`, `permitrootlogin no`, both auth lines `no`; sshd listening on 22; the
login attempt ends with `Permission denied (publickey)` and **no password prompt**.

---

## Is SSH limited to the two admin sources?

```bash
$P 'sudo nft list chain inet filter input | grep -i ssh'
```

**Check:** one rule: `ip saddr { 10.10.10.0/24, 10.10.20.10 } tcp dport 22 accept`.

---

## Is the DMZ still contained?

The Pi must reach the internet and nothing private. OPNsense enforces this (DMZ rules pass
DNS to `10.10.40.1` and `!PRIVATE_NETS` only).

```bash
$P 'ping -c2 -W2 10.10.20.10; ping -c2 -W2 10.10.10.5; ping -c2 -W2 192.168.0.1; curl -s -o /dev/null -w "internet %{http_code}\n" https://1.1.1.1; getent hosts cloudflare.com'
```

**Check:** all three pings fail (100% packet loss), `internet 200` or `301`, and
`cloudflare.com` resolves. A ping reply means the Pi has become a pivot into the lab or
ROOM_NET.

---

## Is forwarding off?

```bash
$P 'sysctl net.ipv4.ip_forward; sudo nft list chain inet filter forward'
```

**Check:** `= 0`, and the forward chain is empty with `policy drop`.

---

## Is fail2ban enforcing?

```bash
$P 'sudo fail2ban-client status; sudo fail2ban-client set sshd banip 203.0.113.55; sudo nft list table inet f2b-table; sudo fail2ban-client set sshd unbanip 203.0.113.55'
```

`203.0.113.55` is TEST-NET-3, safe to ban. The `f2b-table` is created lazily at the first
ban, so its absence on a freshly booted Pi with no bans is normal. The ban appearing in the
kernel ruleset is the proof. `fail2ban-client` reporting a ban is not; that is what a wrong
`banaction` looks like.

**Check:** jails `sshd` and `caddy-404` listed; the test address appears in `f2b-table`.

**Known limitation:** `caddy-404` detects but cannot block. It bans the visitor address from
`CF-Connecting-IP`, but every packet reaching the Pi comes from a Cloudflare address, so the
ban never matches. Blocking moves to Cloudflare with the traffic dashboard (DR-003 11.8).

---

## Visitor IPs

```bash
$P "sudo tail -5 /var/log/caddy/access.log | jq -r '[.request.remote_ip, .request.client_ip, .status] | @tsv'"
```

**Check:** `remote_ip` is a Cloudflare address and `client_ip` is a plausible visitor. Both
Cloudflare means `trusted_proxies` needs a refresh: [Making changes](making-changes.md#refreshing-the-cloudflare-trusted-proxy-list).

---

## Is DDNS keeping up?

```bash
$P 'systemctl list-timers cloudflare-ddns --all --no-pager; sudo journalctl -u cloudflare-ddns --no-pager | tail -5; curl -s -4 https://ifconfig.me; echo'
```

The journal is in RAM, so history starts at the last boot.

**Check:** the timer's next run is under five minutes away, the last lines read
`IP unchanged (<ip>), skipping.` or a success line, and that IP matches `ifconfig.me`.

---

## Certificate

```bash
$P 'openssl x509 -in /etc/caddy/tls/origin.pem -noout -enddate; sudo stat -c "%U:%G %a %n" /etc/caddy/tls/*'
```

**Check:** `notAfter=Sep 25 ... 2041 GMT`; `origin.pem` is `root:caddy 644`; `origin.key` is
`root:caddy 640`.

---

## microSD wear settings

```bash
$P 'findmnt -no OPTIONS /; journalctl --header | grep -i "file path"; swapon --show'
```

**Check:** root options include `noatime` and `commit=600`; the journal path is under
`/run/log/journal` (RAM); swap shows `/dev/zram0` at priority 100 and `/swapfile` 512M at
priority -10.

---

## Thermal

```bash
$P 'vcgencmd measure_temp; vcgencmd get_throttled; tail -5 /var/log/pi-thermal.log'
```

**Check:** idle temperature in the 30s or 40s, `throttled=0x0`, and an hourly log line in
the last hour.

---

## After any change to OPNsense, the Archer or the switch

Run, in this order: the site checks, the Cloudflare-only check, the SSH source check, and
the containment check.

**Check:** all four pass.
