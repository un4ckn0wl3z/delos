#!/usr/bin/env bash
# Smoke-test a built StreamMKV image: web app, login, ffmpeg/ffprobe, the
# built-in rtorrent, a library scan and probing a real file.
#   tools/docker-smoke.sh IMAGE
set -euo pipefail
IMG="${1:?usage: docker-smoke.sh IMAGE}"
W=$(mktemp -d); mkdir -p "$W/media/Smoke Test (2020)" "$W/data"
chmod -R 777 "$W"
cleanup() { docker logs smkv-smoke 2>&1 | tail -40; docker rm -f smkv-smoke >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker run -d --name smkv-smoke -p 18090:8090 -e PUID="$(id -u)" -e PGID="$(id -g)" \
  -v "$W/media:/media" -v "$W/data:/data" "$IMG" >/dev/null
B=http://127.0.0.1:18090
for _ in $(seq 1 60); do curl -fs "$B/" >/dev/null && break; sleep 1; done
curl -fs "$B/" | grep -q 'app.js' || { echo "::error::web app not served"; exit 1; }
curl -fs "$B/vendor/mediabunny.min.mjs" -o /dev/null || { echo "::error::vendor files missing"; exit 1; }
PASS=$(docker logs smkv-smoke 2>&1 | sed -n 's/.*password : //p' | head -1)
[ -n "$PASS" ] || { echo "::error::no first-start password in the logs"; exit 1; }
TOK=$(curl -fs -XPOST "$B/api/login" -d "{\"username\":\"admin\",\"password\":\"$PASS\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
H="Authorization: Bearer $TOK"
curl -fs "$B/api/me" -H "$H" | grep -q '"admin":true' || { echo "::error::login failed"; exit 1; }
# the image's ffmpeg makes a small test movie in the library
docker exec -u "$(id -u):$(id -g)" smkv-smoke ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=320x180:rate=24:duration=5 \
  -f lavfi -i sine=duration=5 -c:v libx264 -preset ultrafast -c:a ac3 "/media/Smoke Test (2020)/Smoke Test (2020).mkv"
LIB=$(curl -fs "$B/api/libraries" -H "$H" | python3 -c 'import sys,json;d=json.load(sys.stdin);d=d.get("libraries",d);print(d[0]["id"])')
curl -fs -XPOST "$B/api/admin/libraries/$LIB/scan" -H "$H" >/dev/null || true
for _ in $(seq 1 30); do curl -fs "$B/api/lib/$LIB" -H "$H" | grep -q 'Smoke Test' && break; sleep 1; done
curl -fs "$B/api/lib/$LIB" -H "$H" | grep -q 'Smoke Test' || { echo "::error::scan didn't find the file"; exit 1; }
curl -fs "$B/api/probe?path=$(python3 -c "import urllib.parse;print(urllib.parse.quote('$LIB/Smoke Test (2020)/Smoke Test (2020).mkv'))")" -H "$H" | grep -q '"ac3"' \
  || { echo "::error::ffprobe failed"; exit 1; }
# the built-in rtorrent answers
for _ in $(seq 1 20); do curl -fs "$B/api/admin/torrents" -H "$H" | grep -q '"ok":true' && break; sleep 1; done
curl -fs "$B/api/admin/torrents" -H "$H" | grep -q '"ok":true' || { echo "::error::built-in rtorrent not reachable"; curl -s "$B/api/admin/torrents" -H "$H"; exit 1; }
# files are owned by PUID:PGID
OWN=$(stat -c '%u:%g' "$W/media/Smoke Test (2020)/Smoke Test (2020).mkv")
[ "$OWN" = "$(id -u):$(id -g)" ] || { echo "::error::files owned by $OWN"; exit 1; }
echo "smoke test passed"
