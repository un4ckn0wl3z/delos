package main

import (
	"bytes"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

func (s *Server) libraryRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/libraries", s.auth(s.handleLibraries))
	mux.HandleFunc("GET /api/lib/{id}", s.auth(s.handleLib))
	mux.HandleFunc("GET /api/cover/{key}", s.auth(s.handleCover))
	mux.HandleFunc("GET /api/audio", s.auth(s.handleAudio))

	mux.HandleFunc("GET /api/admin/libraries", s.adminOnly(s.handleAdminLibraries))
	mux.HandleFunc("POST /api/admin/libraries", s.adminOnly(s.handleAdminLibraryAdd))
	mux.HandleFunc("PUT /api/admin/libraries/{id}", s.adminOnly(s.handleAdminLibraryUpdate))
	mux.HandleFunc("DELETE /api/admin/libraries/{id}", s.adminOnly(s.handleAdminLibraryDelete))
	mux.HandleFunc("POST /api/admin/libraries/{id}/scan", s.adminOnly(s.handleAdminLibraryScan))
	mux.HandleFunc("GET /api/admin/browse", s.adminOnly(s.handleAdminBrowse))
	mux.HandleFunc("POST /api/admin/match", s.adminOnly(s.handleAdminMatch))
	mux.HandleFunc("POST /api/admin/users/{name}/libraries", s.adminOnly(s.handleAdminUserLibraries))
}

type libInfo struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Type     string   `json:"type"`
	Count    int      `json:"count"`
	Scanned  int64    `json:"scanned"`
	Path     string   `json:"path,omitempty"`    // admins only
	Exclude  []string `json:"exclude,omitempty"` // admins only
	Scanning bool     `json:"scanning,omitempty"`
	Owner    string   `json:"owner,omitempty"` // personal library of this user
	Shared   bool     `json:"shared,omitempty"`
	Size     int64    `json:"size,omitempty"`
}

func (s *Server) libInfo(l Library, admin bool) libInfo {
	li := libInfo{ID: l.ID, Name: l.Name, Type: l.Type, Count: s.index.Count(l.ID), Scanned: s.index.Scanned(l.ID), Owner: l.Owner, Shared: l.Shared}
	if admin {
		li.Path = l.Path
		li.Exclude = l.Exclude
	}
	st := s.index.Status()
	li.Scanning = st.Running && st.Lib == l.ID
	return li
}

// GET /api/libraries → the libraries this user can see
func (s *Server) handleLibraries(w http.ResponseWriter, r *http.Request) {
	out := []libInfo{}
	for _, l := range s.visibleLibraries(r) {
		out = append(out, s.libInfo(l, false))
	}
	writeJSON(w, 200, map[string]any{"libraries": out})
}

type itemOut struct {
	Item
	Pos     float64 `json:"pos,omitempty"`
	Watched int64   `json:"watched,omitempty"` // last progress update (for "continue watching")
}

// GET /api/lib/{id} → every item of a library + movie/show metadata + this user's progress
func (s *Server) handleLib(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	lib, ok := s.libs.Get(id)
	if !ok || !s.canAccess(r, id) {
		httpErr(w, 404, "no such library")
		return
	}
	snap := s.index.Snapshot(id)
	prog := s.progress.All(userOf(r))
	items := make([]itemOut, 0, len(snap.Items))
	for _, it := range snap.Items {
		o := itemOut{Item: it}
		if p, ok := prog[it.Path]; ok {
			o.Pos, o.Watched = p.Pos, p.Updated
			if o.Duration == 0 {
				o.Duration = p.Duration
			}
		}
		items = append(items, o)
	}
	resp := map[string]any{"library": s.libInfo(lib, false), "items": items}
	if lib.Type == LibMovies {
		resp["movies"] = snap.Movies
	}
	if lib.Type == LibTV || (lib.Type != LibMusic && len(snap.Shows) > 0) {
		resp["shows"] = snap.Shows
		resp["seasons"] = snap.Seasons
	}
	if s.canEditLib(r, lib) {
		resp["edits"] = snap.Edits // so editors can change one field without dropping others
	}
	writeJSON(w, 200, resp)
}

// GET /api/audio?path=&fmt=mp3|aac&start= — transcoded audio for formats the client can't play
// (wma, ape, alac, …). Most music should be played from /api/raw, which supports seeking.
func (s *Server) handleAudio(w http.ResponseWriter, r *http.Request) {
	path, _, err := s.resolveFor(r, r.URL.Query().Get("path"))
	if err != nil {
		httpErr(w, 404, err.Error())
		return
	}
	start := qFloat(r, "start", 0)
	args := []string{"-hide_banner", "-loglevel", "error", "-nostdin"}
	if start > 0 {
		args = append(args, "-ss", strconv.FormatFloat(start, 'f', 3, 64))
	}
	args = append(args, "-i", path, "-vn", "-map", "0:a:0", "-map_metadata", "-1")
	ctype := "audio/mpeg"
	if r.URL.Query().Get("fmt") == "aac" {
		args = append(args, "-c:a", "aac", "-b:a", "256k", "-f", "adts", "pipe:1")
		ctype = "audio/aac"
	} else {
		args = append(args, "-c:a", "libmp3lame", "-b:a", "256k", "-f", "mp3", "pipe:1")
	}
	release, ok := s.startStream(w, r, ClassRemux) // light: audio only
	if !ok {
		return
	}
	defer release()
	cmd := exec.CommandContext(r.Context(), s.cfg.FFmpeg, args...)
	var stderr bytes.Buffer
	cmd.Stderr = &limitedWriter{buf: &stderr, max: 4096}
	out, err := cmd.StdoutPipe()
	if err != nil {
		httpErr(w, 500, err.Error())
		return
	}
	if err := cmd.Start(); err != nil {
		httpErr(w, 500, "ffmpeg: "+err.Error())
		return
	}
	defer s.conns.Add(userOf(r), r, r.URL.Query().Get("path"), "audio-transcode")()
	w.Header().Set("Content-Type", ctype)
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Accel-Buffering", "no")
	rc := http.NewResponseController(w)
	buf := make([]byte, 64*1024)
	for {
		n, rerr := out.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				break
			}
			rc.Flush()
		}
		if rerr != nil {
			break
		}
	}
	if err := cmd.Wait(); err != nil && r.Context().Err() == nil {
		log.Printf("audio transcode: %v %s", err, strings.TrimSpace(stderr.String()))
	}
}

// ---------------------------------------------------------------- admin

func (s *Server) handleAdminLibraries(w http.ResponseWriter, r *http.Request) {
	out := []libInfo{}
	for _, l := range s.libs.List() {
		out = append(out, s.libInfo(l, true))
	}
	writeJSON(w, 200, map[string]any{"libraries": out, "status": s.index.Status()})
}

type libBody struct {
	Name, Type, Path string
	Exclude          *[]string `json:"exclude"`
}

func (s *Server) handleAdminLibraryAdd(w http.ResponseWriter, r *http.Request) {
	var b libBody
	if !decodeJSON(w, r, &b) {
		return
	}
	var ex []string
	if b.Exclude != nil {
		ex = *b.Exclude
	}
	l, err := s.libs.Add(b.Name, b.Type, b.Path, ex)
	if err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	s.index.mu.Lock()
	s.index.libs[l.ID] = newLibIndex(l)
	s.index.mu.Unlock()
	s.index.Queue(l.ID, false)
	writeJSON(w, 200, s.libInfo(l, true))
}

func (s *Server) handleAdminLibraryUpdate(w http.ResponseWriter, r *http.Request) {
	var b libBody
	if !decodeJSON(w, r, &b) {
		return
	}
	prev, _ := s.libs.Get(r.PathValue("id"))
	l, err := s.libs.Update(r.PathValue("id"), b.Name, b.Type, b.Path, b.Exclude)
	if err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	s.index.Queue(l.ID, prev.Path != l.Path) // type changes are handled by the scan itself
	writeJSON(w, 200, s.libInfo(l, true))
}

func (s *Server) handleAdminLibraryDelete(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := s.libs.Delete(id); err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	s.index.Forget(id)
	writeJSON(w, 200, map[string]bool{"ok": true})
}

func (s *Server) handleAdminLibraryScan(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, ok := s.libs.Get(id); !ok {
		httpErr(w, 404, "no such library")
		return
	}
	s.index.Queue(id, r.URL.Query().Get("refresh") == "1")
	writeJSON(w, 200, map[string]bool{"ok": true})
}

// GET /api/admin/browse?path= — folders on the server, for picking a library path
func (s *Server) handleAdminBrowse(w http.ResponseWriter, r *http.Request) {
	p := r.URL.Query().Get("path")
	if p == "" {
		if home, err := os.UserHomeDir(); err == nil {
			p = home
		} else {
			p = "/"
		}
	}
	p, err := filepath.Abs(p)
	if err != nil {
		httpErr(w, 400, "bad path")
		return
	}
	entries, err := os.ReadDir(p)
	if err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	dirs := []string{}
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".") {
			continue
		}
		if e.IsDir() {
			dirs = append(dirs, e.Name())
		} else if e.Type()&os.ModeSymlink != 0 {
			if st, err := os.Stat(filepath.Join(p, e.Name())); err == nil && st.IsDir() {
				dirs = append(dirs, e.Name())
			}
		}
	}
	sort.Slice(dirs, func(i, j int) bool { return strings.ToLower(dirs[i]) < strings.ToLower(dirs[j]) })
	writeJSON(w, 200, map[string]any{"path": p, "parent": filepath.Dir(p), "dirs": dirs})
}

// POST /api/admin/match {"lib","path"|"show","tmdbId"} — fix a wrong / missing TMDB match (0 = automatic)
func (s *Server) handleAdminMatch(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Lib, Path, Show string
		TMDBID          int `json:"tmdbId"`
	}
	if !decodeJSON(w, r, &b) {
		return
	}
	lib, ok := s.libs.Get(b.Lib)
	if !ok || !s.canAccess(r, lib.ID) {
		httpErr(w, 404, "no such library")
		return
	}
	if !s.canEditLib(r, lib) {
		httpErr(w, 403, "you are not allowed to edit metadata here")
		return
	}
	key := b.Path
	if b.Show != "" && lib.Type != LibMusic { // a series, in any video library
		key = "show:" + b.Show
	} else if lib.Type == LibTV {
		httpErr(w, 400, "show is required for tv libraries")
		return
	} else if lib.Type != LibMovies || b.Path == "" {
		httpErr(w, 400, "matching is only for movie and tv libraries")
		return
	}
	s.index.SetManual(lib.ID, key, b.TMDBID)
	writeJSON(w, 200, map[string]bool{"ok": true})
}

// POST /api/admin/users/{name}/libraries {"libraries": ["id", …] | null}
func (s *Server) handleAdminUserLibraries(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Libraries *[]string `json:"libraries"`
	}
	if !decodeJSON(w, r, &b) {
		return
	}
	if b.Libraries != nil {
		for _, id := range *b.Libraries {
			if _, ok := s.libs.Get(id); !ok {
				httpErr(w, 400, fmt.Sprintf("no such library %q", id))
				return
			}
		}
	}
	if err := s.users.SetLibraries(r.PathValue("name"), b.Libraries); err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}
