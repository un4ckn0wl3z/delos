#!/usr/bin/env bash
# Delos installer for seedboxes — no root, no package manager.
#
#   curl -fsSL https://raw.githubusercontent.com/un4ckn0wl3z/delos/main/deploy/install.sh \
#     | MEDIA_ROOT=$HOME/torrents bash
#
# Env (all optional):
#   MEDIA_ROOT      folder with your .mkv files          (default: $HOME/torrents)
#   PORT            listen port                          (default: random free port 20000-39999, kept on re-install)
#   SMKV_USER       login username                       (default: $USER)
#   SMKV_PASS       login password                       (default: random, kept on re-install)
#   SMKV_DIR        install dir                          (default: $HOME/streammkv)
#   SMKV_VERSION    release tag                          (default: latest)
#   SMKV_BINARY     use this local binary instead of downloading
#   INSTALL_RTORRENT 1 = install rtorrent (static build) when none is found, 0 = don't
#                   (default: ask; without a terminal, don't)
#
# Re-running upgrades the binary and keeps port / password / secret.
set -euo pipefail

REPO="un4ckn0wl3z/delos"
DIR="${SMKV_DIR:-$HOME/streammkv}"
BIN="$DIR/bin"
ENVF="$DIR/streammkv.env"
say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

fetch() { # url dest
  if command -v curl >/dev/null 2>&1; then curl -fL --retry 3 --progress-bar -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then wget -q -O "$2" "$1"
  else die "need curl or wget"; fi
}

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

mkdir -p "$BIN"
chmod 700 "$DIR"

# keep previous settings on re-install
if [ -f "$ENVF" ]; then
  # shellcheck disable=SC1090
  . "$ENVF"
fi

MEDIA_ROOT="${MEDIA_ROOT:-${STREAMMKV_ROOT:-$HOME/torrents}}"
MEDIA_ROOT="${MEDIA_ROOT/#\~/$HOME}"
[ -d "$MEDIA_ROOT" ] || die "MEDIA_ROOT '$MEDIA_ROOT' does not exist"

# ---------------------------------------------------------------- streammkv binary
if [ -n "${SMKV_BINARY:-}" ]; then
  say "Using local binary $SMKV_BINARY"
  cp "$SMKV_BINARY" "$BIN/streammkv.new"
else
  if [ -n "${SMKV_VERSION:-}" ]; then
    URL="https://github.com/$REPO/releases/download/$SMKV_VERSION/streammkv-linux-$ARCH"
  else
    URL="https://github.com/$REPO/releases/latest/download/streammkv-linux-$ARCH"
  fi
  say "Downloading streammkv ($ARCH)"
  fetch "$URL" "$BIN/streammkv.new"
fi
chmod +x "$BIN/streammkv.new"
mv -f "$BIN/streammkv.new" "$BIN/streammkv"

# ---------------------------------------------------------------- ffmpeg / ffprobe (static)
FFMPEG="" FFPROBE=""
if [ -x "$BIN/ffmpeg" ] && [ -x "$BIN/ffprobe" ]; then
  FFMPEG="$BIN/ffmpeg" FFPROBE="$BIN/ffprobe"
elif command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 \
     && ffmpeg -hide_banner -encoders 2>/dev/null | grep libx264 >/dev/null; then
  FFMPEG="$(command -v ffmpeg)" FFPROBE="$(command -v ffprobe)"
  say "Using system ffmpeg: $FFMPEG"
else
  say "Downloading static ffmpeg"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  ok=0
  for u in "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-$ARCH-static.tar.xz" \
           "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux$([ $ARCH = amd64 ] && echo 64 || echo arm64)-gpl.tar.xz"; do
    if fetch "$u" "$TMP/ff.tar.xz" && tar -xJf "$TMP/ff.tar.xz" -C "$TMP"; then ok=1; break; fi
    echo "  (failed: $u)"
  done
  [ $ok = 1 ] || die "could not download ffmpeg (is xz available for tar -J?)"
  f=$(find "$TMP" -type f -name ffmpeg -perm -u+x | head -1)
  p=$(find "$TMP" -type f -name ffprobe -perm -u+x | head -1)
  [ -n "$f" ] && [ -n "$p" ] || die "ffmpeg/ffprobe not found in archive"
  cp "$f" "$p" "$BIN/"
  FFMPEG="$BIN/ffmpeg" FFPROBE="$BIN/ffprobe"
fi
"$FFMPEG" -hide_banner -version 2>/dev/null | head -1 || true

# ---------------------------------------------------------------- rtorrent (for torrent downloads)
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
RT_DIR="$DIR/rtorrent"
RT_SOCK="${STREAMMKV_RTORRENT:-}"
have_rtorrent() {
  pgrep -u "$(id -u)" -x rtorrent >/dev/null 2>&1 || command -v rtorrent >/dev/null 2>&1 \
    || [ -f "$HOME/.rtorrent.rc" ] || [ -f "$HOME/.config/rtorrent/rtorrent.rc" ]
}
if [ -f "$RT_DIR/rtorrent.rc" ]; then
  say "Updating the rtorrent installed by Delos"
  WANT_RT=1
elif have_rtorrent; then
  say "Found rtorrent on this machine — Delos will use it for torrents"
  WANT_RT=0
else
  WANT_RT="${INSTALL_RTORRENT:-}"
  if [ -z "$WANT_RT" ]; then
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
      printf '\033[1;36m==>\033[0m rtorrent was not found. Install it (no root needed) so Delos can download torrents? [Y/n] ' >/dev/tty
      read -r ans </dev/tty || ans=n
      case "$ans" in n|N|no|NO) WANT_RT=0 ;; *) WANT_RT=1 ;; esac
    else
      WANT_RT=0
      echo "  (rtorrent not found; re-run with INSTALL_RTORRENT=1 to install it — http and YouTube downloads work without it)"
    fi
  fi
fi
if [ "$WANT_RT" = 1 ]; then
  # fully static rTorrent 0.9.8 builds (github.com/jesec/rtorrent), amd64 + arm64
  say "Downloading rtorrent ($ARCH)"
  fetch "https://github.com/jesec/rtorrent/releases/latest/download/rtorrent-linux-$ARCH" "$BIN/rtorrent.new" \
    || die "could not download rtorrent; re-run with INSTALL_RTORRENT=0 to skip it"
  chmod +x "$BIN/rtorrent.new"
  mv -f "$BIN/rtorrent.new" "$BIN/rtorrent"
  mkdir -p "$RT_DIR/session" "$MEDIA_ROOT/downloads"
  RT_PORT="$(cat "$RT_DIR/port" 2>/dev/null || true)"
  if [ -z "$RT_PORT" ]; then
    for _ in $(seq 1 50); do c=$(( 40000 + RANDOM % 20000 )); port_busy "$c" || { RT_PORT=$c; break; }; done
    echo "$RT_PORT" >"$RT_DIR/port"
  fi
  cat > "$RT_DIR/rtorrent.rc" <<EOF
# written by the Delos installer — edit freely, it is kept on re-install unless you delete it
directory.default.set = $MEDIA_ROOT/downloads
session.path.set = $RT_DIR/session
network.scgi.open_local = $RT_DIR/rtorrent.sock
system.daemon.set = true
network.port_range.set = $RT_PORT-$RT_PORT
network.port_random.set = no
dht.mode.set = auto
dht.port.set = $RT_PORT
protocol.pex.set = yes
trackers.use_udp.set = yes
throttle.max_uploads.set = 100
throttle.max_uploads.global.set = 250
throttle.min_peers.normal.set = 20
throttle.max_peers.normal.set = 80
pieces.hash.on_completion.set = no
encoding.add = utf8
schedule2 = session_save, 1200, 1200, ((session.save))
EOF
  RT_SOCK="$RT_DIR/rtorrent.sock"
fi

# ---------------------------------------------------------------- config
if [ -z "${PORT:-}" ]; then
  PORT="${STREAMMKV_LISTEN:-}"; PORT="${PORT##*:}"
fi
if [ -z "${PORT:-}" ]; then
  for _ in $(seq 1 50); do
    c=$(( 20000 + RANDOM % 20000 ))
    port_busy "$c" || { PORT=$c; break; }
  done
fi
[ -n "${PORT:-}" ] || die "no free port found; set PORT=..."

rand() { LC_ALL=C tr -dc "$1" </dev/urandom 2>/dev/null | head -c "$2" || true; }
USER_NAME="${SMKV_USER:-${STREAMMKV_USER:-${USER:-admin}}}"
PASS="${SMKV_PASS:-${STREAMMKV_PASS:-$(rand 'A-Za-z0-9' 20)}}"
SECRET="${STREAMMKV_SECRET:-$(rand 'a-f0-9' 64)}"

umask 077
cat > "$ENVF" <<EOF
STREAMMKV_ROOT='$MEDIA_ROOT'
STREAMMKV_LISTEN=':$PORT'
STREAMMKV_USER='$USER_NAME'
STREAMMKV_PASS='$PASS'
STREAMMKV_SECRET='$SECRET'
STREAMMKV_FFMPEG='$FFMPEG'
STREAMMKV_FFPROBE='$FFPROBE'
STREAMMKV_CACHE='$DIR/cache'
STREAMMKV_DATA='$DIR/data'
EOF
[ -n "$RT_SOCK" ] && echo "STREAMMKV_RTORRENT='$RT_SOCK'" >>"$ENVF"
umask 022

FIRST_INSTALL=1
[ -f "$DIR/data/users.json" ] && FIRST_INSTALL=0

# ---------------------------------------------------------------- run script
cat > "$DIR/run.sh" <<'EOF'
#!/usr/bin/env bash
# usage: run.sh [start|stop|restart|status|ensure|version|user ...]
DIR="$(cd "$(dirname "$0")" && pwd)"
PID="$DIR/streammkv.pid"
RT="$DIR/rtorrent"
running() { [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; }
# rtorrent installed by the installer (if any): started and watched together with Delos
rt_running() { [ -f "$RT/rtorrent.pid" ] && kill -0 "$(cat "$RT/rtorrent.pid")" 2>/dev/null; }
rt_start() {
  [ -f "$RT/rtorrent.rc" ] && [ -x "$DIR/bin/rtorrent" ] || return 0
  rt_running && return 0
  rm -f "$RT/rtorrent.sock" "$RT/session/rtorrent.lock"
  nohup "$DIR/bin/rtorrent" -n -o import="$RT/rtorrent.rc" >>"$RT/rtorrent.log" 2>&1 &
  echo $! >"$RT/rtorrent.pid"
  sleep 1
  rt_running && echo "rtorrent started (pid $(cat "$RT/rtorrent.pid"))" || { echo "rtorrent failed to start, see $RT/rtorrent.log"; tail -5 "$RT/rtorrent.log"; }
}
rt_stop() { rt_running && kill "$(cat "$RT/rtorrent.pid")" && echo "rtorrent stopped"; rm -f "$RT/rtorrent.pid"; }
start() {
  running && { echo "already running (pid $(cat "$PID"))"; return; }
  set -a; . "$DIR/streammkv.env"; set +a
  nohup "$DIR/bin/streammkv" >>"$DIR/streammkv.log" 2>&1 &
  echo $! >"$PID"
  sleep 1
  running && echo "started (pid $(cat "$PID"))" || { echo "failed to start, see $DIR/streammkv.log"; tail -5 "$DIR/streammkv.log"; exit 1; }
}
stop() { running && kill "$(cat "$PID")" && echo stopped; rm -f "$PID"; }
case "${1:-start}" in
  start) rt_start; start ;;
  stop) stop; rt_stop ;;
  restart) stop; sleep 1; rt_start; start ;;
  status) running && echo "running (pid $(cat "$PID"))" || echo "not running"
          [ -f "$RT/rtorrent.rc" ] && { rt_running && echo "rtorrent running (pid $(cat "$RT/rtorrent.pid"))" || echo "rtorrent not running"; } ;;
  ensure) rt_running || rt_start; running || start ;;
  rtorrent-restart) rt_stop; sleep 2; rt_start ;;
  version) "$DIR/bin/streammkv" version ;;
  user) shift; set -a; . "$DIR/streammkv.env"; set +a; exec "$DIR/bin/streammkv" user "$@" ;;
  *) echo "usage: $0 {start|stop|restart|status|version|user ...}"; exit 2 ;;
esac
EOF
chmod +x "$DIR/run.sh"

# ---------------------------------------------------------------- start + autostart
"$DIR/run.sh" restart

if command -v crontab >/dev/null 2>&1; then
  ( { crontab -l 2>/dev/null | grep -v "$DIR/run.sh" || true; } ;
    echo "@reboot $DIR/run.sh start >/dev/null 2>&1" ;
    echo "*/5 * * * * $DIR/run.sh ensure >/dev/null 2>&1" ) | crontab - \
    && say "crontab: autostart on reboot + watchdog every 5 min"
else
  echo "  (crontab not available — start manually after reboot: $DIR/run.sh start)"
fi

HOST="$(hostname -f 2>/dev/null || hostname)"
URL="http://$HOST:$PORT/"
G=$(printf '\033[1;32m'); N=$(printf '\033[0m')
echo
echo "${G}Delos $("$BIN/streammkv" version | cut -d' ' -f2) is running${N}"
echo "  URL       : $URL"
if [ "$FIRST_INSTALL" = 1 ]; then
  echo "  Admin     : $USER_NAME"
  echo "  Password  : $PASS"
else
  echo "  Users     : unchanged (manage them in the dashboard)"
fi
cat <<EOF
  Dashboard : ${URL}admin
  Media     : $MEDIA_ROOT
  Manage    : $DIR/run.sh {start|stop|restart|status|version}
  Users CLI : $DIR/run.sh user {list|add NAME [--admin]|passwd NAME|del NAME}
  Log       : $DIR/streammkv.log
$([ -f "$RT_DIR/rtorrent.rc" ] && printf '  rtorrent  : installed · downloads to %s · port %s (open it in your firewall for incoming peers)\n' "$MEDIA_ROOT/downloads" "$(cat "$RT_DIR/port")")

Web app    : ${URL}   (open it in any browser — installable as an app)
Apps       : https://github.com/$REPO/releases/latest
The server updates itself from GitHub releases (toggle in the dashboard).
EOF
