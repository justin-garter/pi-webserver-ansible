# JG-RPi-WebServer — Ansible

Reproducible build for an internet-facing static web server on a Raspberry Pi 5 (1GB), isolated in a DMZ VLAN, fronted by Cloudflare, and reachable for management only over WireGuard.

This playbook builds the host documented in `pi-webserver-runbook-v2.md`. The runbook explains *why*; this repo is the *what*, executable.

---

## What it configures

| Role | Result |
|---|---|
| `base` | Hostname, timezone, packages, cloud-init disabled, radios disabled at firmware, NVMe swapfile below zram in priority, unattended-upgrades with 04:00 auto-reboot |
| `ssh` | Key-only auth on 2222 via a `00-` drop-in that wins over cloud-init's, then asserts the *effective* config matches |
| `wireguard` | `wg0` at `10.10.10.1/24` — the only management path into the DMZ |
| `nftables` | Default-deny inbound. 80/443 public, 51820 for the tunnel, SSH restricted to `wg0` |
| `caddy` | Caddy from the Cloudsmith repo, Cloudflare `trusted_proxies`, six security headers, JSON access log, memory ceilings |
| `fail2ban` | nftables ban backend, `sshd` and `caddy-404` jails |
| `ddns` | Cloudflare DDNS on a 5-minute systemd timer, preserving each record's proxied flag |
| `monitoring` | Hourly thermal and throttle logging |

Site content is **not** managed here. Host configuration and content deploys are separate changes on purpose — when the site breaks you want one variable to check, not two.

---

## Prerequisites

- Ansible control node on Linux (WSL2 is fine; Ansible does not run natively on Windows)
- The WireGuard tunnel **up** — the target is unreachable without it
- SSH private key at `~/.ssh/id_ed25519`, mode `0600`

Run from a native Linux filesystem, not `/mnt/c`. DrvFs cannot represent Unix permissions, so Ansible refuses to load a world-writable `ansible.cfg` and Vault files can't be protected.

```bash
ansible-galaxy collection install -r requirements.yml
```

---

## Setup

```bash
cp group_vars/webserver/vault.yml.example group_vars/webserver/vault.yml
# fill in the real Cloudflare API token and WireGuard private key
ansible-vault encrypt group_vars/webserver/vault.yml
```

Verify before every push:

```bash
head -1 group_vars/webserver/vault.yml    # must read $ANSIBLE_VAULT;1.1;AES256
```

---

## Running

Always dry-run first:

```bash
ansible-playbook site.yml --check --diff --ask-vault-pass
```

Then apply:

```bash
ansible-playbook site.yml --ask-vault-pass
```

A single role:

```bash
ansible-playbook site.yml --tags caddy --ask-vault-pass
```

---

## Lockout risk — read before running `nftables`

**This host has no management path except WireGuard.** The DMZ VLAN blocks the trusted LAN in both directions; SSH on 2222 is not forwarded from the internet. If the tunnel is down or `wg0` is missing when the firewall applies, recovery is HDMI and a keyboard.

Three things guard against that:

1. **Role order.** `wireguard` runs before `nftables` in `site.yml`, so the interface the SSH rule references exists before the rule is written.
2. **A pre-flight assertion.** The `nftables` role refuses to run if `wg0` is absent from gathered facts.
3. **Template validation.** `nft -c -f` checks the ruleset syntactically before it is ever written to disk.

None of that protects against a *semantically* valid ruleset that locks you out. When changing firewall templates, arm a dead-man switch on the host first:

```bash
sudo systemd-run --on-active=300 --unit=fw-rollback nft -f /etc/nftables.conf.bak
# apply, confirm a SECOND session still connects, then:
sudo systemctl stop fw-rollback.timer
```

The WireGuard handler uses `wg syncconf` rather than `wg-quick down/up` for the same reason — tearing down the interface would drop the connection Ansible is running over.

---

## Design notes

**SSH drop-in precedence.** `/etc/ssh/sshd_config` has `Include /etc/ssh/sshd_config.d/*.conf` near the top, and sshd takes the **first** value obtained for most keywords, not the last. Drop-ins are read in lexical order, so `00-hardening.conf` wins over cloud-init's `50-cloud-init.conf`, and anything written further down the main config is dead text. The predecessor host ran with `PasswordAuthentication yes` for months because of exactly this while its documentation claimed key-only. The `ssh` role therefore asserts against `sshd -T` output rather than trusting the file it just wrote.

**fail2ban's ban backend.** This host has no `iptables` binary. A jail left on `iptables-multiport` reports as healthy and bans nothing. `banaction` is set to `nftables[type=multiport]` explicitly.

**`trusted_proxies` is security-critical.** Without it, every access-log entry records a Cloudflare edge IP instead of the visitor, and the `caddy-404` jail bans Cloudflare. Correctly scoped, forged `CF-Connecting-IP` headers from untrusted sources are ignored.

**`caddy validate` runs as root** and sets up the log writer as a side effect, creating `access.log` owned `root:root`. Caddy then starts as the `caddy` user, cannot open its own log, and dies with a misleading permission error. The role repairs ownership immediately after the validate step.

**`/var/swap` is not a stale swapfile.** It is zram's writeback backing store, managed by `rpi-setup-loop@var-swap.service`. Deleting it breaks the zram+file swap tier. The playbook creates `/swapfile` separately, at a priority below zram's 100.

---

## Routed access through the tunnel

This host terminates the WireGuard tunnel and also routes **one** narrowly-scoped flow to another DMZ host (`minecraftserver`, `192.168.54.10:22`), rather than standing up a second VPN endpoint or forwarding another WAN port. Peers already carry `AllowedIPs` covering the whole DMZ `/24`, so no peer config changes were needed.

Driven entirely by `nft_forward_allow` in `group_vars`. An empty list means no routing and sets `net.ipv4.ip_forward` back to `0` — the sysctl and the firewall rules read the same variable so they cannot disagree.

Three deliberate choices:

- **The forward rules live in the existing base chain.** nftables traverses *every* base chain on a hook, so a second chain would still be filtered by the original's `policy drop` — presenting as intermittent failure rather than an obvious error.
- **Tunnel → trusted LAN is explicitly dropped** before any accept can match. The router's VLAN already blocks it; stating it here makes the intent auditable on the one host that could otherwise become a pivot.
- **No masquerade or SNAT.** The destination sees the real `10.10.10.x` source, so its logs attribute connections to a specific peer instead of blaming this host for everything.

The template replaces only `inet filter` rather than issuing `flush ruleset`, because fail2ban maintains its own `inet f2b-table` and a full flush would silently delete active bans while fail2ban continued to report them as enforced.

---

## Known gaps

- `caddy_trusted_proxies` is a static snapshot of Cloudflare's ranges. They change. Refresh from `https://www.cloudflare.com/ips-v4`; a scheduled refresh is not yet automated.
- IPv6 Cloudflare ranges are deliberately absent — the origin publishes no AAAA record, so Cloudflare connects over IPv4. Add them before publishing one.
- The Caddy repo is pinned out of unattended-upgrades, so Caddy CVEs are a manual responsibility.
- No rate limiting or WAF. Accepted for static content with no forms or server-side logic.
- No external uptime monitoring.
- `base` reports leftover WiFi connection profiles rather than deleting them, since removing the profile you are connected through is not something a playbook should do unprompted.
