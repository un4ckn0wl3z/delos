package main

// Song lyrics: a .lrc next to the file, lyrics in the file's tags, or LRCLIB (free, synced).
// Results (also "none found") are cached per file in <cache>/lyrics.

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Lyrics struct {
	Synced  string `json:"synced,omitempty"` // LRC: "[mm:ss.xx] line"
	Plain   string `json:"plain,omitempty"`
	Source  string `json:"source,omitempty"` // file | tags | lrclib
	Checked int64  `json:"checked"`
}

var lyricsMu sync.Mutex // one LRCLIB lookup at a time (be polite)

// lrclibBase: where to look lyrics up online ("" = nowhere, admin turned it off).
func (s *Server) lrclibBase() string {
	switch src := s.settings.Get().LyricsSource; src {
	case "":
		if u := os.Getenv("STREAMMKV_LRCLIB_URL"); u != "" { // tests
			return strings.TrimRight(u, "/")
		}
		return "https://lrclib.net"
	case "off":
		return ""
	default:
		return src
	}
}

// GET /api/lyrics?path=<music file>[&refresh=1]
func (s *Server) handleLyrics(w http.ResponseWriter, r *http.Request) {
	if s.settings.Get().LyricsOff {
		httpErr(w, 404, "lyrics are turned off on this server")
		return
	}
	rel := r.URL.Query().Get("path")
	abs, fi, err := s.resolveFor(r, rel)
	if err != nil {
		httpErr(w, 404, err.Error())
		return
	}
	// the lookup source is part of the key: switching it looks again
	sum := sha1.Sum([]byte(fmt.Sprintf("%s|%d|%d|%s", rel, fi.Size(), fi.ModTime().Unix(), s.lrclibBase())))
	cache := filepath.Join(s.cfg.CacheDir, "lyrics", hex.EncodeToString(sum[:10])+".json")
	if r.URL.Query().Get("refresh") == "" {
		if b, err := os.ReadFile(cache); err == nil {
			var l Lyrics
			// "not found" is retried after a week (LRCLIB grows)
			if json.Unmarshal(b, &l) == nil && (l.Synced != "" || l.Plain != "" || time.Now().Unix()-l.Checked < 7*86400) {
				writeJSON(w, 200, l)
				return
			}
		}
	}
	l := s.findLyrics(r.Context(), rel, abs)
	l.Checked = time.Now().Unix()
	if b, err := json.Marshal(l); err == nil {
		os.MkdirAll(filepath.Dir(cache), 0o755)
		os.WriteFile(cache, b, 0o644)
	}
	writeJSON(w, 200, l)
}

func (s *Server) findLyrics(ctx context.Context, rel, abs string) Lyrics {
	// 1) song.lrc / song.txt next to the file
	base := strings.TrimSuffix(abs, filepath.Ext(abs))
	if b, err := os.ReadFile(base + ".lrc"); err == nil && len(b) > 0 {
		t := strings.TrimPrefix(string(b), "\ufeff")
		if lrcHasTimes(t) {
			return Lyrics{Synced: t, Plain: lrcPlain(t), Source: "file"}
		}
		return Lyrics{Plain: t, Source: "file"}
	}
	// 2) tags (LYRICS, UNSYNCEDLYRICS, lyrics-eng, …)
	if t := s.tagLyrics(ctx, abs); t != "" {
		if lrcHasTimes(t) {
			return Lyrics{Synced: t, Plain: lrcPlain(t), Source: "tags"}
		}
		return Lyrics{Plain: t, Source: "tags"}
	}
	// 3) LRCLIB by artist / title / album / duration
	it, ok := s.itemByPath(rel)
	if !ok || it.Title == "" {
		return Lyrics{}
	}
	artist := it.Artist
	if artist == "" {
		artist = it.AlbumArtist
	}
	online := s.lrclibBase()
	if online == "" {
		return Lyrics{}
	}
	if l, ok := lrclibGet(ctx, online, artist, it.Title, it.Album, it.Duration); ok {
		return l
	}
	return Lyrics{}
}

func (s *Server) itemByPath(rel string) (Item, bool) {
	lib := strings.SplitN(rel, "/", 2)[0]
	for _, it := range s.index.Items(lib) {
		if it.Path == rel {
			return it, true
		}
	}
	return Item{}, false
}

func (s *Server) tagLyrics(ctx context.Context, abs string) string {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, s.cfg.FFprobe, "-v", "error", "-show_entries", "format_tags:stream_tags", "-of", "json", abs).Output()
	if err != nil {
		return ""
	}
	var p struct {
		Format  struct{ Tags map[string]string }   `json:"format"`
		Streams []struct{ Tags map[string]string } `json:"streams"`
	}
	if json.Unmarshal(out, &p) != nil {
		return ""
	}
	all := []map[string]string{p.Format.Tags}
	for _, st := range p.Streams {
		all = append(all, st.Tags)
	}
	for _, tags := range all {
		for k, v := range tags {
			if strings.Contains(strings.ToLower(k), "lyric") && strings.TrimSpace(v) != "" {
				return strings.TrimSpace(v)
			}
		}
	}
	return ""
}

func lrclibGet(ctx context.Context, base, artist, title, album string, dur float64) (Lyrics, bool) {
	lyricsMu.Lock()
	defer lyricsMu.Unlock()
	q := url.Values{"artist_name": {artist}, "track_name": {title}}
	if album != "" {
		q.Set("album_name", album)
	}
	if dur > 0 {
		q.Set("duration", strconv.Itoa(int(dur+0.5)))
	}
	try := func(u string) (Lyrics, bool) {
		ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
		defer cancel()
		req, _ := http.NewRequestWithContext(ctx, "GET", u, nil)
		req.Header.Set("User-Agent", "Delos/"+version+" (https://github.com/un4ckn0wl3z/delos)")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return Lyrics{}, false
		}
		defer resp.Body.Close()
		if resp.StatusCode != 200 {
			return Lyrics{}, false
		}
		var one struct {
			Synced       string `json:"syncedLyrics"`
			Plain        string `json:"plainLyrics"`
			Instrumental bool   `json:"instrumental"`
		}
		var many []struct {
			Synced   string  `json:"syncedLyrics"`
			Plain    string  `json:"plainLyrics"`
			Duration float64 `json:"duration"`
		}
		dec := json.NewDecoder(resp.Body)
		if strings.Contains(u, "/api/search") {
			if dec.Decode(&many) != nil || len(many) == 0 {
				return Lyrics{}, false
			}
			// closest running time, synced first
			best := -1
			for i, m := range many {
				if m.Synced == "" && m.Plain == "" {
					continue
				}
				if dur > 0 && m.Duration > 0 && (m.Duration-dur > 8 || dur-m.Duration > 8) {
					continue
				}
				if best < 0 || (m.Synced != "" && many[best].Synced == "") {
					best = i
				}
			}
			if best < 0 {
				return Lyrics{}, false
			}
			return Lyrics{Synced: many[best].Synced, Plain: many[best].Plain, Source: "lrclib"}, true
		}
		if dec.Decode(&one) != nil || (one.Synced == "" && one.Plain == "") {
			return Lyrics{}, false
		}
		return Lyrics{Synced: one.Synced, Plain: one.Plain, Source: "lrclib"}, true
	}
	if l, ok := try(base + "/api/get?" + q.Encode()); ok {
		return l, true
	}
	// tags often differ a little (feat., remaster…): a search is more forgiving
	return try(base + "/api/search?" + url.Values{"track_name": {title}, "artist_name": {artist}}.Encode())
}

func lrcHasTimes(t string) bool {
	for _, ln := range strings.SplitN(t, "\n", 30) {
		ln = strings.TrimSpace(ln)
		if len(ln) > 6 && ln[0] == '[' && ln[1] >= '0' && ln[1] <= '9' && strings.Contains(ln[:min(len(ln), 12)], ":") {
			return true
		}
	}
	return false
}

// lrcPlain strips the [mm:ss] times and [ar:…] headers.
func lrcPlain(t string) string {
	var out []string
	for _, ln := range strings.Split(strings.ReplaceAll(t, "\r", ""), "\n") {
		for strings.HasPrefix(ln, "[") {
			i := strings.Index(ln, "]")
			if i < 0 {
				break
			}
			ln = ln[i+1:]
		}
		out = append(out, strings.TrimSpace(ln))
	}
	return strings.Trim(strings.Join(out, "\n"), "\n")
}
