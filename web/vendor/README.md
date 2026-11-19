# Vendored: Mediabunny 1.66.1

Used by `web/player-wasm.mjs` (the in-browser player). Copied from npm, unmodified:

| File | Package | License |
|---|---|---|
| `mediabunny.min.mjs` | `mediabunny@1.66.1` — demuxing (MKV/MP4/…), WebCodecs decoding | MPL-2.0 (`LICENSE-mediabunny.txt`) |
| `mediabunny-ac3.min.mjs` | `@mediabunny/ac3@1.66.1` — AC-3 / E-AC-3 decoder (FFmpeg → WebAssembly) | MPL-2.0; FFmpeg parts LGPL-2.1+ (`licenses/`) |
| `mediabunny-dts.min.mjs` | `@mediabunny/dts@1.66.1` — DTS decoder (FFmpeg → WebAssembly) | MPL-2.0; FFmpeg parts LGPL-2.1+ (`licenses/`) |
| `mediabunny-truehd.min.mjs` | `@mediabunny/truehd@1.66.1` — Dolby TrueHD decoder (FFmpeg → WebAssembly) | MPL-2.0; FFmpeg parts LGPL-2.1+ (`licenses/`) |

The codec extensions are only downloaded when a file needs them.

Update: `npm pack mediabunny @mediabunny/ac3 @mediabunny/dts @mediabunny/truehd` and copy `dist/bundles/*.min.mjs` here.
