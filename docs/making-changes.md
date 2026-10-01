# Making changes

Changing the Pi's configuration. Everything goes through Ansible unless this page says
otherwise.

**The rule: if a role manages it, do not edit it on the Pi.** The next run overwrites the
edit, usually months later, with no memory of having made it.

All CONTROL NODE commands run from `/mnt/c/Projects/_Complete/pi-webserver-ansible` with the
agent loaded (`eval "$(ssh-agent -s)" && ssh-add /mnt/c/Users/garte/.ssh/id_ed25519`).
Every `ansible-playbook` run prompts for the become password, then the vault password.

---

## The normal change loop

### Step 1. Edit the role or `group_vars/webserver/vars.yml`

**Check:** `git diff` in PowerShell shows only the change you meant.

### Step 2. Dry run and read the diff

**Run on: CONTROL NODE**

```bash
ansible-playbook site.yml --check --diff
```

Scope to one role with `--tags`: `base`, `ssh`, `nftables` or `firewall`, `caddy` or `web`,
`fail2ban` or `security`, `ddns` or `dns`, `monitoring`.

Check mode cannot run handlers and cannot see what earlier tasks would have created. A clean
dry run is good evidence, not proof.

**Check:** every reported change is one you expect.

### Step 3. Apply

```bash
ansible-playbook site.yml
```

**Check:** `failed=0`.

### Step 4. Prove idempotency

```bash
ansible-playbook site.yml
```

**Check:** `changed=0 failed=0`.

### Step 5. Commit and push from PowerShell

```powershell
cd C:\Projects\_Complete\pi-webserver-ansible
git add -A
git commit
git push
```

**Check:** `git status` reports a clean tree, up to date with `origin/main`.

---

## Firewall changes

The change most likely to lock you out. The console break-glass exists now (R13), but it
costs a trip with a monitor and keyboard.

### Step 1. Arm a dead-man switch on the Pi

**Run on: CONTROL NODE**

```bash
ssh -t justin@10.10.40.10 'sudo cp /etc/nftables.conf /etc/nftables.conf.bak && sudo systemd-run --on-active=300 --unit=fw-rollback /usr/sbin/nft -f /etc/nftables.conf.bak && systemctl list-timers fw-rollback --all --no-pager'
```

The backup is safe to reapply: the ruleset starts with `table inet filter` then
`delete table inet filter`, so it replaces only its own table and leaves fail2ban's alone.

**Check:** the timer is listed with about five minutes left.

### Step 2. Apply the change

```bash
ansible-playbook site.yml --tags firewall
```

**Check:** `failed=0`.

### Step 3. Open a new SSH session

```bash
ssh justin@10.10.40.10 'echo new session ok'
```

It must be a **new** connection. An established session survives rules that block new ones,
because `ct state established,related accept` is the first input rule.

**Check:** prints `new session ok`.

### Step 4. Disarm the switch

```bash
ssh -t justin@10.10.40.10 'sudo systemctl stop fw-rollback.timer && sudo rm /etc/nftables.conf.bak'
```

If Step 3 failed, do nothing for five minutes. The timer restores the previous ruleset.

**Check:** `systemctl list-timers fw-rollback --all` on the Pi lists nothing.

---

## Changing the admin desktop's address

SSH is admitted from `ssh_admin_sources`: `10.10.10.0/24` (MGMT) and `10.10.20.10/32` (the
desktop, pinned by an OPNsense static mapping on MAIN). If the desktop's address changes,
SSH from the desk stops. `fail2ban` ignores the same list.

### Step 1. Add the new address alongside the old one

Edit `ssh_admin_sources` in `vars.yml` to hold both. Apply from the old address with the
firewall procedure above, then `--tags fail2ban`.

**Check:** `sudo nft list chain inet filter input` on the Pi shows both addresses in the SSH
rule.

### Step 2. Move the desktop

Change the OPNsense static mapping, then renew the lease (`ipconfig /renew`).

**Check:** `ipconfig` shows the new address, and `ssh justin@10.10.40.10 hostname` works
from WSL.

### Step 3. Remove the old address

Edit `vars.yml`, apply the firewall and fail2ban roles again.

**Check:** the SSH rule lists only the new address and `10.10.10.0/24`.

---

## Changing `ssh_port`

Avoid it. Port 22 was chosen on purpose (DR-003 11.4). If it has to change:

### Step 1. Add the new port to the OPNsense MGMT to DMZ rule first

**Check:** the rule in OPNsense shows the new port, applied.

### Step 2. Apply the `ssh` role alone

```bash
ansible-playbook site.yml --tags ssh -e ansible_port=22
```

Handlers run at the end of a play. Running `ssh` alone makes its restart happen before the
firewall changes. If both change in one run and a task fails in between, the firewall
demands one port while sshd listens on another.

**Check:** `ssh -t justin@10.10.40.10 'sudo ss -tlnp | grep sshd'` shows the new port. Trust
the socket, not `sshd -T`.

### Step 3. Apply the firewall with the dead-man switch, then update the inventory

**Check:** a new session on the new port works.

---

## Replacing the origin certificate

The current Cloudflare Origin CA certificate expires **2041-09-25**. Replace it before then,
or immediately if the key is ever exposed.

### Step 1. Create the certificate

**Run on: WORKSTATION**, Cloudflare dashboard: `justingarter.com` > **SSL/TLS** >
**Origin Server** > **Create Certificate**. Private key type ECC, hostnames
`justingarter.com` and `*.justingarter.com`, validity 15 years.

Leave this page open until Step 4 passes. **Cloudflare shows the private key once.**

**Check:** the page shows both an Origin Certificate block and a Private Key block.

### Step 2. Save both to the WSL home directory, not the repo

**Run on: CONTROL NODE**

```bash
cd ~
install -m 600 /dev/null origin.key && nano origin.key    # paste the private key, save
nano origin.pem                                            # paste the certificate, save
head -1 origin.pem origin.key; wc -l origin.pem origin.key
```

The key stays outside the repo so its plaintext never exists in the working tree.

**Check:** each file's first line is its `-----BEGIN ...-----` line alone, and each file has
more than three lines. If either file is one long line, do Step 3. Otherwise skip to Step 4.

### Step 3. Re-wrap a collapsed PEM (only if Step 2 failed)

On 2026-09-29 the paste from the browser into nano collapsed both files onto one line.
OpenSSL and Caddy cannot load that.

```bash
rewrap() {
  local f=$1 label body
  label=$(grep -o -- '-----BEGIN [A-Z ]*-----' "$f" | head -1 | sed 's/-----BEGIN //; s/-----$//')
  [ -n "$label" ] || { echo "no BEGIN line in $f"; return 1; }
  body=$(tr -d '\r\n' < "$f" | sed "s/-----BEGIN $label-----//; s/-----END $label-----//" | tr -d ' ')
  ( umask 077; { echo "-----BEGIN $label-----"; echo "$body" | fold -w 64; echo "-----END $label-----"; } > "$f.tmp" ) && mv "$f.tmp" "$f"
}
rewrap ~/origin.pem
rewrap ~/origin.key
head -2 ~/origin.pem ~/origin.key
```

**Check:** each file now starts with the `BEGIN` line, then a 64-character base64 line.

### Step 4. Prove the certificate and key match

```bash
cd ~
EMPTY=$(printf '' | sha256sum | cut -d' ' -f1)
c=$(openssl x509 -in origin.pem -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)
k=$(openssl pkey -in origin.key -pubout -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)
[ "$c" = "$k" ] && [ "$c" != "$EMPTY" ] && echo MATCH || echo "FAIL: mismatch or unreadable"
openssl x509 -in origin.pem -noout -enddate -ext subjectAltName
```

If either file fails to parse, both pipelines hash empty input and a plain equality test
passes. The `EMPTY` guard makes it fail.

**Check:** `MATCH`, the new expiry date, and both hostnames in the SAN.

### Step 5. Put them in the repo

```bash
cd /mnt/c/Projects/_Complete/pi-webserver-ansible
cp ~/origin.pem roles/caddy/files/origin.pem
ansible-vault encrypt ~/origin.key --output roles/caddy/files/origin.key.vault
head -1 roles/caddy/files/origin.key.vault
```

At the `New Vault password` prompt, enter the **existing** vault password. A different one
leaves the playbook unable to decrypt the key with its single vault prompt.

Then rerun the check from [Rebuild from scratch, Step 7](rebuild-from-scratch.md#step-7-confirm-the-origin-certificate-in-the-repo-is-good)
against the repo copies.

**Check:** `$ANSIBLE_VAULT;1.1;AES256`, and the repo check prints `MATCH`.

### Step 6. Remove the plaintext copies

```bash
shred -u ~/origin.key ~/origin.pem
ls ~/origin.* 2>/dev/null || echo removed
```

**Check:** prints `removed`.

### Step 7. Deploy and verify

```bash
ansible-playbook site.yml --tags caddy
ssh justin@10.10.40.10 'openssl x509 -in /etc/caddy/tls/origin.pem -noout -enddate'
```

```powershell
curl.exe -s -o NUL -w "status=%{http_code}`n" https://justingarter.com/
```

**Check:** the Pi reports the new expiry, and the site returns `status=200` from outside.

### Step 8. Close out

Revoke the old certificate in the same Cloudflare page. Update the expiry in
[Runbook](runbook.md) section 9 and in the `vars.yml` comment. Commit.

**Check:** Cloudflare lists one active origin certificate.

---

## Changing a secret

The vault, `group_vars/webserver/vault.yml`, holds one secret: `ddns_api_token`. The origin
key is its own vaulted file (above).

### Step 1. Rotate at the source

Cloudflare dashboard > **My Profile** > **API Tokens**. Scope: Zone > DNS > Edit,
`justingarter.com` only.

**Check:** the new token's **Verify** test passes in the dashboard.

### Step 2. Update the vault and apply

```bash
ansible-vault edit group_vars/webserver/vault.yml
head -1 group_vars/webserver/vault.yml
ansible-playbook site.yml --tags ddns
```

Never use `--diff` on a task that renders a secret. Those tasks carry `no_log: true`; any new
one needs it too. The August 2026 WireGuard key was exposed by exactly this.

**Check:** the header reads `$ANSIBLE_VAULT;1.1;AES256`, and the run is `failed=0`.

### Step 3. Force a DDNS run and read the result

```bash
ssh -t justin@10.10.40.10 'sudo rm -f /var/lib/cloudflare-ddns/last_ip && sudo systemctl start cloudflare-ddns.service && sudo journalctl -u cloudflare-ddns -n 5 --no-pager'
```

Deleting `last_ip` forces a real API write instead of `IP unchanged, skipping`.

**Check:** `Successfully updated justingarter.com`. Then revoke the old token.

---

## Adding a DNS record to DDNS

For `origin.justingarter.com` when Minecraft exists (DR-003 11.5). Not before: a DNS-only
record publishes the home IP.

### Step 1. Create the record in Cloudflare

A record, DNS only, TTL 1 minute, any placeholder address. The updater edits records and
never creates them.

**Check:** the record exists with a grey cloud.

### Step 2. Add it to `ddns_records` in `vars.yml` and apply `--tags ddns`

**Check:** a forced run (previous section, Step 3) logs a success line for each record.

---

## Updating Caddy

Caddy comes from the Cloudsmith repo. unattended-upgrades installs only Debian origins, so
Caddy never updates on its own.

### Step 1. Read the release notes for every version between current and target

**Check:** no breaking Caddyfile changes, or you have the template change ready.

### Step 2. Upgrade

```bash
ssh -t justin@10.10.40.10 'caddy version; sudo apt update && sudo apt install --only-upgrade caddy && caddy version && systemctl is-active caddy'
```

**Check:** the new version prints and Caddy is `active`.

### Step 3. Verify the site

Run Step 4 and Step 6 of [Deploy site content](deploy-site-content.md).

**Check:** `status=200` locally and from outside.

---

## Refreshing the Cloudflare trusted-proxy list

`caddy_trusted_proxies` is a static snapshot. If Cloudflare adds a range, visitors arriving
through it are logged with a Cloudflare address as `client_ip`. OPNsense's `CLOUDFLARE_V4`
alias refreshes itself daily; this list does not.

### Step 1. Compare

```bash
curl -s https://www.cloudflare.com/ips-v4 | sort > /tmp/cf.txt
grep -oE '[0-9.]+/[0-9]+' group_vars/webserver/vars.yml | sort > /tmp/ours.txt
diff /tmp/cf.txt /tmp/ours.txt && echo "no change"
```

The second `grep` also catches `ssh_admin_sources`; ignore `10.10.x` lines in the diff.

**Check:** `no change`, or a list of ranges to add or remove.

### Step 2. Update `vars.yml` and apply `--tags caddy` through the normal loop

**Check:** the access log shows visitor addresses, not Cloudflare's, in `client_ip`. See
[Routine checks](routine-checks.md#visitor-ips).

IPv6 ranges are deliberately absent. The origin has no AAAA record, so Cloudflare connects
over IPv4. Add them before publishing an AAAA record, not after.

---

## Changing site content

Not an Ansible change. See [Deploy site content](deploy-site-content.md).
