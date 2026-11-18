package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// Progress is the per-file watch state shared by every client (browser, app).
type Progress struct {
	Pos      float64 `json:"pos"`
	Duration float64 `json:"duration,omitempty"`
	Audio    *int    `json:"audio,omitempty"` // audio-relative index (0:a:N)
	Sub      *int    `json:"sub,omitempty"`   // subtitle-relative index, -1 = off
	Updated  int64   `json:"updated"`
}

type ProgressStore struct {
	mu    sync.Mutex
	file  string
	users map[string]map[string]*Progress // user → path → progress
	dirty bool
}

type progressFile struct {
	Version int                             `json:"version"`
	Users   map[string]map[string]*Progress `json:"users"`
}

// NewProgressStore loads progress.json. A v1 file (single-user, path → progress)
// is migrated to [legacyOwner].
func NewProgressStore(dir, legacyOwner string) *ProgressStore {
	ps := &ProgressStore{file: filepath.Join(dir, "progress.json"), users: map[string]map[string]*Progress{}}
	if b, err := os.ReadFile(ps.file); err == nil {
		var f progressFile
		if json.Unmarshal(b, &f) == nil && f.Version >= 2 && f.Users != nil {
			ps.users = f.Users
		} else {
			var old map[string]*Progress
			if err := json.Unmarshal(b, &old); err == nil && legacyOwner != "" {
				ps.users[legacyOwner] = old
				ps.dirty = true
				log.Printf("progress.json: migrated %d entries to user %q", len(old), legacyOwner)
			} else if err != nil {
				log.Printf("progress.json unreadable, starting empty: %v", err)
			}
		}
	}
	go func() { // flush at most every 2s
		for range time.Tick(2 * time.Second) {
			ps.flush()
		}
	}()
	return ps
}

func (ps *ProgressStore) flush() {
	ps.mu.Lock()
	if !ps.dirty {
		ps.mu.Unlock()
		return
	}
	b, err := json.Marshal(progressFile{Version: 2, Users: ps.users})
	ps.dirty = false
	ps.mu.Unlock()
	if err != nil {
		return
	}
	tmp := ps.file + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err == nil {
		os.Rename(tmp, ps.file)
	}
}

func (ps *ProgressStore) Get(user, path string) *Progress {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	if p, ok := ps.users[user][path]; ok {
		c := *p
		return &c
	}
	return nil
}

func (ps *ProgressStore) All(user string) map[string]Progress {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	out := make(map[string]Progress, len(ps.users[user]))
	for k, v := range ps.users[user] {
		out[k] = *v
	}
	return out
}

// Recent returns entries of every user updated within [within].
func (ps *ProgressStore) Recent(within time.Duration) []WatchEntry {
	cut := time.Now().Add(-within).Unix()
	ps.mu.Lock()
	defer ps.mu.Unlock()
	var out []WatchEntry
	for u, m := range ps.users {
		for path, p := range m {
			if p.Updated >= cut {
				out = append(out, WatchEntry{User: u, Path: path, Progress: *p})
			}
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Updated > out[j].Updated })
	return out
}

type WatchEntry struct {
	User string `json:"user"`
	Path string `json:"path"`
	Progress
}

// List returns one user's entries, newest first.
func (ps *ProgressStore) List(user string) []WatchEntry {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	out := []WatchEntry{}
	for path, p := range ps.users[user] {
		out = append(out, WatchEntry{User: user, Path: path, Progress: *p})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Updated > out[j].Updated })
	return out
}

func (ps *ProgressStore) Count(user string) (total, inProgress int) {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	for _, p := range ps.users[user] {
		total++
		if p.Pos > 0 {
			inProgress++
		}
	}
	return
}

func (ps *ProgressStore) Clear(user string) {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	delete(ps.users, user)
	ps.dirty = true
}

type progressUpdate struct {
	Path     string   `json:"path"`
	Pos      *float64 `json:"pos"`
	Duration float64  `json:"duration"`
	Audio    *int     `json:"audio"`
	Sub      *int     `json:"sub"`
	Done     bool     `json:"done"`
}

func (ps *ProgressStore) Update(user string, u progressUpdate) {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	m := ps.users[user]
	if m == nil {
		m = map[string]*Progress{}
		ps.users[user] = m
	}
	p := m[u.Path]
	if p == nil {
		p = &Progress{}
	}
	if u.Duration > 0 {
		p.Duration = u.Duration
	}
	if u.Pos != nil {
		p.Pos = *u.Pos
	}
	if u.Done || (p.Duration > 0 && p.Pos > p.Duration-120) {
		p.Pos = 0 // finished: forget the position but keep track choices
	}
	if u.Audio != nil {
		p.Audio = u.Audio
	}
	if u.Sub != nil {
		p.Sub = u.Sub
	}
	p.Updated = time.Now().Unix()
	m[u.Path] = p
	ps.dirty = true
}

// GET  /api/progress            → {"items": {path: Progress}}
// GET  /api/progress?path=...   → Progress or {}
// POST /api/progress            {"path","pos","duration","audio","sub","done"}
func (s *Server) handleProgressGet(w http.ResponseWriter, r *http.Request) {
	if p := r.URL.Query().Get("path"); p != "" {
		if pr := s.progress.Get(userOf(r), p); pr != nil {
			writeJSON(w, 200, pr)
		} else {
			writeJSON(w, 200, map[string]any{})
		}
		return
	}
	writeJSON(w, 200, map[string]any{"items": s.progress.All(userOf(r))})
}

func (s *Server) handleProgressPost(w http.ResponseWriter, r *http.Request) {
	var u progressUpdate
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&u); err != nil || u.Path == "" {
		httpErr(w, 400, "bad request")
		return
	}
	if _, _, err := s.resolve(u.Path); err != nil {
		httpErr(w, 404, err.Error())
		return
	}
	s.progress.Update(userOf(r), u)
	writeJSON(w, 200, map[string]bool{"ok": true})
}

// GET /api/raw?path=  — the original file with HTTP Range support (used by the app's mpv player).
func (s *Server) handleRaw(w http.ResponseWriter, r *http.Request) {
	p, st, err := s.resolve(r.URL.Query().Get("path"))
	if err != nil {
		httpErr(w, 404, err.Error())
		return
	}
	f, err := os.Open(p)
	if err != nil {
		httpErr(w, 500, err.Error())
		return
	}
	defer f.Close()
	defer s.conns.Add(userOf(r), r, r.URL.Query().Get("path"), "direct")()
	if filepath.Ext(p) == ".mkv" {
		w.Header().Set("Content-Type", "video/x-matroska")
	}
	w.Header().Set("Cache-Control", "private, no-transform")
	http.ServeContent(w, r, st.Name(), st.ModTime(), f)
}
