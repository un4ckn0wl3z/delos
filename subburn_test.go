package main

import "testing"

func TestPCSSize(t *testing.T) {
	b := hexdump("\n00000000: 1600 0b07 8004 3810 0002 0000 0000 1700  ......8.........\n00000010: 0a01 0002 f803 c001 9000 3c80 0000       ..........<...\n")
	if w, h := pcsSize(b); w != 1920 || h != 1080 {
		t.Fatalf("got %dx%d", w, h)
	}
}

func TestBurnFilter(t *testing.T) {
	cases := []struct {
		vw, vh, cw, ch, sc, up int
		want                   string
	}{
		{1920, 1080, 1920, 1080, 100, 0, "[0:v:0][0:s:0]overlay=0:0:eof_action=pass"},
		// cropped scope encode: pad to the canvas so letterbox subtitles stay visible
		{1920, 800, 1920, 1080, 100, 0, "[0:v:0]pad=1920:1080:0:140[pv];[pv][0:s:0]overlay=0:0:eof_action=pass"},
		// 2560x1386 with a 1080p canvas (the Sin City case): scale ×1.333, pad 27 px top/bottom
		{2560, 1386, 1920, 1080, 100, 0, "[0:s:0]scale=2560:1440[ss];[0:v:0]pad=2560:1440:0:27[pv];[pv][ss]overlay=0:0:eof_action=pass"},
		// 4K video, 1080p canvas
		{3840, 2160, 1920, 1080, 100, 0, "[0:s:0]scale=3840:2160[ss];[0:v:0][ss]overlay=0:0:eof_action=pass"},
		// smaller and raised
		{1920, 1080, 1920, 1080, 80, 10, "[0:s:0]scale=1536:864[ss];[0:v:0][ss]overlay=192:108:eof_action=pass"},
	}
	for _, c := range cases {
		if got := burnFilter(c.vw, c.vh, c.cw, c.ch, 0, c.sc, c.up); got != c.want {
			t.Errorf("%dx%d on %dx%d %d%% +%d:\n got %s\nwant %s", c.cw, c.ch, c.vw, c.vh, c.sc, c.up, got, c.want)
		}
	}
}
