# Recovery

Getting back in when something has gone wrong. Ordered by how bad the situation is.

**Before doing anything: work out which layer is broken.** Most wasted time in a
recovery comes from fixing the wrong thing confidently. The tests below narrow it down
in about a minute.

---

## Triage

**Run on: WORKSTATION**, with WireGuard **deactivated**:

```powershell
ping -n 2 192.168.54.180
```

| Result | Meaning |
|---|---|
| Times out | Expected — LAN↔DMZ is blocked. Tells you nothing. Move on. |
| **Replies** | The DMZ isolation is open. Something changed on the router. |

Now activate WireGuard and read the client panel:

| Symptom | Where the problem is |
|---|---|
| No handshake, 0 B received | Tunnel. See *Tunnel down* below. |
| Handshake OK, `ssh WebServer` **refused** | Host is up, nothing listening on 2222. See *Port mismatch*. |
| Handshake OK, `ssh WebServer` **times out** | Firewall dropping. See *Port mismatch*. |
| SSH works, site is down | Not a recovery problem. See [Routine checks](routine-checks.md). |

**Refused and timed out mean different things and it is worth being precise.** Refused
is a RST — something answered and declined, so the packet reached the host and nothing
was listening. Timed out is silence — a firewall dropped it. Confusing the two sends you
to the wrong layer.

---

## Tunnel down

Active with no handshake and bytes only going out means your packets are leaving and
nothing is coming back.

**Check the endpoint first.** In the WireGuard client, hit **Edit** and read the literal
`Endpoint` line.

- If it is a **hard-coded IP**, that is almost certainly the fault. The public address
  is dynamic and has changed twice within fifteen minutes. Change it to
  `vpn.justingarter.com:51820` and reactivate — WireGuard re-resolves on handshake
  failure, so a hostname survives a renumber and an IP does not.
- If it is already the hostname, check that the DNS record is current. `vpn` is a
  DNS-only (grey-cloud) record; if it were proxied, Cloudflare would not forward
  WireGuard's UDP at all.

**Then check the router forward.** `51820/udp` must point at `192.168.54.180`. If the
host's IP has drifted off the static address — which happens if a rebuild left it on
DHCP — the forward lands nowhere.

**If you are on the same LAN**, you can bypass NAT hairpinning entirely as a test by
temporarily setting the endpoint to `192.168.54.180:51820`. This only works with a
LAN↔DMZ router rule open, so it is a diagnostic rather than a fix. Put it back to the
hostname afterwards.

---

## Port mismatch: firewall and sshd disagree

The signature is unmistakable once you know it:

| Target | Result |
|---|---|
| `192.168.54.180:2222` | Connection **refused** |
| `192.168.54.180:22` | Connection **timed out** |

Firewall permitting 2222 with nothing listening there, sshd listening on 22 with the
firewall dropping it. The two ends disagree in opposite directions.

**Cause.** Ansible flushes handlers at the *end* of a play, and a failed task aborts the
play before that happens. If a run applies the firewall (which takes effect
immediately) and then fails before the queued sshd restart, the ruleset demands a port
the daemon has not moved to.

**Fix: power cycle the host.** On boot, sshd reads its drop-in and binds the configured
port, nftables loads from `/etc/nftables.conf`, and `wg-quick@wg0` starts. All three are
enabled, so everything realigns on its own. There is nothing to repair — the config on
disk is already correct, it just was not loaded.

This requires physically reaching the machine. Which is the argument for the serial
console below.

---

## Locked out entirely

No tunnel, no SSH, no console. In order of preference:

**1. Power cycle.** Fixes the port-mismatch case above and anything else where the
on-disk config is right and the running state is not. Try it first; it costs one trip
and no risk.

**2. Boot the rescue media.** `BOOT_ORDER=0xf416` tries NVMe first and falls through to
the SD card automatically **if the NVMe will not boot**. That covers a corrupt boot
partition but not a host that boots fine and is merely unreachable.

To force the SD when the NVMe boots correctly, you need the EEPROM changed — which
needs a working system, which is the thing you do not have. In that situation the
options are physically removing the NVMe, or a serial console.

**3. Temporary router rule.** If the host is up and only the tunnel is broken, opening
LAN↔DMZ on the router gets you to it directly. Be clear about the cost: consumer
firmware generally has no directional control, so this also permits DMZ→LAN for the
duration. Close it as soon as you are done and prove it with the isolation tests in
[Routine checks](routine-checks.md).

**4. Restore from the disk image.** See below.

---

## Restoring from a disk image

If you have a partclone image from a rebuild, boot the rescue media and write it back.

**Run on: SERVER (rescue environment)**

Confirm where you are before touching anything:

```bash
hostname
findmnt -n -o SOURCE /                # must be the SD, not nvme
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT    # nvme0n1 must have no mountpoints
```

Restore the partition table, then each partition:

```bash
sudo sfdisk /dev/nvme0n1 < nvme-partition-table.txt
sudo partprobe /dev/nvme0n1

zcat nvme-p1-boot.pcl.gz | sudo partclone.vfat -r -s - -o /dev/nvme0n1p1
zcat nvme-p2-root.pcl.gz | sudo partclone.ext4 -r -s - -o /dev/nvme0n1p2

sudo partprobe /dev/nvme0n1
lsblk -f /dev/nvme0n1
```

Then shut down, restore `BOOT_ORDER=0xf416`, and boot the NVMe.

The image is a point-in-time snapshot. Anything deployed after it was taken — site
content in particular — needs redeploying.

---

## Recovering a locked-out account

Password locked or lost, but disk access available via rescue media:

```bash
sudo mount /dev/nvme0n1p2 /mnt
sudo mount /dev/nvme0n1p1 /mnt/boot/firmware
for d in proc sys dev dev/pts; do sudo mount --bind /$d /mnt/$d; done
sudo chroot /mnt /bin/bash

passwd justin
# or re-add the SSH key:
mkdir -p /home/justin/.ssh
echo '<public key>' > /home/justin/.ssh/authorized_keys
chown -R justin:justin /home/justin/.ssh
chmod 700 /home/justin/.ssh && chmod 600 /home/justin/.ssh/authorized_keys
exit

for d in dev/pts dev sys proc boot/firmware; do sudo umount /mnt/$d; done
sudo sync && sudo umount /mnt
```

Same procedure works for undoing a firewall change that locked you out — edit
`/etc/nftables.conf` under the chroot before rebooting.

---

## What is missing, and why it matters

**There is no serial console.** The EEPROM already has `BOOT_UART=1`, so a USB-to-TTL
adapter on three GPIO pins would give console access from the desk. Roughly ten dollars.

Without it, every recovery above that is not "power cycle" requires physically opening
the case in a basement. During the August 2026 rebuild there was a window where the only
path back was hardware. On a headless host whose management path depends on the host
itself booting correctly and bringing up a tunnel, that is the missing piece — not a
convenience.

**There is no out-of-band power control.** A smart plug would turn the most common
recovery — the power cycle — into something doable from a phone.

---

## After any recovery

Do not stop at "it works again."

1. **Run the full check list** in [Routine checks](routine-checks.md), especially the
   segmentation tests in both directions.
2. **Close anything you opened.** Temporary router rules are extremely easy to forget
   once access is restored, and they leave DMZ→LAN open indefinitely.
3. **Write down what happened** while it is fresh — what broke, what the symptom looked
   like, what actually fixed it. The symptom-to-cause mapping is the part you will have
   forgotten in three months, and it is the part that makes the next recovery fast.
