package main

// Offline support for the apps:
//   - the "offline" permission lets a user save files to their own device
//     (GET /api/download serves the file as an attachment, resumable)
//   - POST /api/meta/lookup lets the app scrape its *own* local folders with
//     the server's TMDB key (any signed-in user; rate limited, cached)

import (
	"errors"
	"fmt"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

func (us *UserStore) IsOffline(name string) bool {
	us.mu.Lock()
	defer us.mu.Unlock()
	u, ok := us.users[name]
	return ok && (u.Offline || u.Admin)
}

func (us *UserStore) SetOffline(name string, on bool) error {
	us.mu.Lock()
	defer us.mu.Unlock()
	u, ok := us.users[name]
	if !ok {
		return errors.New("no such user")
	}
	u.Offline = on
	return us.saveLocked()
}

func (s *Server) offlineRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/download", s.auth(s.handleDownloadFile))
	mux.HandleFunc("POST /api/meta/lookup", s.auth(s.handleMetaLookup))
	mux.HandleFunc("POST /api/admin/users/{name}/offline", s.adminOnly(s.handleAdminOffline))
}

var offlineActive = struct {
	sync.Mutex
	n map[string]int
}{n: map[string]int{}}

// GET /api/download?path= — the file itself, as an attachment (Range = resume).
func (s *Server) handleDownloadFile(w http.ResponseWriter, r *http.Request) {
	user := userOf(r)
	if !s.users.IsOffline(user) {
		httpErr(w, 403, "you are not allowed to download files to your device — ask an admin")
		return
	}
	p, st, err := s.resolveFor(r, r.URL.Query().Get("path"))
	if err != nil {
		httpErr(w, 404, err.Error())
		return
	}
	// at most 3 files at once per person (a phone queueing a whole season)
	offlineActive.Lock()
	if offlineActive.n[user] >= 3 && !isAdmin(r) {
		offlineActive.Unlock()
		httpErr(w, 429, "already downloading 3 files — wait for one to finish")
		return
	}
	offlineActive.n[user]++
	offlineActive.Unlock()
	defer func() {
		offlineActive.Lock()
		offlineActive.n[user]--
		offlineActive.Unlock()
	}()
	f, err := os.Open(p)
	if err != nil {
		httpErr(w, 500, err.Error())
		return
	}
	defer f.Close()
	defer s.conns.Add(user, r, r.URL.Query().Get("path"), "download")()
	name := filepath.Base(p)
	w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": name}))
	if ct, ok := mimeTypes[strings.ToLower(filepath.Ext(p))]; ok {
		w.Header().Set("Content-Type", ct)
	} else {
		w.Header().Set("Content-Type", "application/octet-stream")
	}
	http.ServeContent(w, r, name, st.ModTime(), f)
}

func (s *Server) handleAdminOffline(w http.ResponseWriter, r *http.Request) {
	var b struct{ Offline bool }
	if !decodeJSON(w, r, &b) {
		return
	}
	if err := s.users.SetOffline(r.PathValue("name"), b.Offline); err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}

// ---------------------------------------------------------------- metadata lookup

var lookupState = struct {
	sync.Mutex
	cache map[string]lookupEntry
	rate  map[string][]time.Time
}{cache: map[string]lookupEntry{}, rate: map[string][]time.Time{}}

type lookupEntry struct {
	v  map[string]any
	at time.Time
}

// POST /api/meta/lookup {"type": "movie"|"tv", "title", "year"?, "season"?, "episode"?, "id"?}
// → {"movie": {...}} | {"show": {...}, "episode"?: {...}} | {} when nothing matched.
func (s *Server) handleMetaLookup(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Type, Title               string
		Year, Season, Episode, ID int
	}
	if !decodeJSON(w, r, &b) {
		return
	}
	tm := s.index.tmdb()
	if tm == nil {
		httpErr(w, 503, "the server has no TMDB key")
		return
	}
	title := clip(b.Title, 200)
	if title == "" && b.ID == 0 {
		httpErr(w, 400, "title or id required")
		return
	}
	key := fmt.Sprintf("%s|%s|%d|%d|%d|%d", b.Type, strings.ToLower(title), b.Year, b.Season, b.Episode, b.ID)
	user := userOf(r)
	lookupState.Lock()
	if c, ok := lookupState.cache[key]; ok && time.Since(c.at) < 24*time.Hour {
		lookupState.Unlock()
		writeJSON(w, 200, c.v)
		return
	}
	now := time.Now()
	recent := lookupState.rate[user][:0]
	for _, t := range lookupState.rate[user] {
		if now.Sub(t) < time.Minute {
			recent = append(recent, t)
		}
	}
	if len(recent) >= 120 {
		lookupState.rate[user] = recent
		lookupState.Unlock()
		httpErr(w, 429, "too many lookups — try again in a minute")
		return
	}
	lookupState.rate[user] = append(recent, now)
	lookupState.Unlock()

	out := map[string]any{}
	var err error
	if b.Type == "tv" {
		id := b.ID
		if id == 0 {
			id, err = tm.SearchTV(title, b.Year)
		}
		if err == nil && id > 0 {
			var show *ShowMeta
			if show, err = tm.TV(id); err == nil && show != nil {
				out["show"] = show
				if b.Season > 0 && b.Episode > 0 {
					if eps, err := tm.Season(id, b.Season); err == nil {
						if ep, ok := eps[b.Episode]; ok {
							out["episode"] = ep
						}
					}
				}
			}
		}
	} else {
		id := b.ID
		if id == 0 {
			id, err = tm.SearchMovie(title, b.Year)
		}
		if err == nil && id > 0 {
			var m *MovieMeta
			if m, err = tm.Movie(id); err == nil && m != nil {
				out["movie"] = m
			}
		}
	}
	if err != nil {
		httpErr(w, 502, "TMDB: "+err.Error())
		return
	}
	lookupState.Lock()
	if len(lookupState.cache) > 5000 {
		lookupState.cache = map[string]lookupEntry{}
	}
	lookupState.cache[key] = lookupEntry{out, time.Now()}
	lookupState.Unlock()
	writeJSON(w, 200, out)
}
