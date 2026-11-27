package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestLrcHelpers(t *testing.T) {
	lrc := "[ar:Someone]\n[00:01.00]Hello\n[00:05.50][00:20.00]Again\n"
	if !lrcHasTimes(lrc) {
		t.Fatal("timed LRC not recognised")
	}
	if lrcHasTimes("just words\nmore words") {
		t.Fatal("plain text taken for LRC")
	}
	if got := lrcPlain(lrc); got != "Hello\nAgain" {
		t.Fatalf("plain = %q", got)
	}
}

func TestLrclibGetFallsBackToSearch(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/get":
			http.NotFound(w, r)
		case "/api/search":
			json.NewEncoder(w).Encode([]map[string]any{
				{"plainLyrics": "far off", "syncedLyrics": "[00:01.00]far off", "duration": 300.0},
				{"plainLyrics": "plain only", "duration": 181.0},
				{"plainLyrics": "best", "syncedLyrics": "[00:01.00]best", "duration": 183.0},
			})
		}
	}))
	defer srv.Close()
	t.Setenv("STREAMMKV_LRCLIB_URL", srv.URL)
	l, ok := lrclibGet(context.Background(), "Artist", "Song", "Album", 180)
	if !ok || l.Synced != "[00:01.00]best" || l.Source != "lrclib" {
		t.Fatalf("got %+v %v", l, ok)
	}
}
