# Deploy site content

Putting new or updated HTML, CSS, and images onto the live server.

Takes about two minutes. The site is static, so there is no build step and no service
restart — Caddy reads from disk on every request.

---

## Before you start

**The WireGuard tunnel must be up.** There is no other route to this host. If
`ssh WebServer` hangs, the tunnel is down; fix that first.

Site content is deliberately **not** managed by Ansible. Host configuration and
content deploys stay separate so that when something breaks there is one variable to
check instead of two. Running the playbook will never touch your HTML, and deploying
content will never touch the firewall.

| Fact | Value |
|---|---|
| Web root on the server | `/var/www/portfolio` |
| Owner / group | `justin:caddy` |
| Directory mode | `2755` (setgid, so new files inherit the `caddy` group) |
| File mode | `644` |
| Served by | Caddy, `root * /var/www/portfolio` + `file_server` |

---

## Step 1 — Confirm you can reach the host

**Run on: WORKSTATION**

```powershell
ssh WebServer 'hostname; systemctl is-active caddy'
```

Want `JG-RPi-WebServer` and `active`. If this fails, stop and check the WireGuard
client — you are not going to get further.

---

## Step 2 — Copy the files up

**Run on: WORKSTATION**

```powershell
scp -r "C:\Users\garte\OneDrive\Documents\Projects\Web Portfolio\Version 1.6\*" WebServer:/var/www/portfolio/
```

Change the version folder to whichever one you are deploying.

**The `\*` matters.** Without it you copy the folder itself, and everything lands
nested under a directory with a space in its name inside the web root. The site then
404s and the cause is not obvious.

To save typing this every time, put a function in your PowerShell profile
(`$PROFILE`):

```powershell
function Deploy-Portfolio($v) {
    scp -r "C:\Users\garte\OneDrive\Documents\Projects\Web Portfolio\Version $v\*" WebServer:/var/www/portfolio/
}
```

Then it is `Deploy-Portfolio 1.7`.

---

## Step 3 — Fix ownership

**Run on: SERVER**

```bash
sudo chown -R justin:caddy /var/www/portfolio
sudo find /var/www/portfolio -type d -exec chmod 2755 {} \;
sudo find /var/www/portfolio -type f -exec chmod 644 {} \;
```

Only strictly necessary if you have created new subdirectories, but it is cheap and
it prevents the most annoying failure mode. See the ownership trap below.

---

## Step 4 — Verify on the host

**Run on: SERVER**

```bash
ls /var/www/portfolio/*.html | wc -l
curl -s -o /dev/null -w 'status=%{http_code} bytes=%{size_download}\n' \
  --resolve justingarter.com:443:127.0.0.1 https://justingarter.com/
```

Want the expected file count and `status=200` with a plausible byte count. A `308`
means you hit the HTTP-to-HTTPS redirect instead of the site — check you used
`https://` and the `--resolve` flag.

`--resolve` forces the hostname to loopback while still presenting the right SNI, so
Caddy serves the real certificate. Without it you get a TLS failure, because Caddy has
no certificate for `127.0.0.1`.

---

## Step 5 — Verify from outside

**Run on: WORKSTATION**

```powershell
curl.exe -s -o NUL -w "status=%{http_code} bytes=%{size_download}`n" https://justingarter.com/
```

Note single `%`, not `%%` — `%%` is cmd escaping and produces literal text in
PowerShell.

Then load the site in a browser and **hard-refresh** (Ctrl+F5). Cloudflare caches
aggressively; a stale page in your browser does not mean the deploy failed.

If the old version persists, purge the Cloudflare cache from the dashboard:
**Caching → Configuration → Purge Everything.**

---

## Things that will bite you

**Permission denied on `scp`.** The web root is `justin:caddy`. If it has been reset
to `caddy:caddy` — which happens if you restore a backup with `chown -R caddy:caddy` —
your user can no longer write to it. Fix with the Step 3 commands.

**Stale files from the previous version.** `scp` overwrites and adds; it never
deletes. A file that existed in 1.5 and not in 1.6 stays on the server forever,
reachable by direct URL. If you have renamed or removed pages, check:

```bash
ls -la /var/www/portfolio/
```

and delete what should not be there. If you want a true mirror instead, stage to your
home directory and rsync with `--delete`:

```bash
# WORKSTATION
scp -r "…\Version 1.7\*" WebServer:~/site-staging/
# SERVER
sudo rsync -avn --delete ~/site-staging/ /var/www/portfolio/   # -n = dry run, read it
sudo rsync -av  --delete ~/site-staging/ /var/www/portfolio/
```

Read the dry-run output before dropping the `n`. `--delete` will remove anything in
the web root not present in your source folder.

**Cloudflare cache.** Covered above, but it is the single most common reason a deploy
"did not work" when it did.

**Do not restart Caddy.** It reads from disk per request. If you find yourself
restarting it to make content appear, the problem is somewhere else — most likely
cache or a path error.

**Do not run `sudo caddy validate` or `sudo caddy run`.** Either creates
`/var/log/caddy/access.log` owned `root:root`, after which the service — running as
`caddy` — cannot open its own log and fails to start with a misleading permission
error. If it has already happened:

```bash
sudo chown caddy:caddy /var/log/caddy/access.log
sudo systemctl restart caddy
```

---

## If the site is down after a deploy

Work outward from the host.

```bash
# SERVER
systemctl is-active caddy
sudo journalctl -u caddy --since "10 minutes ago" --no-pager | tail -30
curl -s -o /dev/null -w '%{http_code}\n' --resolve justingarter.com:443:127.0.0.1 https://justingarter.com/
```

Caddy active and serving 200 locally means the problem is DNS, Cloudflare, or your
public IP — not the content. Check [Routine checks](routine-checks.md) for the DDNS
verification steps.
