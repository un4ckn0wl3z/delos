package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"path/filepath"
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
	items map[string]*Progress
	dirty bool
}

func NewProgressStore(dir string) *ProgressStore {
	ps := &ProgressStore{file: filepath.Join(dir, "progress.json"), items: map[string]*Progress{}}
	if b, err := os.ReadFile(ps.file); err == nil {
		if err := json.Unmarshal(b, &ps.items); err != nil {
			log.Printf("progress.json unreadable, starting empty: %v", err)
			ps.items = map[string]*Progress{}
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
	b, err := json.Marshal(ps.items)
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

func (ps *ProgressStore) Get(path string) *Progress {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	if p, ok := ps.items[path]; ok {
		c := *p
		return &c
	}
	return nil
}

func (ps *ProgressStore) All() map[string]Progress {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	out := make(map[string]Progress, len(ps.items))
	for k, v := range ps.items {
		out[k] = *v
	}
	return out
}

type progressUpdate struct {
	Path     string   `json:"path"`
	Pos      *float64 `json:"pos"`
	Duration float64  `json:"duration"`
	Audio    *int     `json:"audio"`
	Sub      *int     `json:"sub"`
	Done     bool     `json:"done"`
}

func (ps *ProgressStore) Update(u progressUpdate) {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	p := ps.items[u.Path]
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
	ps.items[u.Path] = p
	ps.dirty = true
}

// GET  /api/progress            → {"items": {path: Progress}}
// GET  /api/progress?path=...   → Progress or {}
// POST /api/progress            {"path","pos","duration","audio","sub","done"}
func (s *Server) handleProgressGet(w http.ResponseWriter, r *http.Request) {
	if p := r.URL.Query().Get("path"); p != "" {
		if pr := s.progress.Get(p); pr != nil {
			writeJSON(w, 200, pr)
		} else {
			writeJSON(w, 200, map[string]any{})
		}
		return
	}
	writeJSON(w, 200, map[string]any{"items": s.progress.All()})
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
	s.progress.Update(u)
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
	if filepath.Ext(p) == ".mkv" {
		w.Header().Set("Content-Type", "video/x-matroska")
	}
	w.Header().Set("Cache-Control", "private, no-transform")
	http.ServeContent(w, r, st.Name(), st.ModTime(), f)
}
