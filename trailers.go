package main

// Trailers for films and series: YouTube videos from TMDB's list (trailers before
// teasers, official ones first, in the server's TMDB language when there is one,
// else English). Cached a week per title. An admin can turn them off in Features.

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// ------------------------------------------------------------ TMDB videos

type OnlineTrailer struct {
	Site     string `json:"site"` // YouTube
	Key      string `json:"key"`
	Name     string `json:"name"`
	Type     string `json:"type"` // Trailer, Teaser…
	Official bool   `json:"official"`
	Lang     string `json:"lang,omitempty"`
}

type tmdbVideos struct {
	Results []struct {
		Site      string `json:"site"`
		Key       string `json:"key"`
		Name      string `json:"name"`
		Type      string `json:"type"`
		Official  bool   `json:"official"`
		Lang      string `json:"iso_639_1"`
		Size      int    `json:"size"`
		Published string `json:"published_at"`
	} `json:"results"`
}

// Videos: trailers / teasers on YouTube, best first.
func (t *TMDB) Videos(kind string, id int) ([]OnlineTrailer, error) {
	lang2 := strings.ToLower(strings.SplitN(t.lang, "-", 2)[0])
	var v tmdbVideos
	if err := t.get(fmt.Sprintf("/%s/%d/videos", kind, id), url.Values{"include_video_language": {lang2 + ",en,null"}}, "", &v); err != nil {
		return nil, err
	}
	rank := map[string]int{"Trailer": 0, "Teaser": 1}
	type cand struct {
		OnlineTrailer
		r    int
		size int
		pub  string
	}
	var cs []cand
	for _, x := range v.Results {
		r, ok := rank[x.Type]
		if !ok || x.Site != "YouTube" || x.Key == "" {
			continue
		}
		cs = append(cs, cand{OnlineTrailer{Site: x.Site, Key: x.Key, Name: x.Name, Type: x.Type, Official: x.Official, Lang: x.Lang}, r, x.Size, x.Published})
	}
	sort.SliceStable(cs, func(i, j int) bool {
		a, b := cs[i], cs[j]
		if a.r != b.r {
			return a.r < b.r
		}
		if (a.Lang == lang2) != (b.Lang == lang2) && lang2 != "en" {
			return a.Lang == lang2
		}
		if a.Official != b.Official {
			return a.Official
		}
		if a.size != b.size {
			return a.size > b.size
		}
		return a.pub > b.pub
	})
	out := []OnlineTrailer{}
	for _, c := range cs {
		if len(out) == 6 {
			break
		}
		out = append(out, c.OnlineTrailer)
	}
	return out, nil
}

type trailerCache struct {
	Fetched int64           `json:"fetched"`
	Videos  []OnlineTrailer `json:"videos"`
}

func (s *Server) onlineTrailers(kind string, id int) []OnlineTrailer {
	tm := s.index.tmdb()
	if tm == nil || id <= 0 {
		return nil
	}
	f := filepath.Join(s.cfg.CacheDir, "trailers", fmt.Sprintf("%s-%d.json", kind, id))
	var c trailerCache
	if b, err := os.ReadFile(f); err == nil && json.Unmarshal(b, &c) == nil {
		age := time.Since(time.Unix(c.Fetched, 0))
		if age < 7*24*time.Hour && (len(c.Videos) > 0 || age < 24*time.Hour) {
			return c.Videos
		}
	}
	v, err := tm.Videos(kind, id)
	if err != nil {
		return c.Videos // keep what we had
	}
	os.MkdirAll(filepath.Dir(f), 0o755)
	b, _ := json.Marshal(trailerCache{Fetched: time.Now().Unix(), Videos: v})
	os.WriteFile(f, b, 0o644)
	return v
}

// GET /api/trailers?lib=&movie=<movie id or path> | &show=<series key>
func (s *Server) handleTrailers(w http.ResponseWriter, r *http.Request) {
	if s.settings.Get().TrailersOff {
		httpErr(w, 404, "trailers are turned off on this server")
		return
	}
	q := r.URL.Query()
	lib := q.Get("lib")
	if !s.canAccess(r, lib) {
		httpErr(w, 404, "not found")
		return
	}
	kind, tmdbID := "movie", 0
	s.index.mu.RLock()
	if li := s.index.libs[lib]; li != nil {
		if key := q.Get("show"); key != "" {
			kind = "tv"
			if sm := li.Shows[key]; sm != nil {
				tmdbID = sm.TMDBID
			}
		} else if key := q.Get("movie"); key != "" {
			for _, it := range li.Items {
				if it.Show == "" && it.MovieID > 0 && (it.Path == key || strconv.Itoa(it.MovieID) == key) {
					tmdbID = it.MovieID
					break
				}
			}
		}
	}
	s.index.mu.RUnlock()
	online := s.onlineTrailers(kind, tmdbID)
	if online == nil {
		online = []OnlineTrailer{}
	}
	w.Header().Set("Cache-Control", "private, max-age=600")
	writeJSON(w, 200, map[string]any{"online": online})
}
