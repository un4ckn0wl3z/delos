package main

// Music playlists: each user keeps their own, made of track paths ("<library>/<file>").
// Tracks the user can't open (library removed / access taken away) are simply skipped by the apps.

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

type Playlist struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	Tracks  []string `json:"tracks"`
	Created int64    `json:"created"`
	Updated int64    `json:"updated"`
}

type Playlists struct {
	mu   sync.Mutex
	file string
	by   map[string][]*Playlist // user → playlists
}

const maxPlaylists, maxPlaylistTracks = 500, 10000

func NewPlaylists(dataDir string) *Playlists {
	p := &Playlists{file: filepath.Join(dataDir, "playlists.json"), by: map[string][]*Playlist{}}
	if b, err := os.ReadFile(p.file); err == nil {
		if err := json.Unmarshal(b, &p.by); err != nil {
			log.Printf("playlists: %v", err)
		}
	}
	return p
}

func (p *Playlists) saveLocked() error {
	b, err := json.Marshal(p.by)
	if err != nil {
		return err
	}
	if err := os.WriteFile(p.file+".tmp", b, 0o600); err != nil {
		return err
	}
	return os.Rename(p.file+".tmp", p.file)
}

// MovePrefix: tracks under from now live under to (a folder moved to another library).
func (p *Playlists) MovePrefix(from, to string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	changed := false
	for _, list := range p.by {
		for _, pl := range list {
			for i, t := range pl.Tracks {
				if strings.HasPrefix(t, from) {
					pl.Tracks[i] = to + strings.TrimPrefix(t, from)
					changed = true
				}
			}
		}
	}
	if changed {
		p.saveLocked()
	}
}

func (p *Playlists) find(user, id string) *Playlist {
	for _, x := range p.by[user] {
		if x.ID == id {
			return x
		}
	}
	return nil
}

func cleanPlaylistName(n string) string {
	n = strings.Join(strings.Fields(n), " ")
	if len(n) > 120 {
		n = n[:120]
	}
	return n
}

// cleanTracks keeps paths into libraries the user can open (and drops blanks).
func (s *Server) cleanTracks(r *http.Request, in []string) []string {
	out := make([]string, 0, len(in))
	for _, t := range in {
		t = strings.TrimSpace(t)
		lib, _, ok := strings.Cut(t, "/")
		if t == "" || !ok || strings.Contains(t, "..") || !s.canAccess(r, lib) {
			continue
		}
		out = append(out, t)
	}
	return out
}

func (s *Server) playlistRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/playlists", s.auth(s.handlePlaylists))
	mux.HandleFunc("POST /api/playlists", s.auth(s.handlePlaylistCreate))
	mux.HandleFunc("GET /api/playlists/{id}", s.auth(s.handlePlaylistGet))
	mux.HandleFunc("PUT /api/playlists/{id}", s.auth(s.handlePlaylistUpdate))
	mux.HandleFunc("POST /api/playlists/{id}/add", s.auth(s.handlePlaylistAdd))
	mux.HandleFunc("DELETE /api/playlists/{id}", s.auth(s.handlePlaylistDelete))
}

type playlistSummary struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	Count   int      `json:"count"`
	Updated int64    `json:"updated"`
	First   []string `json:"first"` // a few tracks, for cover art
}

// GET /api/playlists → my playlists (newest first)
func (s *Server) handlePlaylists(w http.ResponseWriter, r *http.Request) {
	p := s.playlists
	p.mu.Lock()
	list := p.by[userOf(r)]
	out := make([]playlistSummary, 0, len(list))
	for _, x := range list {
		first := x.Tracks
		if len(first) > 4 {
			first = first[:4]
		}
		out = append(out, playlistSummary{x.ID, x.Name, len(x.Tracks), x.Updated, append([]string{}, first...)})
	}
	p.mu.Unlock()
	sort.Slice(out, func(i, j int) bool { return out[i].Updated > out[j].Updated })
	writeJSON(w, 200, map[string]any{"playlists": out})
}

// POST /api/playlists {name, tracks?}
func (s *Server) handlePlaylistCreate(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Name   string   `json:"name"`
		Tracks []string `json:"tracks"`
	}
	if !decodeJSON(w, r, &b) {
		return
	}
	name := cleanPlaylistName(b.Name)
	if name == "" {
		httpErr(w, 400, "name the playlist")
		return
	}
	tracks := s.cleanTracks(r, b.Tracks)
	if len(tracks) > maxPlaylistTracks {
		tracks = tracks[:maxPlaylistTracks]
	}
	me := userOf(r)
	p := s.playlists
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.by[me]) >= maxPlaylists {
		httpErr(w, 400, "too many playlists")
		return
	}
	now := time.Now().Unix()
	x := &Playlist{ID: chatID(), Name: name, Tracks: tracks, Created: now, Updated: now}
	p.by[me] = append(p.by[me], x)
	if err := p.saveLocked(); err != nil {
		httpErr(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, x)
}

func (s *Server) handlePlaylistGet(w http.ResponseWriter, r *http.Request) {
	p := s.playlists
	p.mu.Lock()
	defer p.mu.Unlock()
	x := p.find(userOf(r), r.PathValue("id"))
	if x == nil {
		httpErr(w, 404, "no such playlist")
		return
	}
	writeJSON(w, 200, x)
}

// PUT /api/playlists/{id} {name?, tracks?} — rename, or replace the track list (reorder / remove)
func (s *Server) handlePlaylistUpdate(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Name   *string   `json:"name"`
		Tracks *[]string `json:"tracks"`
	}
	if !decodeJSON(w, r, &b) {
		return
	}
	var tracks []string
	if b.Tracks != nil {
		tracks = s.cleanTracks(r, *b.Tracks)
		if len(tracks) > maxPlaylistTracks {
			httpErr(w, 400, "too many songs in one playlist")
			return
		}
	}
	p := s.playlists
	p.mu.Lock()
	defer p.mu.Unlock()
	x := p.find(userOf(r), r.PathValue("id"))
	if x == nil {
		httpErr(w, 404, "no such playlist")
		return
	}
	if b.Name != nil {
		n := cleanPlaylistName(*b.Name)
		if n == "" {
			httpErr(w, 400, "name the playlist")
			return
		}
		x.Name = n
	}
	if b.Tracks != nil {
		x.Tracks = tracks
	}
	x.Updated = time.Now().Unix()
	if err := p.saveLocked(); err != nil {
		httpErr(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, x)
}

// POST /api/playlists/{id}/add {tracks} — append (songs already in it are skipped)
func (s *Server) handlePlaylistAdd(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Tracks []string `json:"tracks"`
	}
	if !decodeJSON(w, r, &b) {
		return
	}
	add := s.cleanTracks(r, b.Tracks)
	p := s.playlists
	p.mu.Lock()
	defer p.mu.Unlock()
	x := p.find(userOf(r), r.PathValue("id"))
	if x == nil {
		httpErr(w, 404, "no such playlist")
		return
	}
	have := map[string]bool{}
	for _, t := range x.Tracks {
		have[t] = true
	}
	added := 0
	for _, t := range add {
		if !have[t] && len(x.Tracks) < maxPlaylistTracks {
			have[t] = true
			x.Tracks = append(x.Tracks, t)
			added++
		}
	}
	x.Updated = time.Now().Unix()
	if err := p.saveLocked(); err != nil {
		httpErr(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"added": added, "playlist": x})
}

func (s *Server) handlePlaylistDelete(w http.ResponseWriter, r *http.Request) {
	me := userOf(r)
	p := s.playlists
	p.mu.Lock()
	defer p.mu.Unlock()
	list := p.by[me]
	for i, x := range list {
		if x.ID == r.PathValue("id") {
			p.by[me] = append(list[:i:i], list[i+1:]...)
			if err := p.saveLocked(); err != nil {
				httpErr(w, 500, err.Error())
				return
			}
			writeJSON(w, 200, map[string]bool{"ok": true})
			return
		}
	}
	httpErr(w, 404, "no such playlist")
}
