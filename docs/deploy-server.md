# Deploy the iWalk routing server

Instructions for a deployment agent. Deploy Valhalla (pedestrian routing for Kenya, with elevation) behind Caddy (automatic HTTPS + shared-key check) on a fresh Ubuntu VPS, verify it, and report the URL back.

```
iPhone ──HTTPS──▶ Caddy :443 ──(X-iWalk-Key ok)──▶ valhalla:8002 (internal only)
```

## Inputs (ask the user for anything missing)

| Input | Example | Notes |
|---|---|---|
| VPS public IPv4 | `203.0.113.10` | Ubuntu 24.04, 2 vCPU, **4 GB RAM**, **40 GB disk** |
| SSH access | `ssh root@203.0.113.10` or an alias | Key-based. Never ask for or handle passwords in chat |
| Domain | `routes.example.com`, or none | If none, use `<ip>.sslip.io` (e.g. `203.0.113.10.sslip.io`). A real domain needs an A record pointing at the VPS first |
| Repository | `https://github.com/achingachris/iWalk.git` | Public. The server files are in `server/` |
| Branch | `main` | Use the branch the user names, if any |

## Rules

- **Never print, log or commit the value of `IWALK_KEY`** except once, in your final report to the user. Don't paste `docker compose config` output without `--quiet` anywhere (it contains the key).
- **Never commit `server/.env`** or push anything to the repository. This task changes the VPS only.
- **Never publish port 8002.** Valhalla stays `expose`d on the compose network only. Docker-published ports bypass `ufw`.
- **Don't lock yourself out.** Before turning off password/root SSH logins, confirm the new user can log in with the key and use `sudo` from a second session.
- If ports 80/443 are already in use on the VPS (another web server or proxy), **stop and report** rather than replacing it.
- If a step fails, stop, report the exact error and the step, and don't improvise destructive fixes (no `rm -rf` of data you didn't create, no firewall reset).

## Steps

### 1. Preflight

```bash
# on the VPS
lsb_release -ds            # expect Ubuntu 24.04
nproc; free -h; df -h /    # expect ≥2 CPU, ≥4 GB RAM (or 2 GB + Mombasa clip, step 8), ≥40 GB free
sudo ss -tlnp | grep -E ':(80|443)\s' || echo "80/443 free"
```

### 2. Provision (skip parts already done)

```bash
# on the VPS, as root
adduser --disabled-password --gecos "" iwalk
usermod -aG sudo iwalk
rsync --archive --chown=iwalk:iwalk ~/.ssh /home/iwalk
passwd iwalk   # the user sets a sudo password; you don't need to know it if the user runs this
```

Check from a second session that `ssh iwalk@<ip>` works and `sudo -v` succeeds. Then:

```bash
# on the VPS
printf 'PasswordAuthentication no\nPermitRootLogin no\n' | sudo tee /etc/ssh/sshd_config.d/00-iwalk.conf
sudo sshd -t && sudo systemctl restart ssh
sudo ufw allow 22,80,443/tcp
sudo ufw allow 443/udp
sudo ufw --force enable
sudo ufw status
```

### 3. Install Docker Engine + compose plugin (Docker's apt repo)

```bash
# on the VPS
sudo apt-get update
sudo apt-get install -y ca-certificates curl git
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"
```

Log out and back in, then check `docker version` and `docker compose version`.

### 4. Get the server files

```bash
# on the VPS
git clone --branch main https://github.com/achingachris/iWalk.git ~/iWalk
cd ~/iWalk/server
mkdir -p custom_files
```

### 5. Create `.env`

```bash
# on the VPS, in ~/iWalk/server
cp .env.example .env
chmod 600 .env
KEY=$(openssl rand -hex 32)
DOMAIN=<domain-or-ip.sslip.io>
sed -i "s|^IWALK_DOMAIN=.*|IWALK_DOMAIN=$DOMAIN|; s|^IWALK_KEY=.*|IWALK_KEY=$KEY|" .env
unset KEY
grep -c '^IWALK_KEY=[0-9a-f]\{64\}$' .env   # must print 1
```

### 6. Start and wait for the tile build

```bash
# on the VPS, in ~/iWalk/server
docker compose config --quiet    # silent = valid; errors if IWALK_DOMAIN/IWALK_KEY missing
docker compose up -d
docker compose logs -f valhalla  # wait until the build finishes and the service starts (tens of minutes)
```

- First start downloads the Kenya PBF and SRTM elevation tiles, then builds the routing tiles. Until it finishes, authorised requests get `502`.
- `Permission denied` on `/custom_files`: run `docker run --rm --entrypoint id ghcr.io/valhalla/valhalla-scripted:latest`, then `sudo chown -R <uid>:<gid> custom_files` and `docker compose restart valhalla`.
- Build killed for memory (`Killed`, exit 137): do the Mombasa clip in step 8.
- Certificate: `docker compose logs caddy | grep -i certificate`. If sslip.io hits a Let's Encrypt rate limit, report it; the user can supply a real domain.

### 7. Verify

On the VPS:

```bash
cd ~/iWalk/server
set -a; . ./.env; set +a
curl -s -H "X-iWalk-Key: $IWALK_KEY" "https://$IWALK_DOMAIN/status" | head -c 300; echo
curl -s -H "X-iWalk-Key: $IWALK_KEY" "https://$IWALK_DOMAIN/route" --data @requests/fort-jesus-mama-ngina.json \
  | python3 -c 'import json,sys; t=json.load(sys.stdin)["trip"]; print("km", t["summary"]["length"], "elev samples", len(t["legs"][0].get("elevation", [])))'
curl -s -H "X-iWalk-Key: $IWALK_KEY" "https://$IWALK_DOMAIN/route" --data @requests/nyali-loop.json \
  | python3 -c 'import json,sys; print("km", json.load(sys.stdin)["trip"]["summary"]["length"])'
curl -s -H "X-iWalk-Key: $IWALK_KEY" "https://$IWALK_DOMAIN/route" --data @requests/haller-park-hike.json \
  | python3 -c 'import json,sys; print("km", json.load(sys.stdin)["trip"]["summary"]["length"])'
curl -s -o /dev/null -w 'no key: %{http_code}\n' "https://$IWALK_DOMAIN/route" --data @requests/fort-jesus-mama-ngina.json
curl -s -o /dev/null -w 'wrong key: %{http_code}\n' -H "X-iWalk-Key: wrong" "https://$IWALK_DOMAIN/route" --data @requests/fort-jesus-mama-ngina.json
```

From a machine **outside** the VPS:

```bash
curl -s -m 5 http://<domain>:8002/status && echo "FAIL: 8002 is open" || echo "8002 closed (good)"
curl -s -o /dev/null -w '%{http_code}\n' https://<domain>/route   # expect 401
```

**Success criteria (all must hold):**

- [ ] `/status` returns JSON with a `version` field.
- [ ] Fort Jesus → Mama Ngina returns a distance in km and **more than 0** elevation samples.
- [ ] Nyali loop and Haller Park hike each return a distance. (Their coordinates are approximate; Valhalla snaps them to the nearest path.)
- [ ] No key and wrong key both return `401`.
- [ ] Port 8002 is not reachable from outside.
- [ ] `docker compose ps` shows both services running with restart policy `unless-stopped`.

### 8. Only if RAM is too small: clip to Mombasa

```bash
# on the VPS, in ~/iWalk/server
sudo apt-get install -y osmium-tool
docker compose stop valhalla
[ -f custom_files/kenya-latest.osm.pbf ] || curl -L -o custom_files/kenya-latest.osm.pbf https://download.geofabrik.de/africa/kenya-latest.osm.pbf
osmium extract -b 39.3,-4.4,39.9,-3.7 custom_files/kenya-latest.osm.pbf -o custom_files/mombasa.osm.pbf
mkdir -p ~/pbf-archive && mv custom_files/kenya-latest.osm.pbf ~/pbf-archive/
```

Then in `docker-compose.yml` remove the `tile_urls` line and set `force_rebuild: "True"`, run `docker compose up -d valhalla`, wait for the build, set `force_rebuild: "False"` again and run `docker compose up -d valhalla`. These are local edits on the VPS only; don't commit them. Re-run step 7.

## Report back to the user

Reply with:

1. **Base URL:** `https://<IWALK_DOMAIN>`
2. **API key:** the 64-character `IWALK_KEY` (only here, nowhere else). Say it's also stored in `~/iWalk/server/.env` on the VPS.
3. **What to put in `ios/Config/Local.xcconfig`** (the `$()` is required because `//` starts a comment in xcconfig):
   ```
   IWALK_BASE_URL = https:/$()/<IWALK_DOMAIN>
   IWALK_API_KEY = <the key>
   ```
4. The three distances from step 7 (baselines for later rebuilds).
5. Whether the full Kenya build or the Mombasa clip is running.
6. Anything that failed or was skipped, with the exact error.

## Maintenance (for later, not part of this task)

See `server/README.md` section 7: rebuilding after OpenStreetMap edits, updating images, rotating the key.
