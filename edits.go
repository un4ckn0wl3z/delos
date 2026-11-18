package main

import (
	"hash/fnv"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

// Manual metadata edits. They are stored per library index and re-applied after
// every scan, on top of whatever the scrapers found, so a TMDB refresh never
// undoes them. Keys: "<path>" (a movie file, an episode or a track) or "show:<key>".

var editable = map[string]map[string]bool{
	LibMovies: {"title": true, "year": true, "overview": true, "genres": true, "poster": true, "backdrop": true, "director": true},
	"show":    {"title": true, "year": true, "overview": true, "genres": true, "poster": true, "backdrop": true},
	LibTV:     {"showTitle": true, "season": true, "episode": true, "episodeTitle": true, "episodeOverview": true, "still": true},
	LibMusic:  {"title": true, "artist": true, "album": true, "albumArtist": true, "genres": true, "track": true, "disc": true, "year": true, "cover": true},
}

func splitList(s string) []string {
	var out []string
	for _, x := range genreSplit.Split(strings.TrimSpace(s), -1) {
		if x != "" {
			out = append(out, x)
		}
	}
	return out
}

func syntheticID(path string) int {
	h := fnv.New32a()
	h.Write([]byte(path))
	return -int(h.Sum32()&0x7fffffff) - 1
}

// applyEdits runs with ix.mu held.
func (ix *Indexer) applyEdits(lib Library, li *LibIndex) {
	switch lib.Type {
	case LibMovies:
		used := map[int]bool{}
		for _, it := range li.Items {
			e := li.Edits[it.Path]
			if len(e) == 0 {
				if it.MovieID > 0 {
					used[it.MovieID] = true
				}
				continue
			}
			m := &MovieMeta{Title: it.Title, Year: it.Year}
			if base := li.Movies[it.MovieID]; base != nil && it.MovieID > 0 {
				c := *base
				m = &c
				used[it.MovieID] = true
			}
			for k, v := range e {
				switch k {
				case "title":
					m.Title = v
				case "year":
					m.Year, _ = strconv.Atoi(v)
				case "overview":
					m.Overview = v
				case "genres":
					m.Genres = splitList(v)
				case "poster":
					m.Poster = v
				case "backdrop":
					m.Backdrop = v
				case "director":
					m.Director = v
				}
			}
			id := syntheticID(it.Path)
			m.ID = id
			li.Movies[id] = m
			it.MovieID = id
			used[id] = true
		}
		for id := range li.Movies {
			if id < 0 && !used[id] {
				delete(li.Movies, id)
			}
		}
	case LibTV:
		for _, it := range li.Items {
			for k, v := range li.Edits[it.Path] {
				switch k {
				case "showTitle":
					it.Title = v
					it.Show = showKey(v, it.Year)
				case "season":
					it.Season, _ = strconv.Atoi(v)
				case "episode":
					it.Episode, _ = strconv.Atoi(v)
				case "episodeTitle":
					it.EpisodeTitle = v
				case "episodeOverview":
					it.EpisodeOverview = v
				case "still":
					it.Still = v
				}
			}
			if li.Shows[it.Show] == nil {
				li.Shows[it.Show] = &ShowMeta{Key: it.Show, Title: it.Title, Year: it.Year}
			}
		}
		for key, e := range li.Edits {
			k, ok := strings.CutPrefix(key, "show:")
			sm := li.Shows[k]
			if !ok || sm == nil {
				continue
			}
			for f, v := range e {
				switch f {
				case "title":
					sm.Title = v
				case "year":
					sm.Year, _ = strconv.Atoi(v)
				case "overview":
					sm.Overview = v
				case "genres":
					sm.Genres = splitList(v)
				case "poster":
					sm.Poster = v
				case "backdrop":
					sm.Backdrop = v
				}
			}
		}
	case LibMusic:
		for _, it := range li.Items {
			for k, v := range li.Edits[it.Path] {
				switch k {
				case "title":
					it.Title = v
				case "artist":
					it.Artist = v
				case "album":
					it.Album = v
				case "albumArtist":
					it.AlbumArtist = v
				case "genres":
					it.Genres = splitList(v)
				case "track":
					it.Track, _ = strconv.Atoi(v)
				case "disc":
					it.Disc, _ = strconv.Atoi(v)
				case "year":
					it.Year, _ = strconv.Atoi(v)
				}
			}
		}
	}
}

// applyCoverEdits downloads cover URLs set by users (music) and points the tracks at them.
func (ix *Indexer) applyCoverEdits(li *LibIndex) {
	ix.mu.RLock()
	want := map[string]string{} // path → url
	for p, e := range li.Edits {
		if u := e["cover"]; u != "" {
			want[p] = u
		}
	}
	ix.mu.RUnlock()
	for p, u := range want {
		key := cacheKey("cover-url", u)
		file := ix.s.coverFile(key)
		if _, err := os.Stat(file); err != nil && downloadImage(u, file) != nil {
			continue
		}
		ix.mu.Lock()
		for _, it := range li.Items {
			if it.Path == p {
				it.Cover = key
			}
		}
		ix.mu.Unlock()
	}
}

func downloadImage(u, dst string) error {
	pu, err := url.Parse(u)
	if err != nil || (pu.Scheme != "http" && pu.Scheme != "https") {
		return err
	}
	c := &http.Client{Timeout: 30 * time.Second}
	resp, err := c.Get(u)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return os.ErrNotExist
	}
	tmp := dst + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	_, err = io.Copy(f, io.LimitReader(resp.Body, 20<<20))
	f.Close()
	if err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, dst)
}

// SetEdit stores (or with nil fields, removes) an edit and rescans the library.
func (ix *Indexer) SetEdit(lib Library, key string, fields map[string]string) {
	ix.mu.Lock()
	li := ix.libs[lib.ID]
	if li == nil {
		ix.mu.Unlock()
		return
	}
	if len(fields) == 0 {
		delete(li.Edits, key)
		// make the next scan rebuild the automatic values
		if k, ok := strings.CutPrefix(key, "show:"); ok {
			delete(li.Shows, k)
		} else if _, rel := splitPath(key); li.Items[rel] != nil {
			li.Items[rel].Name = ""
		}
	} else {
		li.Edits[key] = fields
	}
	ix.mu.Unlock()
	ix.Queue(lib.ID, false)
}

// ---------------------------------------------------------------- API

func (s *Server) canEdit(r *http.Request) bool {
	return isAdmin(r) || s.users.IsEditor(userOf(r))
}

func (s *Server) editor(h http.HandlerFunc) http.HandlerFunc {
	return s.auth(func(w http.ResponseWriter, r *http.Request) {
		if !s.canEdit(r) {
			httpErr(w, 403, "you are not allowed to edit metadata")
			return
		}
		h(w, r)
	})
}

func (s *Server) editRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/meta/search", s.editor(s.handleMetaSearch))
	mux.HandleFunc("POST /api/meta/match", s.editor(s.handleAdminMatch))
	mux.HandleFunc("POST /api/meta/edit", s.editor(s.handleMetaEdit))
	mux.HandleFunc("POST /api/admin/users/{name}/editor", s.adminOnly(s.handleAdminEditor))
}

// GET /api/meta/search?lib=&q=&year= — TMDB candidates for "fix match"
func (s *Server) handleMetaSearch(w http.ResponseWriter, r *http.Request) {
	lib, ok := s.libs.Get(r.URL.Query().Get("lib"))
	if !ok || !s.canAccess(r, lib.ID) || (lib.Type != LibMovies && lib.Type != LibTV) {
		httpErr(w, 400, "search is only for movie and tv libraries")
		return
	}
	tm := s.index.tmdb()
	if tm == nil {
		httpErr(w, 400, "no TMDB API key — an admin can add one in the dashboard")
		return
	}
	kind := "movie"
	if lib.Type == LibTV {
		kind = "tv"
	}
	yr, _ := strconv.Atoi(r.URL.Query().Get("year"))
	res, err := tm.SearchList(kind, r.URL.Query().Get("q"), yr)
	if err != nil {
		httpErr(w, 502, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"results": res})
}

// POST /api/meta/edit {"lib","key","fields":{…}|null}
func (s *Server) handleMetaEdit(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Lib    string            `json:"lib"`
		Key    string            `json:"key"`
		Fields map[string]string `json:"fields"`
	}
	if !decodeJSON(w, r, &b) {
		return
	}
	lib, ok := s.libs.Get(b.Lib)
	if !ok || !s.canAccess(r, lib.ID) {
		httpErr(w, 404, "no such library")
		return
	}
	allowed := editable[lib.Type]
	if strings.HasPrefix(b.Key, "show:") {
		allowed = editable["show"]
		if lib.Type != LibTV {
			allowed = nil
		}
	} else if libID, _ := splitPath(b.Key); libID != lib.ID {
		httpErr(w, 400, "key does not belong to this library")
		return
	}
	if allowed == nil {
		httpErr(w, 400, "this library has no editable metadata")
		return
	}
	clean := map[string]string{}
	for k, v := range b.Fields {
		if !allowed[k] {
			httpErr(w, 400, "field "+k+" cannot be edited here")
			return
		}
		if v = strings.TrimSpace(v); v != "" {
			clean[k] = v
		}
	}
	s.index.SetEdit(lib, b.Key, clean)
	writeJSON(w, 200, map[string]bool{"ok": true})
}

func (s *Server) handleAdminEditor(w http.ResponseWriter, r *http.Request) {
	var b struct{ Editor bool }
	if !decodeJSON(w, r, &b) {
		return
	}
	if err := s.users.SetEditor(r.PathValue("name"), b.Editor); err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}
