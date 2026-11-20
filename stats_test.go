package main

import (
	"testing"
	"time"
)

func TestStatsVideoMusic(t *testing.T) {
	st := &Stats{Days: map[string]map[string]*DayStat{}, Done: map[string]map[string]int64{}, lastV: map[string]statMark{}, lastM: map[string]statMark{}}
	st.Video("a", "lib/x.mkv", 100, 1000, false)
	st.lastV["a"] = statMark{"lib/x.mkv", 100, time.Now().Add(-10 * time.Second)}
	st.Video("a", "lib/x.mkv", 110, 1000, false) // 10 s played
	st.lastV["a"] = statMark{"lib/x.mkv", 110, time.Now().Add(-10 * time.Second)}
	st.Video("a", "lib/x.mkv", 600, 1000, false) // a seek: only ~15 s
	st.Video("a", "lib/x.mkv", 950, 1000, false) // past 90 %: one title
	st.Video("a", "lib/x.mkv", 960, 1000, true)  // not twice
	tot := st.totalsLocked("")["a"]
	if tot.Video < 34 || tot.Video > 36 || tot.Titles != 1 { // 10 + 15 + 5 + 5 (5 s slack per save)
		t.Fatalf("video %+v", tot)
	}
	st.Music("b", &Activity{Kind: "music", Path: "m/1.mp3", Title: "One"})
	st.lastM["b"] = statMark{path: "m/1.mp3\x00One", at: time.Now().Add(-30 * time.Second)}
	st.Music("b", &Activity{Kind: "music", Path: "m/2.mp3", Title: "Two"}) // 30 s, new song
	st.lastM["b"] = statMark{path: "m/2.mp3\x00Two", at: time.Now().Add(-20 * time.Second)}
	st.Music("b", nil) // paused: +20 s
	tb := st.totalsLocked("")["b"]
	if tb.Music < 49 || tb.Music > 51 || tb.Songs != 2 {
		t.Fatalf("music %+v", tb)
	}
	// badges: an hour of music → Listener, and the top listener this month
	st.Days["b"][time.Now().Format("2006-01-02")].Music += 3600
	b := st.badgesLocked(time.Now(), func(string) bool { return false })
	ids := map[string]bool{}
	for _, x := range b["b"] {
		ids[x.ID] = true
	}
	if !ids["m1"] || !ids["top-music"] {
		t.Fatalf("badges %+v", b)
	}
	if hidden := st.badgesLocked(time.Now(), func(u string) bool { return u == "b" }); len(hidden["b"]) != 0 {
		t.Fatalf("hidden user got badges")
	}
}
