package main

import (
	"encoding/json"
	"io/fs"
	"net/http"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

func (s *Server) adminRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/admin/overview", s.adminOnly(s.handleAdminOverview))
	mux.HandleFunc("GET /api/admin/users", s.adminOnly(s.handleAdminUsers))
	mux.HandleFunc("POST /api/admin/users", s.adminOnly(s.handleAdminAddUser))
	mux.HandleFunc("POST /api/admin/users/{name}/password", s.adminOnly(s.handleAdminPassword))
	mux.HandleFunc("POST /api/admin/users/{name}/role", s.adminOnly(s.handleAdminRole))
	mux.HandleFunc("POST /api/admin/users/{name}/revoke", s.adminOnly(s.handleAdminRevoke))
	mux.HandleFunc("DELETE /api/admin/users/{name}", s.adminOnly(s.handleAdminDelete))
	mux.HandleFunc("GET /api/admin/users/{name}/progress", s.adminOnly(s.handleAdminUserProgress))
	mux.HandleFunc("DELETE /api/admin/users/{name}/progress", s.adminOnly(s.handleAdminClearProgress))
	mux.HandleFunc("GET /api/admin/update", s.adminOnly(s.handleUpdateStatus))
	mux.HandleFunc("POST /api/admin/update/check", s.adminOnly(s.handleUpdateCheck))
	mux.HandleFunc("POST /api/admin/update/install", s.adminOnly(s.handleUpdateInstall))
	mux.HandleFunc("POST /api/admin/settings", s.adminOnly(s.handleSettings))
	mux.HandleFunc("GET /api/admin/settings", s.adminOnly(s.handleSettingsGet))
	mux.HandleFunc("POST /api/admin/metadata/test", s.adminOnly(s.handleMetadataTest))
}

func (s *Server) handleAdminPage(w http.ResponseWriter, r *http.Request) {
	b, _ := webFS.ReadFile("web/admin.html")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Write(b)
}

func decodeJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192)).Decode(v); err != nil {
		httpErr(w, 400, "bad request")
		return false
	}
	return true
}

// ---------- self service ----------

func (s *Server) handleOwnPassword(w http.ResponseWriter, r *http.Request) {
	var b struct{ Old, New string }
	if !decodeJSON(w, r, &b) {
		return
	}
	if _, ok := s.users.Authenticate(userOf(r), b.Old); !ok {
		time.Sleep(time.Second)
		httpErr(w, 403, "current password is wrong")
		return
	}
	if len(b.New) < 6 {
		httpErr(w, 400, "password must be at least 6 characters")
		return
	}
	if _, err := s.users.SetPassword(userOf(r), b.New); err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	// other sessions are logged out; keep this one by issuing a fresh token
	gen, _ := s.users.Authenticate(userOf(r), b.New)
	tok, exp := s.makeToken(userOf(r), gen)
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: tok, Path: "/", Expires: exp,
		HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: secureReq(r)})
	writeJSON(w, 200, map[string]any{"ok": true, "token": tok})
}

// ---------- users ----------

type adminUser struct {
	UserView
	Watched    int    `json:"watched"`
	InProgress int    `json:"inProgress"`
	Streams    int    `json:"streams"`
	Usage      *usage `json:"usage,omitempty"` // personal libraries
}

func (s *Server) handleAdminUsers(w http.ResponseWriter, r *http.Request) {
	conns := map[string]int{}
	for _, c := range s.conns.List() {
		conns[c.User]++
	}
	out := []adminUser{}
	for _, u := range s.users.List() {
		total, inProg := s.progress.Count(u.Name)
		au := adminUser{UserView: u, Watched: total, InProgress: inProg, Streams: conns[u.Name]}
		if len(s.libs.Owned(u.Name)) > 0 || u.MaxItems > 0 || u.MaxBytes > 0 {
			us := s.usageOf(u.Name, false)
			au.Usage = &us
		}
		out = append(out, au)
	}
	writeJSON(w, 200, map[string]any{"users": out, "me": userOf(r)})
}

func (s *Server) handleAdminAddUser(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Name, Password string
		Admin          bool
	}
	if !decodeJSON(w, r, &b) {
		return
	}
	pw, err := s.users.Add(strings.TrimSpace(b.Name), b.Password, b.Admin)
	if err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	resp := map[string]any{"name": b.Name}
	if b.Password == "" {
		resp["password"] = pw // generated: show once
	}
	writeJSON(w, 200, resp)
}

func (s *Server) handleAdminPassword(w http.ResponseWriter, r *http.Request) {
	var b struct{ Password string }
	if !decodeJSON(w, r, &b) {
		return
	}
	pw, err := s.users.SetPassword(r.PathValue("name"), b.Password)
	if err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	resp := map[string]any{"ok": true}
	if b.Password == "" {
		resp["password"] = pw
	}
	writeJSON(w, 200, resp)
}

func (s *Server) handleAdminRole(w http.ResponseWriter, r *http.Request) {
	var b struct{ Admin bool }
	if !decodeJSON(w, r, &b) {
		return
	}
	if err := s.users.SetAdmin(r.PathValue("name"), b.Admin); err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}

func (s *Server) handleAdminRevoke(w http.ResponseWriter, r *http.Request) {
	if err := s.users.Revoke(r.PathValue("name")); err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}

func (s *Server) handleAdminDelete(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if name == userOf(r) {
		httpErr(w, 400, "you cannot delete yourself")
		return
	}
	if err := s.users.Delete(name); err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	s.progress.Clear(name)
	writeJSON(w, 200, map[string]bool{"ok": true})
}

func (s *Server) handleAdminUserProgress(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, map[string]any{"items": s.progress.List(r.PathValue("name"))})
}

func (s *Server) handleAdminClearProgress(w http.ResponseWriter, r *http.Request) {
	s.progress.Clear(r.PathValue("name"))
	writeJSON(w, 200, map[string]bool{"ok": true})
}

// ---------- overview ----------

type libStats struct {
	Files int   `json:"files"`
	Bytes int64 `json:"bytes"`
	Cache int64 `json:"cacheBytes"`
	at    time.Time
}

var (
	libMu     sync.Mutex
	libCache  libStats
	ffVerOnce sync.Once
	ffVer     string
)

func dirSize(root string, match func(string) bool) (n int, total int64) {
	filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			if strings.HasPrefix(d.Name(), ".") && p != root {
				return filepath.SkipDir
			}
			return nil
		}
		if match != nil && !match(d.Name()) {
			return nil
		}
		if info, err := d.Info(); err == nil && info.Mode().IsRegular() {
			n++
			total += info.Size()
		}
		return nil
	})
	return
}

func (s *Server) library() libStats {
	libMu.Lock()
	defer libMu.Unlock()
	if time.Since(libCache.at) < time.Minute {
		return libCache
	}
	files, bytes := 0, int64(0)
	for _, l := range s.libs.List() {
		for _, it := range s.index.Items(l.ID) {
			files++
			bytes += it.Size
		}
	}
	_, cache := dirSize(s.cfg.CacheDir, func(n string) bool { return strings.HasSuffix(n, ".vtt") })
	libCache = libStats{Files: files, Bytes: bytes, Cache: cache, at: time.Now()}
	return libCache
}

func (s *Server) ffmpegVersion() string {
	ffVerOnce.Do(func() {
		out, err := exec.Command(s.cfg.FFmpeg, "-hide_banner", "-version").Output()
		if err != nil {
			ffVer = "not found: " + err.Error()
			return
		}
		ffVer, _, _ = strings.Cut(string(out), "\n")
		ffVer = strings.TrimPrefix(ffVer, "ffmpeg version ")
		if i := strings.Index(ffVer, " Copyright"); i > 0 {
			ffVer = ffVer[:i]
		}
	})
	return ffVer
}

func (s *Server) handleAdminOverview(w http.ResponseWriter, r *http.Request) {
	lib := s.library()
	diskPath := s.cfg.Root
	if ls := s.libs.List(); len(ls) > 0 {
		diskPath = ls[0].Path
	}
	total, free, ok := diskUsage(diskPath)
	disk := map[string]any{}
	if ok {
		disk = map[string]any{"total": total, "free": free}
	}
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	writeJSON(w, 200, map[string]any{
		"version":    version,
		"started":    s.started.Unix(),
		"libraries":  len(s.libs.List()),
		"scan":       s.index.Status(),
		"ffmpeg":     s.ffmpegVersion(),
		"streams":    s.streamUsage(),
		"library":    lib,
		"disk":       disk,
		"memory":     ms.Sys,
		"users":      s.users.Count(),
		"conns":      s.conns.List(),
		"watching":   s.progress.Recent(90 * time.Second),
		"recent":     s.progress.Recent(7 * 24 * time.Hour),
	})
}

func keys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
