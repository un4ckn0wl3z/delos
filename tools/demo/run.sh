#!/bin/bash
# Demo server for README screenshots: ./run.sh (fresh) or ./run.sh keep
# Needs: go build -o /tmp/streammkv-demo . (repo root), python3 + Pillow, ffmpeg, playwright + Chrome.
DEMO="$(cd "$(dirname "$0")" && pwd)"
# fresh demo server on :8097 with the fake TMDB on :9930
pkill -f "listen 127.0.0.1:8097" ; pkill -f "tmdb.py 9930" ; sleep 1
[ "$1" = keep ] || rm -rf /tmp/demo-data; mkdir -p /tmp/demo-data /tmp/demo-home
(cd $DEMO && python3 tmdb.py 9930 >/tmp/demo-tmdb.log 2>&1 &)
(HOME=/tmp/demo-home STREAMMKV_TMDB_URL=http://127.0.0.1:9930/3 STREAMMKV_MB_URL=http://127.0.0.1:9930 STREAMMKV_CAA_URL=http://127.0.0.1:9930 STREAMMKV_UPDATE_URL=http://127.0.0.1:9 \
  /tmp/streammkv-demo -root /tmp/demo/media/Movies -listen 127.0.0.1:8097 -user mira -pass demo-pass-1 -data /tmp/demo-data -cache /tmp/demo-data >/tmp/demo-srv.log 2>&1 &)
sleep 3
