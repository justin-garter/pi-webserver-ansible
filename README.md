# JG-RPi-WebServer

Everything needed to build, operate, and recover the self-hosted web server behind
[justingarter.com](https://justingarter.com) — an internet-facing static site on a
Raspberry Pi 5, single-homed in a DMZ VLAN, fronted by Cloudflare, and reachable for
management only over WireGuard.

This repo holds both halves: the Ansible playbook that configures the host, and the
operational documentation for running it. The playbook is the *what*, executable.
[`docs/runbook.md`](docs/runbook.md) is the *why*.

---

## Common tasks

Start here. Each page is written to be followed without prior context, with every
command labelled by which machine it runs on.

| I need to… | Page |
|---|---|
| Put new site content on the server | [Deploy site content](docs/deploy-site-content.md) |
| Rebuild the host from a blank disk | [Rebuild from scratch](docs/rebuild-from-scratch.md) |
| Check the host is healthy and doing what it claims | [Routine checks](docs/routine-checks.md) |
| Change firewall rules, add a VPN peer, update Caddy | [Making changes](docs/making-changes.md) |
| Get back in after locking myself out | [Recovery](docs/recovery.md) |
| Look up how something is configured and why | [Runbook](docs/runbook.md) |

---

## The three machines

Nearly every mistake on this system comes from running a command on the wrong box.
The docs label every block. The three are:

| Label | What it is | How you get there |
|---|---|---|
| **WORKSTATION** | Windows desktop. WireGuard client, SSH client, Raspberry Pi Imager, router admin. | It's the machine in front of you. |
| **CONTROL NODE** | WSL2 Ubuntu on the same desktop. Holds this repo and runs Ansible. | `wsl` from PowerShell |
| **SERVER** | The Pi itself, `JG-RPi-WebServer`. | `ssh WebServer` — requires the tunnel up |

Ansible does not run natively on Windows, which is why the control node exists as a
separate thing rather than being the workstation.

---

## What the playbook configures

| Role | Result |
|---|---|
| `base` | Hostname, timezone, packages, cloud-init disabled, radios disabled at firmware, NVMe swapfile below zram in priority, unattended-upgrades |
| `ssh` | Key-only auth on 2222 via a `00-` drop-in that wins over cloud-init's, then asserts the *effective* config matches |
| `wireguard` | `wg0` at `10.10.10.1/24` — the only management path into the DMZ |
| `nftables` | Default-deny inbound. 80/443 public, 51820 for the tunnel, SSH restricted to `wg0` |
| `caddy` | Caddy from the Cloudsmith repo, Cloudflare `trusted_proxies`, six security headers, JSON access log, memory ceilings |
| `fail2ban` | nftables ban backend, `sshd` and `caddy-404` jails |
| `ddns` | Cloudflare DDNS on a 5-minute systemd timer, preserving each record's proxied flag |
| `monitoring` | Hourly thermal and throttle logging |

**Site content is not deployed by this playbook.** Host configuration and content
deploys are separate changes on purpose — when the site breaks you want one variable
to check, not two. See [Deploy site content](docs/deploy-site-content.md).

---

## What the playbook does *not* do

Learned the hard way by wiping the disk and rebuilding from it in August 2026. The
playbook configures a host that is already reachable. It does not create the
conditions that make it reachable.

Before the first run, a bare host needs, by hand:

1. A user account matching `ansible_user` in the inventory
2. That user's SSH public key in `~/.ssh/authorized_keys`
3. Passwordless sudo for that user
4. `sshd` enabled and running
5. A static IP address on the DMZ segment

None of the five are established by any role. Full procedure in
[Rebuild from scratch](docs/rebuild-from-scratch.md).

There is also a **two-pass requirement**: the first run against a bare host fails at
the nftables interface check, because that check reads facts gathered before the
WireGuard role created the interface. The second run succeeds. Both are documented
in the rebuild guide with the reasoning.

---

## Prerequisites

**On the CONTROL NODE:**

- Linux with Ansible installed (WSL2 is fine)
- The repo on a native Linux filesystem, **not** `/mnt/c` — DrvFs cannot represent
  Unix permissions, so Ansible refuses to load a world-writable `ansible.cfg` and
  vault files cannot be protected
- SSH private key at `~/.ssh/id_ed25519`, mode `0600`
- An `~/.ssh/config` entry, since the inventory carries connection details but
  `scp` and manual `ssh` do not read it:

```
Host WebServer jg-rpi-webserver
    HostName 192.168.54.180
    Port 2222
    User justin
```

**On the WORKSTATION:** the WireGuard tunnel must be **up**. The target is
unreachable without it, from either machine.

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

The vault holds exactly two secrets: `wg_private_key` and `ddns_api_token`.

---

## Running

Always dry-run first:

```bash
ansible-playbook -i inventory site.yml --check --diff --ask-vault-pass
```

Then apply:

```bash
ansible-playbook -i inventory site.yml --ask-vault-pass
```

A single role:

```bash
ansible-playbook -i inventory site.yml --tags caddy --ask-vault-pass
```

Tags available: `base`, `ssh`, `wireguard`, `nftables`/`firewall`, `caddy`/`web`,
`fail2ban`/`security`, `ddns`/`dns`, `monitoring`.

A converged host produces `changed=0`. Anything reporting changed on a host you have
not touched is drift worth understanding before you re-apply over it.

---

## Lockout risk — read before running the `nftables` role

**This host has no management path except WireGuard.** The DMZ VLAN blocks the
trusted LAN in both directions; SSH on 2222 is not forwarded from the internet. It
sits in a basement with no monitor attached.

Three things guard against locking yourself out:

1. **Role order.** `wireguard` runs before `nftables` in `site.yml`, so the interface
   the SSH rule references exists before the rule is written.
2. **A pre-flight assertion.** The `nftables` role refuses to run if `wg0` is absent.
3. **Template validation.** `nft -c -f` checks the ruleset syntactically before it is
   ever written to disk.

None of that protects against a *semantically* valid ruleset that locks you out, and
none of it protects against the firewall and sshd disagreeing about which port is in
use. When changing firewall or SSH templates, arm a dead-man switch on the host first
— procedure in [Making changes](docs/making-changes.md).

The WireGuard handler uses `wg syncconf` rather than `wg-quick down/up` for the same
reason: tearing down the interface would drop the connection Ansible is running over.

---

## Design notes

**SSH drop-in precedence.** `/etc/ssh/sshd_config` has
`Include /etc/ssh/sshd_config.d/*.conf` near the top, and sshd takes the **first**
value obtained for most keywords, not the last. Drop-ins are read in lexical order,
so `00-hardening.conf` wins over cloud-init's `50-cloud-init.conf`, and anything
written further down the main config is dead text. The predecessor host ran with
`PasswordAuthentication yes` for months because of exactly this while its
documentation claimed key-only.

The `ssh` role therefore asserts against `sshd -T` rather than trusting the file it
just wrote. Note the limit of that: `sshd -T` reports parsed configuration, meaning
what sshd *would* do on next start. The only test of what the running daemon is
actually doing is the listening socket, and the only test of behaviour is attempting
a password login and being refused. Both are in
[Routine checks](docs/routine-checks.md).

**fail2ban's ban backend.** This host has no `iptables` binary. A jail left on
`iptables-multiport` reports as healthy and bans nothing. `banaction` is set to
`nftables[type=multiport]` explicitly.

**`trusted_proxies` is security-critical.** Without it, every access-log entry records
a Cloudflare edge IP instead of the visitor, and the `caddy-404` jail bans Cloudflare.
Correctly scoped, forged `CF-Connecting-IP` headers from untrusted sources are ignored.

**`caddy validate` runs as root** and sets up the log writer as a side effect,
creating `access.log` owned `root:root`. Caddy then starts as the `caddy` user, cannot
open its own log, and dies with a misleading permission error. The role repairs
ownership immediately after the validate step. Never run `sudo caddy validate` or
`sudo caddy run` by hand.

**`/var/swap` is not a stale swapfile.** It is zram's writeback backing store, managed
by `rpi-setup-loop@var-swap.service`. Deleting it breaks the zram+file swap tier. The
playbook creates `/swapfile` separately, at a priority below zram's 100.

**The Cloudsmith signing key is checksum-pinned.** `get_url` otherwise trusts whatever
that URL serves on any given run. Pinning means a substituted key fails the play
rather than silently installing a new apt trust anchor. When Cloudsmith legitimately
rotates the key the play breaks and you update the hash by hand — for a repository
signing key, failing loudly is correct.

---

## Routed access through the tunnel

This host terminates the WireGuard tunnel and also routes **one** narrowly-scoped flow
to another DMZ host, rather than standing up a second VPN endpoint or forwarding
another WAN port. Peers already carry `AllowedIPs` covering the whole DMZ `/24`, so no
peer config changes were needed.

Driven entirely by `nft_forward_allow` in `group_vars`. An empty list means no routing
and sets `net.ipv4.ip_forward` back to `0` — the sysctl and the firewall rules read the
same variable so they cannot disagree.

Three deliberate choices:

- **The forward rules live in the existing base chain.** nftables traverses *every*
  base chain on a hook, so a second chain would still be filtered by the original's
  `policy drop` — presenting as intermittent failure rather than an obvious error.
- **Tunnel → trusted LAN is explicitly dropped** before any accept can match. The
  router's VLAN already blocks it; stating it here makes the intent auditable on the
  one host that could otherwise become a pivot.
- **No masquerade or SNAT.** The destination sees the real `10.10.10.x` source, so its
  logs attribute connections to a specific peer instead of blaming this host for
  everything.

The template replaces only `inet filter` rather than issuing `flush ruleset`, because
fail2ban maintains its own `inet f2b-table` and a full flush would silently delete
active bans while fail2ban continued to report them as enforced.

---

## Accepted tradeoffs

Deliberate decisions, not oversights. Each is revisited when the thing that justified
it changes.

- **No rate limiting or WAF.** Static HTML with no forms and no server-side logic, so
  the attack surface is small. Revisit if the site gains dynamic content.
- **Caddy is pinned out of unattended-upgrades**, because only Debian security origins
  are allowed. Caddy updates are therefore a manual, scheduled responsibility rather
  than an automatic one.
- **No external uptime monitoring.** The site going down is an inconvenience, not an
  incident.
- **WireGuard is the sole management path with no LAN-side fallback.** This trades a
  convenient fallback for taking a listening SSH port off the segment entirely. The
  cost is real and has been paid: see [Recovery](docs/recovery.md).
- **`base` reports leftover Wi-Fi connection profiles rather than deleting them**,
  since removing the profile you are connected through is not something a playbook
  should do unprompted.
