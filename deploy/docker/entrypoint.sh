#!/bin/sh
# Runs StreamMKV (and, unless RTORRENT=0, a built-in rtorrent) as PUID:PGID,
# so files written to /media belong to your user on the host.
set -e

PUID="${PUID:-1000}"; PGID="${PGID:-1000}"
if ! getent group "$PGID" >/dev/null 2>&1; then addgroup -g "$PGID" smkv; fi
GROUP="$(getent group "$PGID" | cut -d: -f1)"
if ! getent passwd "$PUID" >/dev/null 2>&1; then adduser -D -H -u "$PUID" -G "$GROUP" -h /data/home smkv; fi
USERNAME="$(getent passwd "$PUID" | cut -d: -f1)"
export HOME=/data/home

mkdir -p /data/home /data/cache "${STREAMMKV_USER_LIBS:-/media/personal}"
chown "$PUID:$PGID" /data /data/home /data/cache 2>/dev/null || true
chown "$PUID:$PGID" "${STREAMMKV_USER_LIBS:-/media/personal}" 2>/dev/null || true

# first start without users: make an admin with a random password (printed below)
if [ ! -s /data/users.json ] && [ -z "${STREAMMKV_PASS:-}" ]; then
  export STREAMMKV_USER="${STREAMMKV_USER:-admin}"
  STREAMMKV_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)"
  export STREAMMKV_PASS
  echo "=================================================================="
  echo " StreamMKV first start — admin user: $STREAMMKV_USER"
  echo "                        password : $STREAMMKV_PASS"
  echo " (change it in the dashboard → My account)"
  echo "=================================================================="
fi

if [ "${RTORRENT:-1}" != "0" ] && [ -z "${STREAMMKV_RTORRENT:-}" ]; then
  RT=/data/rtorrent
  mkdir -p "$RT/session" "${RTORRENT_DIR:-/media/downloads}"
  if [ ! -f "$RT/rtorrent.rc" ]; then
    cat > "$RT/rtorrent.rc" <<RC
# StreamMKV's built-in rtorrent (edit freely; kept across restarts)
session.path.set = $RT/session/
directory.default.set = ${RTORRENT_DIR:-/media/downloads}
network.scgi.open_local = $RT/rpc.socket
execute.nothrow = chmod,770,$RT/rpc.socket
network.port_range.set = ${RTORRENT_PORT:-50000}-${RTORRENT_PORT:-50000}
network.port_random.set = no
dht.mode.set = auto
dht.port.set = ${RTORRENT_DHT_PORT:-6881}
protocol.pex.set = yes
trackers.use_udp.set = yes
protocol.encryption.set = allow_incoming,try_outgoing,enable_retry
throttle.max_uploads.global.set = 100
throttle.max_downloads.global.set = 300
pieces.hash.on_completion.set = no
system.umask.set = 0002
system.daemon.set = true
RC
  fi
  chown -R "$PUID:$PGID" "$RT" "${RTORRENT_DIR:-/media/downloads}" 2>/dev/null || true
  # keep it running (restart if it exits)
  (while true; do
     rm -f "$RT/rpc.socket" "$RT/session/rtorrent.lock"
     su-exec "$PUID:$PGID" rtorrent -n -o "import=$RT/rtorrent.rc" </dev/null >>"$RT/rtorrent.log" 2>&1
     echo "rtorrent exited ($?) — restarting in 5 s" >>"$RT/rtorrent.log"; sleep 5
   done) &
  export STREAMMKV_RTORRENT="$RT/rpc.socket"
  for _ in $(seq 1 50); do [ -S "$RT/rpc.socket" ] && break; sleep 0.2; done
  [ -S "$RT/rpc.socket" ] && echo "rtorrent ready ($RT/rpc.socket, peers on port ${RTORRENT_PORT:-50000})" || echo "warning: rtorrent didn't start"
fi

if [ "$1" = "streammkv" ]; then
  shift
  exec su-exec "$PUID:$PGID" /usr/local/bin/streammkv "$@"
fi
exec "$@"
