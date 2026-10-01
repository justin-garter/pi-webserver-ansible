# Recovery

Getting the site back, or getting back into the Pi, when something has gone wrong.

## TLDR

1. Find the broken layer with the triage below before fixing anything.
2. The console is the break-glass: monitor, keyboard, `justin` and the password from the
   password manager. It works with every network layer down (R13).
3. Nothing on the Pi is unique. When in doubt, reflash and follow
   [Rebuild from scratch](rebuild-from-scratch.md). About an hour.

---

## Triage

Work from the outside in. Each row assumes the rows above it passed.

**Run on: WORKSTATION**

```powershell
curl.exe -s -o NUL -w "status=%{http_code}`n" https://justingarter.com/
ping -n 2 10.10.40.1
ping -n 2 10.10.40.10
Test-NetConnection 10.10.40.10 -Port 22
Test-NetConnection 10.10.40.10 -Port 443
ipconfig | findstr IPv4
```

| Result | Broken layer | Go to |
|---|---|---|
| Site 200 | Nothing public. If SSH is the problem, continue down the table | |
| Site 52x (Cloudflare error page) | Origin unreachable from Cloudflare | *Site down, Pi fine* |
| `10.10.40.1` no reply | OPNsense or Proxmox. The whole lab is down, not just the Pi | `proxmox-host-jg.md`, OOB path |
| `10.10.40.10` no reply, gateway replies | Pi off, card failed, cable, or switch port 3 | *Pi unreachable* |
| Ping replies, 22 **times out** | Firewall dropping you. Usually the desktop is not on `10.10.20.10` | *SSH timed out* |
| Ping replies, 22 **refused** | sshd not listening | Console |
| 443 open, site still down | Cloudflare, DNS or the ingress path | *Site down, Pi fine* |

**Timed out and refused mean different things.** Refused is a RST: the packet reached the Pi
and nothing was listening. Timed out is silence: a firewall dropped it.

---

## SSH timed out

### Step 1. Check the desktop's address

`ipconfig` must show `10.10.20.10`. The Pi admits SSH only from that address and
`10.10.10.0/24`. If the desktop holds a different address, the OPNsense static mapping was
lost or the desktop came up on Wi-Fi.

**Check:** `10.10.20.10` on the wired adapter. If not, fix the mapping or renew the lease,
then retry SSH.

### Step 2. Check the OPNsense MAIN to DMZ path

OPNsense web UI > **Firewall** > **Log Files** > **Live View**, filter on `10.10.40.10`, then
retry SSH.

**Check:** the connection shows as passed. If OPNsense blocks it, the problem is upstream of
the Pi.

### Step 3. If both pass, it is the Pi's ruleset

Go to the console section.

**Check:** you are at the console.

---

## Pi unreachable

### Step 1. Look at it

Power LED, activity LED, switch port 3 link light.

**Check:** you know whether it is powered and linked.

### Step 2. Power cycle

Most running-state problems clear on boot: sshd, nftables, NetworkManager and Caddy all
load their on-disk config. That config is what the playbook wrote, so it is correct unless
someone edited it by hand.

**Check:** `ping -n 2 10.10.40.10` replies within two minutes.

### Step 3. Console

If it still does not reply, attach a monitor and keyboard and go to the console section.

**Check:** you see a login prompt. No prompt, or a kernel panic or filesystem errors on
screen, means the card. Go to *Card failed*.

---

## Console break-glass

### Step 1. Log in

`justin`, password from the password manager.

**Check:** shell prompt.

### Step 2. Read the state

```bash
ip -br a
nmcli -t -f NAME,DEVICE,STATE con show
systemctl --failed
sudo nft list chain inet filter input
sudo ss -tlnp
```

**Check:** you can name what is wrong: no address, wrong profile, failed unit, a ruleset that
does not admit your source, or sshd not listening.

### Step 3. Restore SSH temporarily if the ruleset is the problem

```bash
sudo systemctl stop nftables
```

Stopping the unit flushes the whole ruleset, including fail2ban's table, so the Pi accepts
everything OPNsense lets through. OPNsense still admits only MAIN and MGMT on 22 and
Cloudflare on 443, so exposure is limited. Keep the window short.

**Check:** `ssh justin@10.10.40.10 hostname` works from WSL.

### Step 4. Fix it in the repo and rerun the playbook

Never fix a managed file on the Pi. Fix the role or `vars.yml`, then:

```bash
ansible-playbook site.yml
```

The `nftables` role starts the unit again, so the ruleset comes back as part of the run.

**Check:** `failed=0`, then `ssh justin@10.10.40.10 systemctl is-active nftables` prints `active`, and a new SSH
session works.

---

## Site down, Pi fine

The Pi serves locally (`status=200` from the local check in
[Routine checks](routine-checks.md)) but the public site is down.

### Step 1. Is Cloudflare pointed at the current IP?

```bash
ssh justin@10.10.40.10 'curl -s -4 https://ifconfig.me; echo'
dig +short justingarter.com @1.1.1.1
```

The second answer is a Cloudflare address because the record is proxied. Compare the real
record in the Cloudflare dashboard > **DNS** > `justingarter.com`.

**Check:** the dashboard A record matches `ifconfig.me`. If not, force a DDNS run
([Making changes](making-changes.md#changing-a-secret), Step 3) and read its log.

### Step 2. Is the Archer still forwarding 443?

From a phone on ROOM_NET: Archer admin > **NAT Forwarding** > **Virtual Servers**.

**Check:** one entry, TCP 443 to `192.168.0.254:443`.

### Step 3. Is OPNsense still passing it?

OPNsense: `CLOUDFLARE_V4` alias **Loaded#** non-zero; Destination NAT WAN 443 to
`10.10.40.10:443`; the matching WAN pass rule. Live View filtered on `10.10.40.10` shows
Cloudflare sources passing.

**Check:** all three present and the live view shows passes. An empty alias blocks
everything; check its last refresh.

### Step 4. Is Cloudflare's SSL mode still Full (Strict)?

**Check:** **SSL/TLS** > **Overview** shows Full (Strict). A 526 error means Cloudflare
rejected the origin certificate: confirm with the certificate check in
[Routine checks](routine-checks.md#certificate).

---

## Card failed

Reflash and rebuild: [Rebuild from scratch](rebuild-from-scratch.md). Use a new card if the
old one threw errors. Nothing needs restoring: configuration and certificate come from this
repo and content from `Web Portfolio`.

**Check:** the rebuild's Step 12 passes.

---

## Lost the `justin` password

There is one card and no rescue boot, so there is no chroot path. Reflash and rebuild, then
store the new password in the password manager before Step 3 of the rebuild.

**Check:** console login works with the stored password before the playbook runs.

---

## After any recovery

1. Run every check in [Routine checks](routine-checks.md).
2. Confirm `nftables` is `active` if you stopped it.
3. Write down what broke, what the symptom looked like, and what fixed it, here or in the
   runbook build history. The symptom-to-cause mapping is what makes the next recovery
   fast.

**Check:** the routine checks pass and the note is committed.
