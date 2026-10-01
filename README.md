# JG-RPi-WebServer

Ansible playbook and operating docs for the Raspberry Pi that serves
[justingarter.com](https://justingarter.com): a static site on a Pi 5, single-homed in the
DMZ (VLAN 40) behind OPNsense, reachable from the internet only through Cloudflare on 443.

The playbook is the *what*. [`docs/runbook.md`](docs/runbook.md) is the *why*.

---

## Common tasks

| I need to | Page |
|---|---|
| Put new site content on the server | [Deploy site content](docs/deploy-site-content.md) |
| Build the Pi from a blank card | [Rebuild from scratch](docs/rebuild-from-scratch.md) |
| Check the Pi is healthy and doing what it claims | [Routine checks](docs/routine-checks.md) |
| Change config, firewall, SSH sources, certificate, secrets | [Making changes](docs/making-changes.md) |
| Get the site or SSH back | [Recovery](docs/recovery.md) |
| Look up how something is configured and why | [Runbook](docs/runbook.md) |

---

## The three machines

Every procedure labels which machine each command runs on.

| Label | What it is | How you get there |
|---|---|---|
| **WORKSTATION** | Windows desktop on MAIN, `10.10.20.10`. Git, Imager, browser | The machine in front of you |
| **CONTROL NODE** | WSL2 on the same desktop. Runs Ansible | `wsl`, then `cd /mnt/c/Projects/_Complete/pi-webserver-ansible` |
| **SERVER** | The Pi, `JG-RPi-WebServer`, `10.10.40.10` | `ssh justin@10.10.40.10` from WSL, `ssh WebServer` from PowerShell, or the console |

---

## Control node setup

### Step 1. Mount `/mnt/c` with Unix permissions

`/etc/wsl.conf`:

```ini
[automount]
options = "metadata,umask=22,fmask=11"
```

Then `wsl --shutdown` from PowerShell and reopen WSL. Without `metadata`, every file under
`/mnt/c` is mode 777, and Ansible ignores a world-writable `ansible.cfg`: no inventory
default, no vault prompt, no become prompt.

**Check:** `ansible --version | grep 'config file'` shows this repo's `ansible.cfg`.

### Step 2. Install Ansible and the collections

Ansible is installed system-wide in WSL (apt or pipx), not in a venv.

```bash
ansible-galaxy collection install -r requirements.yml
```

**Check:** `ansible-galaxy collection list | grep -E 'ansible.posix|community.general'` shows
both.

### Step 3. Load the SSH key, once per WSL window

```bash
eval "$(ssh-agent -s)" && ssh-add /mnt/c/Users/garte/.ssh/id_ed25519
```

**Check:** `ssh-add -l` lists one ED25519 key.

### Step 4. Confirm the inventory resolves

```bash
ansible-inventory --graph
```

**Check:** `webserver` contains `jg-rpi-webserver`.

---

## Running

```bash
ansible-playbook site.yml --check --diff   # dry run against a converged host
ansible-playbook site.yml                  # apply
ansible-playbook site.yml --tags caddy     # one role
```

Every run prompts twice: `BECOME password` (the `justin` password; sudo keeps its password,
DR-003 11.6) then `Vault password`. Both are in the password manager. Runs are manual and
never scheduled.

Tags: `base`, `ssh`, `nftables`/`firewall`, `caddy`/`web`, `fail2ban`/`security`,
`ddns`/`dns`, `monitoring`.

A converged host reports `changed=0`. Anything else on a host you have not touched is drift
or a role defect.

---

## What the playbook configures

| Role | Result |
|---|---|
| `base` | Refuses to run without a console password (R13). Asserts the host is on `10.10.40.10`, owns it with one NetworkManager profile `dmz`. Hostname, timezone, packages, cloud-init off, seed files deleted, radios off in firmware, root `noatime,commit=600`, journal in RAM, 512 MB swapfile below zram, unattended-upgrades |
| `ssh` | Key-only on 22 via a `00-` drop-in, asserted against `sshd -T` |
| `nftables` | Default-deny inbound. 443 from any (OPNsense limits it to Cloudflare), SSH from `10.10.10.0/24` and `10.10.20.10` only, no forwarding |
| `caddy` | Caddy from Cloudsmith, Cloudflare Origin CA certificate, 443 only, extensionless URLs, `trusted_proxies`, security headers, JSON access log, memory limits |
| `fail2ban` | nftables ban action, `sshd` and `caddy-404` jails |
| `ddns` | Cloudflare DDNS for the apex every 5 minutes, preserving each record's proxied flag |
| `monitoring` | Hourly thermal and throttle log |

**Site content is not deployed by the playbook.** Config and content are separate changes so
a broken site has one variable to check. See [Deploy site content](docs/deploy-site-content.md).

---

## What the playbook does not do

It configures a Pi that is already reachable. Before the first run, the card needs, by hand
(all in [Rebuild from scratch](docs/rebuild-from-scratch.md)):

1. User `justin` with a password and the SSH public key (Imager).
2. sshd enabled (Imager).
3. The address `10.10.40.10/24` seeded in `network-config` on the boot partition. The DMZ
   has no DHCP.
4. Console login verified at the physical console.

No passwordless sudo, no second run, no temporary firewall opening.

---

## Secrets

| File | Holds |
|---|---|
| `group_vars/webserver/vault.yml` | `ddns_api_token` |
| `roles/caddy/files/origin.key.vault` | Origin CA private key, vault-encrypted as a whole file |
| `roles/caddy/files/origin.pem` | Origin CA certificate. Public, not encrypted |

New setup from the example: `cp group_vars/webserver/vault.yml.example
group_vars/webserver/vault.yml`, fill it in, `ansible-vault encrypt` it.

**Before every push:**

```bash
head -1 group_vars/webserver/vault.yml roles/caddy/files/origin.key.vault
```

Both must read `$ANSIBLE_VAULT;1.1;AES256`.

---

## Design notes

**SSH drop-in precedence.** sshd keeps the first value it reads, and `sshd_config.d/*.conf`
is included near the top in lexical order. `00-hardening.conf` therefore beats cloud-init's
`50-`. The role asserts the effective config with `sshd -T`, because the predecessor host ran
with password auth enabled for months while its file said key-only.

**Console break-glass (R13).** In August 2026 the Pi had one way in, SSH over a tunnel it
terminated itself, and no console password. Moving it removed every path in. The password
now exists, lives in the password manager, and `roles/base` refuses to run without it.

**Address owned by NetworkManager, not netplan.** A netplan file written under
NetworkManager's netplan backend gets absorbed and recreated every run (DR-003 11.7).

**fail2ban's ban action is nftables.** The Pi has no `iptables`. An iptables action reports
healthy and bans nothing. `caddy-404` still cannot block visitors behind Cloudflare; that
moves to Cloudflare.

**`trusted_proxies` is security-critical.** Without it every log line records a Cloudflare
edge, and the 404 jail targets Cloudflare.

**The nftables template replaces only `inet filter`**, never `flush ruleset`, so fail2ban's
own table and its bans survive a reload.

**`/var/swap` is not a stale swapfile.** It is zram's writeback store. Deleting it breaks
swap.

**The Cloudsmith signing key is checksum-pinned.** A substituted key fails the play instead
of becoming a new apt trust anchor.

**Line endings.** `.gitattributes` forces LF. A Windows checkout with CRLF once nearly
shipped `#!/bin/bash\r` to the Pi.

---

## Accepted tradeoffs

Listed with their reasons in [Runbook](docs/runbook.md) section 16.
