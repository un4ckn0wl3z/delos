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
  <b>บริการสตรีมมิ่งส่วนตัวบน seedbox</b> — server ภาษา Go ตัวเดียว พร้อมเว็บและแอปทุก platform
</p>

<p align="center">
  <a href="README.md">English</a> · <b>ภาษาไทย</b>
</p>

<p align="center">
  <a href="#-เริ่มใช้งาน">เริ่มใช้งาน</a> ·
  <a href="#-ภาพตัวอย่าง">ภาพตัวอย่าง</a> ·
  <a href="#-ภาพรวมระบบ">ภาพรวมระบบ</a> ·
  <a href="#-คู่มือ">คู่มือ</a> ·
  <a href="https://github.com/un4ckn0wl3z/delos/releases/latest">ดาวน์โหลด</a>
</p>

---

*ชื่อเดิม StreamMKV* ตั้งตามเกาะ Delos บ้านเกิดของฝาแฝด Artemis กับ Apollo — 🌙 **Artemis** ดูแลหนังและซีรีส์ ☀️ **Apollo** ดูแลเพลง

## ✨ จุดเด่น

| | |
|---|---|
| 🎬 | **เล่น MKV ได้ทุกไฟล์ใน browser** ใช้ไฟล์ต้นฉบับ เลือกเสียงพากย์ได้ทุกแทร็ก (DTS / TrueHD / AC-3 ถอดรหัสด้วย WebAssembly) เลือกซับได้ทุกแทร็ก server แปลงไฟล์เฉพาะตอนที่จำเป็น |
| 🗂️ | **หนัง ซีรีส์ เพลง และวิดีโออื่น** มีโปสเตอร์และข้อมูลจาก TMDB / MusicBrainz จัดซีรีส์เป็นซีซั่น มีปุ่มตอนถัดไป |
| 🎤 | **เนื้อเพลงแบบ sync** ภาพตัวอย่างบนแถบเลื่อนเวลา และ **ระบบขอหนัง** ขอเรื่องที่ยังไม่มี โหวต แล้วได้แจ้งเตือนเมื่อมีแล้ว |
| ⬇️ | **ดาวน์โหลด** จาก http, torrent (rtorrent) และ YouTube เข้า library ตรงๆ พร้อมเช็คไฟล์ซ้ำ |
| 📲 | **แอป Android, iOS, Windows, macOS, Linux** เล่นด้วย mpv ดาวน์โหลดไว้ดู offline และเพิ่มโฟลเดอร์ของตัวเองได้ |
| 🎉 | **ดูด้วยกัน แชท จัดอันดับ** ดูพร้อมกันแบบ sync เห็นว่าเพื่อนดูอะไรอยู่ มี badge |
| 📱 | **รีโมต** ใช้มือถือคุม Delos บน PC / ทีวี ผ่านอินเทอร์เน็ตได้ |
| 📺 | **DLNA ให้ทีวี** จากแอปบน PC แปลงเสียงให้ทีวีได้ทั้งแบบสดและแปลงเก็บไว้ |
| 🛡️ | **หลาย user** มี role, กำหนด library ที่แต่ละคนเห็น, โควต้า, ประกาศ และหน้า admin ครบ |

## 📸 ภาพตัวอย่าง

<table>
  <tr>
    <td width="50%"><img src="docs/images/home.webp" alt="หน้าแรก"><br><sub><b>หน้าแรก</b> — ดูต่อ, เรื่องใหม่, เพื่อนที่ออนไลน์</sub></td>
    <td width="50%"><img src="docs/images/movie.webp" alt="หนัง"><br><sub><b>หนัง</b> — โปสเตอร์ นักแสดง และดูต่อจากที่ค้างไว้</sub></td>
  </tr>
  <tr>
    <td><img src="docs/images/show.webp" alt="ซีรีส์"><br><sub><b>ซีรีส์</b> — แยกซีซั่นและตอน มีตอนถัดไป</sub></td>
    <td><img src="docs/images/player.webp" alt="ตัวเล่น"><br><sub><b>ตัวเล่น</b> — เล่นไฟล์ต้นฉบับใน browser</sub></td>
  </tr>
  <tr>
    <td><img src="docs/images/music.webp" alt="เพลง"><br><sub><b>เพลง</b> — อัลบั้ม คิว เล่นเบื้องหลัง</sub></td>
    <td><img src="docs/images/admin.webp" alt="Admin"><br><sub><b>Admin</b> — role ผู้ใช้ และสิทธิ์</sub></td>
  </tr>
</table>

<sub>ภาพตัวอย่างใช้ library สมมุติ ชื่อเรื่องและภาพทั้งหมดสร้างขึ้นเอง</sub>

## 🧭 ภาพรวมระบบ

```mermaid
flowchart LR
  subgraph Seedbox["🌱 Seedbox / server"]
    direction TB
    S["Delos server<br/>(Go ไฟล์เดียว)"]
    FF["ffmpeg / ffprobe"]
    RT["rtorrent"]
    YT["yt-dlp"]
    LIB[("โฟลเดอร์ไฟล์<br/>หนัง · ซีรีส์ · เพลง")]
    S --- FF
    S --- RT
    S --- YT
    RT --> LIB
    YT --> LIB
    S --> LIB
  end
  TMDB["🎞️ TMDB<br/>🎵 MusicBrainz"]
  S -->|ข้อมูลและโปสเตอร์| TMDB

  subgraph Clients["👥 ผู้ใช้"]
    direction TB
    W["🌐 เว็บ (PWA)"]
    A["📱 แอป Android / iOS"]
    D["💻 แอป PC<br/>Windows · macOS · Linux"]
  end
  W <-->|"HTTPS · API · live events"| S
  A <-->|"HTTPS"| S
  D <-->|"HTTPS"| S
  TV["📺 สมาร์ททีวี"]
  D -->|"DLNA (ในบ้าน)"| TV
  A -.->|"📱 รีโมต<br/>ผ่าน server"| D
```

ทุกอย่างรันเป็นโปรแกรม Go ตัวเดียวข้างๆ ไฟล์หนัง browser เปิดเว็บจาก address เดียวกัน แอปใช้ API เดียวกัน server ดึงโปสเตอร์และข้อมูลเอง สั่ง rtorrent / yt-dlp ดาวน์โหลด และใช้ ffmpeg เฉพาะตอนที่อุปกรณ์เล่นไฟล์ต้นฉบับไม่ได้

### ▶️ เล่นวิดีโอยังไง

```mermaid
flowchart TD
  P(["กด ▶ เล่น"]) --> Q{"เล่นจากอะไร?"}
  Q -->|"📲 แอป"| M["mpv เล่นไฟล์ต้นฉบับ<br/>/api/raw · byte ranges<br/>ได้ทุก codec"]
  Q -->|"🌐 Browser"| C{"เครื่องถอดรหัสภาพได้ไหม?<br/>(WebCodecs)"}
  C -->|"ได้"| B["เล่นใน browser เอง<br/>Mediabunny + WebCodecs<br/>DTS/TrueHD/AC-3 → WASM<br/>ไม่ใช้ CPU ของ server"]
  C -->|"ไม่ได้"| R{"codec ภาพ<br/>browser รองรับไหม?"}
  R -->|"รองรับ"| X["server remux<br/>ภาพเดิม · เสียง → AAC"]
  R -->|"ไม่รองรับ / ซับภาพ"| T["server transcode<br/>H.264 · ฝังซับ PGS"]
  M --> PR[("💾 จำตำแหน่งและแทร็ก<br/>แยกตาม user")]
  B --> PR
  X --> PR
  T --> PR
```

### ⬇️ เพิ่มดาวน์โหลด

```mermaid
flowchart LR
  L["วางลิงก์"] --> K{"ลิงก์แบบไหน?"}
  K -->|"http(s)"| H["server โหลดเอง<br/>(restart แล้วโหลดต่อ)"]
  K -->|"magnet / .torrent"| RT["rtorrent<br/>โหลดและ seed"]
  K -->|"YouTube"| Y["yt-dlp<br/>วิดีโอ หรือเสียงพร้อม tag"]
  L --> DUP{"มีอยู่แล้วไหม?<br/>torrent · ไฟล์ · หนังเรื่องเดียวกัน"}
  DUP -->|"มี"| W["⚠ เตือน · จะโหลดต่อไหม?"]
  H --> F[("โฟลเดอร์ library")]
  RT --> F
  Y --> F
  F --> S["สแกน → match TMDB<br/>→ ขึ้นให้ทุกคนเห็น"]
```

### 📱 รีโมต

```mermaid
sequenceDiagram
  autonumber
  participant Phone as 📱 มือถือ (แอป)
  participant Server as 🌱 Delos server
  participant PC as 💻 PC / browser บนทีวี
  PC->>Server: hello (ทุก 30 วิ) + กำลังเล่นอะไร
  Phone->>Server: ขอรายชื่อเครื่องของฉัน
  Server-->>Phone: PC · ว่างอยู่
  Phone->>Server: เล่น "Low Orbit" บน PC
  Server-->>PC: remote-cmd (live event)
  PC->>PC: เปิดตัวเล่น
  PC->>Server: สถานะ: กำลังเล่น 00:12
  Server-->>Phone: remote-state → แถบเวลา ซับ เสียง ตอนถัดไป
```

### 📺 แชร์ให้ทีวี (DLNA)

```mermaid
flowchart LR
  TV["📺 ทีวี<br/>Media Player"] -- "เลือก / เล่น" --> DA["💻 แอป PC<br/>DLNA server"]
  DA --> LF[("ไฟล์ที่ดาวน์โหลดไว้<br/>+ โฟลเดอร์ของคุณ")]
  DA -. "โฟลเดอร์ Online<br/>(passthrough)" .-> SV["🌱 Delos server"]
  DA --> Q{"เสียงที่ทีวี<br/>เล่นไม่ได้?<br/>DTS · TrueHD"}
  Q -->|"ไม่ใช่"| D1["ส่งไฟล์ไปตรงๆ<br/>กรอได้ปกติ"]
  Q -->|"ใช่"| Q2{"มี TV copy แล้ว?"}
  Q2 -->|"มี"| D2["เล่นจากสำเนา<br/>(AC3 กรอได้ทุกจุด)"]
  Q2 -->|"ไม่มี"| D3["แปลงสด → AC3<br/>ที่ PC หรือที่ server<br/>กรอด้วยเวลา"]
```

### 🏷️ ใครเห็นอะไร

```mermaid
flowchart LR
  subgraph Roles
    F["🏷 Family"]
    MU["🏷 Music lovers"]
  end
  F --> L1["🎬 หนัง"]
  F --> L2["📺 ซีรีส์"]
  MU --> L3["🎵 เพลง"]
  U1["theo"] --> F
  U1 --> MU
  U2["ploy"] --> F
  U3["sam (Guest)"] -. "เฉพาะที่ตั้งให้รายคน" .-> L1
  A["👑 admin"] ==> ALL["เห็นทุกอย่าง"]
```

## 🚀 เริ่มใช้งาน

**🐳 Docker** (มี server + ffmpeg + rtorrent ครบในอิมเมจเดียว)

```bash
curl -O https://raw.githubusercontent.com/un4ckn0wl3z/delos/main/docker-compose.yml
# แก้ /path/to/media เป็นโฟลเดอร์หนัง และ PUID/PGID เป็น user ของคุณ (คำสั่ง `id`)
docker compose up -d && docker compose logs delos   # รันครั้งแรกจะพิมพ์รหัสผ่าน admin ออกมา
```

**🌱 Seedbox ที่ไม่มี root**

```bash
curl -fsSL https://raw.githubusercontent.com/un4ckn0wl3z/delos/main/deploy/install.sh | MEDIA_ROOT=~/torrents bash
```

หรือรันสคริปต์จาก PC แล้วตอบคำถามไม่กี่ข้อ: [`deploy/deploy.cmd`](deploy/deploy.cmd) (Windows) / [`deploy/deploy.sh`](deploy/deploy.sh) (Linux / macOS)

**📲 แอป** — [ดาวน์โหลดจาก Releases](https://github.com/un4ckn0wl3z/delos/releases/latest):

| Platform | ไฟล์ | หมายเหตุ |
|---|---|---|
| 🤖 Android | `streammkv-android-arm64-v8a.apk` | เปิดไฟล์เพื่อติดตั้ง |
| 🍎 iOS / iPadOS | `streammkv-ios.ipa` | ติดตั้งผ่าน SideStore / AltStore |
| 🪟 Windows | `streammkv-windows-x64.zip` | แตกไฟล์แล้วเปิด `Delos.exe` |
| 🐧 Linux | `streammkv-linux-x64.tar.gz` | ต้องมี `libmpv2` |
| 🍏 macOS | `streammkv-macos.zip` | Intel และ Apple Silicon |

จากนั้นเปิด `http://<server>:8090` แล้ว login หรือใส่ address เดียวกันในแอป

## 📚 คู่มือ

กดหัวข้อเพื่อเปิดอ่าน

<details>
<summary><strong>🗂️ Library และข้อมูลหนัง</strong></summary>

admin เพิ่ม library ได้ไม่จำกัดที่ **/admin → Libraries** เลือกโฟลเดอร์บน seedbox ด้วยตัวเลือกโฟลเดอร์ แล้วเลือกประเภท:

| ประเภท | ได้อะไร |
|---|---|
| **Movies** | match กับ TMDB จากชื่อไฟล์หรือชื่อโฟลเดอร์ เช่น `Children.of.Men.2006.1080p…` ได้โปสเตอร์ ภาพพื้นหลัง เรื่องย่อ แนว คะแนน ผู้กำกับ และนักแสดง ไฟล์หลายไฟล์ของหนังเรื่องเดียวกันจะรวมเป็น "versions" |
| **TV series** | รู้จัก `S01E02`, `1x02` และโฟลเดอร์ `Season N/` ได้ข้อมูลซีรีส์ แท็บซีซั่น ชื่อตอน ภาพและเรื่องย่อของแต่ละตอน และปุ่ม **Next up** |
| **Music** | `.mp3 .flac .m4a .ogg .opus .wav .wma …` อ่าน tag ด้วย ffprobe ดูตามอัลบั้ม ศิลปิน แนว หรือเพลง ปกอัลบั้มมาจาก `cover.jpg`/`folder.jpg` ถ้าไม่มีใช้ภาพที่ฝังในไฟล์ แล้วจึงหาจาก MusicBrainz/Cover Art Archive |
| **Other videos** | เปิดดูเป็นโฟลเดอร์ธรรมดา ไม่ดึงข้อมูล |

- **TMDB key:** ใส่ที่ **/admin → Metadata** ใช้ v3 API key ฟรีหรือ v4 read token ก็ได้ เลือกภาษาของข้อมูลได้ เช่น `th-TH` ถ้าเรื่องไหนไม่มีเรื่องย่อภาษานั้นจะใช้ภาษาอังกฤษแทน ถ้าไม่ใส่ key หนังและซีรีส์ยังเล่นได้ แค่ไม่มีโปสเตอร์และข้อมูล
- **ยกเว้นโฟลเดอร์:** ที่ **Edit library → Exclude folders** ใส่ทีละบรรทัด หรือกด **Add folder…** ถ้ามี `/` เช่น `Extras/Featurettes` หมายถึงโฟลเดอร์นั้นโฟลเดอร์เดียว ถ้าไม่มี เช่น `Sample` หรือ `Behind*` หมายถึงโฟลเดอร์ชื่อนี้ทุกระดับ โฟลเดอร์ที่ยกเว้นจะไม่ขึ้นในรายการและเล่นไฟล์ข้างในไม่ได้
- **Test:** **/admin → Metadata → Test** เช็ค 4 อย่าง: TMDB key และ server ต่อ TMDB ได้ไหม, ต่อ MusicBrainz ได้ไหม, browser นี้โหลดภาพโปสเตอร์ได้ไหม และแต่ละ library มีภาพกี่เรื่อง พร้อมบอกเรื่องที่ match ไม่ได้ และเตือน library ที่จะไม่มีวันได้ข้อมูล เช่นประเภท *Other videos* ทดสอบ key ก่อนบันทึกได้
- **การสแกน:** สแกนทุก library ใหม่ทุก 30 นาที หรือกด **Scan** เพื่อสแกนทันที **Refresh metadata** จะ match ใหม่ทั้งหมด ผลเก็บไว้ใน `<data>/index/` และปกใน `<data>/covers/` สแกนรอบหลังจึงหาเฉพาะเรื่องใหม่
- **สิทธิ์ราย user:** **/admin → Users → Libraries** เลือกว่าแต่ละคนเห็น library ไหน ค่าเริ่มต้นคือเห็นทั้งหมด เช่นให้บัญชีเด็กเห็นแค่ Music (หรือใช้ Roles จัดเป็นกลุ่ม ดูหัวข้อ Roles ด้านล่าง)
- **แก้ match ผิด:** ในเว็บ เปิดหนัง ซีรีส์ ตอน อัลบั้ม หรือเพลง แล้วกด **✎ Edit** ค้นหาใน TMDB แล้วเลือกเรื่องที่ถูก ใส่ TMDB ID หรือแก้ทีละช่องเอง (ชื่อ ปี แนว เรื่องย่อ URL โปสเตอร์ / ศิลปิน อัลบั้ม เพลง URL ปก…) **Reset to automatic** ลบการแก้ไข การแก้เก็บแยกไว้และอยู่รอดการสแกน admin แก้ได้เสมอ ถ้าจะให้คนอื่นแก้ ใช้ **/admin → Users → Make editor**
- **Playlist:** ทุกคนสร้าง playlist เพลงของตัวเองได้ กด ＋ ข้างเพลง อัลบั้ม ศิลปิน หรือคิวที่กำลังเล่น (ในแอป: กดค้างที่เพลง หรือ *Playlist* ที่อัลบั้ม / ศิลปิน) เปลี่ยนชื่อ เรียงลำดับ (ลาก หรือ ↑ ↓) เล่นหรือสุ่มได้ เพลงจาก library ส่วนตัวของคนอื่นจะมีชื่อเจ้าของกำกับ (👤)
- **เพลงแบบ offline:** user ที่มีสิทธิ์ *offline* เซฟเพลงได้ ในแอป: กดค้างที่เพลง → *Save to this device* หรือ **Save** ที่อัลบั้ม ศิลปิน หรือ playlist เพลงที่เซฟแล้ว (มี ✓) จะเล่นจากเครื่องแม้มีเน็ต และ **Offline → Music** เล่นได้โดยไม่ต้องมี server (รวมถึงโหมด offline ของแอป พร้อมปุ่มคุมบนหน้าจอล็อก) ในเว็บ: ⬇ ข้างเพลง หรือ **⬇ Download** ที่อัลบั้ม ศิลปิน หรือ playlist (ได้ไฟล์ .zip เดียว playlist เรียงตามลำดับ)
- **การเล่นเพลง:** ไฟล์ที่ browser หรือแอปเล่นได้เองจะส่งไปตรงๆ รองรับ Range ไฟล์อื่น (wma, ape, …) แปลงเป็น mp3 สดๆ ผ่าน `/api/audio` เล่นเบื้องหลังได้ พร้อมปุ่มคุมบนหน้าจอล็อกและปุ่ม media บนคีย์บอร์ด
- **อัปเกรดจาก ≤1.3:** `-root` เดิมกลายเป็น library ชื่อ `main` (ประเภท *Other videos*) ประวัติการดูยังอยู่ เปลี่ยนประเภทเป็น Movies หรือ TV ได้ในหน้า admin

</details>

<details>
<summary><strong>⬇️ ดาวน์โหลด (HTTP, torrent, YouTube)</strong></summary>

ที่ **/admin → Downloads** วางลิงก์ แล้วเลือก library และโฟลเดอร์ (ไม่ใส่ก็ได้):

- **ลิงก์ http(s)://** — server โหลดเอง ถ้า server restart จะโหลดต่อ เช็คพื้นที่ว่างก่อนเริ่ม และสแกน library ให้เมื่อโหลดเสร็จ
- **magnet:… , ลิงก์ `.torrent` และอัปโหลดไฟล์ `.torrent`** — ส่งให้ **rtorrent** บน seedbox โหลดตรงเข้าโฟลเดอร์ library และ seed ต่อตามปกติ ใน ruTorrent จะมี label `StreamMKV` (ชื่อเดิม)
- **ลิงก์ YouTube / YouTube Music และ playlist** — โหลดด้วย [yt-dlp](https://github.com/yt-dlp/yt-dlp) ถ้าโหลดเข้า library **เพลง** จะได้เสียง (m4a ใส่ tag ชื่อ / ศิลปิน / อัลบั้ม และฝังปก) ถ้าเข้า library วิดีโอจะได้วิดีโอ (สูงสุด 1080p, mkv) ลิงก์ playlist จะโหลดทุกเพลงเข้าโฟลเดอร์ชื่อ playlist (tag อัลบั้มเป็นชื่อ playlist) ถ้าวางลิงก์วิดีโอที่อยู่ใน playlist ติ๊ก **Whole playlist** ได้ ปุ่ม **Update** ที่ playlist ที่โหลดเสร็จแล้วจะโหลดเฉพาะที่เพิ่มมาใหม่ yt-dlp และ Deno (JavaScript runtime ที่ YouTube ต้องใช้แล้ว) ใช้จาก PATH หรือตั้งด้วย `STREAMMKV_YTDLP` / `STREAMMKV_YTDLP_JS` ถ้าไม่มีจะโหลดเข้า `<data>/bin` ครั้งแรกและอัปเดตให้เอง โหลดเฉพาะสิ่งที่คุณมีสิทธิ์
- **หา rtorrent:** Delos ดูใน `~/.rtorrent.rc` / `~/.config/rtorrent/rtorrent.rc` หา `network.scgi.open_local` / `scgi_port` และเช็คที่อยู่ socket ที่ใช้บ่อย ถ้าหาไม่เจอ ใส่เองที่ **Downloads → rtorrent**: path ของ socket, `127.0.0.1:5000` หรือ URL ของ ruTorrent เช่น `https://user:pass@host/rutorrent/plugins/httprpc/action.php` หรือ `/RPC2` แล้วกด **Test**
- **rtorrent มาจากไหน:** อิมเมจ Docker มีในตัว สคริปต์ติดตั้งบน seedbox ใช้ตัวที่รันอยู่แล้ว หรือเสนอติดตั้งแบบ static ถ้าไม่มี บน VPS ที่ไม่ใช้ Docker ติดตั้งเองก็ได้ (`apt install rtorrent` เพิ่ม `network.scgi.open_local = ~/.rtorrent.sock` ใน `~/.rtorrent.rc` แล้วเปิดค้างไว้) ดาวน์โหลด http และ YouTube ใช้ได้โดยไม่ต้องมี rtorrent
- **ไฟล์ซ้ำ:** ก่อนโหลด Delos เช็ค 3 แบบ:
  - **torrent เดียวกัน** (ดูจาก info hash ของ magnet, ไฟล์ .torrent และลิงก์ .torrent) ถ้ามีใน rtorrent แล้วจะไม่ให้โหลด และบอกว่าอยู่ที่ไหน
  - **ไฟล์หรือลิงก์เดียวกัน** สำหรับลิงก์ http(s) เช็คชื่อไฟล์ก่อน
  - **หนังหรือตอนเดียวกัน** ที่มีใน library ประเภทเดียวกันแล้ว แม้ชื่อไฟล์ต่างกัน

  สองแบบหลังเลือก **Download anyway** ได้ หลังโหลดเสร็จและ match แล้ว เวอร์ชันอื่นของเรื่องเดียวกันจะขึ้นเตือนไว้ ("⚠ Also in the library")
- **จัดการ torrent:** ทุกรายการแสดงสถานะ (Downloading / Seeding / Paused / Stopped / Finished / Checking), ratio, ยอดอัปโหลด, ความเร็ว และ peer เจ้าของหรือ admin กด **Pause / Resume**, **Stop seeding** และ **Seed** ใหม่, **Recheck**, ดู **trackers & files** และ **Remove** ได้ เลือกลบแค่ torrent (ไฟล์ยังอยู่ใน library) หรือลบ torrent **พร้อมไฟล์** ทำได้ทั้งในหน้า admin, เว็บ และแอป (เมนู ⋮)
- **ขีดจำกัดการ seed:** ที่ **/admin → Torrents → Seeding rule** ตั้ง ratio และ/หรือจำนวนชั่วโมง ครบแล้ว torrent ของ Delos จะหยุด seed (หรือเอาออกจาก rtorrent โดยเก็บไฟล์ไว้) แต่ละ torrent ตั้งเองได้ (ค่าของ server / ไม่จำกัด / ratio หรือชั่วโมงของตัวเอง) ถ้ากดเริ่มใหม่เองหลังถูกหยุดอัตโนมัติ จะ seed ต่อไป
- **rtorrent ทั้งหมด (admin):** **/admin → Torrents** แสดงทุก torrent ใน rtorrent รวมที่เพิ่มจากที่อื่น มีตัวกรอง (downloading / seeding / paused / stopped / from Delos) ปุ่มเดียวกัน และ **จำกัดความเร็ว** รวม (มีผลจนกว่า rtorrent จะ restart ถ้าจะให้ถาวร ใส่ `throttle.global_down.max_rate` / `throttle.global_up.max_rate` ใน `.rtorrent.rc`) *Remove with data* ลบเฉพาะไฟล์/โฟลเดอร์ของ torrent นั้น ไม่มีทางลบโฟลเดอร์หลักของ library หรือ home ของคุณ
- **🧹 ไฟล์ที่ไม่มีใครใช้ (admin):** **/admin → Torrents → Find unused files** สแกนโฟลเดอร์ดาวน์โหลดของ rtorrent (หรือโฟลเดอร์ที่พิมพ์เอง) หาไฟล์และโฟลเดอร์ที่ไม่มี torrent ไหนใช้แล้ว เช่นที่ค้างจากการลบ torrent พร้อมขนาด เลือกลบได้ แต่ละรายการจะเช็คซ้ำอีกครั้งก่อนลบ library, โฟลเดอร์ของ Delos และโฟลเดอร์ที่มีของพวกนี้อยู่ข้างใน จะไม่ถูกเสนอให้ลบทั้งก้อน แต่จะแสดงของข้างในทีละรายการ และรายการที่ยังอยู่ใน library จะมีเครื่องหมายกำกับ
- **ใครเพิ่มดาวน์โหลดได้:** admin และ user ที่ได้ **Make downloader** downloader เห็นเฉพาะ library ที่ตัวเองเข้าถึงได้ และมีแค่ตัวเองหรือ admin ที่ยกเลิกหรือลบรายการของตัวเองได้ โหลดจาก address ภายในหรือ loopback ไม่ได้

</details>

<details>
<summary><strong>🚦 จำกัดจำนวนสตรีม</strong></summary>

ตั้งที่ **/admin → Connections → Limits** มีผลทันที ไม่ต้อง restart

| ขีดจำกัด | นับอะไร | ค่าเริ่มต้น |
|---|---|---|
| **Transcodes** | การแปลงภาพใหม่: โหมด Transcode และการฝังซับ PGS ใช้ CPU หนัก seedbox ทั่วไปไหว 1–2 สตรีมที่ 1080p | `-max-streams` (3) |
| **Light streams** | งาน ffmpeg ที่ไม่แปลงภาพ: browser ที่แค่เปลี่ยน container และเพลงที่แปลงสด (wma/ape → mp3) | 10 |
| **Per user** | จำนวนวิดีโอต่างเรื่องที่หนึ่งคนดูพร้อมกันได้ ทุกโหมดรวม Direct ของแอป เพลงไม่นับ และ admin ไม่ถูกจำกัด | 0 = ไม่จำกัด |

Direct ในแอปไม่ใช้ ffmpeg จึงนับแค่ขีดจำกัดต่อ user เมื่อเต็ม ตัวเล่นจะบอกเหตุผล เช่น "The server is busy: 2 of 2 transcodes running — try Direct mode" หรือ "You're already watching 1 video at once"

</details>

<details>
<summary><strong>👤 Library ส่วนตัวและโควต้า</strong></summary>

user ที่มีสิทธิ์ **downloader** สร้าง **library ของตัวเอง** ได้ที่ Downloads → *My libraries* ตั้งชื่อ เลือกประเภท (Movies / TV / Music / Other videos) และเลือกว่าจะ **แชร์ให้ทุกคน** ไหม

- **ไฟล์ไปอยู่ไหน:** server สร้างโฟลเดอร์ที่ `<โฟลเดอร์ library ส่วนตัว>/<user>/<library>` ตั้งได้ที่ **/admin → Downloads** ค่าเริ่มต้นคือ `~/streammkv-libraries` user ชี้ library ไป path อื่นไม่ได้
- **ใครเห็นอะไร:**
  - library **ส่วนตัว** เห็นแค่เจ้าของและ admin
  - library ที่ **แชร์** ทุกคนเห็น พร้อมชื่อเจ้าของ เช่น "from bob"
  - บัญชีที่ admin จำกัด library ไว้ เห็นเฉพาะที่ถูกติ๊กให้
- **ลบไฟล์:** เจ้าของลบไฟล์ใน library ของตัวเองได้ (🗑 ในเว็บ, กดค้าง → *Delete from server* ในแอป) โฟลเดอร์ของหนัง (nfo, โปสเตอร์, ซับ) และรายการใน rtorrent ที่ตรงกันจะถูกลบด้วย admin ลบได้ทุกที่ ไม่มีใครลบใน library ของคนอื่นได้
- **โควต้า:** ตั้งที่ **/admin → Users → Limits** เป็นจำนวนไฟล์สูงสุด และ/หรือ GB สูงสุดรวมทุก library ส่วนตัวของ user การโหลดที่จะเกินจะถูกปฏิเสธ (magnet ด้วย เมื่อรู้ขนาดแล้ว) user ที่มีโควต้าโหลดได้เฉพาะเข้า library ของตัวเอง การใช้งานแสดงในหน้า admin และหน้า Downloads ของ user

</details>

<details>
<summary><strong>💬 เพื่อนและแชท</strong></summary>

- **ใครออนไลน์:** เห็นว่าใครออนไลน์และ **กำลังดูหรือฟังอะไร** เช่น "▶ Children of Men · 45:12" กด ▶ เพื่อเปิดเรื่องเดียวกันได้ ถ้าคุณเข้าถึง library นั้น ใครก็เปิด *Hide what I'm watching* ได้ คนอื่นจะยังเห็นว่าออนไลน์ ข้างชื่อมีป้าย role ของแต่ละคน (Guest ถ้ายังไม่มี role)
- **แชท:** แชทส่วนตัวและ **แชทกลุ่ม** สมาชิกทุกคนเปลี่ยนชื่อกลุ่มหรือเพิ่มคนได้ มีแค่คนสร้างกลุ่ม (หรือ admin) ที่เอาคนออกได้ และทุกคนออกจากกลุ่มได้ จำนวนข้อความที่ยังไม่อ่านและการแจ้งเตือนอัปเดตสด (Server-Sent Events, `GET /api/events`) admin อ่านแชทของคนอื่นไม่ได้
- **ส่งให้เพื่อน:** แชร์หนัง ตอน หรือเพลงเข้าแชทเป็นการ์ดที่เพื่อนกดเล่นได้ ถ้าเพื่อนเปิด library นั้นไม่ได้ จะมีคำเตือน
- **รูปและไฟล์:** 📎 แนบรูปหรือไฟล์อะไรก็ได้ (ในเว็บวางหรือลากมาวางได้ด้วย) รูปแสดงในแชท (รูปใหญ่มีภาพย่อ) กดดูเต็มได้ ไฟล์อื่นเป็นการ์ดดาวน์โหลด เปิดได้เฉพาะสมาชิกแชท admin ตั้งขนาดไฟล์สูงสุด (ค่าเริ่มต้น 25 MB, 0 = ปิด) และเก็บไว้นานเท่าไร (ค่าเริ่มต้น 30 วัน, 0 = ตลอดไป) ที่ /admin → *Chat files* พอหมดอายุ ข้อความยังอยู่แต่บอกว่าไฟล์หมดอายุแล้ว
- **Emoji และ reaction:** 😊 ตัวเลือก emoji พร้อมค้นหา (เว็บและแอป) และ react ข้อความได้ — ในเว็บชี้แล้วกด ☺︎+ ในแอปกดค้าง (หรือคลิกขวา) กด reaction เพื่อเพิ่มหรือเอาออก
- **อยู่ตรงไหน:** รายชื่อ People และลิ้นชัก 💬 ในแถบซ้ายของเว็บ และแท็บ **Chat** ในแอป การแจ้งเตือนขึ้นเฉพาะตอนเปิดแอปหรือหน้าเว็บอยู่
- **รูปโปรไฟล์:** ตั้งหรือลบได้ในแอป (Settings → Account) หรือเว็บ (Chats → *Change picture*) JPG/PNG/GIF ไม่เกิน 10 MB server ตัดเป็นสี่เหลี่ยมจัตุรัสและย่อเป็น 256 px คนที่ไม่มีรูปจะเป็นตัวอักษรแรกบนพื้นสี admin ลบรูปได้ที่ /admin → Users
- **Admin** มีป้าย **ADMIN** ข้างชื่อในรายชื่อและแชท

</details>

<details>
<summary><strong>🎉 ดูด้วยกัน (Watch party)</strong></summary>

ดูหนังหรือฟังเพลงพร้อมกัน: **หัวห้อง** คนเดียวคุมการเล่น ทุกคนในห้องตามไปด้วย (เล่น หยุด กรอ และตอน / เพลงถัดไป) คนอื่นคุมการเล่นไม่ได้

- **เปิดห้อง:** 🎉 *Watch together* ในตัวเล่นวิดีโอ, 🎉 ในตัวเล่นเพลง หรือ **🎉 Party → New party** (แถบซ้ายของเว็บ ในแอป: Chat → Party หรือปุ่ม 🎉 ด้านบน) เลือกว่าจะเล่นอะไร **ตอนนี้หรือนัดเวลา** (ห้องที่นัดไว้ขึ้นใน *Coming up* และทุกคนที่ถูกเชิญได้แจ้งเตือนเมื่อถึงเวลา) public หรือ private ใส่รหัสผ่านได้ และเลือกคนที่จะเชิญ
- **เข้าห้อง:** จากคำเชิญ, รายการ Party (ห้อง public) หรือ **ขอเข้ากับเพื่อนที่กำลังดู** ด้วยปุ่ม 🎉 ข้างชื่อในรายชื่อ People เพื่อนเลือกได้ว่าจะให้เข้าไหม ถ้าตกลง สิ่งที่เพื่อนกำลังเล่นจะกลายเป็นห้อง ห้อง private ที่ไม่ได้ถูกเชิญเข้าได้ด้วยการขอหัวห้องเท่านั้น
- **ในห้อง:** แชท, emoji ลอยบนวิดีโอ, รายชื่อสมาชิก (👑 = หัวห้อง) **Mute chat** ซ่อนแชทและ emoji เฉพาะตัวคุณ หัวห้องปิดแชททั้งห้อง เชิญคน ให้คนเข้า **เตะ** คนออก (กลับมาไม่ได้จนกว่าจะถูกเชิญใหม่) เปลี่ยนชื่อห้อง / การมองเห็น / รหัสผ่าน ส่งต่อหัวห้อง หรือปิดห้องได้ ถ้าหัวห้องออก คนถัดไปจะเป็นหัวห้องแทน
- เวลา sync กับนาฬิกาของ server คนที่คลาดเกิน ~2.5 วินาทีจะถูกดึงกลับมาให้ตรง สมาชิกต้องเข้าถึง library ของสิ่งที่กำลังเล่น ห้องที่ไม่มีใครอยู่ 30 นาทีจะปิดเอง

</details>

<details>
<summary><strong>📱 รีโมต</strong></summary>

ใช้มือถือเป็นรีโมตคุม Delos บน PC หรือทีวี (แอป หรือหน้าเว็บใน browser ไหนก็ได้ รวม browser บนทีวี) login เป็น user เดียวกัน

- มือถือ: กดค้างที่หนัง ตอน หรือเพลง → **Play on…** → เลือกเครื่อง เรื่องจะเริ่มเล่นที่เครื่องนั้น และมือถือเปิดหน้ารีโมตให้
- รีโมต (📡 ที่แถบบน): เครื่องของคุณที่ออนไลน์และแต่ละเครื่องกำลังเล่นอะไร ปุ่ม: เล่น/หยุด, เลื่อนเวลา, ±10/30 วิ, เพลงก่อนหน้า/ถัดไป, เสียง, หยุด
- สำหรับวิดีโอมีปุ่มลัดเพิ่ม: ซับ (เลือกแทร็กหรือปิด), ดีเลย์ซับ ±0.1 วิ (แตะสองครั้งเพื่อรีเซ็ต), แทร็กเสียง, ตอนถัดไป, เต็มจอ และ Home (ปิดตัวเล่นแล้วกลับหน้าแรก)
- คำสั่งส่งผ่าน server มือถือกับทีวีไม่ต้องอยู่ Wi-Fi เดียวกัน เครื่องจะขึ้นในรายชื่อตอนที่เปิด Delos อยู่
- เปลี่ยนชื่อเครื่อง: รีโมต → 🪪 (เช่น "PC ห้องนั่งเล่น")

</details>

<details>
<summary><strong>📺 แชร์ให้ทีวี (DLNA, แอป PC)</strong></summary>

แอปบน PC (Windows, macOS, Linux) เปิดเป็น DLNA media server ได้ ให้สมาร์ททีวีในบ้านเล่นไฟล์ที่อยู่ใน PC นั้น (ไฟล์ที่ดาวน์โหลดไว้และโฟลเดอร์ของคุณเอง) เหมาะกับ PC หรือเครื่องพกพา (เช่น ROG Ally) ที่วางข้างทีวี

- เปิด: Settings → **Share to TV (DLNA)** (หรือ 📺 ในหน้า Offline) บน Windows ให้อนุญาต Delos ใน *Private networks* เมื่อถูกถาม บน Linux ถ้าเปิด firewall ให้เปิด UDP 1900 และ TCP 58200
- บนทีวี: LG → Media Player / Photo & Video, Samsung → Connected devices, Android TV → VLC / Kodi (UPnP) เปิด **Delos (ชื่อเครื่อง)**: Recently added, Movies, TV shows → ซีซั่น → ตอน, Videos, Music (อัลบั้ม / ศิลปิน / เพลงทั้งหมด) พร้อมโปสเตอร์
- ส่งไฟล์ไปตรงๆ (ไม่แปลง) กรอได้ ถ้ามีไฟล์ `.srt` วางข้างวิดีโอ จะส่งให้ทีวีเป็นซับด้วย
- ทำงานเฉพาะตอนเปิดแอปอยู่ เปลี่ยนชื่อได้ในหน้าเดียวกัน
- เครื่องจะไม่หลับระหว่างที่ทีวีเล่นอยู่ (หรือหยุดไว้ไม่เกินไม่กี่นาที) หรือระหว่างแปลงไฟล์ บนเครื่อง Modern Standby (ROG Ally, โน้ตบุ๊กส่วนใหญ่) จอจะติดค้างไว้ด้วย เพราะจอดับเท่ากับเครื่องหลับ ปิดได้
- **เสียงที่ทีวีเล่นไม่ได้** (DTS, TrueHD/Atmos — เลือกเองได้): แปลงเป็น Dolby Digital 5.1 สดๆ ภาพไม่ถูกแตะ กรอด้วยเวลา ต้องมีตัวแปลง (ffmpeg) ซึ่งหน้าตั้งค่าโหลดให้ (≈ 150 MB)
- **แปลงเก็บไว้ล่วงหน้า (TV copies)**: ทำสำเนาที่แปลงแล้วทีละเรื่อง ทั้งหมด หรืออัตโนมัติสำหรับไฟล์ใหม่ ตอนดูจะไม่ต้องแปลง และกรอได้ทุกทีวี สำเนาเก็บในโฟลเดอร์ของแอป ลบได้ตลอด ไฟล์ Online ก็ทำสำเนาได้ (ดึงจาก server)
- **Library ออนไลน์ (passthrough)**: แสดง library ของ server ในโฟลเดอร์ "Online" ด้วย ไฟล์สตรีมจาก server ผ่าน PC (กรอได้) ไฟล์ที่ต้องแปลง เลือกได้ว่าจะแปลงที่ **This PC** (ffmpeg บน PC) หรือ **Server** (seedbox แปลง ใช้ CPU ของ seedbox)

</details>

<details>
<summary><strong>🏷️ Roles</strong></summary>

Admin → **Roles**: role คือชุด library ที่ตั้งชื่อไว้ (เช่น *Family*: Movies + Kids, *Music only*: Music หรือ *All libraries* รวม library ที่เพิ่มทีหลัง) ใส่สิทธิ์เพิ่มได้ (editor, downloader, offline) ให้ user ได้ทีละหลาย role ที่ **Users → Roles** user จะเห็นทุก library ของทุก role ที่มี และได้สิทธิ์รวมกัน **Extra libraries** ให้ library เพิ่มเฉพาะคนนั้นนอกเหนือจาก role ลบ role แล้วสมาชิกจะเสียสิ่งที่ role นั้นให้ไว้ user ที่ไม่มี role ใช้รายการ library ของตัวเองเหมือนเดิม และแสดงเป็น **Guest** admin เห็นทุกอย่างเสมอ ไม่ขึ้นกับ role

ทุกคนเห็น role ของตัวเองบนการ์ดใต้ชื่อ Delos ในเว็บ, ในหน้าแชท และในเมนูข้างของแอป และเห็น role ของคนอื่นในรายชื่อ People

</details>

<details>
<summary><strong>🏆 Ranking</strong></summary>

🏆 *Ranking* (แถบซ้ายของเว็บ ในแอป: Chat → Ranking) แสดงว่าใครดูและฟังมากที่สุดในสัปดาห์ / เดือน / ปี / ตลอดกาล พร้อม badge ชั่วโมง, จำนวนเรื่องที่ดูจบ, จำนวนเพลง, ดูต่อเนื่องกี่วัน และคนที่ดู / ฟังมากที่สุดของเดือน นับเฉพาะเวลาที่เล่นจริง คนที่ซ่อนกิจกรรมจะไม่ถูกจัดอันดับ

</details>

<details>
<summary><strong>🙋 ขอหนัง / ซีรีส์ (Requests)</strong></summary>


🙋 *Requests* (เมนูข้างของเว็บ, ในแอป: แชท → Requests) ไว้ขอหนังหรือซีรีส์ที่ยังไม่มีใน server

- **ค้นหา** จาก TMDB ทุกผลลัพธ์จะบอกว่า **มีแล้ว** (กดเปิดดูได้เลย), **มีคนขอแล้ว** (กด 👍 โหวตเพิ่ม) หรือกดขอได้ พิมพ์ปีต่อท้ายเพื่อให้แคบลง เช่น `Dune 2021`
- **คำขอที่ยังเปิดอยู่** เรียงตามจำนวนโหวต เรื่องที่คนอยากดูมากที่สุดอยู่บนสุด คนขอยกเลิกคำขอของตัวเองได้ตอนที่ยังรออยู่
- **Admin** ได้แจ้งเตือนทันทีเมื่อมีคนขอ เห็นตัวเลขข้างเมนู *Requests* และเปลี่ยนสถานะได้: ⏳ รอ, 👍 อนุมัติ, ✕ ปฏิเสธ (ใส่เหตุผลได้), ✅ มีแล้ว หรือจะลบทิ้งก็ได้
- **เปลี่ยนเป็น ✅ มีแล้ว ให้เอง** เมื่อเรื่องนั้นเข้ามาใน library หนังหรือซีรีส์หลังสแกน (เทียบ TMDB id) ทุกคนที่ขอหรือโหวตจะได้แจ้งเตือนพร้อมปุ่ม *Open*
- ต้องมี TMDB key, admin ปิดระบบนี้ได้ที่ **/admin → Features**

</details>

<details>
<summary><strong>🎤 เนื้อเพลง ภาพตัวอย่างบนแถบเวลา และ trailer</strong></summary>


**เนื้อเพลง** กดปุ่ม 🎤 ในหน้า *Now playing* (เว็บ) หรือในหน้าเล่นเพลง (แอป) เนื้อเพลงแบบ sync จะไฮไลต์บรรทัดที่กำลังร้องและเลื่อนตามเอง กดที่บรรทัดไหนก็ข้ามไปตรงนั้น Delos หาเนื้อเพลงตามลำดับนี้:

1. ไฟล์ `.lrc` (หรือข้อความธรรมดา) ชื่อเดียวกับเพลงที่อยู่ข้างๆ เช่น `03 - Song.lrc`
2. เนื้อเพลงที่ฝังอยู่ใน tag ของไฟล์ (`LYRICS`, `UNSYNCEDLYRICS`, …)
3. [LRCLIB](https://lrclib.net) จากชื่อศิลปิน ชื่อเพลง อัลบั้ม และความยาว

ผลลัพธ์ถูก cache ไว้ ถ้าหาไม่เจอจะลองใหม่หลังผ่านไปหนึ่งสัปดาห์ หรือกด *Search again* เพื่อหาใหม่ทันที ที่ **/admin → Features** ปิดเนื้อเพลงได้ หรือตั้ง *Look up online* เป็น **ใช้ไฟล์ในเครื่องเท่านั้น** หรือ **LRCLIB server อื่น** ได้ LRCLIB เป็น open source ถ้าวันหนึ่งเว็บหลักปิดตัว ก็ตั้งให้ Delos ไปใช้ server ที่ host เองได้

**ภาพตัวอย่างบนแถบเวลา** เอาเมาส์ชี้แถบเลื่อนเวลา (เว็บ, แอป PC) หรือลากแถบ (มือถือ) จะเห็นภาพเล็กๆ ของช่วงนั้น ครั้งแรกที่เล่นวิดีโอ server จะกระโดดไปดึง keyframe ทีละจุด (อ่านแค่ไม่กี่ MB ต่อภาพ ไม่ต้องอ่านทั้งไฟล์ ไฟล์ remux 60 GB ใช้เวลาพอๆ กับไฟล์เล็ก) แล้วรวมเป็น sprite sheet เก็บไว้ใน cache ระหว่างที่ยังทำไม่เสร็จ กล่องเวลาจะขึ้นว่า *preparing previews · N %* ความถี่ของภาพ: ทุก 2 วินาทีสำหรับวิดีโอสั้น, 5 วินาทีถ้าไม่เกิน 30 นาที, 10 วินาทีสำหรับเรื่องที่ยาวกว่านั้น สูงสุด 480 ภาพต่อเรื่อง ปิดได้ที่ **/admin → Features** ถ้าอยากประหยัด CPU

**Trailer** หนังและซีรีส์ที่ match กับ TMDB แล้วจะมีปุ่ม 🎞 *Trailer* กดแล้วเล่น trailer จาก YouTube ในหน้าต่างซ้อนบนหน้าเดิม (trailer ทางการขึ้นก่อน ใช้ภาษาตามที่ตั้งไว้ใน TMDB ถ้ามี) teaser กับ trailer อื่นๆ กดสลับได้ ปิดได้ที่ **/admin → Features**

</details>

<details>
<summary><strong>📣 ประกาศ</strong></summary>

admin ส่งข้อความถึง user ได้ที่ **/admin → 📣 Announcements**: หัวข้อและข้อความ (ลิงก์กดได้) ระดับความสำคัญ ส่งถึงใคร (ทุกคนหรือเลือกคน) วันหมดอายุ (ไม่ใส่ก็ได้) และ *Pin* ให้อยู่ในรายการหลังอ่านแล้ว

- **Info / Warning** ขึ้นเป็นแถบด้านบนของเว็บ (และ SnackBar ในแอป) **Important** ขึ้นเป็นหน้าต่าง
- ส่งถึง **ทันที** สำหรับทุกคนที่เปิดเว็บหรือแอปอยู่ คนอื่นจะเห็นเมื่อเปิดครั้งถัดไป
- ปุ่ม **📣** (แถบซ้ายของเว็บ, แถบบนของแอป) แสดงประกาศที่ยังมีผลพร้อมจำนวนที่ยังไม่อ่าน อ่านหรือปิดแล้วถือว่าอ่าน
- หน้า admin บอกว่ามีกี่คนอ่านแล้ว (ชี้เพื่อดูชื่อ) แก้ไขแล้วเลือก **แสดงให้ทุกคนอีกครั้ง** ได้ ลบแล้วหายจากทุกที่

</details>

<details>
<summary><strong>📥 Library แบบ offline (แอป)</strong></summary>

แอปเล่นได้ **โดยไม่ต้องมี server** แยกเป็น 2 ส่วนชัดเจน (แท็บ 📥 Offline):

- **☁️ Downloaded from server** — user ที่มีสิทธิ์ **Offline downloads** (admin มีเสมอ; หน้า admin → Users → *Allow offline*) กดค้างที่หนัง/ตอน → *Download to this device* โหลดเบื้องหลังพร้อมแจ้งเตือน หยุด/โหลดต่อได้ ลบออกจากเครื่องได้ (ไฟล์บน server ยังอยู่) โปสเตอร์ของเรื่องที่โหลดแล้วมีป้าย 📥 และจะเล่นจากไฟล์ในเครื่อง ตำแหน่งที่ดูถึงจะ sync กลับ server เมื่อเชื่อมต่อได้
- **📁 My folders** — เพิ่มโฟลเดอร์วิดีโอของคุณในเครื่อง (Movies / TV series / Other videos) แอปอ่านชื่อไฟล์แบบเดียวกับ server และดึงข้อมูลจาก TMDB: ผ่าน server ถ้า login อยู่ (ไม่ต้องมี key) หรือใช้ TMDB key ของตัวเอง (⚙ Offline settings) ถ้าไม่ได้ login บน iOS โฟลเดอร์คือ *Files → On My iPhone → Delos → My Videos* ของแอป

ตัวเล่นบอกว่าวิดีโอมาจากไหน: **LOCAL** (สีเขียว: ดาวน์โหลดไว้ / โฟลเดอร์ของฉัน) หรือ **STREAM** (สีฟ้า: Direct / Transcode)

**ไฟล์ดาวน์โหลดไปอยู่ไหน** (⚙ Offline settings): ในแอป (ส่วนตัว, ค่าเริ่มต้น) หรือบน Android ในโฟลเดอร์ของแอปบนพื้นที่เครื่อง / SD card (`Android/data/dev.un4ckn0wl3z.streammkv/files/Delos` เห็นผ่าน USB และแอปจัดการไฟล์ Android ลบให้เมื่อถอนแอป) บน iOS ในโฟลเดอร์ Files ของแอป และบน Windows/Linux/macOS เลือกโฟลเดอร์ไหนก็ได้ ไฟล์ใหม่ไปที่ใหม่ ไฟล์เก่าอยู่ที่เดิม

**โหมด offline:** ที่หน้า login เลือก *Use offline — without a server* ครั้งต่อไปแอปจะเปิดเข้า library offline เลย ถ้า login อยู่แต่ต่อ server ไม่ได้ หน้า error จะมีปุ่ม *Offline library*

หมายเหตุ: สิทธิ์นี้คุมเฉพาะฟีเจอร์ดาวน์โหลดของแอป — ใครที่สตรีมได้ (Direct) ก็ได้รับไฟล์ทั้งไฟล์อยู่แล้วในทางเทคนิค ใช้ `GET /api/download?path=` (รองรับ Range, พร้อมกันได้ 3 ไฟล์ต่อ user) และ `POST /api/meta/lookup`

</details>

<details>
<summary><strong>🛡️ ผู้ใช้และหน้า admin</strong></summary>

Delos รองรับหลาย user แต่ละคนมีประวัติการดู ตำแหน่งที่ค้างไว้ และแทร็กที่เลือกของตัวเอง admin เลือกว่าแต่ละคนเห็น library ไหน

- **หน้า admin:** `http://<server>/admin` admin เพิ่ม user, รีเซ็ตรหัสผ่าน, ตั้งเป็น admin, สั่งออกจากระบบทุกเครื่อง, ดูหรือล้างประวัติได้ หน้านี้ยังแสดงว่าใครกำลังดูอะไร สตรีมที่เปิดอยู่และเป็น direct หรือ transcode, สถิติ library และดิสก์, สถานะอัปเดต และเวอร์ชัน / platform ของแอปที่แต่ละคนใช้ user ที่ไม่ใช่ admin เห็นแค่หน้าเปลี่ยนรหัสผ่าน
- **CLI บน seedbox:** `~/streammkv/run.sh user list | add NAME [--admin] [--password P] | passwd NAME | admin NAME on|off | revoke NAME | del NAME` ถ้าไม่ใส่รหัสผ่านจะสุ่มให้ server ที่รันอยู่จะเห็นการเปลี่ยนแปลงภายใน 2 วินาที
- **การเก็บข้อมูล:** user เก็บใน `<data>/users.json` รหัสผ่าน hash ด้วย PBKDF2-SHA256 เมื่อเปลี่ยนรหัสหรือสั่งออกจากระบบ ทุก session เดิมของคนนั้นใช้ไม่ได้ทันที
- **เริ่มครั้งแรก:** admin คนแรกสร้างจาก `-user/-pass` หลังจากนั้น flag นี้จะไม่มีผล ถ้าอัปเกรดจากรุ่นที่มี user เดียว บัญชีเดิมจะเป็น admin และประวัติการดูยังอยู่

</details>

<details>
<summary><strong>🔄 เวอร์ชันและการอัปเดต</strong></summary>

- ไฟล์ `VERSION` เป็นที่เดียวที่เก็บเลขเวอร์ชัน `tools/bump.sh X.Y.Z` อัปเดตไฟล์นี้พร้อมเวอร์ชันแอป commit แล้ว push CI จะ build server, `SHA256SUMS` และแอปทั้งหมด อัปโหลดเข้า release แบบร่าง แล้วเผยแพร่เมื่อครบ
- **Server:** เช็ค GitHub ทุก 6 ชั่วโมง ถ้าเปิด auto-update (ค่าเริ่มต้น ปิดได้ในหน้า admin) จะโหลดไฟล์ใหม่ เช็คกับ `SHA256SUMS` สลับไฟล์ แล้วรันตัวเองใหม่ด้วย PID เดิม ไฟล์เก่าเก็บไว้เป็น `streammkv.old` อัปเดตเฉพาะตอนที่ไม่มีใครสตรีมอยู่ หรือกด **Update now** ในหน้า admin
- **แอป:** ตอนเปิดจะเช็ค release ล่าสุดและเสนอ APK ที่ตรงกับ CPU ของเครื่อง *Settings → Check for app updates* เช็คเองได้ Android ไม่ให้แอปที่ติดตั้งเองอัปเดตเงียบๆ ต้องกด Install เอง
- **เว็บ:** เป็นส่วนหนึ่งของ server อัปเดตไปพร้อมกัน

</details>

<details>
<summary><strong>📲 แอป: Android, iOS, Windows, Linux, macOS</strong></summary>

แอปเขียนด้วย Flutter ใช้ [media_kit](https://github.com/media-kit/media-kit) (libmpv) หน้าตาเหมือนกันทุก platform ดาวน์โหลดได้ที่ [Releases](https://github.com/un4ckn0wl3z/delos/releases/latest)

แอปดู library แบบเดียวกับเว็บ: Home (ดูต่อ / เรื่องใหม่), หนังพร้อมโปสเตอร์และตัวกรองแนว, ซีรีส์พร้อมซีซั่นและ Next up, เพลงตามอัลบั้ม ศิลปิน แนว หรือเพลง มีตัวเล่นเล็กและเล่นเสียงเบื้องหลัง **กดค้าง** ที่โปสเตอร์หรือตอนเพื่อเปิดเมนู (บน PC คลิกขวา) มี Play/Resume, **Start over** และ **Remove from Continue watching** admin และ editor มี **Identify…** เพิ่ม ใช้ค้น TMDB เลือกเรื่องที่ถูก หรือใส่ TMDB ID **Re-detect** กลับไปใช้การ match อัตโนมัติ การแก้ข้อมูลอื่นทำได้ในเว็บ

| Platform | ไฟล์ | ติดตั้ง |
|---|---|---|
| Android | `streammkv-android-arm64-v8a.apk` | เปิดไฟล์ APK ถ้าอัปเดตแล้วขึ้น "App not installed" ให้ถอนแอปเก่าก่อน ประวัติการดูเก็บอยู่บน server |
| iOS / iPadOS | `streammkv-ios.ipa` (ไม่ได้ sign) | ติดตั้งด้วย [SideStore](https://sidestore.io) หรือ [AltStore](https://altstore.io) ด้วย Apple ID ฟรี ดูด้านล่าง |
| Windows 10/11 | `streammkv-windows-x64.zip` | แตกไฟล์แล้วเปิด `Delos.exe` |
| Linux x64 | `streammkv-linux-x64.tar.gz` | ติดตั้ง libmpv ก่อน (`sudo apt install libmpv2`) แล้วแตกไฟล์และเปิด `Delos/streammkv` มีไฟล์ `.desktop` ให้ |
| macOS 11+ (Intel และ Apple Silicon) | `streammkv-macos.zip` | แตกไฟล์แล้วย้าย `Delos.app` ไป Applications แอปไม่ได้ notarize ให้รัน `xattr -dr com.apple.quarantine /Applications/Delos.app` ครั้งเดียว หรืออนุญาตที่ System Settings → Privacy & Security → Open Anyway |

บน Windows, Linux และ macOS: ปุ่ม ⛶ ที่แถบบนหรือ **F11** ทำให้ทั้งแอปเต็มจอ (จำไว้ครั้งหน้า) ในตัวเล่นกด **F** หรือดับเบิลคลิกกลางจอเพื่อเต็มจอ ปุ่มอื่น: space เล่น/หยุด, ←/→ ±10 วิ, J/L ±30 วิ, ↑/↓ เสียง, A สลับเสียง, C สลับซับ, Z/X ปรับดีเลย์ซับ, Esc ออกจากเต็มจอ **Settings → Streaming buffer** ปรับขนาด buffer ได้ (Auto ≈ 2 นาทีของไฟล์ หรือ 64 MB – 1 GB)

#### iOS ด้วย SideStore / AltStore (Apple ID ฟรี)

1. ติดตั้ง SideStore หรือ AltStore ครั้งเดียวตามคู่มือของเขา ครั้งแรกต้องใช้คอมพิวเตอร์
2. ใน SideStore/AltStore เปิด **Sources → +** แล้วเพิ่ม
   `https://github.com/un4ckn0wl3z/delos/releases/latest/download/altstore-source.json`
3. ติดตั้ง **Delos** จาก source นั้น เมื่อมี release ใหม่ source จะแสดงการอัปเดต
4. แอปที่ sign ด้วย Apple ID ฟรีหมดอายุใน **7 วัน** และติดตั้งเองได้สูงสุด 3 แอป refresh Delos ใน SideStore ก่อนหมดอายุ (SideStore ทำบนมือถือได้ หรือตั้ง Shortcut ให้ refresh อัตโนมัติ)

ถ้ามี Apple Developer แบบเสียเงิน CI เดียวกันนี้อัปโหลดขึ้น TestFlight แทนได้

#### รายละเอียด Android

- **Direct**: mpv สตรีมไฟล์ MKV ต้นฉบับผ่าน `/api/raw` (รองรับ HTTP Range) เล่นได้ทุก codec (HEVC, DTS, TrueHD…) สลับแทร็กเสียงและซับในไฟล์ได้ แสดง ASS แบบเต็มและ PGS กรอได้แม่นยำ server แทบไม่ใช้ CPU แต่ต้องมีเน็ตพอสำหรับ bitrate ต้นฉบับ
- **Transcode 1080/720/480p**: เล่นสตรีมจาก `/api/stream` ใช้ประหยัดเน็ตมือถือ
- **ประวัติและแทร็ก** เก็บบน server (`/api/progress`) แอปและทุก browser ดูต่อจากกันได้
- **ท่าทาง**: แตะสองครั้งซ้าย/ขวาเพื่อย้อน/ข้าม 10 วิ แตะสองครั้งตรงกลางเพื่อเล่น/หยุด เมนู ⚙ มีคุณภาพ ดีเลย์ซับ และขนาดซับ

build เอง:

```bash
cd app
flutter create --org dev.un4ckn0wl3z --project-name streammkv --platforms android .
python3 tool/patch_android.py      # สิทธิ์ INTERNET, cleartext HTTP, ชื่อแอป
flutter build apk --release --split-per-abi
```

CI (`.github/workflows/app.yml`) sign APK ด้วย key จาก secret `ANDROID_DEBUG_KEYSTORE_B64` (keystore เข้ารหัส base64, alias `androiddebugkey`, รหัส `android`) ถ้าไม่ได้ตั้ง secret นี้ แต่ละ build จะได้ key ต่างกัน ต้องถอนเวอร์ชันเก่าก่อนติดตั้งใหม่

</details>

<details>
<summary><strong>⚙️ เบื้องหลังการทำงาน</strong></summary>

#### เล่นใน browser (ค่าเริ่มต้น)

เว็บเล่น **ไฟล์ต้นฉบับ** เองแบบเดียวกับ mpv ในแอป:

- อ่านไฟล์จาก server ตรงๆ ด้วย HTTP Range (`/api/raw`) — server แค่ส่ง byte: **ไม่ใช้ ffmpeg ไม่กินโควต้าสตรีม กรอได้ทันที**
- [Mediabunny](https://mediabunny.dev) แยก MKV/MP4 ใน browser ภาพถอดรหัสด้วย decoder ของเครื่องผ่าน **WebCodecs** (ส่วนใหญ่เป็น hardware: H.264, HEVC, AV1, VP9)
- เสียง **AC-3, E-AC-3 (DD+), DTS และ TrueHD** ที่ browser เล่นไม่ได้ ถอดรหัสด้วย FFmpeg ที่ compile เป็น **WebAssembly** (โหลดเฉพาะตอนไฟล์ต้องใช้ ราว 0.2–0.4 MB ต่อตัวหลังบีบอัด) จึงได้ **ทุกแทร็กเสียง** และจำนวน channel เดิม
- วาดภาพบน canvas และ sync กับนาฬิกาเสียง ซับแบบข้อความใช้ overlay แบบเดิม
- browser เปิด WebCodecs ให้เฉพาะ **หน้าที่ปลอดภัย** (https หรือ localhost) — ดู HTTPS ด้านล่าง ถ้าเปิดผ่าน http เว็บจะมีปุ่มสลับให้
- ถ้า browser ทำไม่ได้ จะใช้ server แทน **อัตโนมัติ** เช่น codec ภาพที่เครื่องถอดไม่ได้ (DivX เก่า, HEVC 10-bit ที่ไม่มี hardware), ซับแบบภาพ (PGS/VobSub, server ฝังให้) หรือ browser ที่ไม่มี WebCodecs ป้ายในตัวเล่นบอกว่าใช้แบบไหน: **direct · in browser**, **remux · server** หรือ **transcode** เลือกเองได้ที่ *Video* และ ⚙ Settings → *Playback* ตั้งให้ใช้ server เป็นค่าเริ่มต้นได้

#### เล่นผ่าน server

- **ภาพ**: ถ้า browser ถอด codec ภาพได้ (H.264 8-bit, HEVC/AV1/VP9 ถ้ารองรับ) ส่งไปตามเดิมด้วย `-c:v copy` แทบไม่ใช้ CPU ไม่อย่างนั้นแปลงเป็น H.264 ด้วย `libx264 veryfast` ย่อตามความสูงสูงสุดที่เลือก
- **เสียง**: ส่งเฉพาะแทร็กที่เลือก (`-map 0:a:N`) แปลงเป็น AAC stereo เสมอ เพราะ browser เล่น AC3/DTS/TrueHD ไม่ได้
- **การกรอ**: ขอใหม่ด้วย `?start=` ในโหมด copy จะถาม keyframe ที่ใกล้ที่สุดก่อน (`/api/keyframe`) ให้แถบเวลาและซับตรงกัน
- **ซับแบบข้อความ** (SRT/ASS/VTT): แยกเป็น WebVTT เก็บ cache บน server แล้วเว็บวาดเป็น overlay ปรับดีเลย์และเปลี่ยนซับได้โดยไม่ต้องเริ่มวิดีโอใหม่
- **ซับแบบภาพ** (PGS/VobSub): ฝังลงในภาพ ต้องใช้โหมด transcode
- **หน้าเว็บมาจาก server เอง** (origin เดียวกับไฟล์) ไม่มีปัญหา CORS, mixed content หรือ CSP

</details>

<details>
<summary><strong>🐳 รันด้วย Docker</strong></summary>

อิมเมจมี server, ffmpeg และ rtorrent ในตัว (สำหรับดาวน์โหลด) รองรับ `linux/amd64` และ `linux/arm64`:

```bash
curl -O https://raw.githubusercontent.com/un4ckn0wl3z/delos/main/docker-compose.yml
# แก้: /path/to/media → โฟลเดอร์ไฟล์ของคุณ, PUID/PGID → user ของคุณ (`id`)
docker compose up -d
docker compose logs delos          # รันครั้งแรกจะพิมพ์รหัสผ่าน admin
```

แล้วเปิด `http://<host>:8090` หรือรันแบบไม่ใช้ compose:

```bash
docker run -d --name delos -p 8090:8090 -p 50000:50000 -p 6881:6881/udp \
  -e PUID=$(id -u) -e PGID=$(id -g) -e TZ=Asia/Bangkok \
  -v ./data:/data -v /path/to/media:/media ghcr.io/un4ckn0wl3z/delos:latest
```

| | |
|---|---|
| `/media` | library ของคุณ — library แรกชี้มาที่นี่ เพิ่มได้อีกใน /admin (ที่ไหนก็ได้ใต้ `/media` หรือ mount โฟลเดอร์เพิ่ม) |
| `/data` | user, การตั้งค่า, ประวัติการดู, แชท, cache และ session ของ rtorrent ในตัว |
| `PUID` / `PGID` | ไฟล์ที่ Delos และ rtorrent เขียน (ดาวน์โหลด, library ส่วนตัวใน `/media/personal`) เป็นของ user นี้ |
| `STREAMMKV_USER` / `STREAMMKV_PASS` | admin คนแรก (ใช้เฉพาะตอนยังไม่มี user ถ้าไม่ใส่จะสุ่มรหัสและพิมพ์ใน log) |
| `RTORRENT=0` | ไม่รัน rtorrent ในตัว ใช้ `STREAMMKV_RTORRENT=scgi://host:5000` (หรือ path ของ socket / URL http) เพื่อใช้ตัวอื่น |
| ports | `8090` เว็บ + API · `50000` + `6881/udp` สำหรับ peer / DHT ของ rtorrent ในตัว |

ใช้อิมเมจเก่า `ghcr.io/un4ckn0wl3z/streammkv` อยู่? ยังได้ release เดียวกัน ไม่มีอะไรพัง เปลี่ยนบรรทัด `image:` เป็น `ghcr.io/un4ckn0wl3z/delos:latest` ตอนไหนก็ได้ (`./data` ยังอยู่เหมือนเดิม)

torrent โหลดเข้า `/media/downloads` เป็นค่าเริ่มต้น (หรือ library ที่เลือก) การตั้งค่าของ rtorrent ในตัวอยู่ที่ `/data/rtorrent/rtorrent.rc` แก้แล้ว restart container

**อัปเดต:** `docker compose pull && docker compose up -d` (การอัปเดตตัวเองจากหน้า admin ปิดไว้ใน Docker) ถ้าจะเปิดให้เข้าจากอินเทอร์เน็ต ให้วางหลัง reverse proxy ที่มี HTTPS

</details>

<details>
<summary><strong>🌱 ติดตั้งบน seedbox (ไม่ต้องมี root หรือ package manager)</strong></summary>

**จาก PC (ง่ายที่สุด):** โหลดสคริปต์ deploy แล้วรัน จะถาม host ของ seedbox, user/port ของ SSH, โฟลเดอร์หนัง และ port (ไม่ใส่ก็ได้) แล้วติดตั้งหรืออัปเกรดผ่าน SSH ให้ คุณพิมพ์แค่รหัส SSH และสคริปต์จำคำตอบไว้ใช้ครั้งหน้า

- Windows 10/11: [`deploy/deploy.cmd`](deploy/deploy.cmd) ดับเบิลคลิก ใช้ OpenSSH ที่มากับ Windows
- Linux / macOS: [`deploy/deploy.sh`](deploy/deploy.sh) รัน `bash deploy.sh`

ตอนจบจะพิมพ์ URL, ชื่อผู้ใช้ และรหัสผ่านสำหรับเปิดใน browser หรือใส่ในแอป รันซ้ำเมื่อไรก็ได้เพื่ออัปเกรดเป็นรุ่นล่าสุด port และรหัสผ่านยังเหมือนเดิม

**หรือบน seedbox เอง** (คำสั่งเดียว: โหลด binary + ffmpeg แบบ static, เลือก port ว่าง, สุ่มรหัสผ่าน, เปิด server และตั้ง cron ให้เปิดเองตอนบูต):

```bash
curl -fsSL https://raw.githubusercontent.com/un4ckn0wl3z/delos/main/deploy/install.sh | MEDIA_ROOT=~/torrents bash
```

รันซ้ำเพื่ออัปเกรด port/รหัสผ่านเดิม จัดการด้วย `~/streammkv/run.sh {start|stop|restart|status}` การตั้งค่าอยู่ที่ `~/streammkv/streammkv.env`

**rtorrent:** ถ้า seedbox มี rtorrent รันอยู่แล้ว (เกือบทุกเจ้ามี) Delos จะหาเจอและใช้ตัวนั้น ถ้าไม่เจอ สคริปต์จะถามว่าจะติดตั้งไหม — เป็น rTorrent 0.9.8 แบบ static ([jesec/rtorrent](https://github.com/jesec/rtorrent)) ไม่ต้องใช้ root โหลดเข้า `<media>/downloads` มี port ของตัวเอง และ `run.sh` เปิด / ปิด / เฝ้าดูให้พร้อมกับ Delos ตอบล่วงหน้าได้ด้วย `INSTALL_RTORRENT=1` (หรือ `0`) ดาวน์โหลด http และ YouTube ใช้ได้โดยไม่ต้องมี rtorrent

#### ติดตั้งเอง

```bash
mkdir -p ~/bin ~/streammkv && cd ~/streammkv

# 1) binary ของ streammkv — build บนเครื่องคุณด้วย:
#    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o dist/streammkv-linux-amd64 .
#    แล้ว copy ไป (scp) หรือใช้ dist/streammkv-linux-amd64 ที่มีให้
chmod +x streammkv-linux-amd64

# 2) ffmpeg + ffprobe แบบ static
curl -L -o ffmpeg.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz
tar xf ffmpeg.tar.xz && cp ffmpeg-*-static/ffmpeg ffmpeg-*-static/ffprobe ~/bin/ && rm -rf ffmpeg-*-static ffmpeg.tar.xz

# 3) รัน
STREAMMKV_PASS='change-me' ./streammkv-linux-amd64 \
  -root ~/downloads -user me -listen :8090 \
  -ffmpeg ~/bin/ffmpeg -ffprobe ~/bin/ffprobe \
  -secret "$(openssl rand -hex 32)"
```

ให้รันค้างโดยไม่มี systemd: `nohup ... > streammkv.log 2>&1 &` หรือ `screen -dmS streammkv ...` เพิ่มใน `crontab -e` เป็น `@reboot ...` ให้เปิดเองหลังรีบูต

#### Flags / env

| flag | env | ค่าเริ่มต้น | |
|---|---|---|---|
| `-root` | `STREAMMKV_ROOT` | `.` | โฟลเดอร์ของ library แรก library อื่นเพิ่มใน /admin |
| `-listen` | `STREAMMKV_LISTEN` | `:8090` | |
| `-user` / `-pass` | `STREAMMKV_USER` / `STREAMMKV_PASS` | — | admin คนแรก (ใช้เฉพาะตอนยังไม่มี user) |
| `-secret` | `STREAMMKV_SECRET` | สุ่ม เก็บใน `<data>/secret.key` | key สำหรับ sign token |
| `-ffmpeg` / `-ffprobe` | `STREAMMKV_FFMPEG` / `STREAMMKV_FFPROBE` | จาก PATH | |
| `-ext` | `STREAMMKV_EXT` | `.mkv,.mp4,.m4v,.avi,.webm,.mov,.ts,…` | นามสกุลวิดีโอสำหรับ library วิดีโอ |
| `-cache` | `STREAMMKV_CACHE` | `~/.cache/streammkv` | cache ของ WebVTT |
| `-data` | `STREAMMKV_DATA` | เหมือน cache | `users.json`, `progress.json`, `settings.json`, `libraries.json`, `secret.key`, `index/`, `covers/` |
| | `STREAMMKV_UPDATE_REPO` | `un4ckn0wl3z/delos` | repo บน GitHub ที่ใช้อัปเดต (สำหรับ fork) |
| `-tls` | `STREAMMKV_TLS` | `on` | https ที่ port เดียวกับ http (`off` เพื่อปิด) |
| `-tls-cert` / `-tls-key` | `STREAMMKV_TLS_CERT` / `_KEY` | — (ใบรับรองในตัว) | ใช้ใบรับรองของคุณเอง (โหลดใหม่เมื่อไฟล์เปลี่ยน) |
| | `STREAMMKV_TLS_HOSTS` | — | ชื่อ/IP เพิ่มสำหรับใบรับรองในตัว คั่นด้วย comma |
| `-max-streams` | `STREAMMKV_MAX_STREAMS` | `3` | ค่าเริ่มต้นของขีดจำกัด transcode (เปลี่ยนทีหลังใน /admin) |

#### HTTPS (มีในตัว)

server ตอบทั้ง **http และ https ที่ port เดียวกัน** — `http://box:port` และ `https://box:port` ใช้ได้ทั้งคู่ แอปไม่ต้องเปลี่ยนอะไร browser ต้องใช้ https สำหรับการเล่นใน browser (WebCodecs) หน้า http จึงมีปุ่ม **Switch to https** (login ยังอยู่)

- ถ้าไม่ได้ตั้งใบรับรอง server จะสร้าง certificate authority เล็กๆ ของตัวเองใน `<data>/tls` เปิดครั้งแรก browser จะเตือน — กด *Advanced → Proceed* ครั้งเดียว หรือติดตั้งใบรับรองจาก **`/tls`** (หน้าช่วยเหลือพร้อมปุ่มดาวน์โหลดและขั้นตอนสำหรับ Windows, macOS, iPhone/iPad, Android, Linux และ Firefox) แล้วจะไม่เตือนอีก
- ใบรับรองนั้น **จำกัดชื่อ** ไว้เฉพาะชื่อ/IP ของ server นี้ จึงเอาไปใช้กับเว็บอื่นไม่ได้ ชื่อเรียนรู้จาก address ที่ใช้เปิด **/admin** และแก้ได้ในส่วน *HTTPS* ของหน้า admin (เปลี่ยนแล้วจะได้ใบใหม่ที่อุปกรณ์ต้องติดตั้งใหม่)
- มีใบรับรองจริง (Let's Encrypt, Cloudflare origin cert, …)? ตั้ง `STREAMMKV_TLS_CERT` / `STREAMMKV_TLS_KEY`

#### Reverse proxy

ถ้า seedbox มี nginx พร้อมใบรับรองจริงอยู่แล้ว วาง Delos ไว้ใต้ subpath ได้:

```nginx
location /streammkv/ {
    proxy_pass http://127.0.0.1:8090/;
    proxy_buffering off;              # จำเป็นสำหรับสตรีม
    proxy_read_timeout 6h;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

แล้วเปิด `https://your.box/streammkv/`

</details>

<details>
<summary><strong>🌐 ใช้ใน browser</strong></summary>

1. เปิด address ของ server เช่น `http://your-seedbox:8090/` แล้ว login ไม่ต้องติดตั้งอะไร
2. อยากได้ไอคอนแอป: Chrome/Edge → **Install app** (แถบ address หรือเมนู), Android Chrome → **Add to Home screen**, iPhone Safari → Share → **Add to Home Screen**
3. ⚙ Settings: ภาษาเสียง / ซับที่ชอบ (เช่น เสียง `jpn,eng` ซับ `tha,eng`), วิธีเล่น, ความสูงสูงสุดตอน transcode

แถบซ้ายแสดง library ของคุณ **Home** มี *Continue watching* และ *Recently added* หนังและซีรีส์กรองตามแนวได้ เพลงมีแท็บ Albums / Artists / Genres / Songs และแถบตัวเล่นด้านล่างพร้อมคิว สุ่ม และเล่นซ้ำ admin มีลิงก์ 🛡 ไปหน้า admin แถวการ์ดแนวนอนเลื่อนได้ด้วยปุ่ม ‹ › ลากแถบด้านล่าง หรือลากที่แถว

> **อัปเกรดจาก userscript (≤ 1.9):** เว็บแทนที่ userscript แล้ว — ลบ *Delos* ออกจาก Tampermonkey ระหว่างนี้ userscript จะไม่รบกวน (และบน server ที่เก่ากว่า 2.0 ยังใช้ได้เหมือนเดิม)

#### คีย์บอร์ด

`space`/`k` เล่น/หยุด · `←/→` ±10 วิ · `j/l` ±30 วิ · `a` สลับเสียง · `c` สลับซับ · `z/x` ดีเลย์ซับ ±0.1 วิ · `f` เต็มจอ · `m` ปิดเสียง · `↑/↓` เสียง

พับเมนูข้างให้เหลือแค่ไอคอน: ปุ่ม ◧ มุมบนของเมนู หรือ `Ctrl+B` (`⌘B` บน Mac) จำค่าไว้ให้

#### จำไว้ทุกไฟล์

server จำตำแหน่งที่ดูถึงและแทร็กเสียง/ซับที่เลือกของแต่ละไฟล์ browser และแอปใช้ข้อมูลเดียวกัน หยุดที่เครื่องหนึ่งแล้วดูต่อที่อีกเครื่องได้

</details>

<details>
<summary><strong>⚠️ ข้อจำกัด</strong></summary>

- เปิดซับแบบข้อความครั้งแรก server ต้องอ่านทั้งไฟล์ MKV เพื่อแยกซับ (ไฟล์ 20 GB อาจใช้หลายสิบวินาที) ครั้งต่อไปใช้จาก cache
- โหมด copy กรอไปที่ keyframe ก่อนจุดที่เลือก (ปกติไม่เกิน 2–10 วินาทีก่อนหน้า)
- transcode 4K หรือฝังซับใช้ CPU มาก ถ้า seedbox แรงไม่พอ ตั้ง Max height เป็น 720p
- การเล่นใน browser ต้องมี WebCodecs (Chrome / Edge / Firefox / Safari รุ่นใหม่) HEVC ต้องมี hardware decoder ในเครื่อง ไม่อย่างนั้นจะใช้ server

</details>

<details>
<summary><strong>🔌 API</strong></summary>

ทุก endpoint ยกเว้นไฟล์ของเว็บ (`/`, `/app.js`, `/vendor/…`, ไอคอน) และ `/api/login` ต้องยืนยันตัวตน: cookie `streammkv`, header `Authorization: Bearer <token>` หรือ `?token=` — รายการ endpoint ทั้งหมดดูได้ใน [README ภาษาอังกฤษ](README.md#-documentation) หัวข้อ API

</details>

---

<p align="center"><sub>ทำไว้ดูหนังจาก seedbox บนโซฟา 🛋️</sub></p>
