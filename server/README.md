# iWalk routing server

[Valhalla](https://github.com/valhalla/valhalla) plans pedestrian routes with elevation for Kenya. [Caddy](https://caddyserver.com) sits in front of it. Caddy gets a Let's Encrypt certificate automatically (iOS requires HTTPS) and forwards a request only if it carries the shared `X-iWalk-Key` header. Every other request gets `401`.

```
iPhone ──HTTPS──▶ Caddy :443 ──(X-iWalk-Key ok)──▶ valhalla:8002 (internal only)
```

| File | Purpose |
| --- | --- |
| `docker-compose.yml` | The `valhalla` and `caddy` services |
| `Caddyfile` | HTTPS site, key check, reverse proxy |
| `.env.example` | Template for `.env` (`IWALK_DOMAIN`, `IWALK_KEY`), which stays on the VPS and is git-ignored |
| `requests/*.json` | Fixed Mombasa route requests for the checks in step 6 |
| `custom_files/` | Created on the VPS. Holds the PBF, routing tiles and elevation tiles. Git-ignored |

Follow the steps in order on a fresh VPS. Commands in a box marked "on the VPS" run over SSH. The rest run on your Mac.

## 1. VPS sizing

- **OS:** Ubuntu 24.04 LTS
- **CPU / RAM:** 2 vCPU, **4 GB RAM**. The full-Kenya tile build needs this. A Mombasa-only clip (step 7) fits in 2 GB.
- **Disk:** **40 GB**. This covers the Kenya PBF, routing tiles, SRTM elevation tiles and headroom for rebuilds.
- **Region:** any provider; pick the one with the lowest latency to Kenya.
- Note the VPS's public IPv4 address. Below it is `203.0.113.10`; use yours.

## 2. Provision the server

Log in as root (or the provider's default user) with the SSH key you gave the provider. Create a non-root sudo user that logs in with the same key:

```bash
# on the VPS, as root
adduser iwalk
usermod -aG sudo iwalk
rsync --archive --chown=iwalk:iwalk ~/.ssh /home/iwalk
```

From a **second terminal**, check that `ssh iwalk@203.0.113.10` works and `sudo -v` accepts the password before you go on. Then turn off password and root logins:

```bash
# on the VPS
printf 'PasswordAuthentication no\nPermitRootLogin no\n' | sudo tee /etc/ssh/sshd_config.d/00-iwalk.conf
sudo sshd -t && sudo systemctl restart ssh
```

The `00-` prefix matters: sshd uses the first value it reads, so this file wins over the provider's `50-cloud-init.conf`.

Open only SSH, HTTP and HTTPS (HTTP/3 uses 443/udp), then turn on the firewall:

```bash
# on the VPS
sudo ufw allow 22,80,443/tcp
sudo ufw allow 443/udp
sudo ufw enable
sudo ufw status
```

> Ports that Docker publishes bypass ufw. That's why Valhalla's port 8002 is only `expose`d to the compose network and never published. Keep it that way.

Optional but sensible: `sudo apt update && sudo apt upgrade -y`, then reboot.

## 3. Install Docker Engine and the compose plugin

Use Docker's own apt repository (Ubuntu's `docker.io` package lags behind and has no compose plugin):

```bash
# on the VPS
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"
```

Log out and back in so the `docker` group applies, then check:

```bash
# on the VPS
docker version
docker compose version
```

## 4. Copy `server/` over and create `.env`

From the repo root on your Mac (this skips any local `.env` and `custom_files/`):

```bash
rsync -av --exclude .env --exclude custom_files server/ iwalk@203.0.113.10:~/iwalk-server/
```

(Or `git clone` the repo on the VPS and work in its `server/` folder.)

On the VPS, create the data folder and `.env`:

```bash
# on the VPS
cd ~/iwalk-server
mkdir -p custom_files
cp .env.example .env
chmod 600 .env
openssl rand -hex 32   # copy the output into IWALK_KEY
nano .env
```

Set the two values:

- `IWALK_DOMAIN`: either a domain whose **A record points to the VPS IP** (check with `dig +short your.domain` from your Mac), or the free `<ip>.sslip.io` name, which resolves to that IP with no DNS setup, for example `203.0.113.10.sslip.io`.
- `IWALK_KEY`: the 64-character hex string from `openssl rand -hex 32`. Never leave it empty or as `change-me`.

Ports 80 and 443 must be reachable from the internet (step 2) so Let's Encrypt can verify the domain.

## 5. Start it and wait for the build

```bash
# on the VPS, in ~/iwalk-server
docker compose config --quiet   # silent means the files and .env are valid
docker compose up -d
docker compose logs -f valhalla
```

`docker compose config --quiet` stops with an error if `IWALK_DOMAIN` or `IWALK_KEY` is missing or empty. (Without `--quiet` it prints the resolved config, key included, so don't paste that output anywhere.)

On the first start Valhalla downloads the Kenya PBF, downloads the SRTM elevation tiles for its area, and builds the routing tiles, admin areas, time zones and the tile tarball. **Expect tens of minutes.** Leave `logs -f` running until the build steps stop and the service starts, then press Ctrl-C (the containers keep running). Until then, authorised requests get `502` from Caddy.

If the log shows `Permission denied` on `/custom_files`, give the folder to the user the image runs as, then restart:

```bash
# on the VPS
docker run --rm --entrypoint id ghcr.io/valhalla/valhalla-scripted:latest   # note uid and gid
sudo chown -R <uid>:<gid> custom_files
docker compose restart valhalla
```

Caddy requests the certificate on start. Check it with `docker compose logs caddy | grep -i certificate`. With sslip.io a Let's Encrypt rate limit is possible on busy days. If the certificate fails for that reason, use a real domain.

Check the build is done from the VPS itself:

```bash
# on the VPS
set -a; . ./.env; set +a
curl -s -H "X-iWalk-Key: $IWALK_KEY" "https://$IWALK_DOMAIN/status"
```

A JSON reply with a `version` field means Valhalla is up behind Caddy.

## 6. Checks from a phone hotspot

Run these on your Mac **tethered to a phone's mobile hotspot** (not home Wi-Fi), so the test goes over the same kind of network the iPhone will use. You need `jq` (`brew install jq`). From the `server/` folder of the repo:

```bash
export DOMAIN=203.0.113.10.sslip.io   # your IWALK_DOMAIN
export KEY=paste-the-key-from-.env    # your IWALK_KEY
```

**Route with elevation: Fort Jesus → Mama Ngina Drive**

```bash
curl -s -H "X-iWalk-Key: $KEY" https://$DOMAIN/route --data @requests/fort-jesus-mama-ngina.json | jq '.trip.summary, (.trip.legs[0].elevation|length)'
```

Expect a `summary` object with `length` (km) and `time` (seconds), followed by a number greater than 0. That number is the count of elevation samples, one every 30 m along the route, in metres. `trip.legs[].shape` is an encoded polyline with 6-digit precision (polyline6).

**Nyali loop**

```bash
curl -s -H "X-iWalk-Key: $KEY" https://$DOMAIN/route --data @requests/nyali-loop.json | jq '.trip.summary, (.trip.legs[0].elevation|length)'
```

The start and end are the same point and the middle points are `through` stops, so the loop comes back as a single leg.

**Haller Park hike (hike costing)**

```bash
curl -s -H "X-iWalk-Key: $KEY" https://$DOMAIN/route --data @requests/haller-park-hike.json | jq '.trip.summary, (.trip.legs[0].elevation|length)'
```

Uses the app's hike settings: `max_hiking_difficulty` 4, `use_tracks` 1.0, `use_hills` 0.8.

The coordinates in `requests/` are approximate; Valhalla snaps each one to the nearest walkable way. **Write down the three `length` values** as baselines. After a rebuild, or when the app plans the same routes, the distances should match.

**Negative checks: no key, wrong key, internal port**

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://$DOMAIN/route --data @requests/fort-jesus-mama-ngina.json
```

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H "X-iWalk-Key: wrong" https://$DOMAIN/route --data @requests/fort-jesus-mama-ngina.json
```

Both must print `401`.

```bash
curl -s -m 5 http://$DOMAIN:8002/status || echo "8002 closed (good)"
```

This must time out or be refused. If it returns JSON, port 8002 has been published by mistake.

**Hand the values to the app:** put the base URL (`https://<IWALK_DOMAIN>`) and the key into `ios/Config/Local.xcconfig` as `IWALK_BASE_URL` and `IWALK_API_KEY`. That file is git-ignored; never commit the key. In an `.xcconfig`, `//` starts a comment, so write the URL as `https:/$()/your.domain`.

## 7. Maintenance

All commands run on the VPS in `~/iwalk-server`.

**Rebuild after OpenStreetMap edits.** Geofabrik refreshes the Kenya extract daily. To pick up new edits:

1. Delete the old extract so a fresh one is downloaded: `rm custom_files/kenya-latest.osm.pbf`
2. In `docker-compose.yml`, set `force_rebuild: "True"`.
3. `docker compose up -d valhalla` (recreates the container with the new setting), then `docker compose logs -f valhalla` until the build finishes.
4. Set `force_rebuild: "False"` again and run `docker compose up -d valhalla`. Otherwise every restart rebuilds.
5. Re-run the step 6 checks and compare distances with the baselines.

**Clip to Mombasa if RAM is tight** (for example on a 2 GB VPS, or if the Kenya build gets killed for running out of memory):

```bash
# on the VPS
sudo apt-get install -y osmium-tool
osmium extract -b 39.3,-4.4,39.9,-3.7 custom_files/kenya-latest.osm.pbf -o custom_files/mombasa.osm.pbf
mkdir -p ~/pbf-archive && mv custom_files/kenya-latest.osm.pbf ~/pbf-archive/
```

The image builds from every `.pbf` in `custom_files`, which is why the Kenya file is moved out. Then in `docker-compose.yml`, **remove the `tile_urls` line** (otherwise it downloads Kenya again), set `force_rebuild: "True"`, and rebuild as in steps 3–5 above. The box `39.3,-4.4,39.9,-3.7` (west, south, east, north) covers Mombasa island, Nyali, Bamburi, Likoni and Diani. If you have no Kenya file on the VPS yet, download it first with `curl -LO https://download.geofabrik.de/africa/kenya-latest.osm.pbf`.

**Other routine tasks**

- Update images: `docker compose pull && docker compose up -d` (Valhalla reuses the built tiles; `use_tiles_ignore_pbf` stops it rebuilding).
- Rotate the key: put a new `openssl rand -hex 32` into `.env`, run `docker compose up -d caddy`, then update `ios/Config/Local.xcconfig` and rebuild the app.
- Disk use: `docker system df` and `du -sh custom_files`. Container logs are capped at 3 × 10 MB per service.
- Status: `docker compose ps`.
