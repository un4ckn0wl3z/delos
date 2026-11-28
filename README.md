<p align="center">
  <img src="docs/images/banner.webp" alt="Delos" width="100%">
</p>

<p align="center">
  <a href="https://github.com/un4ckn0wl3z/delos/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/un4ckn0wl3z/delos?style=flat-square&color=3b6fd6"></a>
  <img alt="Go" src="https://img.shields.io/badge/server-Go-00ADD8?style=flat-square&logo=go&logoColor=white">
  <img alt="Flutter" src="https://img.shields.io/badge/apps-Flutter-02569B?style=flat-square&logo=flutter&logoColor=white">
  <img alt="Platforms" src="https://img.shields.io/badge/Web%20·%20Android%20·%20iOS%20·%20Windows%20·%20macOS%20·%20Linux-2f9e74?style=flat-square">
  <a href="https://github.com/un4ckn0wl3z/delos/pkgs/container/delos"><img alt="Docker" src="https://img.shields.io/badge/docker-ghcr.io-2496ED?style=flat-square&logo=docker&logoColor=white"></a>
</p>

<p align="center">
  <b>Your own streaming service on a seedbox.</b> One small Go server, a web app and apps for every platform.
</p>

<p align="center">
  <b>English</b> · <a href="README.th.md">ภาษาไทย</a>
</p>

<p align="center">
  <a href="#-quick-start">Quick start</a> ·
  <a href="#-screenshots">Screenshots</a> ·
  <a href="#-how-it-fits-together">Architecture</a> ·
  <a href="#-documentation">Docs</a> ·
  <a href="https://github.com/un4ckn0wl3z/delos/releases/latest">Download</a>
</p>

---

*Formerly StreamMKV.* Named after the island where the twins Artemis and Apollo were born — 🌙 **Artemis** for films and series, ☀️ **Apollo** for music.

## ✨ Highlights

| | |
|---|---|
| 🎬 | **Plays any MKV in the browser** — the original file, any audio track (DTS / TrueHD / AC-3 decoded in WebAssembly), any subtitle. The server only transcodes when it must. |
| 🗂️ | **Movies, series, music & videos** with posters and info from TMDB / MusicBrainz, series grouping and *Next up*. |
| 🎤 | **Synced lyrics** for music, **seek-bar previews** for videos, and **requests**: ask for what isn't here yet, vote, get told when it lands. |
| ⬇️ | **Downloads** from http, torrents (rtorrent) and YouTube straight into a library, with duplicate checks. |
| 📲 | **Apps for Android, iOS, Windows, macOS, Linux** (mpv inside), offline downloads and your own folders. |
| 🎉 | **Watch party, chat & ranking** — watch together in sync, see what friends play, badges. |
| 📱 | **Remote control** — your phone drives Delos on the PC / TV, over the internet — and any DLNA TV at home through the desktop app (**Play on… → TV**). |
| 📺 | **DLNA for TVs** from the desktop app, with on-the-fly audio conversion and TV copies. |
| 🛡️ | **Multi-user** with roles, per-library access, limits, announcements and a full admin dashboard. |

## 📸 Screenshots

<table>
  <tr>
    <td width="50%"><img src="docs/images/home.webp" alt="Home"><br><sub><b>Home</b> — continue watching, recently added, who's online</sub></td>
    <td width="50%"><img src="docs/images/movie.webp" alt="Movie"><br><sub><b>Movie</b> — poster, cast, resume</sub></td>
  </tr>
  <tr>
    <td><img src="docs/images/show.webp" alt="TV show"><br><sub><b>Series</b> — seasons, episodes, next up</sub></td>
    <td><img src="docs/images/player.webp" alt="Player"><br><sub><b>Player</b> — plays the original file in the browser</sub></td>
  </tr>
  <tr>
    <td><img src="docs/images/music.webp" alt="Music"><br><sub><b>Music</b> — albums, queue, background play</sub></td>
    <td><img src="docs/images/admin.webp" alt="Admin"><br><sub><b>Admin</b> — roles, users, permissions</sub></td>
  </tr>
</table>

<sub>Screenshots use a made-up demo library (titles and artwork are generated).</sub>

## 🧭 How it fits together

```mermaid
flowchart LR
  subgraph Seedbox["🌱 Seedbox / server"]
    direction TB
    S["Delos server<br/>(Go, one binary)"]
    FF["ffmpeg / ffprobe"]
    RT["rtorrent"]
    YT["yt-dlp"]
    LIB[("Media folders<br/>Movies · TV · Music")]
    S --- FF
    S --- RT
    S --- YT
    RT --> LIB
    YT --> LIB
    S --> LIB
  end
  TMDB["🎞️ TMDB<br/>🎵 MusicBrainz"]
  S -->|metadata & posters| TMDB

  subgraph Clients["👥 Clients"]
    direction TB
    W["🌐 Web app (PWA)"]
    A["📱 Android / iOS app"]
    D["💻 Desktop app<br/>Windows · macOS · Linux"]
  end
  W <-->|"HTTPS · API · live events"| S
  A <-->|"HTTPS"| S
  D <-->|"HTTPS"| S
  TV["📺 Smart TV"]
  D -->|"DLNA (home network)"| TV
  A -.->|"📱 remote control<br/>via the server"| D
```

Everything runs as one Go program next to your files. Browsers get a web app from the same address; the apps talk to the same API. The server fetches posters and info, drives rtorrent / yt-dlp for downloads, and uses ffmpeg only when a device can't play a file as it is.


### ▶️ How a video plays

```mermaid
flowchart TD
  P(["Press ▶ Play"]) --> Q{"Which client?"}
  Q -->|"📲 App"| M["mpv plays the original file<br/>/api/raw · byte ranges"]
  Q -->|"🌐 Browser"| C{"Can this device decode<br/>the video? (WebCodecs)"}
  C -->|"yes"| B["Plays in the browser<br/>Mediabunny + WebCodecs<br/>DTS/TrueHD/AC-3 → WASM"]
  C -->|"no"| R{"Video codec OK<br/>for the browser?"}
  R -->|"yes"| X["Server remux<br/>video copy · audio → AAC"]
  R -->|"no / image subs"| T["Server transcode<br/>H.264 · burn-in PGS"]
  M --> PR[("💾 Progress & tracks<br/>saved per user")]
  B --> PR
  X --> PR
  T --> PR
```

### ⬇️ Adding a download

```mermaid
flowchart LR
  L["Paste a link"] --> K{"Kind?"}
  K -->|"http(s)"| H["Server downloads<br/>(resumes after restart)"]
  K -->|"magnet / .torrent"| RT["rtorrent<br/>downloads & seeds"]
  K -->|"YouTube"| Y["yt-dlp<br/>video or tagged audio"]
  L --> DUP{"Already have it?<br/>torrent · file · same movie"}
  DUP -->|"yes"| W["⚠ Warn · Download anyway?"]
  H --> F[("Library folder")]
  RT --> F
  Y --> F
  F --> S["Scan → TMDB match<br/>→ shows up for everyone"]
```

### 📱 Remote control

```mermaid
sequenceDiagram
  autonumber
  participant Phone as 📱 Phone (app)
  participant Server as 🌱 Delos server
  participant PC as 💻 PC / TV browser
  PC->>Server: hello (every 30 s) + what's playing
  PC->>Server: hello for each DLNA TV it sees (Play on… → TV)
  Phone->>Server: list my devices
  Server-->>Phone: PC · idle, 📺 LG TV via PC
  Phone->>Server: Play "Low Orbit" on PC
  Server-->>PC: remote-cmd (live event)
  PC->>PC: opens the player
  PC->>Server: state: playing 00:12
  Server-->>Phone: remote-state → seek bar, subs, audio, next episode
  Note over Phone,PC: For a TV: the PC gets the command, tells the TV (UPnP AVTransport)<br/>to play from its DLNA server, and reports the TV's state back
```

### 📺 Share to a TV (DLNA)

```mermaid
flowchart LR
  TV["📺 TV<br/>Media Player"] -- "browse / play" --> DA["💻 Desktop app<br/>DLNA server"]
  DA --> LF[("Offline downloads<br/>+ your folders")]
  DA -. "Online folder<br/>(passthrough)" .-> SV["🌱 Delos server"]
  DA --> Q{"Audio the TV<br/>can't play?<br/>DTS · TrueHD"}
  Q -->|"no"| D1["Sent as it is<br/>byte-range seeking"]
  Q -->|"yes"| Q2{"TV copy made?"}
  Q2 -->|"yes"| D2["Play the copy<br/>(AC3, seeks anywhere)"]
  Q2 -->|"no"| D3["Convert live → AC3<br/>on this PC or on the server<br/>seek by time"]
```

### 🏷️ Who sees what

```mermaid
flowchart LR
  subgraph Roles
    F["🏷 Family"]
    MU["🏷 Music lovers"]
  end
  F --> L1["🎬 Movies"]
  F --> L2["📺 TV Shows"]
  MU --> L3["🎵 Music"]
  U1["theo"] --> F
  U1 --> MU
  U2["ploy"] --> F
  U3["sam (Guest)"] -. "own list only" .-> L1
  A["👑 admin"] ==> ALL["everything"]
```

## 🚀 Quick start

**🐳 Docker** (server + ffmpeg + rtorrent in one image)

```bash
curl -O https://raw.githubusercontent.com/un4ckn0wl3z/delos/main/docker-compose.yml
# edit /path/to/media and PUID/PGID
docker compose up -d && docker compose logs delos   # first start prints the admin password
```

**🌱 Seedbox without root**

```bash
curl -fsSL https://raw.githubusercontent.com/un4ckn0wl3z/delos/main/deploy/install.sh | MEDIA_ROOT=~/torrents bash
```

Or run the deploy script from your PC: [`deploy/deploy.cmd`](deploy/deploy.cmd) (Windows) / [`deploy/deploy.sh`](deploy/deploy.sh) (Linux / macOS).

**📲 Apps** — [download from Releases](https://github.com/un4ckn0wl3z/delos/releases/latest):

| Platform | File |
|---|---|---|
| 🤖 Android | `streammkv-android-arm64-v8a.apk` |
| 🍎 iOS / iPadOS | `streammkv-ios.ipa` |
| 🪟 Windows | `streammkv-windows-x64.zip` | unzip → `Delos.exe` |
| 🐧 Linux | `streammkv-linux-x64.tar.gz` | needs `libmpv2` |
| 🍏 macOS | `streammkv-macos.zip` | Intel & Apple Silicon |

Then open `http://<server>:8090` and sign in — or enter the same address in the app.

## 📚 Documentation

Click a topic to open it.

<details>
<summary><strong>🗂️ Libraries & metadata</strong></summary>


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
- **Fixing wrong matches:** in the web app, open a movie, show, episode, album or track and press **✎ Edit**. You can search TMDB and pick the correct title, enter a TMDB ID, or override fields by hand (title, year, genres, overview, poster URL; artist, album, track, cover URL…). **Reset to automatic** removes the edit. Edits are kept separately and survive rescans. Admins can always edit; to let another user edit, use **/admin → Users → Make editor**.
- **Playlists:** everyone can make their own music playlists — press ＋ next to a song, album, artist or the Now-playing queue (in the app: long-press a song, or *Playlist* on an album / artist). Playlists can be renamed, reordered (drag, or ↑ ↓) and played or shuffled. Music from someone's personal library is labelled with their name (👤).
- **Music offline:** users with the *offline* permission can save music. In the app: long-press a song → *Save to this device*, or **Save** on an album, artist or playlist; saved songs (marked ✓) play from the device even when online, and **Offline → Music** plays them with no server at all (also in the app's offline mode, with lock-screen controls). In the web app: ⬇ next to a song, or **⬇ Download** on an album, artist or playlist (one .zip, playlists in order).
- **Music playback:** files the browser or app can play natively are streamed as they are, with Range support. Anything else (wma, ape, …) is transcoded to mp3 on the fly through `/api/audio`. Playback continues in the background, with lock-screen and media-key controls.
- **Upgrading from ≤1.3:** your old `-root` becomes a library called `main` (type *Other videos*), and watch progress carries over. You can change its type to Movies or TV in the dashboard.

</details>

<details>
<summary><strong>⬇️ Downloads (HTTP, torrent, YouTube)</strong></summary>


Use **/admin → Downloads** to paste a link, then pick a library and an optional folder:

- **http(s):// links** — the server downloads these itself. If the server restarts, the download resumes. The server checks free disk space first, and the library is rescanned when the download finishes.
- **magnet:… links, `.torrent` URLs and `.torrent` uploads** — these are handed to the seedbox's **rtorrent**, which downloads straight into the library folder and keeps seeding as usual. They are labelled `StreamMKV` in ruTorrent (the label is kept from the old name).
- **YouTube / YouTube Music links and playlists** — downloaded with [yt-dlp](https://github.com/yt-dlp/yt-dlp). Into a **music** library you get the audio (m4a, tagged with title / artist / album, cover art embedded); into a video library, the video (up to 1080p, mkv). A playlist link downloads every entry into a folder named after the playlist (the album tag is the playlist name); for a video link that's part of a playlist you can tick **Whole playlist**. **Update** on a finished playlist fetches only what was added since. yt-dlp and Deno (the JavaScript runtime YouTube now needs) are used from PATH, or set with `STREAMMKV_YTDLP` / `STREAMMKV_YTDLP_JS`, or else downloaded into `<data>/bin` the first time and kept up to date. Only download what you have the right to.
- **Finding rtorrent:** Delos looks in `~/.rtorrent.rc` / `~/.config/rtorrent/rtorrent.rc` for `network.scgi.open_local` / `scgi_port` and checks common socket paths. If that doesn't find it, enter the address under **Downloads → rtorrent**: a socket path, `127.0.0.1:5000`, or a ruTorrent URL like `https://user:pass@host/rutorrent/plugins/httprpc/action.php` or `/RPC2`. Then press **Test**.
- **Where rtorrent comes from:** the Docker image has one built in; the seedbox installer uses the one already running, or offers to install a static build when there's none; on your own VPS without Docker you can also install it yourself (`apt install rtorrent`, add `network.scgi.open_local = ~/.rtorrent.sock` to `~/.rtorrent.rc` and keep it running). HTTP and YouTube downloads work without rtorrent.
- **Duplicates:** before downloading, Delos checks for three kinds:
  - **The same torrent** (by info hash, for magnets, .torrent files and .torrent links). If it's already in rtorrent, the download is refused and you're told where it is.
  - **The same file or link.** For http(s) links the file name is checked first.
  - **The same movie or episode** already in a library of that type, even under a different file name.

  For the last two you can choose **Download anyway**. After a download finishes and is matched, other versions of the same title are listed on it ("⚠ Also in the library").
- **Managing torrents:** every torrent download shows its state (Downloading / Seeding / Paused / Stopped / Finished / Checking), ratio, uploaded amount, speeds and peers. Its owner or an admin can **Pause / Resume**, **Stop seeding** and **Seed** again, **Recheck** the files, see **trackers & files**, and **Remove** — either the torrent only (files stay in the library) or the torrent **and its files**. This works in the dashboard, the web app and the app (⋮ menu).
- **Seeding limits:** in **/admin → Torrents → Seeding rule**, set a ratio and/or hours of seeding after which Delos's torrents stop seeding (or are removed from rtorrent, keeping the files). Each torrent can override it (server default / no limit / its own ratio or hours). Starting a torrent again by hand after it was auto-stopped keeps it seeding.
- **All of rtorrent (admins):** **/admin → Torrents** lists every torrent in rtorrent, including ones added outside Delos, with filters (downloading / seeding / paused / stopped / from Delos), the same actions, and global **speed limits** (these last until rtorrent restarts; put `throttle.global_down.max_rate` / `throttle.global_up.max_rate` in `.rtorrent.rc` to keep them). *Remove with data* only deletes the torrent's own file/folder, never a library root or your home folder.
- **🧹 Unused files (admins):** **/admin → Torrents → Find unused files** scans rtorrent's download folder (or any folder you type) for files and folders that no torrent in rtorrent uses any more, e.g. left behind after removing torrents, with their size. Pick what to delete; each item is checked again just before it's removed. Libraries, Delos's own folders and anything containing them are never offered whole; their contents are listed one by one, and items still in a library are marked.
- **Who can add downloads:** admins, plus users given **Make downloader** in Users. Downloaders only see libraries they have access to, and only they or an admin can cancel or remove their downloads. They can't download from private or loopback addresses.

</details>

<details>
<summary><strong>🚦 Stream limits</strong></summary>


Set these under **/admin → Connections → Limits**. Changes apply straight away, with no restart.

| limit | what counts | default |
|---|---|---|
| **Transcodes** | re-encoding video: Transcode mode and PGS burn-in. Heavy on the CPU; a typical seedbox manages 1–2 at 1080p | `-max-streams` (3) |
| **Light streams** | ffmpeg work that doesn't re-encode video: browser playback that only changes the container, and music converted on the fly (wma/ape → mp3) | 10 |
| **Per user** | different videos one person can watch at once, in any mode including the app's Direct play. Music doesn't count, and admins are never limited | 0 = unlimited |

The app's Direct play doesn't use ffmpeg, so it only counts toward the per-user limit. When a limit is reached, the player shows why, e.g. "The server is busy: 2 of 2 transcodes running — try Direct mode" or "You're already watching 1 video at once".

</details>

<details>
<summary><strong>👤 Personal libraries & limits</strong></summary>


Users with the **downloader** role can create **their own libraries** under Downloads → *My libraries*. They give it a name and a type (Movies / TV / Music / Other videos), and choose whether to **share it with everyone**.

- **Where the files go:** the server creates the folder at `<personal libraries folder>/<user>/<library>`. This is set in **/admin → Downloads** and defaults to `~/streammkv-libraries`. Users can't point a library at any other path.
- **Who sees what:**
  - A **private** library is visible only to its owner and admins.
  - A **shared** one is visible to everyone and labelled with the owner, e.g. "from bob".
  - Accounts that an admin limited to specific libraries only see the ones ticked for them.
- **Deleting:** owners can delete files in their own libraries (🗑 in the web app, long-press → *Delete from server* in the app). The movie's folder (nfo, posters, subs) and the matching rtorrent download are removed too. Admins can delete anywhere. Nobody can delete from someone else's library.
- **Limits:** set under **/admin → Users → Limits**, as max items and/or max GB across the user's personal libraries. Downloads that would go over the limit are refused, including magnets once their size is known. A user with a limit can only download into their own libraries. Usage shows in the dashboard and on the user's Downloads page.

</details>

<details>
<summary><strong>💬 People & chat</strong></summary>


- **Who's online:** see who is online and **what they're watching or listening to**, e.g. "▶ Children of Men · 45:12". You can press ▶ to open the same title, if you have access to its library. Anyone can switch on *Hide what I'm watching*; others will still see that they are online.
- **Chats:** 1-to-1 chats and **group chats**. Any member can rename a group or add people; only the group's creator (or an admin) can remove people, and anyone can leave. Unread counts and new-message notifications update live (Server-Sent Events, `GET /api/events`). Admins can't read other people's chats.
- **Send to a friend:** share a movie, episode or song into a chat as a card your friend can tap to play. If they can't open that library, you get a warning.
- **Pictures & files:** 📎 attach pictures or any file (web app: also paste or drag & drop). Pictures show inline (big ones get a small preview) and open full size; other files are a download card. Only the chat's members can open them. Admins set the largest file (default 25 MB, 0 = off) and how long files are kept (default 30 days, 0 = forever) in /admin → *Chat files*; after that the message stays and says the file expired.
- **Emoji & reactions:** 😊 picker with search (web and app), and react to any message — hover and click ☺︎+ on the web, long-press (or right-click) in the app; tap a reaction to add or remove yours.
- **Where:** the people list and 💬 drawer in the web app sidebar, and the **Chat** tab in the app. Notifications appear only while the app or page is open.
- **Profile pictures:** set or remove yours in the app (Settings → Account) or the web app (Chats → *Change picture*). Any JPG/PNG/GIF up to 10 MB; the server crops it square and scales it to 256 px. People without one get their initial on a colour. Admins can remove a picture in /admin → Users.
- **Admins** carry an **ADMIN** tag next to their name in People and Chat.

</details>

<details>
<summary><strong>🎉 Watch party</strong></summary>


Watch a movie or listen to music together: one **host** plays, everyone in the party follows (play, pause, seeking and the next episode / song). Guests can't control playback.

- **Start one:** 🎉 *Watch together* in the video player, 🎉 in the music player, or **🎉 Party → New party** (web sidebar; in the app: Chat → Party, or the 🎉 button at the top). Pick what to play, **now or later** (a scheduled party shows under *Coming up* and everyone invited gets a reminder when it starts), public or private, an optional password, and who to invite.
- **Join:** from an invite, the Party list (public parties), or **ask a friend who's watching**: the 🎉 next to their name in the People list. They choose whether to let you in; if they say yes, what they're playing becomes the party. A private party you weren't invited to can be joined only by asking the host.
- **In the party:** chat, emoji that float over the video, members (👑 = host). **Mute chat** hides chat and emoji just for you. The host can turn chat off for everyone, invite people, let people in, **remove** someone (they can't come back unless invited again), change the title / visibility / password, hand the party over, or end it. If the host leaves, the next person becomes host.
- Time is synced to the server clock; a guest drifting more than ~2.5 s is moved back in step. A guest needs access to the library of what's playing. Parties nobody's in for 30 minutes end by themselves.

</details>

<details>
<summary><strong>📱 Remote control</strong></summary>


Use your phone as the remote for Delos on a PC or TV (the app, or the web page in any browser, TV browsers included), signed in as the same user.

- Phone: long-press a movie, episode or song → **Play on…** → pick the device. It starts there, and the phone shows the remote.
- Remote (📡 in the top bar): your online devices and what each one is playing. Controls: play/pause, seek, ±10/30 s, previous/next song, volume, stop.
- For videos the remote also has shortcuts: subtitles (pick a track or turn them off), subtitle delay ±0.1 s (double-tap to reset), audio track, next episode, full screen, and Home (closes the player and goes back to the start page).
- Commands go through your server, so the phone and the TV don't need to be on the same Wi-Fi. A device appears while Delos is open on it.
- Rename a device: Remote → 🪪 (e.g. "Living room PC").
- **TVs without Delos** (any DLNA TV — LG, Samsung, Sony, Android TV…): while the desktop app at home runs its DLNA server, the TVs on its network show up on the phone as devices too ("TV via *PC name*"). **Play on…** → the TV starts the film from the PC (passed through from the server, DTS / TrueHD converted to AC3 like when browsing), and the remote drives it: play/pause, seek, ±10/30 s, volume, stop, **next episode**, and **audio track** (the TV can't switch tracks, so it starts again from the same spot with the chosen track, converted). Watch progress is saved as usual. Turn it off in Settings → Share to TV (DLNA) → *Show the TVs on your phone*.

</details>

<details>
<summary><strong>📺 Share to TV (DLNA, desktop apps)</strong></summary>


The desktop apps (Windows, macOS, Linux) can act as a DLNA media server so a smart TV on the same network plays what's saved on that PC (offline downloads and your own folders) — handy on a PC or handheld (e.g. ROG Ally) next to the TV.

- Turn it on: Settings → **Share to TV (DLNA)** (or 📺 in Offline). On Windows allow Delos on *Private networks* when asked; on Linux with a firewall allow UDP 1900 and TCP 58200.
- On the TV: LG → Media Player / Photo & Video; Samsung → Connected devices; Android TV → VLC / Kodi (UPnP). Open **Delos (PC name)**: Recently added, Movies, TV shows → seasons → episodes, Videos, Music (albums / artists / all songs), with posters.
- Files are sent as they are (no transcoding), with seeking; a `.srt` next to a video is offered to the TV as subtitles.
- It runs while the app is open; rename it on the same page.
- The computer doesn't go to sleep while a TV is playing from it (or paused in the last few minutes) or while converting; on Modern Standby PCs (ROG Ally, most laptops) the screen stays on for that, since screen-off is sleep there. Can be turned off.
- **Audio the TV can't play** (DTS, TrueHD/Atmos — you pick which): converted to Dolby Digital 5.1 on the fly, the picture untouched, seeking by time. Needs the converter (ffmpeg), which the page downloads for you (≈ 150 MB).
- **Convert ahead (TV copies)**: make a converted copy of a file (or all of them, or automatically for new files) so nothing is converted while you watch and seeking works on every TV. Copies live in the app's folder; delete them any time. Online files can get a copy too (fetched from the server).
- **Play on a TV from your phone**: the TVs this PC sees are listed on the page and on your phone's *Play on…* / Remote (see Remote control).
- **Online library (passthrough)**: also show the server's libraries in an "Online" folder; files stream from the server through the PC (seeking works). For files that need converting, choose where: **This PC** (ffmpeg on the PC) or **Server** (the seedbox converts; uses its CPU).

</details>

<details>
<summary><strong>🏷️ Roles</strong></summary>


Admin → **Roles**: a role is a named set of libraries (e.g. *Family*: Movies + Kids, *Music only*: Music, or *All libraries* including ones added later), optionally with permissions (editor, downloader, offline). Give users one or more roles in **Users → Roles**; they see every library of their roles, and the permissions add up. **Extra libraries** gives one user more on top of their roles. Deleting a role takes it off its members. Users without roles keep working as before (their own library list) and show as **Guest**. Admins always see everything, whatever their roles.

Everyone sees their own roles on the card under *Delos* in the web app, in Chats and in the app's side menu, and other people's roles next to their names in People.

</details>

<details>
<summary><strong>🏆 Ranking</strong></summary>


🏆 *Ranking* (web sidebar; app: Chat → Ranking) shows who watched and listened the most this week / month / year / ever, with badges for hours, finished titles, songs, streaks and this month's top watcher / listener. Only time actually playing counts. People who hide their activity aren't ranked.

</details>

<details>
<summary><strong>🙋 Requests</strong></summary>


🙋 *Requests* (web sidebar; app: Chat → Requests) is where people ask for films and series that aren't on the server yet.

- **Search** TMDB for a film or a series. Each result shows whether it's **already here** (open it straight away), **already asked for** (add your 👍 instead), or can be requested. A year at the end (`Dune 2021`) narrows the search.
- **Open requests** are sorted by votes, so the most wanted are on top. The requester can withdraw an open request.
- **Admins** get a live notice when someone asks, see a count next to *Requests*, and set the status: ⏳ Waiting, 👍 Approved, ✕ Declined (with an optional reason), ✅ Available — or delete it — on the Requests page or in the **Requests** tab of /admin (with notes, votes and filters).
- **The people who asked** get a live notice when the status changes; if they weren't online, a count waits next to *Requests* (in the app: a dot on the Chat tab) and the changed requests are marked **NEW** until they've looked.
- **It turns ✅ Available by itself** when the title shows up in a movie or TV library after a scan (TMDB id match), and everyone who asked or voted gets a live notice with an *Open* button.
- Needs a TMDB key. Admins can switch requests off in **/admin → Features**.

</details>

<details>
<summary><strong>🎤 Lyrics, seek-bar previews & trailers</strong></summary>


**Lyrics** — the 🎤 button in *Now playing* (web) or in the music player (app) shows the words of the song. Synced lyrics highlight the current line and scroll along; tap or click a line to jump there. Delos looks, in order, for:

1. a `.lrc` (or plain-text) file next to the song with the same name, e.g. `03 - Song.lrc`;
2. lyrics in the song's tags (`LYRICS`, `UNSYNCEDLYRICS`, …);
3. [LRCLIB](https://lrclib.net) by artist, title, album and length.

Results are cached; "not found" is tried again after a week, or straight away with *Search again*. In **/admin → Features** you can turn lyrics off, or set *Look up online* to **local files only** or to **another LRCLIB server** — LRCLIB is open source, so if the public site ever goes away you can point Delos at your own copy.

**Seek-bar previews** — hover the seek bar (web, desktop app) or drag it (phone) to see a small frame of that moment. The first time a video is played, the server jumps to each moment and grabs one keyframe there (it reads a few MB per frame, never the whole file, so a 60 GB remux costs the same as a small file), lays the frames out into sprite sheets and keeps them in the cache. Until they're ready the time bubble says *preparing previews · N %*. Frames are every 2 s for short videos, 5 s up to 30 minutes, 10 s beyond — at most 480 per video. Turn them off in **/admin → Features** to save CPU.

**Trailers** — films and series matched on TMDB get a 🎞 *Trailer* button: the trailer plays on YouTube in a window over the page (official trailers first, in the server's TMDB language when there is one), with teasers and other trailers one click away. Turn it off in **/admin → Features**.

</details>

<details>
<summary><strong>📣 Announcements</strong></summary>


Admins post messages to users from **/admin → 📣 Announcements**: a title and a message (links are clickable), a level, who gets it (everyone or chosen users), an optional expiry, and *Pin* to keep it in the list after it's read.

- **Info / Warning** show as a banner at the top of the web app (and a SnackBar in the app). **Important** pops up as a dialog.
- They arrive **live** to everyone who has the web app or the app open, and to the rest the next time they open it.
- The **📣** button (web app sidebar, app top bar) lists the active ones with an unread count; reading or dismissing marks them read.
- The dashboard shows how many of the audience have read each one (hover for names). Editing can **show it again to everyone**; deleting removes it everywhere.

</details>

<details>
<summary><strong>📥 Offline library (app)</strong></summary>


The app can play things **without the server**, in two clearly separate places (📥 Offline tab):

- **☁️ Downloaded from server** — users with the **Offline downloads** permission (admins always; dashboard → Users → *Allow offline*) long-press a movie/episode → *Download to this device*. Downloads run in the background with a notification, can be paused/resumed, and can be removed from the device (the file stays on the server). Downloaded posters get a 📥 badge, and playing them uses the local copy — progress is synced back to the server when it's reachable.
- **📁 My folders** — add any folder of your own videos on the device (Movies / TV series / Other videos). Files are named-parsed like the server does and scraped from TMDB: through the server when signed in (no key needed), or with your own TMDB key (⚙ Offline settings) when not. On iOS the folder is the app's own *Files → On My iPhone → Delos → My Videos*.

The player shows where a video comes from: **LOCAL** (green: downloaded / my folder) or **STREAM** (blue: Direct / Transcode).

**Where downloads go** (⚙ Offline settings): inside the app (private, default), or on Android the app's folder on device storage / SD card (`Android/data/dev.un4ckn0wl3z.streammkv/files/Delos`, visible over USB and in file managers; Android removes it when the app is uninstalled), on iOS the app's Files folder, and on Windows/Linux/macOS any folder. New downloads use the new place; earlier ones stay where they are.

**Offline mode:** on the sign-in screen choose *Use offline — without a server*; the app opens straight to the offline library next time. If the server can't be reached while signed in, the error screen has an *Offline library* button.

Notes: the permission controls the app's download feature — anyone who can stream (Direct) technically receives the whole file anyway. `GET /api/download?path=` (Range supported, 3 at a time per user) and `POST /api/meta/lookup` back this.

</details>

<details>
<summary><strong>🛡️ Users & admin dashboard</strong></summary>


Delos supports several users. Each user has their own watch progress, resume positions and track choices. Admins choose which libraries each user can see.

- **Dashboard:** `http://<server>/admin`. Admins can add users, reset passwords, promote users to admin, sign a user out on every device, and view or clear a user's history. The dashboard also shows who is watching now, the open streams and whether each one is direct or transcode, library and disk stats, and update status. A user who is not an admin only gets a "change password" page there. It's split into tabs — 📊 Overview, 📚 Libraries, 🙋 Requests, ⬇ Downloads, 👥 Users & roles, ⚙ Settings — and remembers the last one (`/admin#users` opens a tab directly).
- **CLI on the seedbox:** `~/streammkv/run.sh user list | add NAME [--admin] [--password P] | passwd NAME | admin NAME on|off | revoke NAME | del NAME`. If you leave out the password, a random one is generated. The running server picks up changes within 2 seconds.
- **Storage:** users are kept in `<data>/users.json` with PBKDF2-SHA256 password hashes. When you change a password or sign a user out, every existing session for that user stops working.
- **First start:** the first admin is created from `-user/-pass`. After that those flags are ignored. When you upgrade from a single-user install, your existing account becomes the admin and keeps its watch progress.

</details>

<details>
<summary><strong>🔄 Versions & updates</strong></summary>


- The `VERSION` file is the single source for the version. `tools/bump.sh X.Y.Z` updates it together with the app version (and the retired userscript stub). Commit and push, and CI builds the server binaries, `SHA256SUMS` and the APKs. It uploads them to a draft release and publishes the release once everything is there.
- **Server:** checks GitHub every 6 hours. With auto-update on (the default, which you can toggle in the dashboard), it downloads the new binary, checks it against `SHA256SUMS`, swaps it in and re-execs itself with the same PID. The previous binary is kept as `streammkv.old`. It only installs while nobody is streaming. You can also press **Update now** in the dashboard.
- **App:** when it starts, it checks the latest release and offers the APK built for your phone's CPU. *Settings → Check for app updates* runs the check by hand. Android does not let sideloaded apps install updates silently, so you still have to tap Install.
- **Web app:** part of the server — it updates with it.

</details>

<details>
<summary><strong>📲 Apps: Android, iOS, Windows, Linux, macOS</strong></summary>


The app is written in Flutter with [media_kit](https://github.com/media-kit/media-kit) (libmpv) and is the same on every platform. Download it from [Releases](https://github.com/un4ckn0wl3z/delos/releases/latest).

The app browses libraries the same way the web app does: Home (continue watching / recently added), movies with posters and genre filters, TV shows with seasons and Next up, and music by album, artist, genre or song. It has a mini player and background audio. **Long-press** a poster or episode to open a menu (on desktop, right-click). It offers Play/Resume, **Start over** and **Remove from Continue watching**. Admins and editors also get **Identify…**, which lets you search TMDB, pick the right title or type a TMDB ID; **Re-detect** returns the title to automatic matching. Other metadata edits are only in the web app.

| Platform | File | Install |
|---|---|---|
| Android | `streammkv-android-arm64-v8a.apk` | Open the APK. When an update fails with "App not installed", uninstall the old app first; your watch progress is kept on the server. |
| iOS / iPadOS | `streammkv-ios.ipa` (unsigned) | Install with [SideStore](https://sidestore.io) or [AltStore](https://altstore.io) using a free Apple ID. See below. |
| Windows 10/11 | `streammkv-windows-x64.zip` | Unzip and run `Delos.exe`. |
| Linux x64 | `streammkv-linux-x64.tar.gz` | Install libmpv first (`sudo apt install libmpv2`), then unpack and run `Delos/streammkv`. A `.desktop` file is included. |
| macOS 11+ (Intel & Apple Silicon) | `streammkv-macos.zip` | Unzip and move `Delos.app` to Applications. The app is not notarized, so run `xattr -dr com.apple.quarantine /Applications/Delos.app` once, or allow it under System Settings → Privacy & Security → Open Anyway. |

On Windows, Linux and macOS: ⛶ in the top bar or **F11** puts the whole app in full screen (remembered next time). In the player, press **F** or double-click the middle of the video for fullscreen. Other keys: space play/pause, ←/→ ±10s, J/L ±30s, ↑/↓ volume, A cycles audio, C cycles subtitles, Z/X adjust subtitle delay, Esc leaves fullscreen. **Settings → Streaming buffer** sets how far ahead the app reads (Auto ≈ 2 minutes of the file, or 64 MB – 1 GB).

#### iOS with SideStore / AltStore (free Apple ID)

1. Set up SideStore or AltStore once, following their guides. The first setup needs a computer.
2. In SideStore/AltStore open **Sources → +** and add
   `https://github.com/un4ckn0wl3z/delos/releases/latest/download/altstore-source.json`
3. Install **Delos** from that source. Once a new release is out, the source shows the update.
4. Apps signed with a free Apple ID expire after **7 days**, and you can have at most 3 sideloaded apps. Refresh Delos in SideStore before it expires; SideStore can do this on the phone, or set up the auto-refresh Shortcut.

With a paid Apple Developer account, the same CI could upload to TestFlight instead.

#### Android details

The `app/` folder holds a Flutter app that uses [media_kit](https://github.com/media-kit/media-kit) (libmpv). Install the APK from [Releases](https://github.com/un4ckn0wl3z/delos/releases): `streammkv-android-arm64-v8a.apk` works on most phones.

- **Direct**: mpv streams the original MKV through `/api/raw`, which supports HTTP Range. It plays every codec (HEVC, DTS, TrueHD…), switches between the file's audio and subtitle tracks, and renders full ASS styling and PGS. Seeking is native and accurate, and the server uses almost no CPU, but this mode needs enough bandwidth for the original bitrate.
- **Transcode 1080/720/480p**: plays the stream from `/api/stream`. Use it to save data on a mobile network.
- **Watch progress and tracks** are stored on the server (`/api/progress`), so the app and every browser can pick up where you left off.
- **Gestures**: double-tap the left/right side to skip back/forward 10s, double-tap the middle to play or pause. The ⚙ menu has quality, subtitle delay and subtitle size.

Build it yourself:

```bash
cd app
flutter create --org dev.un4ckn0wl3z --project-name streammkv --platforms android .
python3 tool/patch_android.py      # INTERNET permission, cleartext HTTP, app label
flutter build apk --release --split-per-abi
```

CI (`.github/workflows/app.yml`) signs the APK with the key from the `ANDROID_DEBUG_KEYSTORE_B64` secret, a base64-encoded keystore with alias `androiddebugkey` and password `android`. If that secret isn't set, every build gets a different key, and you have to uninstall the old version before installing a new one.

</details>

<details>
<summary><strong>⚙️ How it works</strong></summary>


### Playing in the browser (default)

The web app plays the **original file** itself, like mpv does in the app:

- It reads the file straight from the server with HTTP Range requests (`/api/raw`) — the server only sends bytes: **no ffmpeg, no stream slot, instant seeking**.
- [Mediabunny](https://mediabunny.dev) demuxes the MKV/MP4 in the browser; video is decoded by the device's own decoder through **WebCodecs** (usually hardware: H.264, HEVC, AV1, VP9).
- **AC-3, E-AC-3 (DD+), DTS and TrueHD** audio — which browsers can't play — are decoded by FFmpeg compiled to **WebAssembly** (downloaded only when a file needs them; ~0.2–0.4 MB each, gzipped), so you get **any audio track** and the original channels.
- Video is drawn on a canvas and kept in sync with the audio clock; text subtitles use the same overlay as before.
- Browsers only offer WebCodecs on a **secure page** (https or localhost) — see [HTTPS](#https-built-in); on plain http the web app offers a one-click switch.
- It falls back to the server **automatically** when the browser can't do it — e.g. a video codec the device can't decode (old DivX, HEVC 10-bit without hardware support), image subtitles (PGS/VobSub, burned in by the server), or a browser without WebCodecs. The player's badge says which is used: **direct · in browser**, **remux · server** or **transcode**. *Video* lets you pick, and ⚙ Settings → *Playback* can make the server the default.

#### Playing through the server

- **Video**: if the browser can decode the video codec (H.264 8-bit, HEVC/AV1/VP9 when supported), it is passed through unchanged with `-c:v copy`, which uses almost no CPU. Otherwise it is transcoded to H.264 with `libx264 veryfast`, scaled down to the max height you choose.
- **Audio**: only the selected track is sent (`-map 0:a:N`). It is always converted to stereo AAC, because browsers cannot play AC3/DTS/TrueHD.
- **Seeking**: the client sends a new request with `?start=`. In copy mode it first asks for the nearest keyframe (`/api/keyframe`) so the seek bar and subtitles stay in sync.
- **Text subtitles** (SRT/ASS/VTT): extracted to WebVTT and cached on the server, then drawn by the web app in an overlay. You can adjust the subtitle delay and change subtitles without restarting the video.
- **Image subtitles** (PGS/VobSub): burned into the video, which forces transcode mode.
- **The UI is served by the server itself** (same origin as the media), so there are no CORS, mixed-content or CSP problems.

</details>

<details>
<summary><strong>🐳 Run with Docker</strong></summary>


The image has the server, ffmpeg and a built-in rtorrent (for downloads), for `linux/amd64` and `linux/arm64`:

```bash
curl -O https://raw.githubusercontent.com/un4ckn0wl3z/delos/main/docker-compose.yml
# edit: /path/to/media → your media folder, PUID/PGID → your user (`id`)
docker compose up -d
docker compose logs delos          # first start prints the admin password
```

Then open `http://<host>:8090`. Or without compose:

```bash
docker run -d --name delos -p 8090:8090 -p 50000:50000 -p 6881:6881/udp \
  -e PUID=$(id -u) -e PGID=$(id -g) -e TZ=Asia/Bangkok \
  -v ./data:/data -v /path/to/media:/media ghcr.io/un4ckn0wl3z/delos:latest
```

| | |
|---|---|
| `/media` | your library — the first library points here; more can be added in /admin (anywhere under `/media`, or mount more folders) |
| `/data` | users, settings, watch progress, chat, caches and the built-in rtorrent's session |
| `PUID` / `PGID` | files Delos and rtorrent write (downloads, personal libraries in `/media/personal`) belong to this user |
| `STREAMMKV_USER` / `STREAMMKV_PASS` | the first admin (only used when there are no users yet; otherwise a random password is printed in the log) |
| `RTORRENT=0` | don't run the built-in rtorrent; `STREAMMKV_RTORRENT=scgi://host:5000` (or a socket path / http URL) uses another one |
| ports | `8090` web app + API · `50000` + `6881/udp` incoming peers / DHT for the built-in rtorrent |

Already running the old image `ghcr.io/un4ckn0wl3z/streammkv`? It keeps getting the same releases, so nothing breaks — switch the `image:` line to `ghcr.io/un4ckn0wl3z/delos:latest` whenever you like (your `./data` stays as it is).

Torrents download to `/media/downloads` by default (or to the library you pick). The built-in rtorrent's settings are in `/data/rtorrent/rtorrent.rc` — edit and restart the container to change them.

**Updating:** `docker compose pull && docker compose up -d` (the dashboard's self-update is turned off inside Docker). Put it behind a reverse proxy with HTTPS for access from the internet.

</details>

<details>
<summary><strong>🌱 Install on the seedbox (no root, no package manager needed)</strong></summary>


**From your PC (easiest):** download and run the deploy script. It asks for the seedbox host, SSH user/port, your movie folder and an optional port, then installs or upgrades over SSH. You only type the SSH password. It remembers your answers for next time.

- Windows 10/11: [`deploy/deploy.cmd`](deploy/deploy.cmd). Double-click it; it uses the built-in OpenSSH client.
- Linux / macOS: [`deploy/deploy.sh`](deploy/deploy.sh). Run `bash deploy.sh`.

At the end it prints the URL, username and password to open in a browser or put into the app. Run it again any time to upgrade to the latest release; the port and password stay the same.

**Or, on the seedbox itself** (one-liner; downloads the release binary + static ffmpeg, picks a free port, generates a password, starts the server and adds an autostart cron):

```bash
curl -fsSL https://raw.githubusercontent.com/un4ckn0wl3z/delos/main/deploy/install.sh | MEDIA_ROOT=~/torrents bash
```

Re-running it upgrades to the latest release and keeps the port/password. Manage with `~/streammkv/run.sh {start|stop|restart|status}`; config lives in `~/streammkv/streammkv.env`.

**rtorrent:** if the seedbox already runs rtorrent (almost all do), Delos finds and uses it. If none is found, the installer asks whether to install one — a fully static rTorrent 0.9.8 ([jesec/rtorrent](https://github.com/jesec/rtorrent)), no root needed. It downloads into `<media>/downloads`, gets its own port, and `run.sh` starts, stops and watches it together with Delos. Answer ahead with `INSTALL_RTORRENT=1` (or `0`). http and YouTube downloads work without rtorrent.

#### Manual install

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

#### Flags / env

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
| | `STREAMMKV_UPDATE_REPO` | `un4ckn0wl3z/delos` | GitHub repo to update from (forks) |
| `-tls` | `STREAMMKV_TLS` | `on` | https on the same port as http (`off` to disable) |
| `-tls-cert` / `-tls-key` | `STREAMMKV_TLS_CERT` / `_KEY` | — (built-in certificate) | use your own certificate (reloaded when the file changes) |
| | `STREAMMKV_TLS_HOSTS` | — | extra names/IPs for the built-in certificate, comma-separated |
| `-max-streams` | `STREAMMKV_MAX_STREAMS` | `3` | starting value for the transcode limit (change it later in /admin) |

#### HTTPS (built in)

The server answers **http and https on the same port** — `http://box:port` and `https://box:port` both work, and the apps don't need any change. Browsers need https for in-browser playback (WebCodecs), so on an http page the web app shows a **Switch to https** button (your login carries over).

- With no certificate configured, the server makes its own small certificate authority in `<data>/tls`. The first visit shows a browser warning — click *Advanced → Proceed* once — or install the certificate from **`/tls`** (a help page with a download button and steps for Windows, macOS, iPhone/iPad, Android, Linux and Firefox) so the warning never appears.
- That certificate is **name-constrained** to this server's own names/IPs, so it can't be misused for any other website. The names are learned from the address you open **/admin** with, and can be edited in the dashboard's *HTTPS* section (changing them makes a new certificate that devices must install again).
- Have a real certificate (Let's Encrypt, Cloudflare origin cert, …)? Set `STREAMMKV_TLS_CERT` / `STREAMMKV_TLS_KEY`.

#### Reverse proxy

If the seedbox already has nginx with a real certificate, you can also mount Delos under a subpath:

```nginx
location /streammkv/ {
    proxy_pass http://127.0.0.1:8090/;
    proxy_buffering off;              # required for streaming
    proxy_read_timeout 6h;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

Then open `https://your.box/streammkv/`.

</details>

<details>
<summary><strong>🌐 Use it in a browser</strong></summary>


1. Open the server's address, e.g. `http://your-seedbox:8090/`, and sign in. Nothing to install.
2. To get an app icon: Chrome/Edge → **Install app** (address bar or menu), Android Chrome → **Add to Home screen**, iPhone Safari → Share → **Add to Home Screen**.
3. ⚙ Settings: preferred audio / subtitle languages (e.g. audio `jpn,eng`, subs `tha,eng`), playback engine, max height for transcoding.

The left sidebar lists your libraries. **Home** shows *Continue watching* and *Recently added*. Movies and shows can be filtered by genre. Music has Albums / Artists / Genres / Songs tabs and a player bar at the bottom with a queue, shuffle and repeat. Admins get a 🛡 link to the dashboard.

> **Upgrading from the userscript (≤ 1.9):** the web app replaces it — remove *Delos* from Tampermonkey. Until you do, the userscript stays out of the way (and on servers older than 2.0 it keeps working as before).

#### Keyboard

`space`/`k` play/pause · `←/→` ±10s · `j/l` ±30s · `a` cycle audio · `c` cycle subs · `z/x` sub delay ±0.1s · `f` fullscreen · `m` mute · `↑/↓` volume

Fold the sidebar to a rail of icons with the ◧ button at its top or `Ctrl+B` (`⌘B` on a Mac); it stays that way.

#### Remembered per file

For each file, the server remembers your playback position and the audio/subtitle tracks you picked. The browser and the Android app share this, so you can stop on one and continue on the other.

</details>

<details>
<summary><strong>⚠️ Limitations</strong></summary>


- The first time you open a text subtitle track, the server has to read the whole MKV to extract it (a 20 GB file can take tens of seconds). After that it is served from cache.
- Copy mode seeks to the nearest keyframe before the point you chose (usually no more than 2–10 seconds earlier).
- Transcoding 4K or burning in subtitles uses a lot of CPU. If the seedbox is weak, set Max height to 720p.
- In-browser playback needs WebCodecs (Chrome / Edge / Firefox / Safari, recent versions); HEVC needs a hardware decoder on the device. Otherwise the server is used.

</details>

<details>
<summary><strong>🔌 API</strong></summary>


All endpoints except the web app's files (`/`, `/app.js`, `/vendor/…`, icons) and `/api/login` need auth: the `streammkv` cookie, an `Authorization: Bearer <token>` header, or `?token=`.

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
GET  /api/me                              → {"user","admin","editor","version","roles","features":{lyrics,trickplay,requests}}
GET  /api/lyrics       ?path=[&refresh=1] → {"synced" (LRC),"plain","source":"file|tags|lrclib"}
GET  /api/trickplay    ?path=            → {ready,interval,w,h,cols,rows,sheets,count} · 202 {pending,progress} while being made
GET  /api/trickplay/sheet ?path=&n=      → JPEG sprite sheet n (frame i: sheet i/(cols*rows), cell i%(cols*rows))
GET  /api/trailers     ?lib=&movie=<id>|&show=<key> → {"online":[{site,key,name,type,official,lang}]} (YouTube, via TMDB)
GET  /api/requests                        → {requests[],tmdb,manage}
GET  /api/requests/search ?q=&kind=movie|tv → TMDB results + {have,lib,where,request}
POST /api/requests     {"kind","tmdbId"}  (asks, or votes when it was already asked for)
POST /api/requests/{id}/vote {"on"}       DELETE /api/requests/{id}  (requester while open, or admin)

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
GET|POST /api/admin/settings              {"autoUpdate"?, "tmdbKey"?, "tmdbLang"?, "lyrics"?, "lyricsSource"? ("" | "off" | URL), "trickplay"?, "requests"?, "trailers"?}
POST   /api/requests/{id}/status          {"status":"pending|approved|declined|available","note"}
GET|POST /api/admin/libraries             {"name","type":"movies|tv|music|videos","path"}
PUT|DELETE /api/admin/libraries/{id}      POST /api/admin/libraries/{id}/scan[?refresh=1]
GET    /api/admin/browse ?path=           folder picker
POST   /api/admin/users/{name}/libraries  {"libraries": [ids] | null (= all)}
POST   /api/admin/users/{name}/editor     {"editor": bool}
```

</details>

---

<p align="center"><sub>Made for a seedbox and a sofa. 🛋️</sub></p>
