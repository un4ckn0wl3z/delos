# StreamMKV

ดูหนัง MKV จาก seedbox ผ่านเบราว์เซอร์ เลือก audio track / subtitle ได้ — พร้อมหลาย library (หนัง / ซีรีส์ / เพลง / วิดีโออื่น), ดึง metadata จาก TMDB + MusicBrainz, จัดกลุ่มตามแนว ศิลปิน อัลบั้ม และสตรีมเพลง (mp3/flac/…)

```
┌──────────── Browser (Tampermonkey) ────────────┐        ┌────────────── Seedbox ──────────────┐
│ streammkv.user.js                              │  HTTPS │ streammkv (Go, single binary)        │
│  • settings: server URL / user / password      │ ─────▶ │  /api/list      list *.mkv           │
│  • file list + search + resume                 │        │  /api/probe     ffprobe → tracks     │
│  • player: audio / subs / sub delay / seek     │ ◀───── │  /api/stream    ffmpeg → fMP4        │
│  • renders text subs itself (WebVTT)           │        │  /api/subtitle  track → WebVTT (cache)│
└────────────────────────────────────────────────┘        └──────────────────────────────────────┘
```

## Libraries & metadata

Admins can add as many libraries as they like from **/admin → Libraries**. Pick a folder on the seedbox with the folder browser, then choose its type:

| type | what you get |
|---|---|
| **Movies** | Matched to TMDB from the file or folder name, e.g. `Children.of.Men.2006.1080p…`. You get the poster, backdrop, overview, genres, rating, director and cast. Multiple files of the same movie are grouped as "versions". |
| **TV series** | `S01E02`, `1x02` and `Season N/` folders are recognised. You get show metadata, season tabs, episode titles, stills and overviews, plus a **Next up** button. |
| **Music** | `.mp3 .flac .m4a .ogg .opus .wav .wma …`. Tags are read with ffprobe. Browse by album, artist, genre or song. Covers come from `cover.jpg`/`folder.jpg`, then embedded art, then MusicBrainz/Cover Art Archive. |
| **Other videos** | A plain folder browser with no scraping. |

- **TMDB key:** set it in **/admin → Metadata**. A free v3 API key or a v4 read token works. You can also choose the metadata language, e.g. `th-TH`; when there is no overview in that language it falls back to English. Without a key, movies and TV shows still work, just without posters or metadata.
- **Exclude folders:** under **Edit library → Exclude folders**, enter one entry per line, or use **Add folder…**. `Extras/Featurettes` (with a `/`) means that one folder. `Sample` or `Behind*` means any folder with that name, at any depth. Excluded folders are left out of every list and their files can't be played.
- **Test:** **/admin → Metadata → Test** checks four things: the TMDB key and whether the server can reach TMDB, whether MusicBrainz is reachable, whether this browser can load poster images, and how many items in each library have artwork. It also lists titles that weren't matched and warns about libraries that will never get metadata, such as type *Other videos*. You can test a key before saving it.
- **Scanning:** every library is re-scanned every 30 minutes, or straight away with **Scan**. **Refresh metadata** re-matches everything. Results are cached in `<data>/index/` and covers in `<data>/covers/`, so a rescan only looks up new titles.
- **Per-user access:** **/admin → Users → Libraries** chooses which libraries a user can see. The default is all of them, so a kids' account can be limited to Music, for example.
- **Fixing wrong matches:** in the userscript, open a movie, show, episode, album or track and press **✎ Edit**. You can search TMDB and pick the correct title, enter a TMDB ID, or override fields by hand (title, year, genres, overview, poster URL; artist, album, track, cover URL…). **Reset to automatic** removes the edit. Edits are kept separately and survive rescans. Admins can always edit; to let another user edit, use **/admin → Users → Make editor**.
- **Music playback:** files the browser or app can play natively are streamed as they are, with Range support. Anything else (wma, ape, …) is transcoded to mp3 on the fly through `/api/audio`. Playback continues in the background, with lock-screen and media-key controls.
- **Upgrading from ≤1.3:** your old `-root` becomes a library called `main` (type *Other videos*), and watch progress carries over. You can change its type to Movies or TV in the dashboard.

## Downloads (HTTP + torrent)

Use **/admin → Downloads** to paste a link, then pick a library and an optional folder:

- **http(s):// links** — the server downloads these itself. If the server restarts, the download resumes. The server checks free disk space first, and the library is rescanned when the download finishes.
- **magnet:… links, `.torrent` URLs and `.torrent` uploads** — these are handed to the seedbox's **rtorrent**, which downloads straight into the library folder and keeps seeding as usual. They are labelled `StreamMKV` in ruTorrent.
- **Finding rtorrent:** StreamMKV looks in `~/.rtorrent.rc` / `~/.config/rtorrent/rtorrent.rc` for `network.scgi.open_local` / `scgi_port` and checks common socket paths. If that doesn't find it, enter the address under **Downloads → rtorrent**: a socket path, `127.0.0.1:5000`, or a ruTorrent URL like `https://user:pass@host/rutorrent/plugins/httprpc/action.php` or `/RPC2`. Then press **Test**.
- **On your own VPS:** install rtorrent (`apt install rtorrent`), add `network.scgi.open_local = ~/.rtorrent.sock` to `~/.rtorrent.rc` and keep it running (tmux or systemd). HTTP downloads work without rtorrent.
- **Duplicates:** before downloading, StreamMKV checks for three kinds:
  - **The same torrent** (by info hash, for magnets, .torrent files and .torrent links). If it's already in rtorrent, the download is refused and you're told where it is.
  - **The same file or link.** For http(s) links the file name is checked first.
  - **The same movie or episode** already in a library of that type, even under a different file name.

  For the last two you can choose **Download anyway**. After a download finishes and is matched, other versions of the same title are listed on it ("⚠ Also in the library").
- **Who can add downloads:** admins, plus users given **Make downloader** in Users. Downloaders only see libraries they have access to, and only they or an admin can cancel or remove their downloads. They can't download from private or loopback addresses.

## Personal libraries & limits

Users with the **downloader** role can create **their own libraries** under Downloads → *My libraries*. They give it a name and a type (Movies / TV / Music / Other videos), and choose whether to **share it with everyone**.

- **Where the files go:** the server creates the folder at `<personal libraries folder>/<user>/<library>`. This is set in **/admin → Downloads** and defaults to `~/streammkv-libraries`. Users can't point a library at any other path.
- **Who sees what:**
  - A **private** library is visible only to its owner and admins.
  - A **shared** one is visible to everyone and labelled with the owner, e.g. "from bob".
  - Accounts that an admin limited to specific libraries only see the ones ticked for them.
- **Deleting:** owners can delete files in their own libraries (🗑 in the userscript, long-press → *Delete from server* in the app). The movie's folder (nfo, posters, subs) and the matching rtorrent download are removed too. Admins can delete anywhere. Nobody can delete from someone else's library.
- **Limits:** set under **/admin → Users → Limits**, as max items and/or max GB across the user's personal libraries. Downloads that would go over the limit are refused, including magnets once their size is known. A user with a limit can only download into their own libraries. Usage shows in the dashboard and on the user's Downloads page.

## People & chat

- **Who's online:** see who is online and **what they're watching or listening to**, e.g. "▶ Children of Men · 45:12". You can press ▶ to open the same title, if you have access to its library. Anyone can switch on *Hide what I'm watching*; others will still see that they are online.
- **Chats:** 1-to-1 chats and **group chats**. Any member can rename a group or add people; only the group's creator (or an admin) can remove people, and anyone can leave. Unread counts and new-message notifications update live (Server-Sent Events, `GET /api/events`). Admins can't read other people's chats.
- **Send to a friend:** share a movie, episode or song into a chat as a card your friend can tap to play. If they can't open that library, you get a warning.
- **Where:** the people list and 💬 drawer in the userscript sidebar, and the **Chat** tab in the app. Notifications appear only while the app or page is open.

## Users & admin dashboard

StreamMKV supports several users. Each user has their own watch progress, resume positions and track choices. Admins choose which libraries each user can see.

- **Dashboard:** `http://<server>/admin`. Admins can add users, reset passwords, promote users to admin, sign a user out on every device, and view or clear a user's history. The dashboard also shows who is watching now, the open streams and whether each one is direct or transcode, library and disk stats, and update status. A user who is not an admin only gets a "change password" page there.
- **CLI on the seedbox:** `~/streammkv/run.sh user list | add NAME [--admin] [--password P] | passwd NAME | admin NAME on|off | revoke NAME | del NAME`. If you leave out the password, a random one is generated. The running server picks up changes within 2 seconds.
- **Storage:** users are kept in `<data>/users.json` with PBKDF2-SHA256 password hashes. When you change a password or sign a user out, every existing session for that user stops working.
- **First start:** the first admin is created from `-user/-pass`. After that those flags are ignored. When you upgrade from a single-user install, your existing account becomes the admin and keeps its watch progress.

## Versions & updates

- The `VERSION` file is the single source for the version. `tools/bump.sh X.Y.Z` updates it together with the userscript and app versions. Commit and push, and CI builds the server binaries, `SHA256SUMS` and the APKs. It uploads them to a draft release and publishes the release once everything is there.
- **Server:** checks GitHub every 6 hours. With auto-update on (the default, which you can toggle in the dashboard), it downloads the new binary, checks it against `SHA256SUMS`, swaps it in and re-execs itself with the same PID. The previous binary is kept as `streammkv.old`. It only installs while nobody is streaming. You can also press **Update now** in the dashboard.
- **App:** when it starts, it checks the latest release and offers the APK built for your phone's CPU. *Settings → Check for app updates* runs the check by hand. Android does not let sideloaded apps install updates silently, so you still have to tap Install.
- **Userscript:** Tampermonkey updates it from GitHub through `@updateURL`.

## Apps: Android, iOS, Windows, Linux, macOS

The app is written in Flutter with [media_kit](https://github.com/media-kit/media-kit) (libmpv) and is the same on every platform. Download it from [Releases](https://github.com/un4ckn0wl3z/streammkv/releases/latest).

The app browses libraries the same way the userscript does: Home (continue watching / recently added), movies with posters and genre filters, TV shows with seasons and Next up, and music by album, artist, genre or song. It has a mini player and background audio. **Long-press** a poster or episode to open a menu (on desktop, right-click). It offers Play/Resume, **Start over** and **Remove from Continue watching**. Admins and editors also get **Identify…**, which lets you search TMDB, pick the right title or type a TMDB ID; **Re-detect** returns the title to automatic matching. Other metadata edits are only in the userscript.

| Platform | File | Install |
|---|---|---|
| Android | `streammkv-android-arm64-v8a.apk` | Open the APK. When an update fails with "App not installed", uninstall the old app first; your watch progress is kept on the server. |
| iOS / iPadOS | `streammkv-ios.ipa` (unsigned) | Install with [SideStore](https://sidestore.io) or [AltStore](https://altstore.io) using a free Apple ID. See below. |
| Windows 10/11 | `streammkv-windows-x64.zip` | Unzip and run `StreamMKV.exe`. |
| Linux x64 | `streammkv-linux-x64.tar.gz` | Install libmpv first (`sudo apt install libmpv2`), then unpack and run `StreamMKV/streammkv`. A `.desktop` file is included. |
| macOS 11+ (Intel & Apple Silicon) | `streammkv-macos.zip` | Unzip and move `StreamMKV.app` to Applications. The app is not notarized, so run `xattr -dr com.apple.quarantine /Applications/StreamMKV.app` once, or allow it under System Settings → Privacy & Security → Open Anyway. |

On Windows, Linux and macOS: press **F** or double-click the middle of the video for fullscreen. Other keys: space play/pause, ←/→ ±10s, J/L ±30s, ↑/↓ volume, A cycles audio, C cycles subtitles, Z/X adjust subtitle delay, Esc leaves fullscreen.

### iOS with SideStore / AltStore (free Apple ID)

1. Set up SideStore or AltStore once, following their guides. The first setup needs a computer.
2. In SideStore/AltStore open **Sources → +** and add
   `https://github.com/un4ckn0wl3z/streammkv/releases/latest/download/altstore-source.json`
3. Install **StreamMKV** from that source. Once a new release is out, the source shows the update.
4. Apps signed with a free Apple ID expire after **7 days**, and you can have at most 3 sideloaded apps. Refresh StreamMKV in SideStore before it expires; SideStore can do this on the phone, or set up the auto-refresh Shortcut.

With a paid Apple Developer account, the same CI could upload to TestFlight instead.

### Android details

The `app/` folder holds a Flutter app that uses [media_kit](https://github.com/media-kit/media-kit) (libmpv). Install the APK from [Releases](https://github.com/un4ckn0wl3z/streammkv/releases): `streammkv-android-arm64-v8a.apk` works on most phones.

- **Direct**: mpv streams the original MKV through `/api/raw`, which supports HTTP Range. It plays every codec (HEVC, DTS, TrueHD…), switches between the file's audio and subtitle tracks, and renders full ASS styling and PGS. Seeking is native and accurate, and the server uses almost no CPU, but this mode needs enough bandwidth for the original bitrate.
- **Transcode 1080/720/480p**: plays the stream from `/api/stream`. Use it to save data on a mobile network.
- **Watch progress and tracks** are stored on the server (`/api/progress`), so the app and every browser running the userscript can pick up where you left off.
- **Gestures**: double-tap the left/right side to skip back/forward 10s, double-tap the middle to play or pause. The ⚙ menu has quality, subtitle delay and subtitle size.

Build it yourself:

```bash
cd app
flutter create --org dev.un4ckn0wl3z --project-name streammkv --platforms android .
python3 tool/patch_android.py      # INTERNET permission, cleartext HTTP, app label
flutter build apk --release --split-per-abi
```

CI (`.github/workflows/app.yml`) signs the APK with the key from the `ANDROID_DEBUG_KEYSTORE_B64` secret, a base64-encoded keystore with alias `androiddebugkey` and password `android`. If that secret isn't set, every build gets a different key, and you have to uninstall the old version before installing a new one.

## How it works

- **Video**: if the browser can decode the video codec (H.264 8-bit, HEVC/AV1/VP9 when supported), it is passed through unchanged with `-c:v copy`, which uses almost no CPU. Otherwise it is transcoded to H.264 with `libx264 veryfast`, scaled down to the max height you choose.
- **Audio**: only the selected track is sent (`-map 0:a:N`). It is always converted to stereo AAC, because browsers cannot play AC3/DTS/TrueHD.
- **Seeking**: the client sends a new request with `?start=`. In copy mode it first asks for the nearest keyframe (`/api/keyframe`) so the seek bar and subtitles stay in sync.
- **Text subtitles** (SRT/ASS/VTT): extracted to WebVTT and cached on the server, then drawn by the userscript in an overlay. You can adjust the subtitle delay and change subtitles without restarting the video.
- **Image subtitles** (PGS/VobSub): burned into the video, which forces transcode mode.
- **The UI runs on the server's own page.** The userscript detects `<meta name="streammkv-app">` and draws the player there, which avoids CORS, mixed-content and page-CSP problems with `<video>`. You can open it from any website through the Tampermonkey menu.

## Install on the seedbox (no root, no package manager needed)

**From your PC (easiest):** download and run the deploy script. It asks for the seedbox host, SSH user/port, your movie folder and an optional port, then installs or upgrades over SSH. You only type the SSH password. It remembers your answers for next time.

- Windows 10/11: [`deploy/deploy.cmd`](deploy/deploy.cmd). Double-click it; it uses the built-in OpenSSH client.
- Linux / macOS: [`deploy/deploy.sh`](deploy/deploy.sh). Run `bash deploy.sh`.

At the end it prints the URL, username and password to put into the app or the Tampermonkey settings. Run it again any time to upgrade to the latest release; the port and password stay the same.

**Or, on the seedbox itself** (one-liner; downloads the release binary + static ffmpeg, picks a free port, generates a password, starts the server and adds an autostart cron):

```bash
curl -fsSL https://raw.githubusercontent.com/un4ckn0wl3z/streammkv/main/deploy/install.sh | MEDIA_ROOT=~/torrents bash
```

Re-running it upgrades to the latest release and keeps the port/password. Manage with `~/streammkv/run.sh {start|stop|restart|status}`; config lives in `~/streammkv/streammkv.env`.

### Manual install

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
| `-root` | `STREAMMKV_ROOT` | `.` | folder for the first library; later libraries are added in /admin |
| `-listen` | `STREAMMKV_LISTEN` | `:8090` | |
| `-user` / `-pass` | `STREAMMKV_USER` / `STREAMMKV_PASS` | — | first admin (only used while no users exist) |
| `-secret` | `STREAMMKV_SECRET` | random, saved in `<data>/secret.key` | key for signing tokens |
| `-ffmpeg` / `-ffprobe` | `STREAMMKV_FFMPEG` / `STREAMMKV_FFPROBE` | from PATH | |
| `-ext` | `STREAMMKV_EXT` | `.mkv,.mp4,.m4v,.avi,.webm,.mov,.ts,…` | video extensions for video libraries |
| `-cache` | `STREAMMKV_CACHE` | `~/.cache/streammkv` | WebVTT cache |
| `-data` | `STREAMMKV_DATA` | same as cache | `users.json`, `progress.json`, `settings.json`, `libraries.json`, `secret.key`, `index/`, `covers/` |
| | `STREAMMKV_UPDATE_REPO` | `un4ckn0wl3z/streammkv` | GitHub repo to update from (forks) |
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

The left sidebar lists your libraries. **Home** shows *Continue watching* and *Recently added*. Movies and shows can be filtered by genre. Music has Albums / Artists / Genres / Songs tabs and a player bar at the bottom with a queue, shuffle and repeat.

The script uses `@match *://*/*` so the menu shows up on every website. It does nothing on other pages except register the menu. If you only want it on the server page, change `@match` to your server URL.

### Keyboard

`space`/`k` play/pause · `←/→` ±10s · `j/l` ±30s · `a` cycle audio · `c` cycle subs · `z/x` sub delay ±0.1s · `f` fullscreen · `m` mute · `↑/↓` volume

### Remembered per file

For each file, the server remembers your playback position and the audio/subtitle tracks you picked. The browser and the Android app share this, so you can stop on one and continue on the other.

## Limitations

- The first time you open a text subtitle track, the server has to read the whole MKV to extract it (a 20 GB file can take tens of seconds). After that it is served from cache.
- Copy mode seeks to the nearest keyframe before the point you chose (usually no more than 2–10 seconds earlier).
- Transcoding 4K or burning in subtitles uses a lot of CPU. If the seedbox is weak, set Max height to 720p.
- The password is stored in plain text in Tampermonkey storage.

## API

All endpoints except `/`, `/streammkv.user.js` and `/api/login` need auth: the `streammkv` cookie, an `Authorization: Bearer <token>` header, or `?token=`.

```
POST /api/login        {"username","password"} → {"token","expires","user","admin"} + Set-Cookie
GET  /api/libraries    → [{id,name,type,count,scanned}]   (only libraries this user may see)
GET  /api/lib/{id}     → {library, items[] (+pos/watched), movies{}, shows{}, edits? (editors)}
GET  /api/cover/{key}  → image
GET  /api/audio        ?path=&fmt=mp3|aac&start=S   → transcoded audio
GET  /api/list         → {"files":[…]}   (legacy flat list of all video libraries; paths are "<libid>/<relpath>")
GET  /api/probe        ?path=            → {duration,start,video,audio[],subs[]}
GET  /api/keyframe     ?path=&t=         → {"t": keyframe time ≤ t}
GET  /api/stream       ?path=&audio=N&start=S&v=copy|transcode&burn=N&maxh=1080&crf=22  → video/mp4 (fragmented)
GET  /api/subtitle     ?path=&sub=N      → text/vtt
GET  /api/raw          ?path=            → original file (HTTP Range)
GET  /api/progress     [?path=]          → {"items":{path:{pos,duration,audio,sub,updated}}} or a single entry
POST /api/progress     {"path","pos","duration","audio","sub" (-1 = off),"done"}      (per user)
GET  /api/me                              → {"user","admin","editor","version"}

# editors (admins + users with the editor role)
GET  /api/meta/search  ?lib=&type=movie|tv&q=&year=   → TMDB results
POST /api/meta/match   {"lib","key","tmdbId"}         (key = movie group / show key)
POST /api/meta/edit    {"lib","key","fields":{…}}     (fields: null = reset to automatic)
POST /api/me/password  {"old","new"}

# admin only
GET    /api/admin/overview                → stats, connections, watching now, recent
GET    /api/admin/users                   POST /api/admin/users {"name","password"?,"admin"}
POST   /api/admin/users/{name}/password   {"password"?}  (blank = generate)
POST   /api/admin/users/{name}/role       {"admin": bool}
POST   /api/admin/users/{name}/revoke     DELETE /api/admin/users/{name}
GET|DELETE /api/admin/users/{name}/progress
GET    /api/admin/update                  POST /api/admin/update/check | /api/admin/update/install
GET|POST /api/admin/settings              {"autoUpdate"?, "tmdbKey"?, "tmdbLang"?}
GET|POST /api/admin/libraries             {"name","type":"movies|tv|music|videos","path"}
PUT|DELETE /api/admin/libraries/{id}      POST /api/admin/libraries/{id}/scan[?refresh=1]
GET    /api/admin/browse ?path=           folder picker
POST   /api/admin/users/{name}/libraries  {"libraries": [ids] | null (= all)}
POST   /api/admin/users/{name}/editor     {"editor": bool}
```
