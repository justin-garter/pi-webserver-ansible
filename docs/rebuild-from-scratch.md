# Rebuild from scratch

Wiping the NVMe and rebuilding the host from the playbook. Performed and verified
August 2026.

**Time:** about two hours end to end. Roughly 20 minutes of that is waiting.
**Downtime:** the site is offline from the wipe until Step 7.
**Risk:** real. There is a window where the host is unreachable and recovery requires
physically touching it.

---

## What this actually proves, and what it doesn't

The playbook reproduces every file it manages exactly — 192 files verified with zero
content, ownership, or permission differences, and a byte-identical firewall ruleset.

It does **not** produce a working host from a blank disk on its own. It configures a
host that is already reachable, and getting to "reachable" is manual. Five
prerequisites have to exist before Ansible can connect at all:

1. A user account matching `ansible_user` in the inventory
2. That user's SSH public key in `~/.ssh/authorized_keys`
3. Passwordless sudo for that user
4. `sshd` enabled and running
5. A static IP on the DMZ segment

Steps 4 and 5 below establish those. Budget for it rather than being surprised by it.

---

## Before you start

**You need physical access at least once.** The Pi lives in a basement with no monitor.
There is a window in Step 5 where a bad outcome means walking down there.

**Check what you have:**

- Boot media — an SD card or USB stick, 8 GB or larger. Currently there is an SD card
  already in the Pi as a permanent rescue path (see Boot order below).
- Disk space on the control node — about 2 GB for the disk image.
- The vault password.
- Your WireGuard client config, unmodified.

**Confirm the vault holds the live WireGuard key before wiping anything.** If it does
not, the rebuild generates a different tunnel identity and every existing peer config
breaks — on the host whose only management path is that tunnel.

**Run on: SERVER**
```bash
sudo grep PrivateKey /etc/wireguard/wg0.conf | awk -F'= ' '{printf "%s", $2}' | sha256sum
```

**Run on: CONTROL NODE**
```bash
cd ~/pi-webserver-ansible
ansible-vault view group_vars/webserver/vault.yml --ask-vault-pass \
  | awk -F': ' '/^wg_private_key/{gsub(/"/,"",$2); printf "%s", $2}' | sha256sum
```

The two hashes must match. Hashing rather than printing keeps the key off your screen
and out of scrollback.

---

## Boot order and the rescue path

The Pi's EEPROM holds `BOOT_ORDER=0xf416`. Nibbles read right to left: NVMe first,
then SD, then USB, then restart the loop.

That means **an SD card can sit in the slot permanently**. Normal boots use the NVMe
and ignore it; if the NVMe ever fails to boot, the Pi falls through to the card by
itself. For a headless machine in a basement this is worth having and costs nothing.

To deliberately boot the SD instead — which Step 2 needs — flip the order:

**Run on: SERVER**
```bash
sudo rpi-eeprom-config --out /tmp/boot.conf
sudo sed -i 's/^BOOT_ORDER=.*/BOOT_ORDER=0xf461/' /tmp/boot.conf
grep BOOT_ORDER /tmp/boot.conf
```

**Note the `sudo` on the `sed`.** `rpi-eeprom-config --out` writes a root-owned file,
so `sed -i` without sudo fails on the rename and silently leaves the value unchanged.
It then applies the *original* config and reports "UPDATE SUCCESSFUL" — which is true
and useless. Always read the `grep` output before applying.

```bash
sudo rpi-eeprom-config --apply /tmp/boot.conf
sudo reboot
```

`0xf461` = SD first, NVMe second. `0xf463` if your media is USB.

---

## Step 1 — Capture the baseline

Everything the rebuild will be measured against. Do this first; there is no second
chance once the disk is wiped.

**Run on: SERVER**

```bash
mkdir -p ~/rebuild-baseline && cd ~/rebuild-baseline

dpkg-query -W -f='${Package} ${Version}\n' | sort > packages.txt
systemctl list-unit-files --state=enabled --no-pager | sort > units-enabled.txt
systemctl list-timers --all --no-pager > timers.txt
sudo nft list ruleset > nft.txt
sudo sysctl -a 2>/dev/null | sort > sysctl.txt
getent passwd > passwd.txt; getent group > group.txt
ss -tulpn 2>/dev/null | sort > listening.txt
sudo ls -la /etc/sudoers.d/ > sudoers-d.txt
grep -vE '^\s*#|^\s*$' /boot/firmware/config.txt > boot-config.txt
uname -a > kernel.txt

sudo find /etc/caddy /etc/wireguard /etc/nftables.conf /etc/ssh/sshd_config \
  /etc/ssh/sshd_config.d /etc/fail2ban /etc/sysctl.d /etc/systemd/system \
  /usr/local/bin /etc/apt/sources.list.d /etc/apt/keyrings \
  -type f 2>/dev/null | sort | while read -r f; do
    printf '%s  %s  %s\n' "$(sudo sha256sum "$f" | cut -d' ' -f1)" \
      "$(sudo stat -c '%U:%G %a' "$f")" "$f"
  done > managed-files.txt

wc -l *.txt
```

Then preserve the three things Ansible does not manage:

```bash
sudo tar -czf ~/rebuild-baseline/preserve-caddy-certs.tgz -C /var/lib/caddy .
sudo tar -czf ~/rebuild-baseline/preserve-webroot.tgz    -C /var/www/portfolio .
sudo tar -czf ~/rebuild-baseline/preserve-wireguard.tgz  -C /etc/wireguard .
sudo chown justin:justin ~/rebuild-baseline/*.tgz
```

**Run on: CONTROL NODE**

```bash
mkdir -p ~/pi-rebuild && cd ~/pi-rebuild
scp -r WebServer:rebuild-baseline .
ls -la rebuild-baseline/
```

The certs tarball matters more than it looks. Let's Encrypt allows five duplicate
certificates per domain per week. Restoring the cert store means the rebuilt host
reuses the existing certificate instead of requesting a new one, so a failed attempt
does not eat your quota.

---

## Step 2 — Image the disk from a rescue environment

The rollback path. Do not skip it.

**First, flash the boot media.** On the **WORKSTATION**, use Raspberry Pi Imager:
Raspberry Pi OS Lite 64-bit, hostname `rebuild-live`, your username and SSH public
key, password auth disabled. Naming it differently from the real host matters — it is
how you tell at a glance which environment you are sitting in.

Then flip the boot order (above), insert the card, and reboot. Find the new DHCP lease
on the router and SSH to it on **port 22**.

**Run on: SERVER (rebuild-live)**

Confirm where you are before touching any disk:

```bash
hostname                              # must say rebuild-live
findmnt -n -o SOURCE /                # must be /dev/mmcblk0p2, NOT nvme
lsblk -o NAME,SIZE,TYPE,TRAN,MOUNTPOINT
```

You need `nvme0n1` present with **no mountpoints**. An unmounted filesystem is what
makes a consistent image possible.

```bash
sudo apt update && sudo apt install -y partclone pigz
cd ~
sudo sfdisk -d /dev/nvme0n1 > nvme-partition-table.txt
sudo dd if=/dev/nvme0n1 bs=1M count=32 status=none | pigz -c > nvme-header.img.gz
sudo partclone.vfat -c -s /dev/nvme0n1p1 -o - | pigz -c > nvme-p1-boot.pcl.gz
sudo partclone.ext4 -c -s /dev/nvme0n1p2 -o - | pigz -c > nvme-p2-root.pcl.gz
sudo chown justin:justin nvme-*
ls -lh nvme-*
```

**Use partclone, not `dd` on the whole disk.** partclone copies only allocated blocks
— under two minutes for ~10 GB of real data. A full-disk `dd` reads all 238 GB,
takes hours, and produces a crash-consistent image of a mounted filesystem, which is
worse in every way.

Get it off the machine you are about to wipe:

**Run on: CONTROL NODE**
```bash
cd ~/pi-rebuild
scp WebServer-rescue:nvme-* .        # or scp justin@<dhcp-address>:nvme-* .
for f in nvme-*.gz; do gzip -t "$f" && echo "OK   $f" || echo "BAD  $f"; done
```

Three `OK` lines and you have a verified rollback. **This is the point of no return.**

---

## Step 3 — Write a fresh OS to the NVMe

Still in the rescue environment.

**Run on: SERVER (rebuild-live)**

```bash
cd ~
curl -fL -o raspios.img.xz https://downloads.raspberrypi.com/raspios_lite_arm64_latest
curl -fsSL https://downloads.raspberrypi.com/raspios_lite_arm64_latest.sha256
sha256sum raspios.img.xz
```

Compare the two hashes yourself. The filenames differ because of the rename; only the
hash matters.

```bash
findmnt -n -o SOURCE /                            # confirm: mmcblk0p2
lsblk -o NAME,MOUNTPOINT /dev/nvme0n1             # confirm: no mountpoints

sudo sh -c 'xzcat /home/justin/raspios.img.xz | dd of=/dev/nvme0n1 bs=4M conv=fsync status=progress'
sudo partprobe /dev/nvme0n1
sudo udevadm settle
lsblk -f /dev/nvme0n1
```

`lsblk -f` may show empty filesystem fields immediately after the write — that is a
stale kernel view, not a failed write. `partprobe` and `udevadm settle` clear it. If
still blank, mount `nvme0n1p1` and look for `config.txt` and `cmdline.txt` to confirm.

---

## Step 4 — Bootstrap the five prerequisites

**`custom.toml` does not work.** The documented Raspberry Pi OS first-boot preseed —
writing hostname, user, SSH key, and timezone to `/boot/firmware/custom.toml` — was
written correctly and silently ignored. The host booted with the default `raspberrypi`
hostname, a default `pi` user, SSH disabled, and the wrong timezone. The file was
still sitting on the boot partition afterwards, unread.

Do it offline from the rescue environment instead. Deterministic, and you can verify
before booting.

**Run on: SERVER (rebuild-live)**

```bash
sudo mount /dev/nvme0n1p2 /mnt
sudo mount /dev/nvme0n1p1 /mnt/boot/firmware
for d in proc sys dev dev/pts; do sudo mount --bind /$d /mnt/$d; done
sudo chroot /mnt /bin/bash
```

Inside the chroot — generate the password hash first with `openssl passwd -6` if you
do not have one:

```bash
useradd -m -s /bin/bash -G sudo,adm,users,netdev justin
echo 'justin:<PASSWORD-HASH>' | chpasswd -e

mkdir -p /home/justin/.ssh
echo '<YOUR-SSH-PUBLIC-KEY>' > /home/justin/.ssh/authorized_keys
chown -R justin:justin /home/justin/.ssh
chmod 700 /home/justin/.ssh && chmod 600 /home/justin/.ssh/authorized_keys

echo 'justin ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/010-justin-nopasswd
chmod 440 /etc/sudoers.d/010-justin-nopasswd

echo 'JG-RPi-WebServer' > /etc/hostname
sed -i 's/raspberrypi/JG-RPi-WebServer/g' /etc/hosts

systemctl enable ssh
id justin && exit
```

Set a real console password. It is your only login if SSH breaks, which is not
hypothetical.

Unwind, restore boot order, and reboot into the new system:

```bash
for d in dev/pts dev sys proc boot/firmware; do sudo umount /mnt/$d; done
sudo sync && sudo umount /mnt

sudo rpi-eeprom-config --out /tmp/boot.conf
sudo sed -i 's/^BOOT_ORDER=.*/BOOT_ORDER=0xf416/' /tmp/boot.conf
grep BOOT_ORDER /tmp/boot.conf                    # must read 0xf416
sudo rpi-eeprom-config --apply /tmp/boot.conf
sudo reboot
```

Setting the order back to NVMe-first means you can **leave the SD card in** and still
boot the real system, while keeping automatic fallback. No second physical trip.

### Set the static IP

The playbook does not configure networking. The fresh host comes up on DHCP, and the
router forwards `51820/udp` to `192.168.54.180` — so until the address is right, the
tunnel cannot reach it.

Find the new DHCP lease on the router, SSH in on **port 22**, then:

**Run on: SERVER**

```bash
nmcli -t -f NAME,DEVICE con show          # confirm the connection name

# arm a rollback first - this is the one command where a typo means a basement trip
sudo tee /usr/local/bin/net-rollback.sh >/dev/null <<'EOF'
#!/bin/bash
nmcli con mod "Wired connection 1" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns ""
nmcli con up "Wired connection 1"
EOF
sudo chmod +x /usr/local/bin/net-rollback.sh
sudo systemd-run --on-active=300 --unit=net-rollback /usr/local/bin/net-rollback.sh

sudo nmcli con mod "Wired connection 1" \
  ipv4.method manual \
  ipv4.addresses 192.168.54.180/24 \
  ipv4.gateway 192.168.54.1 \
  ipv4.dns "1.1.1.1,9.9.9.9"

nmcli -g ipv4.method,ipv4.addresses,ipv4.gateway con show "Wired connection 1"
```

Read that back before applying. Then:

```bash
sudo nohup nmcli con up "Wired connection 1" >/dev/null 2>&1 &
```

Your session dies. Reconnect to `192.168.54.180` on port 22, then **cancel the
rollback immediately** or you lose the address in five minutes:

```bash
sudo systemctl stop net-rollback.timer
sudo rm /usr/local/bin/net-rollback.sh
ip -br a
```

---

## Step 5 — Reaching the host from the control node

**The DMZ is unreachable from the trusted LAN in both directions.** Your control node
is on the LAN. The only path to the DMZ is WireGuard, which only exists on a fully
configured host. So at this moment, Ansible cannot reach the host it is meant to build.

Two ways through:

**Option A — temporary router rule.** Open LAN↔DMZ on the router for the duration.
Fast, but be clear about what you are accepting: most consumer firmware has no
directional control, so this also permits DMZ→LAN, which is the direction the entire
segmentation design exists to prevent. Close it the moment the tunnel is back and
re-run the isolation tests in [Routine checks](routine-checks.md) to prove it closed.

**Option B — run Ansible on a host already in the DMZ**, or locally on the Pi with
`-c local` after cloning the repo there. Slower to set up, no hole opened.

Option A is what was used. Track the closure as a task somewhere you will see it — an
open bidirectional rule is very easy to forget once things are working again.

---

## Step 6 — Run the playbook

**Run on: CONTROL NODE**

Clear stale host keys first. A reflashed host has new keys, and SSH stores non-default
ports under a **separate entry** — clearing one does not clear the other:

```bash
ssh-keygen -f ~/.ssh/known_hosts -R '192.168.54.180'
ssh-keygen -f ~/.ssh/known_hosts -R '[192.168.54.180]:2222'
ssh -p 22 justin@192.168.54.180 'echo connected'
```

Then run it. The fresh host is on port 22; the inventory says 2222:

```bash
cd ~/pi-webserver-ansible
ansible-playbook -i inventory site.yml --ask-vault-pass -e ansible_port=22 2>&1 \
  | tee ~/pi-rebuild/playbook-run-1.log
```

### Expect the first run to fail

It fails at **`nftables : Verify the management interface exists`** with
`wg0 is not present`.

WireGuard installed correctly and the interface is up. The check reads
`ansible_facts['interfaces']`, gathered at the *start* of the play — before the
wireguard role ran. It is testing a snapshot from forty seconds earlier.

Confirm WireGuard is genuinely fine, then run it again:

```bash
# SERVER
ip -br a && sudo wg show && systemctl is-active wg-quick@wg0
```

```bash
# CONTROL NODE
ansible-playbook -i inventory site.yml --ask-vault-pass -e ansible_port=22 2>&1 \
  | tee ~/pi-rebuild/playbook-run-2.log
```

### Expect the second run to fail too, and to lock you out

Run 2 gets much further — nftables, Caddy, and fail2ban all apply — then fails at
**`fail2ban : Assert both jails loaded`**, because the `caddy-404` jail points at
`/var/log/caddy/access.log`, which does not exist yet on a host where Caddy has served
nothing.

**By this point you are locked out, and it is worth understanding why.**

Ansible flushes handlers at the *end* of a play. A failed task aborts the play first,
so pending handlers never run. At the moment of failure:

- the `ssh` role had written a drop-in setting `Port 2222` and queued a restart
- the `nftables` role had already applied a ruleset permitting SSH **only** on 2222
  over `wg0`

The restart never happened. sshd stayed on port 22. The result:

| Target | Result | Meaning |
|---|---|---|
| `192.168.54.180:2222` | Connection refused | firewall permits, nothing listening |
| `192.168.54.180:22` | Connection timed out | sshd listening, firewall drops |

**Recovery is a power cycle.** On boot, sshd reads the drop-in and binds 2222, nftables
loads from `/etc/nftables.conf`, and `wg-quick@wg0` starts. All three are enabled, so
everything realigns by itself. Nothing to fix, but you do have to physically reach the
plug.

After the reboot, both fail2ban jails load correctly — Caddy started first and created
the log.

### Third run: clean

The host is now on 2222 where the inventory expects it, so no port override:

```bash
cd ~/pi-webserver-ansible
ansible-playbook -i inventory site.yml --ask-vault-pass 2>&1 \
  | tee ~/pi-rebuild/playbook-run-3.log
```

Expect `failed=0`. Run it a fourth time and expect `changed=0` — that is the
idempotency check, and anything reporting changed on a converged host is drift you want
to understand.

---

## Step 7 — Restore what Ansible does not manage

**Restore certificates before Caddy first starts if you can.** In the run above Caddy
started during the playbook and requested a fresh certificate at that point, consuming
one of five weekly Let's Encrypt issuances before the preserved store was put back.

**Run on: CONTROL NODE**
```bash
cd ~/pi-rebuild/rebuild-baseline
scp preserve-webroot.tgz preserve-caddy-certs.tgz WebServer:~/
```

**Run on: SERVER**
```bash
grep -iE 'root|file_server' /etc/caddy/Caddyfile      # confirm the web root path

sudo systemctl stop caddy
sudo tar -xzf ~/preserve-caddy-certs.tgz -C /var/lib/caddy
sudo tar -xzf ~/preserve-webroot.tgz     -C /var/www/portfolio
sudo chown -R caddy:caddy /var/lib/caddy
sudo chown -R justin:caddy /var/www/portfolio
sudo find /var/www/portfolio -type d -exec chmod 2755 {} \;
sudo find /var/www/portfolio -type f -exec chmod 644 {} \;
sudo systemctl start caddy
sleep 5
systemctl is-active caddy
ls /var/www/portfolio/*.html | wc -l
```

Note the split ownership: the cert store is `caddy:caddy`, the web root is
`justin:caddy` so your deploy `scp` still works.

---

## Step 8 — Verify

Run the full checklist in [Routine checks](routine-checks.md). At minimum:

**Run on: SERVER**
```bash
systemctl is-active caddy nftables wg-quick@wg0 fail2ban ssh
curl -s -o /dev/null -w 'status=%{http_code}\n' --resolve justingarter.com:443:127.0.0.1 https://justingarter.com/
ping -c2 -W2 192.168.50.1                       # MUST fail - DMZ to LAN isolation
sudo fail2ban-client status
```

**Run on: WORKSTATION** — with the tunnel up:
```powershell
ssh WebServer 'hostname'
curl.exe -s -o NUL -w "status=%{http_code}`n" https://justingarter.com/
```

Then diff against the baseline you captured in Step 1. Capture the same files into
`~/rebuilt-state` on the server, pull them down, and compare. The comparison worth
doing is `managed-files.txt` — every hash and permission should match.

---

## Step 9 — Close out

- **Close the temporary router rule** if you opened one, and prove it with the
  isolation tests.
- **Remove the leftover `pi` account.** The failed first-boot preseed creates it with
  `sudo`, `adm`, `users`, and `netdev`. No role creates it, so no role removes it.
  ```bash
  sudo userdel -r pi
  sudo grep -E '^(sudo|adm|users|netdev):' /etc/group
  ```
- **Run a full upgrade.** The image is months old; a rebuilt host starts behind on
  patches, including the kernel, until unattended-upgrades catches up on its own.
  ```bash
  sudo apt update && sudo apt full-upgrade -y
  cat /var/run/reboot-required.pkgs 2>/dev/null && sudo reboot
  ```
- **Clear first-boot debris:** `/etc/ssh/sshd_config.d/rename_user.conf` (an SSH banner
  claiming no valid user is set up), `userconfig.service`, and the `cloud-config`,
  `cloud-final`, and `cloud-init-local` units. Leave `cloud-init-main`,
  `cloud-init-network`, and `cloud-init-hotplugd.socket` — those are enabled on a
  correctly built host too.
- **Set the WireGuard peer endpoint to `vpn.justingarter.com:51820`**, never a literal
  IP. A dynamic address can change more than once in the same evening.

---

## Trap index

Everything above that is easy to miss, in one place.

| Trap | Symptom | Fix |
|---|---|---|
| `sed` without `sudo` on `rpi-eeprom-config --out` | Reports UPDATE SUCCESSFUL, boot order unchanged | `sudo sed`; always `grep` the file before applying |
| `custom.toml` ignored | Host boots as `raspberrypi`, no user, SSH off | Bootstrap offline via chroot |
| Stale `known_hosts` | `REMOTE HOST IDENTIFICATION HAS CHANGED` | Clear **both** `1.2.3.4` and `[1.2.3.4]:2222` |
| Full-disk `dd` | Hours, and a crash-consistent image | `partclone` on unmounted partitions |
| `lsblk -f` blank after write | Looks like the write failed | `partprobe` + `udevadm settle`; mount to confirm |
| Fresh host on DHCP | Tunnel never establishes | Set the static IP before running the playbook |
| First playbook run fails on `wg0` | `wg0 is not present` when it plainly is | Run it again |
| Second run fails, host unreachable | 2222 refused, 22 times out | Power cycle |
| Certs requested during the build | One Let's Encrypt issuance consumed | Restore the cert store before Caddy first starts |
| Leftover `pi` account | Silent; nothing reports it | `userdel -r pi` |
