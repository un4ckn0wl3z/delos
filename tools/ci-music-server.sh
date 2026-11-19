#!/usr/bin/env bash
# Start a throw-away StreamMKV server on :8090 with a small music library (for the emulator test).
set -eu
command -v ffmpeg >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq ffmpeg >/dev/null; }
go build -o /tmp/smkv .
M=/tmp/ci-music/Test\ Artist/Test\ Album; mkdir -p "$M" /tmp/ci-movies /tmp/ci-data
for i in 1 2 3; do
  ffmpeg -v error -y -f lavfi -i "sine=frequency=$((300+i*110)):duration=240" -c:a libmp3lame -b:a 128k \
    -metadata title="Track $i" -metadata artist="Test Artist" -metadata album="Test Album" -metadata track=$i "$M/0$i Track $i.mp3"
done
nohup /tmp/smkv -root /tmp/ci-movies -listen :8090 -user ci -pass ci-pass-123 -data /tmp/ci-data -cache /tmp/ci-data -tls off > /tmp/smkv.log 2>&1 &
for i in $(seq 1 30); do curl -sf http://127.0.0.1:8090/ >/dev/null && break; sleep 1; done
J=/tmp/ci-cookies
curl -sf -c $J -H 'Content-Type: application/json' -d '{"username":"ci","password":"ci-pass-123"}' http://127.0.0.1:8090/api/login >/dev/null
curl -sf -b $J -H 'Content-Type: application/json' -d '{"name":"Music","type":"music","path":"/tmp/ci-music"}' http://127.0.0.1:8090/api/admin/libraries
sleep 5
curl -sf -b $J http://127.0.0.1:8090/api/libraries; echo
