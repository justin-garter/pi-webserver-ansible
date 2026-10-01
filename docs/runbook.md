# JG-RPi-WebServer: Technical Runbook (v3)

**Last updated:** 2026-09-30
**Supersedes:** v2 (August 2026, parents' network, NVMe, WireGuard). v2 is in git history.
**Design records:** DR-002 (gateway policy) and DR-003 (this playbook's rework) in the
`infrastructure-redesign` repo.

Lookup reference: exact configuration and why. Procedures live in the other `docs/` pages.

---

## 1. Architecture

```
Internet
   |
Cloudflare  (apex + www proxied, Always Use HTTPS, SSL Full (Strict))
   |  TCP 443 only, from Cloudflare ranges
TP-Link Archer BE9500  (ROOM_NET 192.168.0.0/24, roommate network)
   |  virtual server: TCP 443 -> 192.168.0.254:443
OPNsense VM 100 on Proxmox  (WAN 192.168.0.254)
   |  DNAT WAN:443 -> 10.10.40.10:443, source CLOUDFLARE_V4 only
   |  DMZ interface 10.10.40.1/24, VLAN 40, no DHCP
TL-SG105E port 3  (VLAN 40 untagged)
   |
JG-RPi-WebServer  10.10.40.10
```

| Direction | Policy | Enforced by |
|---|---|---|
| Internet to Pi | TCP 443 from Cloudflare's IPv4 ranges only | OPNsense alias + WAN rule |
| MAIN to Pi | Any at OPNsense; SSH admitted on the Pi from `10.10.20.10` only | OPNsense MAIN default pass, Pi nftables |
| MGMT to Pi | TCP 22 | OPNsense MGMT rule, Pi nftables |
| Pi to any private range | Blocked, except DNS to `10.10.40.1` | OPNsense DMZ rules (`!PRIVATE_NETS`) |
| Pi to internet | Allowed | OPNsense DMZ rule |

**Single-homed by design.** Wi-Fi and Bluetooth are disabled in firmware (`config.txt`). A
dual-homed host bridges networks regardless of firewall rules.

**Verified 2026-09-29** from a phone on cellular: the site loads with a valid padlock, http
redirects to https, and the house IP direct on 443 times out.

---

## 2. Device

| Item | Value |
|---|---|
| Hardware | Raspberry Pi 5, 1 GB |
| Storage | 64 GB Class 10 microSDXC. Image auto-expanded to the full card |
| OS | Raspberry Pi OS Lite 64-bit (Debian 13 trixie). Exact release: `cat /etc/os-release` |
| Hostname | `JG-RPi-WebServer` |
| Address | `10.10.40.10/24`, gateway and DNS `10.10.40.1` |
| Switch | TL-SG105E port 3, VLAN 40 untagged |
| Account | `justin`. SSH key-only. Password set, used for console login and sudo |
| Timezone | `America/New_York` |
| Power | Shares the lab power strip. No UPS (R4) |

---

## 3. Network and addressing

**NetworkManager owns `eth0`.** Raspberry Pi OS runs NetworkManager with a netplan backend.
A hand-written netplan file gets absorbed into NetworkManager's own `90-NM-<uuid>.yaml`, so
`roles/base` manages one NetworkManager profile instead (DR-003 11.7):

| Property | Value |
|---|---|
| Profile | `dmz`, persisted as `/etc/NetworkManager/system-connections/dmz.nmconnection` |
| IPv4 | manual, `10.10.40.10/24`, gateway `10.10.40.1`, DNS `10.10.40.1` |
| IPv6 | disabled |
| Other Ethernet profiles | deleted by the playbook |
| `/etc/netplan/` | empty |

**First boot address:** seeded in `network-config` on the boot partition (DMZ has no DHCP).
The playbook deletes that file and `/etc/netplan/50-cloud-init.yaml` once `dmz` is active.

**cloud-init is disabled** (`/etc/cloud/cloud-init.disabled`). It applies Imager's
customisation on first boot, then keeps rewriting `/etc/hosts` and the hostname. The seed
files `user-data` and `network-config` are deleted: they hold the password hash on FAT32,
where the displayed permissions enforce nothing.

Change addressing in `vars.yml` (`dmz_*`), never with `nmcli` on the Pi.

---

## 4. Ingress path

Full detail in `opnsense-vm.md` 5.5. Summary:

| Layer | Configuration |
|---|---|
| Cloudflare | Apex and `www` proxied. Always Use HTTPS on. SSL mode Full (Strict) |
| Archer | One virtual server: TCP 443 to `192.168.0.254:443`. Port 80 is not forwarded |
| OPNsense alias | `CLOUDFLARE_V4`, URL table `https://www.cloudflare.com/ips-v4`, refreshed daily |
| OPNsense DNAT | WAN, TCP, source `CLOUDFLARE_V4`, WAN:443 to `10.10.40.10:443` |
| OPNsense WAN rule | Pass TCP, source `CLOUDFLARE_V4`, destination `10.10.40.10:443`, logged. Added by hand |
| Pi nftables | 443 from any. Upstream already limits it to Cloudflare |

---

## 5. DNS

**Registrar:** Cloudflare Registrar. **Domain expires:** 2027-07-12.

| Type | Name | Content | Proxy |
|---|---|---|---|
| A | `justingarter.com` | home public IP, kept current by DDNS | Proxied |
| CNAME | `www` | `justingarter.com` | Proxied |

`vpn` was deleted 2026-09-22 (no WireGuard). `origin` is deliberately absent until
Minecraft exists (DR-003 11.5): a DNS-only record publishes the home IP and lets anyone skip
Cloudflare.

---

## 6. DDNS

| Item | Value |
|---|---|
| Script | `/usr/local/bin/cloudflare-ddns.sh`, `0700 root:root` |
| Config | `/etc/cloudflare-ddns/config`, `0600 root:root`. Holds the API token |
| Units | `cloudflare-ddns.service` and `.timer`, every 5 minutes |
| Records | `ddns_records`: apex only |
| State | `/var/lib/cloudflare-ddns/last_ip` |

Two behaviours to keep if it is ever rewritten:

- It reads each record's `proxied` flag before writing instead of hardcoding it.
- It caches `last_ip` only when every record succeeds, so a partial failure retries all.

It edits existing records and never creates them.

---

## 7. Firewall

`/etc/nftables.conf`, rendered from `roles/nftables/templates/nftables.conf.j2`:

```nft
table inet filter
delete table inet filter

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        ct state established,related accept
        ct state invalid drop
        iif lo accept
        ip  protocol icmp   icmp   type { echo-request, destination-unreachable, time-exceeded } accept
        ip6 nexthdr  icmpv6 icmpv6 type { echo-request, nd-neighbor-solicit, nd-neighbor-advert,
                                          nd-router-advert, packet-too-big,
                                          destination-unreachable, time-exceeded } accept
        tcp dport { 443 } accept
        ip saddr { 10.10.10.0/24, 10.10.20.10/32 } tcp dport 22 accept comment "ssh - mgmt + admin desktop only"
        counter comment "dropped"
    }
    chain forward { type filter hook forward priority 0; policy drop; }
    chain output  { type filter hook output  priority 0; policy accept; }
}
```

- **Replace only `inet filter`, never `flush ruleset`.** fail2ban keeps its own
  `inet f2b-table`. A full flush deletes active bans while fail2ban keeps reporting them.
- **SSH is source-scoped, not interface-scoped.** There is no management interface. This
  also removed the old two-pass first run, which existed only because an interface check
  read facts gathered before WireGuard created `wg0`.
- **No forwarding.** `net.ipv4.ip_forward = 0`, pinned in `/etc/sysctl.d/99-no-forward.conf`
  and asserted.
- **No UDP 443.** Caddy does not advertise HTTP/3; Cloudflare reaches the origin over TCP.
- **Validation:** the template is checked with `nft -c -f` before it is written, and the role
  refuses an empty `ssh_admin_sources`.

---

## 8. SSH and access

| Item | Value |
|---|---|
| Port | 22 (DR-003 11.4) |
| Auth | Key only. `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin no` |
| Drop-in | `/etc/ssh/sshd_config.d/00-hardening.conf` |
| Sources | `10.10.10.0/24` and `10.10.20.10/32` (nftables and OPNsense) |
| sudo | Password required (DR-003 11.6). Ansible prompts with `become_ask_pass` |
| Console | `justin` with password. The break-glass (R13), asserted by `roles/base` |

**Drop-in precedence.** `sshd_config` includes `sshd_config.d/*.conf` near the top and sshd
keeps the **first** value it reads for most keywords. `00-` sorts before cloud-init's `50-`,
so it wins. The role asserts against `sshd -T`, not the file, because the predecessor host
ran with password auth on for months while its file said otherwise.

**SSH aliases on the desktop:** `WebServer` in PowerShell (`10.10.40.10`, user `justin`).
WSL connects by address.

---

## 9. Caddy and TLS

| Item | Value |
|---|---|
| Source | Cloudsmith `caddy/stable` repo. Signing key checksum-pinned in the role |
| Config | `/etc/caddy/Caddyfile` |
| Sites | `justingarter.com`, `www.justingarter.com` |
| Web root | `/var/www/portfolio`, `justin:justin 0755` |
| URLs | `try_files {path} {path}.html`, so extensionless links work |
| Listeners | 443 only. `auto_https disable_redirects`, so no :80 listener |
| Protocols | `h1 h2` |
| Access log | JSON, `/var/log/caddy/access.log` |
| Memory | `GOMEMLIMIT=256MiB`, `MemoryMax=384M` (systemd override) |
| Headers | HSTS (1 year, includeSubDomains, preload), nosniff, `X-Frame-Options: DENY`, `strict-origin-when-cross-origin`, Permissions-Policy, `-Server` |

**TLS: Cloudflare Origin CA** (DR-003 11.8).

| Item | Value |
|---|---|
| Type | ECC |
| SAN | `justingarter.com`, `*.justingarter.com` |
| **Expires** | **2041-09-25** |
| Certificate | `roles/caddy/files/origin.pem` in git, deployed to `/etc/caddy/tls/origin.pem`, `root:caddy 0644` |
| Key | `roles/caddy/files/origin.key.vault` (ansible-vault), deployed to `/etc/caddy/tls/origin.key`, `root:caddy 0640` |

Why not Let's Encrypt: behind Cloudflare's proxy only HTTP-01 works, which needs port 80
open and a renewal every 60 to 90 days that fails silently. DNS-01 needs a custom Caddy build
and a DNS-edit token on an internet-facing host. Origin CA needs neither.

Limitation, accepted: only Cloudflare trusts the certificate. If the record is ever set to
DNS only, browsers reject it. `curl` on the Pi needs `-k` for the same reason.

**`trusted_proxies` is security-critical.** Without it every log line records a Cloudflare
edge as the client. Correctly scoped, forged `CF-Connecting-IP` headers from anyone else are
ignored. Static IPv4 list in `vars.yml`; IPv6 omitted because there is no AAAA record.

**Never run `sudo caddy validate` or `sudo caddy run` by hand.** Either creates the access
log as `root:root`, and Caddy, running as `caddy`, then cannot open it. The role repairs
ownership after its own validate step.

**No rate limiting or WAF at the origin.** Static HTML, no forms. Blocking belongs at
Cloudflare (Section 10).

---

## 10. fail2ban

| Item | Value |
|---|---|
| Package | Debian `fail2ban` 1.1.x, plus `python3-systemd` for the journal backend |
| Ban action | `nftables[type=multiport]`. The Pi has no `iptables`; an iptables action looks healthy and bans nothing |
| ignoreip | `127.0.0.1/8 ::1 10.10.10.0/24 10.10.20.10/32` |
| `sshd` jail | port 22, systemd journal |
| `caddy-404` jail | access log, 10 hits in 120 s, ban 3600 s. Filter matches `client_ip` with status 404 |

`f2b-table` appears only after the first ban. Its absence after a reboot is normal.

**`caddy-404` detects but cannot block.** It bans the visitor address, but every packet the
Pi receives comes from a Cloudflare address, so the nftables ban never matches. Effective
blocking moves to Cloudflare (WAF rule or IP list through the API) with the web traffic
dashboard.

---

## 11. Updates

| Component | Mechanism |
|---|---|
| Debian packages | unattended-upgrades. Local settings in `52unattended-upgrades-local`: reboot at 04:00 when required, remove unused kernels and dependencies |
| Caddy | Manual. Cloudsmith is not an allowed origin. Procedure in [Making changes](making-changes.md#updating-caddy) |
| Raspberry Pi kernel and firmware | Manual (`sudo apt full-upgrade`). The Raspberry Pi repo has no separate security pocket |
| Cloudflare ranges | OPNsense alias: daily, automatic. Caddy `trusted_proxies`: manual |

---

## 12. Thermal and throttling

Hourly log: `/var/log/pi-thermal.log`, from `pi-thermal.timer`.

`vcgencmd get_throttled` bits 0 to 3 are current; 16 to 19 are sticky since boot.

| Bit | Meaning |
|---|---|
| 0 / 16 | under-voltage now / has occurred |
| 1 / 17 | ARM frequency capped now / has occurred |
| 2 / 18 | throttled now / has occurred |
| 3 / 19 | soft temperature limit now / has occurred |

`0xe0000` means it happened at some point and nothing is happening now. Only a reboot clears
the sticky bits.

`fan1_input` reading 0 at idle is normal. The Pi 5 fan curve starts around 50 C.

---

## 13. Storage, memory and swap

microSD wear settings (DR-003 7, as amended in 11.1):

| Setting | Value | Why |
|---|---|---|
| Root mount | `defaults,noatime,commit=600` | No write per read; ext4 flushes every 10 minutes, coalescing log writes |
| journald | `Storage=volatile`, `RuntimeMaxUse=32M` | Journal in RAM only |
| log2ram | Not used | Needs a third-party apt repo on an internet-facing host |

| Swap tier | Size | Priority |
|---|---|---|
| zram0 | about RAM size | 100, fills first |
| `/var/swap` | | zram writeback store. **Not a stale swapfile. Do not delete** |
| `/swapfile` | 512 MB | -10, backstop only |

**R14, accepted:** a hard power loss loses up to 10 minutes of log data and the whole
journal. Nothing in either is load-bearing for a static site.

---

## 14. Secrets

| Secret | Lives in | Notes |
|---|---|---|
| SSH private key | `C:\Users\garte\.ssh\id_ed25519` | WSL uses it through `ssh-agent` |
| `justin` password | Password manager | Console login and sudo. Same password |
| Ansible vault password | Password manager | Decrypts `vault.yml` and `origin.key.vault` |
| Cloudflare API token | `vault.yml` as `ddns_api_token`; on the Pi in `/etc/cloudflare-ddns/config` | Zone > DNS > Edit, this zone only |
| Origin CA private key | `roles/caddy/files/origin.key.vault`; on the Pi in `/etc/caddy/tls/origin.key` | Shown once by Cloudflare. Never in the repo as plaintext |

Before every push: `head -1 group_vars/webserver/vault.yml roles/caddy/files/origin.key.vault`
must print `$ANSIBLE_VAULT;1.1;AES256` twice.

---

## 15. Build history

| Date | Event |
|---|---|
| 2026-08 | Built on the parents' network: VLAN 54, NVMe, WireGuard-only management. Rebuilt from the playbook on 2026-08-16 |
| 2026-09-22 | Booted at the new place, no console login possible (DR-003 Section 2, R13). Card wiped |
| 2026-09-29 | Rebuilt on VLAN 40 behind OPNsense from a 64 GB microSD. First run found three defects (fail2ban handlers not flushed before the jail assert, netplan file fighting NetworkManager, missing vault prompt), all fixed in the playbook. Console login verified. Origin CA PEM files collapsed to one line on paste, re-wrapped and match-checked. Reboot, then a full run at `changed=0 failed=0`. Site live |

---

## 16. Accepted tradeoffs and open items

**Accepted:**

- No rate limiting or WAF at the origin. Static site.
- No external uptime monitoring. Downtime is an inconvenience, not an incident.
- Caddy updates are manual.
- `trusted_proxies` is a static list.
- Origin certificate trusted by Cloudflare only.
- `base` reports leftover Wi-Fi profiles in `/etc/netplan` instead of deleting them.
- R14: up to 10 minutes of logs lost on power cut.

**Open:**

- `caddy-404` blocking at Cloudflare, with the web traffic dashboard (Section 10).
- Card overprovisioning (DR-003 7: image into about 16 GB, leave the rest unallocated) was
  not done. The image auto-expanded. Revisit at the next rebuild.
- `wrk` stays in `verification_packages`, but the August load-test figures were measured on
  NVMe at the old site. Retake them or retract them from the site (DR-003 10).
- No serial console. A USB-to-TTL adapter would make console recovery possible from the desk.

---

## 17. Maintenance commands

Run on the Pi.

| Task | Command |
|---|---|
| Service overview | `systemctl status caddy fail2ban nftables cloudflare-ddns.timer pi-thermal.timer` |
| Live traffic | `sudo tail -f /var/log/caddy/access.log \| jq .` |
| Recent visitor IPs | `sudo tail -20 /var/log/caddy/access.log \| jq -r .request.client_ip` |
| Ban lists | `sudo fail2ban-client status caddy-404` and `sshd` |
| Bans in the kernel | `sudo nft list table inet f2b-table` |
| Manual DDNS run | `sudo systemctl start cloudflare-ddns.service` |
| Public IP | `curl -s -4 https://ifconfig.me` |
| Reload Caddy | `sudo systemctl reload caddy` |
| Certificate expiry | `openssl x509 -in /etc/caddy/tls/origin.pem -noout -enddate` |
| Forwarding state | `sysctl net.ipv4.ip_forward`, expect 0 |
| Single-homed | `ip -br a`, expect `lo` and `eth0` |
| NM profiles | `nmcli con show`, expect `dmz` and `lo` |
| Effective SSH config | `sudo sshd -T \| grep -iE '^(port\|password\|permitroot)'` |
| Thermal history | `tail /var/log/pi-thermal.log` |
