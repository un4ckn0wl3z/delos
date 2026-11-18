#!/usr/bin/env bash
# StreamMKV installer for seedboxes — no root, no package manager.
#
#   curl -fsSL https://raw.githubusercontent.com/un4ckn0wl3z/streammkv/main/deploy/install.sh \
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
#
# Re-running upgrades the binary and keeps port / password / secret.
set -euo pipefail

REPO="un4ckn0wl3z/streammkv"
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

# ---------------------------------------------------------------- config
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
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
umask 022

FIRST_INSTALL=1
[ -f "$DIR/data/users.json" ] && FIRST_INSTALL=0

# ---------------------------------------------------------------- run script
cat > "$DIR/run.sh" <<'EOF'
#!/usr/bin/env bash
# usage: run.sh [start|stop|restart|status|ensure|version|user ...]
DIR="$(cd "$(dirname "$0")" && pwd)"
PID="$DIR/streammkv.pid"
running() { [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; }
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
  start) start ;;
  stop) stop ;;
  restart) stop; sleep 1; start ;;
  status) running && echo "running (pid $(cat "$PID"))" || echo "not running" ;;
  ensure) running || start ;;
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
echo "${G}StreamMKV $("$BIN/streammkv" version | cut -d' ' -f2) is running${N}"
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

Userscript : ${URL}streammkv.user.js
Android app: https://github.com/$REPO/releases/latest
The server updates itself from GitHub releases (toggle in the dashboard).
EOF
