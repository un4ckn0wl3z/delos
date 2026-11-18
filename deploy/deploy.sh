#!/usr/bin/env bash
# Deploy / upgrade StreamMKV on your seedbox over SSH (Linux / macOS).
# Asks for the connection details; answers are remembered for next time.
set -euo pipefail

URL="https://raw.githubusercontent.com/un4ckn0wl3z/streammkv/main/deploy/install.sh"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/streammkv-deploy.env"

SSH_HOST="${SSH_HOST:-}" SSH_USER="${SSH_USER:-}" SSH_PORT="${SSH_PORT:-22}"
MEDIA_ROOT="${MEDIA_ROOT:-}" APP_PORT="${APP_PORT:-}"
# shellcheck disable=SC1090
[ -f "$CFG" ] && . "$CFG"

ask() { # var prompt
  local in=""
  read -r -p "$2 [${!1:-}]: " in || true
  if [ -n "$in" ]; then printf -v "$1" '%s' "$in"; fi
}

echo "StreamMKV — deploy / upgrade on a seedbox over SSH"
echo "(press Enter to keep the value in [brackets])"
echo
ask SSH_HOST "Seedbox host"
ask SSH_USER "SSH username"
ask SSH_PORT "SSH port"
[ -n "$MEDIA_ROOT" ] || MEDIA_ROOT="/home/$SSH_USER/torrents"
ask MEDIA_ROOT "Folder with your .mkv files (on the seedbox)"
ask APP_PORT "StreamMKV port (blank = random free port, or keep the current one)"

[ -n "$SSH_HOST" ] && [ -n "$SSH_USER" ] || { echo "Host and username are required." >&2; exit 1; }

mkdir -p "$(dirname "$CFG")"
{
  printf 'SSH_HOST=%q\nSSH_USER=%q\nSSH_PORT=%q\nMEDIA_ROOT=%q\nAPP_PORT=%q\n' \
    "$SSH_HOST" "$SSH_USER" "$SSH_PORT" "$MEDIA_ROOT" "$APP_PORT"
} > "$CFG"

REMOTE="curl -fsSL $URL | MEDIA_ROOT=$(printf %q "$MEDIA_ROOT")${APP_PORT:+ PORT=$(printf %q "$APP_PORT")} bash"
echo
echo "Connecting to $SSH_USER@$SSH_HOST:$SSH_PORT …"
exec ssh -t -o StrictHostKeyChecking=accept-new -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "$REMOTE"
