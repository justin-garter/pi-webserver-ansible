# Rebuild from scratch

Building `JG-RPi-WebServer` from a blank microSD card. Written from the build done on
2026-09-29, the first on VLAN 40 behind OPNsense (DR-003).

**Time:** about an hour. The playbook run itself is about 10 minutes.
**Downtime:** justingarter.com is down from the moment the old card comes out until Step 11.
Nothing else in the lab or on ROOM_NET is affected.
**Physical access:** needed once, in Step 5, for the console check.

---

## TLDR

Nothing on the Pi is unique. Host configuration and the origin certificate are in this
repo, secrets are in the vault, passwords are in the password manager, and site content is
in `C:\Projects\Web Portfolio`. A rebuild is: flash the card with the address seeded,
prove console login works, run the playbook twice, deploy content.

There is no two-pass requirement, no temporary router rule and no certificate to request.
DR-003 removed all three.

---

## Machines

| Label | What it is | How you get there |
|---|---|---|
| **WORKSTATION** | Windows desktop on MAIN, pinned to `10.10.20.10` by an OPNsense static mapping. Raspberry Pi Imager, browser, git | The machine in front of you |
| **CONTROL NODE** | WSL2 Ubuntu on the same desktop. Runs Ansible from `/mnt/c/Projects/_Complete/pi-webserver-ansible` | `wsl` from PowerShell |
| **SERVER** | The Pi, `JG-RPi-WebServer`, `10.10.40.10`, switch port 3 | Console, or `ssh justin@10.10.40.10` from WSL, or `ssh WebServer` from PowerShell |

Run checks against the Pi from WSL. PowerShell strips embedded double quotes from
arguments passed to native programs, so quoted remote commands break there.

---

## Before you start

You need:

- A 64 GB microSD card and a card reader.
- A micro HDMI cable, a monitor and a USB keyboard for Step 5.
- From the password manager: the `justin` password (console and sudo, the same one) and
  the Ansible vault password.
- The desktop on MAIN at `10.10.20.10`. The Pi's firewall admits SSH from `10.10.20.10/32`
  and `10.10.10.0/24` only. Check with `ipconfig` in PowerShell.
- The apex A record `justingarter.com` present in Cloudflare. The DDNS updater edits
  records and never creates them. Do **not** create `origin` (DR-003 11.5).

---

## Step 1. Confirm the control node can load this repo's config

**Run on: CONTROL NODE**

```bash
grep -A1 automount /etc/wsl.conf
cd /mnt/c/Projects/_Complete/pi-webserver-ansible
ansible --version | grep 'config file'
ansible-galaxy collection list 2>/dev/null | grep -E 'ansible.posix|community.general'
```

Expected `wsl.conf` content:

```ini
[automount]
options = "metadata,umask=22,fmask=11"
```

If it is missing, add it, run `wsl --shutdown` from PowerShell, and open a new WSL window.

Why this matters: without `metadata`, every file under `/mnt/c` shows as mode 777.
Ansible refuses to read an `ansible.cfg` in a world-writable directory, prints one warning, and falls
back to defaults. The run then has no inventory default, no vault prompt and no become
prompt, and fails in ways that do not point at the cause.

If either collection is missing: `ansible-galaxy collection install -r requirements.yml`.

**Check:** `config file = /mnt/c/Projects/_Complete/pi-webserver-ansible/ansible.cfg`, and
both collections are listed.

---

## Step 2. Load the SSH key into the WSL agent

Every new WSL window needs this. Ansible connects with the Windows key file through the
agent.

**Run on: CONTROL NODE**

```bash
eval "$(ssh-agent -s)" && ssh-add /mnt/c/Users/garte/.ssh/id_ed25519
```

**Check:** `ssh-add -l` prints one line ending in `(ED25519)`.

---

## Step 3. Flash the card

**Run on: WORKSTATION**, Raspberry Pi Imager.

| Setting | Value |
|---|---|
| Device | Raspberry Pi 5 |
| OS | Raspberry Pi OS Lite (64-bit) |
| Hostname | `JG-RPi-WebServer` |
| Username / password | `justin` / the password from the password manager |
| Wi-Fi | Not configured |
| Locale | `America/New_York` |
| SSH | Enabled, **public-key authentication only**, key from `C:\Users\garte\.ssh\id_ed25519.pub` |

**Set the password.** Imager lets you configure SSH with a key and no password. That is how
the August host ended up with no console login (DR-003 Section 2, R13). `roles/base`
now refuses to run against an account without a password, but you find out at Step 8
instead of now.

Do not let Imager eject the card yet if you can avoid it. Step 4 edits the boot partition.

**Check:** Imager finishes with write **and** verify successful.

---

## Step 4. Seed the DMZ address

VLAN 40 has no DHCP by design. Unknown devices plugged into the DMZ get nothing. The first
boot takes its address from cloud-init's `network-config` on the boot partition.

**Run on: WORKSTATION**

Open the card's boot partition (`bootfs`) in Explorer. Open `network-config` in a text
editor, creating it if absent, and replace its contents with:

```yaml
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: false
      addresses: [10.10.40.10/24]
      routes:
        - to: default
          via: 10.10.40.1
      nameservers:
        addresses: [10.10.40.1]
```

Spaces only, no tabs. Save as UTF-8 and eject the card.

This file only has to work once. On the first playbook run, `roles/base` takes over the
address with a NetworkManager profile named `dmz` and deletes `network-config` from the boot
partition, because cloud-init seed files sit on FAT32 where permissions enforce nothing.

**Check:** reopen `network-config` and confirm the address reads `10.10.40.10/24` and the
gateway `10.10.40.1`.

---

## Step 5. Boot the Pi and prove console login works

Card in, Ethernet to **switch port 3**, monitor and keyboard attached, power on. First boot
takes a minute or two and may reboot once.

**Run on: SERVER**, at the physical console.

Log in as `justin` with the password. Then:

```bash
ip -br a
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Write down the `SHA256:` fingerprint. Step 6 compares against it.

This is the R13 gate. If console login fails here, stop and reflash with a password. A host
whose only way in is the network is unrecoverable when the network is what breaks.

**Check:** console login succeeds, and `eth0` shows `10.10.40.10/24`.

---

## Step 6. Connect from the control node and pin the host key

A reflashed card has new host keys, so the old `known_hosts` entries must go.
`host_key_checking = True` in `ansible.cfg`, so Ansible will not connect until this is done.

**Run on: CONTROL NODE**

```bash
ssh-keygen -R 10.10.40.10
ssh -o HostKeyAlgorithms=ssh-ed25519 justin@10.10.40.10 hostname
```

Answer `yes` only if the fingerprint SSH shows matches the one from Step 5.

**Run on: WORKSTATION**, so `ssh WebServer` keeps working from PowerShell:

```powershell
ssh-keygen -R 10.10.40.10
ssh WebServer hostname
```

Same fingerprint, same answer.

**Check:** both commands print `JG-RPi-WebServer` and the fingerprint matched Step 5.

---

## Step 7. Confirm the origin certificate in the repo is good

The Cloudflare Origin CA certificate (`roles/caddy/files/origin.pem`) and its vaulted key
(`roles/caddy/files/origin.key.vault`) are in the repo. Nothing is requested during a
rebuild. This step proves the pair still matches before Caddy depends on it.

**Run on: CONTROL NODE**, from the repo directory.

```bash
openssl x509 -in roles/caddy/files/origin.pem -noout -subject -enddate -ext subjectAltName

EMPTY=$(printf '' | sha256sum | cut -d' ' -f1)
c=$(openssl x509 -in roles/caddy/files/origin.pem -noout -pubkey 2>/dev/null \
    | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)
k=$(ansible-vault view roles/caddy/files/origin.key.vault \
    | openssl pkey -pubout -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)
[ "$c" = "$k" ] && [ "$c" != "$EMPTY" ] && echo MATCH || echo "FAIL: mismatch or unreadable"
```

`ansible-vault view` prompts for the vault password.

The `EMPTY` comparison matters. If either file fails to parse, both pipelines hash empty
input, the two hashes are equal, and a plain equality test reports a match. This check
fails instead.

If it fails, replace the certificate: [Making changes](making-changes.md#replacing-the-origin-certificate).

**Check:** `notAfter=Sep 25 ... 2041 GMT`, SAN lists `justingarter.com` and
`*.justingarter.com`, and the last line is `MATCH`.

---

## Step 8. First playbook run

Do not dry-run a fresh card. Several tasks read state that earlier tasks create (the
NetworkManager profile, the fail2ban jails, the Caddy log), so `--check` reports failures a
real run does not have. `--check --diff` is for changes to a converged host.

**Run on: CONTROL NODE**

```bash
cd /mnt/c/Projects/_Complete/pi-webserver-ansible
ansible-playbook site.yml 2>&1 | tee ~/webserver-build-1.log
```

Two prompts, in this order:

1. `BECOME password:` is the `justin` password. Sudo keeps its password on this host
   (DR-003 11.6). SSH is key-only, so the sudo password is what stands between a stolen
   key and root.
2. `Vault password:` is the Ansible vault password. `ask_vault_pass = True` because
   `group_vars/webserver/vault.yml` loads for every command against this host.

What the first run does, in order:

- `base` asserts `justin` has a usable password, asserts the host is already on
  `10.10.40.10`, creates the `dmz` NetworkManager profile, activates it (same address, so
  SSH survives), deletes every other Ethernet profile, removes the cloud-init seed files,
  disables Wi-Fi and Bluetooth in `config.txt`, sets root to `noatime,commit=600`, puts the
  journal in RAM, adds a 512 MB swapfile below zram.
- `ssh` writes the `00-hardening.conf` drop-in and asserts the effective config with
  `sshd -T`.
- `nftables` asserts the SSH source list is not empty, pins forwarding off, applies the
  ruleset. From here SSH is admitted only from `10.10.10.0/24` and `10.10.20.10`.
- `caddy`, `fail2ban`, `ddns`, `monitoring` install and start.

**Check:** the `PLAY RECAP` line reads `failed=0`. A `Reboot required` handler message is
expected.

---

## Step 9. Reboot

The radio overlays only take effect at boot, and the root mount options are proven only by
a boot.

**Run on: CONTROL NODE**

```bash
ssh -t justin@10.10.40.10 'sudo reboot'
```

Wait about a minute.

```bash
ssh justin@10.10.40.10 'ip -br a; nmcli -t -f NAME,DEVICE con show; findmnt -no OPTIONS /'
```

**Check:** interfaces are `lo` and `eth0` only (no `wlan0`), the only profiles are `dmz` on
`eth0` and `lo`, and the root options include `noatime` and `commit=600`.

---

## Step 10. Second run, idempotency

**Run on: CONTROL NODE**

```bash
ansible-playbook site.yml 2>&1 | tee ~/webserver-build-2.log
```

**Check:** `changed=0 failed=0`. Anything reporting changed on a host you have not touched
is a defect in a role. Fix it before going further. That is how the netplan and
NetworkManager fight in DR-003 11.7 was found.

---

## Step 11. Deploy site content

Follow [Deploy site content](deploy-site-content.md). The playbook creates an empty web
root and never touches content.

**Check:** the deploy page's final step passes: `status=200` from outside.

---

## Step 12. Verify end to end

**Run on: WORKSTATION**

```powershell
curl.exe -s -o NUL -w "status=%{http_code}`n" https://justingarter.com/
curl.exe -s -o NUL -w "status=%{http_code}`n" https://justingarter.com/projects
```

**Run on:** a phone on cellular, Wi-Fi off.

- `https://justingarter.com` loads with a valid padlock.
- `http://justingarter.com` redirects to https (Cloudflare's Always Use HTTPS).
- `https://<home public IP>` times out. The origin answers Cloudflare's ranges only.

Then run the full list in [Routine checks](routine-checks.md).

**Check:** both `curl.exe` lines print `status=200`, and all three phone results are as
listed.

---

## Step 13. Record the build

Add a line to the build history in [Runbook](runbook.md#15-build-history) with the date,
the image release from `cat /etc/os-release`, and anything that did not go as written here.
If something did not go as written, fix this page in the same commit.

**Check:** the commit is pushed and `git status` is clean.

---

## Trap index

Everything that went wrong or nearly went wrong on 2026-09-29, and the fix now in place.

| Trap | Symptom | Fix |
|---|---|---|
| Imager with key and no password | No console login. The August 2026 host had exactly this | Set the password in Imager. `roles/base` asserts it |
| `/mnt/c` without `metadata` | Ansible ignores `ansible.cfg`: no inventory, no prompts | `wsl.conf` in Step 1 |
| New WSL window | `Permission denied (publickey)` | Agent snippet in Step 2 |
| Stale `known_hosts` | `REMOTE HOST IDENTIFICATION HAS CHANGED` | `ssh-keygen -R 10.10.40.10` on both WSL and Windows |
| PowerShell quoting | Remote command with quotes runs mangled | Run Pi checks from WSL |
| CRLF line endings in the checkout | `#!/bin/bash\r` shipped to the Pi, DDNS script dies | `.gitattributes` forces `eol=lf`. After cloning: `git ls-files --eol` shows `i/lf` |
| No DHCP on the DMZ | Fresh card never gets an address | Seed `network-config` in Step 4 |
| netplan file written under NetworkManager | `changed=2` every run, two profiles for one interface | Fixed: `roles/base` manages one NM profile, `dmz` (DR-003 11.7) |
| fail2ban handlers pending at the jail assert | Assert checks Debian's default jails and fails | Fixed: `meta: flush_handlers` before the assert |
| Vault not prompted | Decrypt error on the first task | Fixed: `ask_vault_pass = True` |
| PEM pasted from browser into nano | Certificate or key collapsed onto one line, Caddy cannot load it | Re-wrap: [Making changes](making-changes.md#replacing-the-origin-certificate) |
| Cert and key match check on bad files | Two empty hashes compare equal and pass | The `EMPTY` guard in Step 7 |
| Creating `origin.justingarter.com` early | Publishes the home IP, origin reachable around Cloudflare | Not created until Minecraft exists (DR-003 11.5) |
