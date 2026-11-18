# StreamMKV

ดูหนัง MKV จาก seedbox ผ่านเบราว์เซอร์ เลือก audio track / subtitle ได้

```
┌──────────── Browser (Tampermonkey) ────────────┐        ┌────────────── Seedbox ──────────────┐
│ streammkv.user.js                              │  HTTPS │ streammkv (Go, single binary)        │
│  • settings: server URL / user / password      │ ─────▶ │  /api/list      list *.mkv           │
│  • file list + search + resume                 │        │  /api/probe     ffprobe → tracks     │
│  • player: audio / subs / sub delay / seek     │ ◀───── │  /api/stream    ffmpeg → fMP4        │
│  • renders text subs itself (WebVTT)           │        │  /api/subtitle  track → WebVTT (cache)│
└────────────────────────────────────────────────┘        └──────────────────────────────────────┘
```

## How it works

- **Video**: if the browser can decode the video codec (H.264 8-bit, HEVC/AV1/VP9 when supported), it is passed through unchanged with `-c:v copy`, which uses almost no CPU. Otherwise it is transcoded to H.264 with `libx264 veryfast`, scaled down to the max height you choose.
- **Audio**: only the selected track is sent (`-map 0:a:N`). It is always converted to stereo AAC, because browsers cannot play AC3/DTS/TrueHD.
- **Seeking**: the client sends a new request with `?start=`. In copy mode it first asks for the nearest keyframe (`/api/keyframe`) so the seek bar and subtitles stay in sync.
- **Text subtitles** (SRT/ASS/VTT): extracted to WebVTT and cached on the server, then drawn by the userscript in an overlay. You can adjust the subtitle delay and change subtitles without restarting the video.
- **Image subtitles** (PGS/VobSub): burned into the video, which forces transcode mode.
- **The UI runs on the server's own page.** The userscript detects `<meta name="streammkv-app">` and draws the player there, which avoids CORS, mixed-content and page-CSP problems with `<video>`. You can open it from any website through the Tampermonkey menu.

## Install on the seedbox (no root, no package manager needed)

```bash
mkdir -p ~/bin ~/streammkv && cd ~/streammkv

# 1) streammkv binary — build on your machine with:
#    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o dist/streammkv-linux-amd64 .
#    then copy it over (scp), or use the bundled dist/streammkv-linux-amd64
chmod +x streammkv-linux-amd64

# 2) static ffmpeg + ffprobe
curl -L -o ffmpeg.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz
tar xf ffmpeg.tar.xz && cp ffmpeg-*-static/ffmpeg ffmpeg-*-static/ffprobe ~/bin/ && rm -rf ffmpeg-*-static ffmpeg.tar.xz

# 3) run
STREAMMKV_PASS='change-me' ./streammkv-linux-amd64 \
  -root ~/downloads -user me -listen :8090 \
  -ffmpeg ~/bin/ffmpeg -ffprobe ~/bin/ffprobe \
  -secret "$(openssl rand -hex 32)"
```

To keep it running with no systemd: `nohup ... > streammkv.log 2>&1 &` or `screen -dmS streammkv ...`. Add it to `crontab -e` with `@reboot ...` so it starts again after a reboot.

### Flags / env

| flag | env | default | |
|---|---|---|---|
| `-root` | `STREAMMKV_ROOT` | `.` | media folder (scanned recursively, hidden folders skipped) |
| `-listen` | `STREAMMKV_LISTEN` | `:8090` | |
| `-user` / `-pass` | `STREAMMKV_USER` / `STREAMMKV_PASS` | — | required |
| `-secret` | `STREAMMKV_SECRET` | random | key for signing tokens. If empty, tokens reset on restart (the userscript logs in again automatically) |
| `-ffmpeg` / `-ffprobe` | `STREAMMKV_FFMPEG` / `STREAMMKV_FFPROBE` | from PATH | |
| `-ext` | `STREAMMKV_EXT` | `.mkv` | e.g. `.mkv,.mp4,.avi` |
| `-cache` | `STREAMMKV_CACHE` | `~/.cache/streammkv` | WebVTT cache |
| `-tls-cert` / `-tls-key` | `STREAMMKV_TLS_CERT` / `_KEY` | — | serve HTTPS directly |
| `-max-streams` | | `3` | max number of ffmpeg processes at once |

### HTTPS / reverse proxy (recommended)

The password is sent at login, so use HTTPS. If the seedbox already has nginx, you can mount StreamMKV under a subpath:

```nginx
location /streammkv/ {
    proxy_pass http://127.0.0.1:8090/;
    proxy_buffering off;              # required for streaming
    proxy_read_timeout 6h;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

Then set the Server URL in the userscript to `https://your.box/streammkv/`.

## Install the userscript

1. Install Tampermonkey.
2. Open `https://<server>/streammkv.user.js`; the server serves this file itself and Tampermonkey will offer to install it. Or copy `web/streammkv.user.js` and add it by hand.
3. Tampermonkey menu → **⚙ StreamMKV settings**. Enter the Server URL, username, password, and your preferred languages, e.g. audio `jpn,eng` and subs `tha,eng`.
4. Tampermonkey menu → **▶ Open StreamMKV**, or open the server URL directly.

The script uses `@match *://*/*` so the menu shows up on every website. It does nothing on other pages except register the menu. If you only want it on the server page, change `@match` to your server URL.

### Keyboard

`space`/`k` play/pause · `←/→` ±10s · `j/l` ±30s · `a` cycle audio · `c` cycle subs · `z/x` sub delay ±0.1s · `f` fullscreen · `m` mute · `↑/↓` volume

### Remembered per file

The script remembers your playback position (resume) and the audio and subtitle tracks you picked for each file.

## Limitations

- The first time you open a text subtitle track, the server has to read the whole MKV to extract it (a 20 GB file can take tens of seconds). After that it is served from cache.
- Copy mode seeks to the nearest keyframe before the point you chose (usually no more than 2–10 seconds earlier).
- Transcoding 4K or burning in subtitles uses a lot of CPU. If the seedbox is weak, set Max height to 720p.
- The password is stored in plain text in Tampermonkey storage.

## API

All endpoints except `/`, `/streammkv.user.js` and `/api/login` need auth: the `streammkv` cookie, an `Authorization: Bearer <token>` header, or `?token=`.

```
POST /api/login        {"username","password"} → {"token","expires"} + Set-Cookie
GET  /api/list         → {"files":[{path,name,dir,size,mtime}]}
GET  /api/probe        ?path=            → {duration,start,video,audio[],subs[]}
GET  /api/keyframe     ?path=&t=         → {"t": keyframe time ≤ t}
GET  /api/stream       ?path=&audio=N&start=S&v=copy|transcode&burn=N&maxh=1080&crf=22  → video/mp4 (fragmented)
GET  /api/subtitle     ?path=&sub=N      → text/vtt
```
