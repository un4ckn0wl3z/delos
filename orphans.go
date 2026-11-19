package main

import (
	"errors"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Unused files: things in rtorrent's download folder that no torrent in
// rtorrent owns any more (left over after removing torrents, old downloads…).
// Admins review the list in /admin → Torrents and delete what they pick.

type orphan struct {
	Path     string `json:"path"`
	Rel      string `json:"rel"`
	Dir      bool   `json:"dir"`
	Size     int64  `json:"size"`
	Files    int    `json:"files"`
	Modified int64  `json:"modified"`
	Library  string `json:"library,omitempty"`  // inside a StreamMKV library (still watchable there)
	Download string `json:"download,omitempty"` // an HTTP download StreamMKV made (by whom)
}

// orphanRoot: ?dir= (absolute, existing) or rtorrent's directory.default.
func (s *Server) orphanRoot(rt *RTorrent, dir string) (string, error) {
	if dir == "" {
		v, err := rt.Call("directory.default", "")
		if err != nil {
			return "", err
		}
		dir, _ = v.(string)
	}
	dir = filepath.Clean(expandHome(strings.TrimSpace(dir)))
	if !filepath.IsAbs(dir) {
		return "", errors.New("give an absolute folder")
	}
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		return "", errors.New(dir + " is not a folder")
	}
	if home, _ := os.UserHomeDir(); dir == "/" || dir == filepath.Dir(home) {
		return "", errors.New("pick the folder rtorrent downloads into, not " + dir)
	}
	return dir, nil
}

// scanOrphans lists entries under root that aren't (and don't contain) any
// torrent's data. Folders that hold torrents are opened up (a few levels).
func (s *Server) scanOrphans(rt *RTorrent, root string) ([]orphan, int, error) {
	items, err := rt.List()
	if err != nil {
		return nil, 0, err
	}
	used := map[string]bool{}    // a torrent's file / folder
	holders := map[string]bool{} // folders that contain torrent data
	for _, it := range items {
		p := filepath.Clean(it.dataPath())
		if p == "." || p == "" {
			continue
		}
		used[p] = true
		for d := filepath.Dir(p); len(d) > 1 && d != filepath.Dir(d); d = filepath.Dir(d) {
			holders[d] = true
		}
	}
	// never offer a library, StreamMKV's own folders, or anything holding one
	// as a whole: open those up and list what's inside instead
	skip := map[string]bool{}
	protect := []string{s.userLibRoot(), s.cfg.DataDir, s.cfg.CacheDir}
	if exe, err := os.Executable(); err == nil {
		protect = append(protect, filepath.Dir(exe))
	}
	for _, l := range s.libs.List() {
		holders[filepath.Clean(l.Path)] = true
		protect = append(protect, l.Path)
	}
	for _, x := range protect {
		if x == "" {
			continue
		}
		x = filepath.Clean(x)
		for d := filepath.Dir(x); len(d) > 1 && d != filepath.Dir(d); d = filepath.Dir(d) {
			holders[d] = true
		}
	}
	for _, x := range []string{s.cfg.DataDir, s.cfg.CacheDir} {
		if x != "" {
			skip[filepath.Clean(x)] = true
		}
	}
	// rtorrent's own session folder and active HTTP downloads

	if v, err := rt.Call("session.path", ""); err == nil {
		if p, _ := v.(string); p != "" {
			skip[filepath.Clean(p)] = true
		}
	}
	httpJobs := map[string]string{}
	s.dl.mu.Lock()
	for _, j := range s.dl.jobs {
		if j.Kind == "http" && j.Name != "" {
			if dir, _, err := s.dl.targetDir(j.Lib, j.Subdir); err == nil {
				httpJobs[filepath.Join(dir, j.Name)] = j.User
			}
		}
	}
	s.dl.mu.Unlock()

	var out []orphan
	var walk func(dir string, depth int)
	walk = func(dir string, depth int) {
		ents, err := os.ReadDir(dir)
		if err != nil {
			return
		}
		for _, e := range ents {
			p := filepath.Join(dir, e.Name())
			if strings.HasPrefix(e.Name(), ".") || skip[p] || used[p] {
				continue
			}
			if holders[p] {
				if depth < 6 {
					walk(p, depth+1)
				}
				continue
			}
			o := orphan{Path: p, Dir: e.IsDir()}
			o.Rel, _ = filepath.Rel(root, p)
			if fi, err := e.Info(); err == nil {
				o.Modified = fi.ModTime().Unix()
				if !e.IsDir() {
					o.Size, o.Files = fi.Size(), 1
				}
			}
			if e.IsDir() {
				filepath.WalkDir(p, func(q string, d fs.DirEntry, err error) error {
					if err == nil && !d.IsDir() {
						if fi, err := d.Info(); err == nil {
							o.Size += fi.Size()
							o.Files++
							o.Modified = max(o.Modified, fi.ModTime().Unix())
						}
					}
					return nil
				})
			}
			if id := s.libOfPath(p); id != "" {
				if l, ok := s.libs.Get(id); ok {
					o.Library = l.Name
				}
			}
			if u, ok := httpJobs[p]; ok {
				o.Download = u
			}
			out = append(out, o)
		}
	}
	walk(root, 1)
	sort.Slice(out, func(a, b int) bool { return out[a].Size > out[b].Size })
	return out, len(items), nil
}

// GET /api/admin/torrents/orphans[?dir=]
func (s *Server) handleOrphans(w http.ResponseWriter, r *http.Request) {
	rt, err := s.dl.rt()
	if err != nil {
		httpErr(w, 502, err.Error())
		return
	}
	root, err := s.orphanRoot(rt, r.URL.Query().Get("dir"))
	if err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	start := time.Now()
	list, n, err := s.scanOrphans(rt, root)
	if err != nil {
		httpErr(w, 502, err.Error())
		return
	}
	var total int64
	for _, o := range list {
		total += o.Size
	}
	writeJSON(w, 200, map[string]any{"root": root, "orphans": list, "total": total, "torrents": n, "ms": time.Since(start).Milliseconds()})
}

// POST /api/admin/torrents/orphans/delete {"dir": root, "paths": [...]} —
// each path is checked again against a fresh scan before it's deleted.
func (s *Server) handleOrphansDelete(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Dir   string
		Paths []string
	}
	if !decodeJSON(w, r, &b) {
		return
	}
	rt, err := s.dl.rt()
	if err != nil {
		httpErr(w, 502, err.Error())
		return
	}
	root, err := s.orphanRoot(rt, b.Dir)
	if err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	list, _, err := s.scanOrphans(rt, root)
	if err != nil {
		httpErr(w, 502, err.Error())
		return
	}
	still := map[string]orphan{}
	for _, o := range list {
		still[o.Path] = o
	}
	var deleted []string
	var freed int64
	var errs []string
	libs := map[string]bool{}
	for _, p := range b.Paths {
		o, ok := still[filepath.Clean(p)]
		if !ok {
			errs = append(errs, p+": not in the unused list (skipped)")
			continue
		}
		if _, err := s.deletablePath(o.Path, filepath.Base(o.Path)); err != nil {
			errs = append(errs, err.Error())
			continue
		}
		if err := os.RemoveAll(o.Path); err != nil {
			errs = append(errs, err.Error())
			continue
		}
		deleted = append(deleted, o.Path)
		freed += o.Size
		if id := s.libOfPath(o.Path); id != "" {
			libs[id] = true
		}
	}
	for id := range libs {
		s.index.Queue(id, false)
	}
	writeJSON(w, 200, map[string]any{"deleted": deleted, "freed": freed, "errors": errs})
}
