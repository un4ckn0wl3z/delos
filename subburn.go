package main

// Burning image subtitles (PGS / VobSub) into the transcoded video.
//
// A PGS track is drawn on its own canvas (usually 1920×1080), which often isn't the video's
// size: 4K encodes, cropped encodes (2560×1386, 1920×800, …). ffprobe only knows the canvas
// once it has decoded a subtitle, which it may not reach while probing (forced-only tracks
// start late), so we read it from the first composition segment ourselves.
//
// Layout: the canvas is scaled uniformly to the video width and centred on the picture, the
// video is padded when the canvas is taller (subtitles that sat in the letterbox stay
// visible), then the viewer's size (%) and raise (% of height) are applied around the
// bottom-centre.

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"sync"
	"time"
)

var pgsCanvasCache sync.Map // "path|idx|mtime" → [2]int

// subCanvas returns the subtitle canvas size, or the video size when it can't be found.
func (m *Media) subCanvas(ctx context.Context, path string, mod time.Time, info *ProbeInfo, idx int, start float64) (int, int) {
	sub, v := info.Subs[idx], info.Video
	if sub.Width > 0 && sub.Height > 0 {
		return sub.Width, sub.Height
	}
	if sub.Codec != "hdmv_pgs_subtitle" {
		return v.Width, v.Height
	}
	key := fmt.Sprintf("%s|%d|%d", path, idx, mod.UnixNano())
	if c, ok := pgsCanvasCache.Load(key); ok {
		wh := c.([2]int)
		return wh[0], wh[1]
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	for _, iv := range []string{fmt.Sprintf("%.3f%%+600", start), "%+1800"} {
		if w, h := m.pgsCanvasAt(ctx, path, idx, iv); w > 0 {
			pgsCanvasCache.Store(key, [2]int{w, h})
			return w, h
		}
	}
	return v.Width, v.Height
}

func (m *Media) pgsCanvasAt(ctx context.Context, path string, idx int, interval string) (int, int) {
	cmd := exec.CommandContext(ctx, m.cfg.FFprobe, "-v", "error", "-select_streams", fmt.Sprintf("s:%d", idx),
		"-read_intervals", interval, "-show_packets", "-show_data", "-show_entries", "packet=data", "-of", "json", path)
	out, err := cmd.Output()
	if err != nil && len(out) == 0 {
		return 0, 0
	}
	var res struct {
		Packets []struct {
			Data string `json:"data"`
		} `json:"packets"`
	}
	if json.Unmarshal(out, &res) != nil {
		return 0, 0
	}
	for _, p := range res.Packets {
		if w, h := pcsSize(hexdump(p.Data)); w > 0 {
			return w, h
		}
	}
	return 0, 0
}

// hexdump decodes ffprobe's "00000000: 1600 0b07 …  ascii" format.
func hexdump(s string) []byte {
	var out []byte
	for _, line := range strings.Split(s, "\n") {
		i := strings.Index(line, ": ")
		if i < 0 {
			continue
		}
		hx := line[i+2:]
		if j := strings.Index(hx, "  "); j >= 0 {
			hx = hx[:j]
		}
		b, err := hex.DecodeString(strings.ReplaceAll(hx, " ", ""))
		if err != nil {
			return out
		}
		out = append(out, b...)
	}
	return out
}

// pcsSize finds a Presentation Composition Segment (type 0x16) and returns its video size.
func pcsSize(b []byte) (int, int) {
	for p := 0; p+3 <= len(b); {
		typ, size := b[p], int(b[p+1])<<8|int(b[p+2])
		if typ == 0x16 && size >= 4 && p+7 <= len(b) {
			w, h := int(b[p+3])<<8|int(b[p+4]), int(b[p+5])<<8|int(b[p+6])
			if w >= 320 && h >= 200 && w <= 8192 && h <= 8192 {
				return w, h
			}
		}
		p += 3 + size
	}
	return 0, 0
}

// burnFilter builds the filter graph (ending in [vb]) that draws subtitle stream idx on the video.
// scalePct: subtitle size (100 = as authored), raisePct: move up by this % of the picture height.
func burnFilter(vw, vh, cw, ch, idx, scalePct, raisePct int) string {
	even := func(v float64) int {
		n := int(v + 0.5)
		if n < 2 {
			n = 2
		}
		return n &^ 1
	}
	s0 := float64(vw) / float64(cw)
	h0 := float64(ch) * s0 // canvas height at video width
	fh := vh
	if int(h0+0.5) > vh {
		fh = even(h0)
	}
	k := float64(scalePct) / 100
	w, h := even(float64(vw)*k), even(h0*k)
	x := (vw - w) / 2
	// keep the canvas' bottom edge where it was, then raise
	y := int((float64(fh)+h0)/2 - float64(h) - float64(raisePct)*float64(vh)/100)

	var fc strings.Builder
	sub := fmt.Sprintf("[0:s:%d]", idx)
	if w != cw || h != ch {
		fmt.Fprintf(&fc, "[0:s:%d]scale=%d:%d[ss];", idx, w, h)
		sub = "[ss]"
	}
	base := "[0:v:0]"
	if fh != vh {
		fmt.Fprintf(&fc, "[0:v:0]pad=%d:%d:0:%d[pv];", vw, fh, (fh-vh)/2)
		base = "[pv]"
	}
	fmt.Fprintf(&fc, "%s%soverlay=%d:%d:eof_action=pass", base, sub, x, y)
	return fc.String()
}
