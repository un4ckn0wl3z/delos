package main

import (
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
)

// POST /api/admin/metadata/test {"tmdbKey"?, "tmdbLang"?}
// Checks the TMDB key (or the saved one), MusicBrainz reachability, and how
// well each library is matched, with hints for libraries that will never get
// posters (e.g. "Other videos" type).
func (s *Server) handleMetadataTest(w http.ResponseWriter, r *http.Request) {
	var b struct {
		TMDBKey  string `json:"tmdbKey"`
		TMDBLang string `json:"tmdbLang"`
	}
	if r.ContentLength > 0 && !decodeJSON(w, r, &b) {
		return
	}
	st := s.settings.Get()
	key := strings.TrimSpace(b.TMDBKey)
	if key == "" {
		key = st.TMDBKey
	}
	lang := firstNonEmpty(b.TMDBLang, st.TMDBLang, "en-US")
	writeJSON(w, 200, map[string]any{
		"tmdb":        testTMDB(key, lang),
		"musicbrainz": testMusicBrainz(),
		"libraries":   s.libraryHealth(key != ""),
		"scan":        s.index.Status(),
	})
}

type checkResult struct {
	OK     bool   `json:"ok"`
	MS     int64  `json:"ms"`
	Error  string `json:"error,omitempty"`
	Detail string `json:"detail,omitempty"`
	Image  string `json:"image,omitempty"`
}

func testTMDB(key, lang string) checkResult {
	if key == "" {
		return checkResult{Error: "No TMDB key saved"}
	}
	t0 := time.Now()
	res, err := NewTMDB(key, lang).SearchList("movie", "Inception", 2010)
	r := checkResult{MS: time.Since(t0).Milliseconds()}
	if err != nil {
		r.Error = err.Error()
		if !strings.Contains(r.Error, "API key") && !strings.HasPrefix(r.Error, "TMDB ") {
			r.Error = "Cannot reach TMDB from the server: " + r.Error
		}
		return r
	}
	if len(res) == 0 {
		r.Error = "TMDB answered but returned no results"
		return r
	}
	kind := "v3 API key"
	if strings.HasPrefix(key, "eyJ") {
		kind = "v4 read token"
	}
	r.OK = true
	r.Detail = kind + " works · sample: " + res[0].Title
	r.Image = res[0].Poster
	return r
}

func testMusicBrainz() checkResult {
	t0 := time.Now()
	req, _ := http.NewRequest("GET", mbBase()+"/release-group?fmt=json&limit=1&query="+url.QueryEscape(`releasegroup:"Abbey Road"`), nil)
	req.Header.Set("User-Agent", "Delos/"+version+" ( https://github.com/un4ckn0wl3z/delos )")
	resp, err := (&http.Client{Timeout: 15 * time.Second}).Do(req)
	r := checkResult{MS: time.Since(t0).Milliseconds()}
	if err != nil {
		r.Error = "Cannot reach MusicBrainz: " + err.Error()
		return r
	}
	resp.Body.Close()
	if resp.StatusCode != 200 {
		r.Error = "MusicBrainz: " + resp.Status
		return r
	}
	r.OK = true
	r.Detail = "reachable (used for album covers)"
	return r
}

type libHealth struct {
	ID        string   `json:"id"`
	Name      string   `json:"name"`
	Type      string   `json:"type"`
	Items     int      `json:"items"`
	Matched   int      `json:"matched"`
	Unmatched []string `json:"unmatched,omitempty"` // a few examples
	Missing   int      `json:"missing"`
	Warning   string   `json:"warning,omitempty"`
}

func (s *Server) libraryHealth(haveKey bool) []libHealth {
	out := []libHealth{}
	for _, lib := range s.libs.List() {
		snap := s.index.Snapshot(lib.ID)
		h := libHealth{ID: lib.ID, Name: lib.Name, Type: lib.Type, Items: len(snap.Items)}
		miss := map[string]bool{}
		switch lib.Type {
		case "movies":
			for _, it := range snap.Items {
				if m := snap.Movies[it.MovieID]; m != nil && m.Poster != "" {
					h.Matched++
				} else {
					miss[firstNonEmpty(it.Title, it.Name)] = true
				}
			}
		case "tv":
			for _, it := range snap.Items {
				if m := snap.Shows[it.Show]; m != nil && m.Poster != "" {
					h.Matched++
				} else {
					miss[firstNonEmpty(it.Title, it.Name)] = true
				}
			}
		case "music":
			for _, it := range snap.Items {
				if it.Cover != "" {
					h.Matched++
				} else {
					miss[firstNonEmpty(it.Album, it.Name)] = true
				}
			}
		default:
			if h.Items > 0 {
				h.Warning = `Type is "Other videos": it never fetches posters or metadata. Click Edit and change the type to Movies or TV series.`
			}
		}
		if (lib.Type == "movies" || lib.Type == "tv") && !haveKey {
			h.Warning = "No TMDB key — titles come from file names only."
		}
		for k := range miss {
			h.Unmatched = append(h.Unmatched, k)
		}
		sort.Strings(h.Unmatched)
		h.Missing = len(h.Unmatched)
		if len(h.Unmatched) > 8 {
			h.Unmatched = h.Unmatched[:8]
		}
		if snap.Scanned == 0 && h.Warning == "" {
			h.Warning = "Not scanned yet — click Scan."
		}
		out = append(out, h)
	}
	return out
}
