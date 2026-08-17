# Making changes

Changing the host's configuration. Everything here goes through Ansible unless there
is a stated reason it cannot.

**The rule: if it is managed by a role, do not edit it on the host.** The next playbook
run overwrites it, and you lose the change at the worst possible moment — usually
months later, with no memory of having made it.

---

## The normal change loop

**Run on: CONTROL NODE**

```bash
cd ~/pi-webserver-ansible

# 1. edit the role or the variables
# 2. dry run, and actually read the diff
ansible-playbook -i inventory site.yml --check --diff --ask-vault-pass

# 3. apply
ansible-playbook -i inventory site.yml --ask-vault-pass

# 4. confirm idempotency
ansible-playbook -i inventory site.yml --ask-vault-pass    # expect changed=0
```

Scope a run to one role with tags: `base`, `ssh`, `wireguard`, `nftables`/`firewall`,
`caddy`/`web`, `fail2ban`/`security`, `ddns`/`dns`, `monitoring`.

```bash
ansible-playbook -i inventory site.yml --tags caddy --ask-vault-pass
```

Then commit. The repo is the record; an unpushed change is a change that does not exist
next time you look.

### Reading `--check` output honestly

Check mode cannot run handlers and cannot see the results of tasks that would have run
earlier in the same play. Two consequences worth knowing:

- Tasks that report `changed` in check mode are not always real changes. A `get_url`
  without a `checksum` will report changed every run; pinning the checksum makes it
  honest. The Cloudsmith key task is pinned for exactly this reason.
- Tasks conditioned on something an earlier task creates may report incorrectly,
  because that earlier thing does not exist in a dry run.

A dry run that shows only expected diffs is good evidence. It is not proof.

---

## Firewall changes

**This is the change most likely to lock you out.** The host has no management path
except WireGuard and no console attached.

Arm a dead-man switch on the host before applying anything:

**Run on: SERVER**
```bash
sudo cp /etc/nftables.conf /etc/nftables.conf.bak
sudo systemd-run --on-active=300 --unit=fw-rollback \
  /usr/sbin/nft -f /etc/nftables.conf.bak
systemctl list-timers fw-rollback --all --no-pager
```

Apply the change, then **open a second, separate session** and confirm it connects.
Not the session you already have — an established connection survives rules that would
block a new one, because `ct state established,related accept` is the first input rule.
Testing on your existing session proves nothing.

Only once a fresh session works:

```bash
sudo systemctl stop fw-rollback.timer
sudo rm /etc/nftables.conf.bak
```

If you get locked out, do nothing for five minutes and the rollback restores the
previous ruleset.

### The one the guard does not catch

The `nftables` role asserts `wg0` exists before restricting SSH to it. It does not
check that **sshd is listening on the port the new ruleset is about to require**.

If you change `ssh_port`, the ssh role writes the config and queues a restart handler
— and handlers do not run until the *end* of the play. If anything fails in between,
the firewall demands one port while sshd still listens on another, and you are locked
out of a headless machine.

Changing `ssh_port` safely:

```bash
# CONTROL NODE - apply the ssh role alone first, so its handler flushes
ansible-playbook -i inventory site.yml --tags ssh --ask-vault-pass

# SERVER - confirm the daemon actually moved before touching the firewall
sudo ss -tlnp | grep sshd

# CONTROL NODE - only now
ansible-playbook -i inventory site.yml --tags firewall --ask-vault-pass
```

Verify the socket, not `sshd -T`. `-T` reports parsed config, which will happily agree
with you while the running daemon is somewhere else entirely.

---

## Adding or removing a WireGuard peer

Peers are declared in `group_vars/webserver/vars.yml` and asserted by the wireguard
role, so this is an Ansible change rather than a host edit.

**On the new client**, generate a keypair and give it an address in `10.10.10.0/24`
that is not already taken. Client config:

```
[Interface]
PrivateKey = <client private key>
Address    = 10.10.10.N/32
DNS        = 1.1.1.1

[Peer]
PublicKey  = <server public key: sudo wg show wg0 public-key>
Endpoint   = vpn.justingarter.com:51820
AllowedIPs = 10.10.10.0/24, 192.168.54.0/24
PersistentKeepalive = 25
```

**Always use the hostname for `Endpoint`, never a literal IP.** The public address is
dynamic and has changed twice within fifteen minutes. `vpn.justingarter.com` is a
DNS-only record kept current by the DDNS timer; a hard-coded IP is a landmine that
detonates the next time your ISP renumbers you, which is exactly when you need remote
access.

**Then add the peer to `vars.yml`** with its name, public key, and `allowed_ips`, and
apply:

```bash
ansible-playbook -i inventory site.yml --tags wireguard --ask-vault-pass
```

The handler uses `wg syncconf`, not `wg-quick down/up`, so your own tunnel survives the
change.

Verify:
```bash
# SERVER
sudo wg show
```

To remove a peer, delete it from `vars.yml` and re-run. Confirm it is gone from
`wg show` — a peer removed from the file but still in the running interface means the
sync did not happen.

---

## Rotating the WireGuard server key

The rotation breaks the only connection to the host, by design. Make both ends
revertible before you start.

1. **Generate on the CONTROL NODE:**
   ```bash
   NEW_PRIV=$(wg genkey); echo "$NEW_PRIV" | wg pubkey
   ```
2. **On the WORKSTATION**, duplicate the WireGuard tunnel and set the copy's
   `[Peer] PublicKey` to the new public key. Keep the original — it is your rollback.
3. **On the SERVER**, back up and arm a timed revert:
   ```bash
   sudo cp /etc/wireguard/wg0.conf /etc/wireguard/wg0.conf.bak
   sudo systemd-run --on-active=300 --unit=wg-rollback /bin/bash -c \
     'cp /etc/wireguard/wg0.conf.bak /etc/wireguard/wg0.conf && wg syncconf wg0 <(wg-quick strip wg0)'
   ```
4. Edit `PrivateKey` with `nano` — not `sed`, which puts the key in shell history —
   then `sudo bash -c 'wg syncconf wg0 <(wg-quick strip wg0)'`. **Your session dies here.**
5. Switch to the new tunnel on the workstation. On reconnect:
   `sudo systemctl stop wg-rollback.timer` and delete the backup.
6. **Update the vault, then prove the two agree:**
   ```bash
   # CONTROL NODE
   ansible-vault view group_vars/webserver/vault.yml --ask-vault-pass \
     | awk -F': ' '/^wg_private_key/{gsub(/"/,"",$2); print $2}' | wg pubkey
   ssh WebServer 'sudo wg show wg0 public-key'
   ```
   These must match. Skipping step 6 leaves the playbook holding the old key, and the
   next apply writes it back and locks you out.

---

## Updating Caddy

Caddy does not auto-update. The Cloudsmith repo is pinned out of unattended-upgrades
because only Debian security origins are permitted, so Caddy CVEs are a manual
responsibility.

**Run on: SERVER**
```bash
caddy version
sudo apt update
apt list --upgradable 2>/dev/null | grep -i caddy
sudo apt install --only-upgrade caddy
systemctl is-active caddy
curl -s -o /dev/null -w '%{http_code}\n' --resolve justingarter.com:443:127.0.0.1 https://justingarter.com/
```

Check the release notes before upgrading — a config-breaking change on a host reachable
only through a tunnel is not where you want to discover a syntax change.

---

## Refreshing the Cloudflare trusted-proxy list

`caddy_trusted_proxies` is a static snapshot. Cloudflare adds ranges over time. When it
drifts, visitor IPs stop resolving and the `caddy-404` jail starts banning Cloudflare
edges — which takes the site down for everyone, not just an attacker.

**Run on: CONTROL NODE**
```bash
curl -s https://www.cloudflare.com/ips-v4
```

Update `caddy_trusted_proxies` in `group_vars/webserver/vars.yml`, then:

```bash
ansible-playbook -i inventory site.yml --tags caddy --check --diff --ask-vault-pass
ansible-playbook -i inventory site.yml --tags caddy --ask-vault-pass
```

Verify with real traffic — the check is that `client_ip` is a plausible visitor and not
a Cloudflare address:

```bash
# SERVER
sudo tail -5 /var/log/caddy/access.log | jq -r '[.request.remote_ip, .request.client_ip] | @tsv'
```

The IPv6 ranges are deliberately absent because the origin publishes no AAAA record, so
Cloudflare connects over IPv4. **Add them before publishing an AAAA record**, not after.

---

## Adding a routed flow through the tunnel

The host routes narrowly-scoped flows to other DMZ hosts rather than standing up a
second VPN endpoint. Controlled entirely by `nft_forward_allow` in `vars.yml`.

Add an entry with `name`, `dest`, and `port`. The same variable drives both the
firewall rules and `net.ipv4.ip_forward`, so the sysctl and the ruleset cannot
disagree — an empty list sets forwarding back to `0`.

Apply with the firewall dead-man switch armed (above), then verify from a VPN client
that the intended flow works and the unintended ones do not:

```bash
ssh justin@<dest>                              # should succeed
ping -c2 -W2 192.168.50.1                      # must fail
nmap -Pn -p 80,443 <dest>                      # must find nothing
```

Run the scans from your **workstation**, not the server. Scanning from inside the DMZ
tests the wrong direction, and it means keeping scanning tools on an internet-facing
host for no benefit.

---

## Changing a secret

The vault holds two: `wg_private_key` and `ddns_api_token`.

```bash
# CONTROL NODE
ansible-vault edit group_vars/webserver/vault.yml
ansible-playbook -i inventory site.yml --check --diff --ask-vault-pass
```

**Never run `--diff` on a task that renders a secret.** That is how the WireGuard server
key was exposed and had to be rotated. Tasks that template secrets carry `no_log: true`;
if you add one, add the flag.

Confirm the file is still encrypted before pushing:

```bash
head -1 group_vars/webserver/vault.yml    # must read $ANSIBLE_VAULT;1.1;AES256
```

For the Cloudflare token, rotate at the Cloudflare dashboard first (scope: Zone → DNS →
Edit, restricted to this zone), update the vault, apply, then force a DDNS run and
watch it succeed:

```bash
# SERVER
sudo systemctl start cloudflare-ddns.service
sudo journalctl -u cloudflare-ddns -n 10 --no-pager
```

---

## Changing site content

Not an Ansible change. See [Deploy site content](deploy-site-content.md).
