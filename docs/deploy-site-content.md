# Deploy site content

Putting a version of the site from `C:\Projects\Web Portfolio` onto the Pi.

**Time:** about two minutes. **Downtime:** none. Caddy reads from disk on every request, so
there is no restart.

---

## TLDR

```bash
# CONTROL NODE, agent loaded
rsync -rtvn --delete --chmod=D755,F644 "/mnt/c/Projects/Web Portfolio/Version 1.6/" justin@10.10.40.10:/var/www/portfolio/
# read the list, then the same command without the n
```

Then purge the Cloudflare cache and check from outside.

---

## Facts

| Fact | Value |
|---|---|
| Source | `C:\Projects\Web Portfolio\Version <n>\`, flat, no subfolders. `Version 1.6` is current |
| Web root | `/var/www/portfolio`, owned `justin:justin`, mode `0755`, created by `roles/caddy` |
| File modes | Directories `755`, files `644`. Caddy reads them as world-readable; it never writes |
| Served by | Caddy `file_server` with `try_files {path} {path}.html`, so `/projects` serves `projects.html` |
| Not managed by | Ansible. A playbook run never touches content, and a deploy never touches config |

The web root is owned by `justin`, so the deploy needs no sudo.

---

## Step 1. Confirm the connection

**Run on: CONTROL NODE**

```bash
eval "$(ssh-agent -s)" && ssh-add /mnt/c/Users/garte/.ssh/id_ed25519   # skip if already loaded this window
command -v rsync || sudo apt install -y rsync
ssh justin@10.10.40.10 'hostname; systemctl is-active caddy; stat -c "%U:%G %a" /var/www/portfolio'
```

**Check:** prints `JG-RPi-WebServer`, `active`, and `justin:justin 755`.

---

## Step 2. Dry run

**Run on: CONTROL NODE**

```bash
SRC="/mnt/c/Projects/Web Portfolio/Version 1.6/"
rsync -rtvn --delete --chmod=D755,F644 "$SRC" justin@10.10.40.10:/var/www/portfolio/
```

Change `Version 1.6` to the version you are deploying.

- **The trailing slash on `SRC` matters.** Without it rsync copies the folder itself, and
  the site lands in `/var/www/portfolio/Version 1.6/`. The site then 404s.
- **`--delete` removes anything on the Pi that is not in the source.** That is the point:
  pages removed from the site stop being reachable by direct URL. Read the `deleting` lines.
- **`-rt` plus `--chmod`, not `-a`.** Modes on `/mnt/c` come from `wsl.conf`, not from
  anything meaningful. `-a` would copy them, and owner and group with them.

**Check:** the list shows the files you expect, and every `deleting` line is something you
meant to remove.

---

## Step 3. Deploy

**Run on: CONTROL NODE**

```bash
rsync -rtv --delete --chmod=D755,F644 "$SRC" justin@10.10.40.10:/var/www/portfolio/
```

**Check:** the summary line shows no errors, and this matches the source file count:

```bash
ls "$SRC" | wc -l
ssh justin@10.10.40.10 'ls /var/www/portfolio | wc -l'
```

---

## Step 4. Verify on the Pi

**Run on: CONTROL NODE**

```bash
ssh justin@10.10.40.10 "curl -sk -o /dev/null -w 'status=%{http_code} bytes=%{size_download}\n' --resolve justingarter.com:443:127.0.0.1 https://justingarter.com/"
```

- `--resolve` sends the request to loopback with the correct SNI. Without it, SNI is
  `127.0.0.1` and the handshake fails, because the certificate covers only
  `justingarter.com` and `*.justingarter.com`.
- `-k` is required. The Cloudflare Origin CA certificate is trusted by Cloudflare only, so
  `curl` on the Pi rejects the chain. That is expected and is not a fault. Cloudflare
  validates it for real on every request (Full (Strict)).

**Check:** `status=200` and a plausible byte count.

---

## Step 5. Purge the Cloudflare cache

Cloudflare caches aggressively. A stale page after a deploy is almost always cache.

**Run on: WORKSTATION**, Cloudflare dashboard: `justingarter.com` > **Caching** >
**Configuration** > **Purge Everything**.

**Check:** the dashboard confirms the purge.

---

## Step 6. Verify from outside

**Run on: WORKSTATION**

```powershell
curl.exe -s -o NUL -w "status=%{http_code} bytes=%{size_download}`n" https://justingarter.com/
```

Single `%`, not `%%`. `%%` is cmd escaping.

Then open the site in a browser and hard-refresh (Ctrl+F5). Click through to two or three
pages to confirm extensionless links resolve.

**Check:** `status=200`, and the browser shows the new version.

---

## If the site is down after a deploy

Work outward from the Pi.

**Run on: CONTROL NODE**

```bash
ssh justin@10.10.40.10 'systemctl is-active caddy; ls -la /var/www/portfolio | head'
ssh -t justin@10.10.40.10 'sudo journalctl -u caddy --since "10 minutes ago" --no-pager | tail -30'
```

| Finding | Cause |
|---|---|
| Web root contains a `Version 1.6` directory | Missing trailing slash in Step 2. Rerun with it, `--delete` cleans up |
| Every page but `/` is 404 | `try_files` missing from the Caddyfile. Run the playbook with `--tags caddy` |
| Caddy local 200, outside fails | Not content. DNS, Cloudflare, or the ingress path: [Recovery](recovery.md) |
| Caddy inactive | Not a deploy problem. A deploy cannot stop Caddy. [Recovery](recovery.md) |

**Do not restart Caddy to make content appear.** It reads from disk per request. If a
restart seems to help, the real cause was cache.

**Never run `sudo caddy validate` or `sudo caddy run` by hand.** Either creates
`/var/log/caddy/access.log` owned `root:root`, and the service, running as `caddy`, then
fails to open its own log. Repair: `sudo chown caddy:caddy /var/log/caddy/access.log &&
sudo systemctl restart caddy`.
