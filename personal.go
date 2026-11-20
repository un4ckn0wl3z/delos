package main

// Personal libraries (created by downloaders, private or shared), deleting
// your own files, and per-user limits on personal storage.

import (
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const maxPersonalLibs = 20

func (s *Server) userLibRoot() string {
	if v := strings.TrimSpace(s.settings.Get().UserLibRoot); v != "" {
		return v
	}
	if v := strings.TrimSpace(os.Getenv("STREAMMKV_USER_LIBS")); v != "" {
		return v
	}
	home, _ := os.UserHomeDir()
	if home == "" {
		home = s.cfg.DataDir
	}
	return filepath.Join(home, "streammkv-libraries")
}

func (ls *LibraryStore) SetOwner(id, owner string, shared bool) (Library, error) {
	ls.mu.Lock()
	defer ls.mu.Unlock()
	for _, l := range ls.libs {
		if l.ID == id {
			l.Owner, l.Shared = owner, shared
			return *l, ls.save()
		}
	}
	return Library{}, errors.New("no such library")
}

func (ls *LibraryStore) Owned(user string) []Library {
	var out []Library
	for _, l := range ls.List() {
		if l.Owner == user {
			out = append(out, l)
		}
	}
	return out
}

// ---------------------------------------------------------------- usage

type usage struct {
	Items int   `json:"items"`
	Bytes int64 `json:"bytes"`
}

var usageCache = struct {
	sync.Mutex
	m map[string]struct {
		u  usage
		at time.Time
	}
}{m: map[string]struct {
	u  usage
	at time.Time
}{}}

// Usage of a user's personal libraries: indexed items + bytes on disk.
func (s *Server) usageOf(user string, fresh bool) usage {
	usageCache.Lock()
	c, ok := usageCache.m[user]
	usageCache.Unlock()
	if ok && !fresh && time.Since(c.at) < 30*time.Second {
		return c.u
	}
	var u usage
	for _, l := range s.libs.Owned(user) {
		u.Items += s.index.Count(l.ID)
		_, b := dirSize(l.Path, func(string) bool { return true })
		u.Bytes += b
	}
	usageCache.Lock()
	usageCache.m[user] = struct {
		u  usage
		at time.Time
	}{u, time.Now()}
	usageCache.Unlock()
	return u
}

// checkQuota returns an error when a new download into lib would break the
// user's limits. extra = bytes about to be added (0 = unknown).
func (s *Server) checkQuota(user string, lib Library, extra int64) error {
	maxItems, maxBytes := s.users.Limits(user)
	if maxItems == 0 && maxBytes == 0 {
		return nil
	}
	if lib.Owner != user {
		return errors.New("your account has a storage limit — download into one of your own libraries")
	}
	u := s.usageOf(user, true)
	if maxItems > 0 && u.Items >= maxItems {
		return fmt.Errorf("limit reached: %d of %d items — delete something first", u.Items, maxItems)
	}
	if maxBytes > 0 && u.Bytes+extra > maxBytes {
		return fmt.Errorf("not enough space in your quota: %s used of %s — delete something first", fmtBytes(u.Bytes), fmtBytes(maxBytes))
	}
	return nil
}

// ---------------------------------------------------------------- API

func (s *Server) personalRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/my/libraries", s.downloader(s.handleMyLibraries))
	mux.HandleFunc("POST /api/my/libraries", s.downloader(s.handleMyLibraryAdd))
	mux.HandleFunc("PUT /api/my/libraries/{id}", s.downloader(s.handleMyLibraryUpdate))
	mux.HandleFunc("DELETE /api/my/libraries/{id}", s.downloader(s.handleMyLibraryDelete))
	mux.HandleFunc("POST /api/my/libraries/{id}/scan", s.downloader(s.handleMyLibraryScan))
	mux.HandleFunc("POST /api/my/libraries/{id}/give", s.downloader(s.handleMyLibraryGive))
	mux.HandleFunc("POST /api/files/delete", s.auth(s.handleDeleteFiles))
	mux.HandleFunc("POST /api/admin/users/{name}/limits", s.adminOnly(s.handleAdminLimits))
}

func (s *Server) myLibrariesJSON(user string) map[string]any {
	libs := []libInfo{}
	for _, l := range s.libs.Owned(user) {
		li := s.libInfo(l, false)
		for _, it := range s.index.Items(l.ID) {
			li.Size += it.Size
		}
		libs = append(libs, li)
	}
	sort.Slice(libs, func(a, b int) bool { return strings.ToLower(libs[a].Name) < strings.ToLower(libs[b].Name) })
	maxItems, maxBytes := s.users.Limits(user)
	return map[string]any{"libraries": libs, "usage": s.usageOf(user, true), "maxItems": maxItems, "maxBytes": maxBytes}
}

func (s *Server) handleMyLibraries(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, s.myLibrariesJSON(userOf(r)))
}

func (s *Server) handleMyLibraryAdd(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Name, Type string
		Shared     bool
	}
	if !decodeJSON(w, r, &b) {
		return
	}
	user := userOf(r)
	if len(s.libs.Owned(user)) >= maxPersonalLibs {
		httpErr(w, 400, fmt.Sprintf("you can have at most %d libraries", maxPersonalLibs))
		return
	}
	name := strings.TrimSpace(b.Name)
	folder := sanitizeFileName(name)
	if folder == "" {
		httpErr(w, 400, "name is required")
		return
	}
	dir := filepath.Join(s.userLibRoot(), sanitizeFileName(user), folder)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		httpErr(w, 500, "cannot create the folder: "+err.Error())
		return
	}
	l, err := s.libs.Add(name, b.Type, dir, nil)
	if err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	if l, err = s.libs.SetOwner(l.ID, user, b.Shared); err != nil {
		httpErr(w, 500, err.Error())
		return
	}
	s.index.mu.Lock()
	s.index.libs[l.ID] = newLibIndex(l)
	s.index.mu.Unlock()
	s.index.Queue(l.ID, false)
	writeJSON(w, 200, s.libInfo(l, false))
}

// ownLib: the caller's personal library (admins may manage anyone's).
func (s *Server) ownLib(w http.ResponseWriter, r *http.Request) (Library, bool) {
	l, ok := s.libs.Get(r.PathValue("id"))
	if !ok || l.Owner == "" || (l.Owner != userOf(r) && !isAdmin(r)) {
		httpErr(w, 404, "no such library")
		return Library{}, false
	}
	return l, true
}

func (s *Server) handleMyLibraryUpdate(w http.ResponseWriter, r *http.Request) {
	l, ok := s.ownLib(w, r)
	if !ok {
		return
	}
	var b struct {
		Name, Type string
		Shared     *bool
	}
	if !decodeJSON(w, r, &b) {
		return
	}
	name, typ := firstNonEmpty(strings.TrimSpace(b.Name), l.Name), firstNonEmpty(b.Type, l.Type)
	nl, err := s.libs.Update(l.ID, name, typ, l.Path, nil)
	if err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	shared := l.Shared
	if b.Shared != nil {
		shared = *b.Shared
	}
	if nl, err = s.libs.SetOwner(l.ID, l.Owner, shared); err != nil {
		httpErr(w, 500, err.Error())
		return
	}
	if typ != l.Type {
		s.index.Queue(l.ID, false)
	}
	writeJSON(w, 200, s.libInfo(nl, false))
}

func (s *Server) handleMyLibraryDelete(w http.ResponseWriter, r *http.Request) {
	l, ok := s.ownLib(w, r)
	if !ok {
		return
	}
	if err := s.libs.Delete(l.ID); err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	s.index.Forget(l.ID)
	if r.URL.Query().Get("files") == "1" {
		// only ever inside the user-library folder
		if rel, err := filepath.Rel(s.userLibRoot(), l.Path); err == nil && rel != "." && !strings.HasPrefix(rel, "..") {
			s.eraseTorrentsUnder(l.Path)
			os.RemoveAll(l.Path)
		}
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}

// POST /api/admin/libraries/{id}/owner {"owner": "" | "<user>", "shared": bool}
// Admins move any library between the server ("" = everyone's) and a user, or between users.
func (s *Server) handleAdminLibraryOwner(w http.ResponseWriter, r *http.Request) {
	l, ok := s.libs.Get(r.PathValue("id"))
	if !ok {
		httpErr(w, 404, "no such library")
		return
	}
	var b struct {
		Owner  string `json:"owner"`
		Shared bool   `json:"shared"`
	}
	if !decodeJSON(w, r, &b) {
		return
	}
	b.Owner = strings.TrimSpace(b.Owner)
	if b.Owner != "" && !s.users.Exists(b.Owner) {
		httpErr(w, 400, "no such user")
		return
	}
	shared := b.Shared && b.Owner != ""
	nl, err := s.libs.SetOwner(l.ID, b.Owner, shared)
	if err != nil {
		httpErr(w, 500, err.Error())
		return
	}
	for _, u := range []string{l.Owner, b.Owner} {
		if u != "" {
			s.usageOf(u, true)
		}
	}
	log.Printf("library %q: owner %q → %q (by %s)", l.Name, l.Owner, b.Owner, userOf(r))
	writeJSON(w, 200, s.libInfo(nl, false))
}

// POST /api/my/libraries/{id}/give {"mode": "own" | "into", "into": "<library id>", "folder": "…"}
// Give a personal library to everyone: "own" = it becomes a library of the server (no owner);
// "into" = its folder moves into an existing server library (as a sub-folder) and it's gone.
func (s *Server) handleMyLibraryGive(w http.ResponseWriter, r *http.Request) {
	l, ok := s.ownLib(w, r)
	if !ok {
		return
	}
	var b struct{ Mode, Into, Folder string }
	if !decodeJSON(w, r, &b) {
		return
	}
	switch b.Mode {
	case "own":
		nl, err := s.libs.SetOwner(l.ID, "", false)
		if err != nil {
			httpErr(w, 500, err.Error())
			return
		}
		s.usageOf(l.Owner, true)
		log.Printf("library %q of %s given to everyone by %s", l.Name, l.Owner, userOf(r))
		writeJSON(w, 200, s.libInfo(nl, false))
	case "into":
		t, ok := s.libs.Get(b.Into)
		if !ok || t.Owner != "" || t.ID == l.ID {
			httpErr(w, 400, "pick a library everyone has")
			return
		}
		if (l.Type == LibMusic) != (t.Type == LibMusic) {
			httpErr(w, 400, "music goes into a music library, videos into a video library")
			return
		}
		s.dl.mu.Lock()
		busy := false
		for _, j := range s.dl.jobs {
			if j.Lib == l.ID && (j.State == "queued" || j.State == "downloading") {
				busy = true
			}
		}
		s.dl.mu.Unlock()
		if busy {
			httpErr(w, 409, "something is still downloading into this library — wait until it's done")
			return
		}
		folder := sanitizeFileName(firstNonEmpty(strings.TrimSpace(b.Folder), l.Name))
		if folder == "" || folder == "." || folder == ".." {
			folder = sanitizeFileName(l.Name)
		}
		dest := filepath.Join(t.Path, folder)
		for i := 2; ; i++ {
			if _, err := os.Lstat(dest); errors.Is(err, os.ErrNotExist) {
				break
			}
			dest = filepath.Join(t.Path, folder+" ("+strconv.Itoa(i)+")")
		}
		// torrents seeding from the old folder stop (the files move with the folder)
		s.eraseTorrentsUnder(l.Path)
		if err := os.Rename(l.Path, dest); err != nil {
			msg := err.Error()
			if strings.Contains(msg, "cross-device") || strings.Contains(msg, "different") {
				msg = "the two libraries are on different disks — move the folder by hand"
			}
			httpErr(w, 500, msg)
			return
		}
		if err := s.libs.Delete(l.ID); err != nil {
			httpErr(w, 500, err.Error())
			return
		}
		s.index.Forget(l.ID)
		// watch positions and playlists follow the files
		newPrefix := t.ID + "/" + filepath.ToSlash(filepath.Base(dest)) + "/"
		s.progress.MovePrefix(l.ID+"/", newPrefix)
		s.playlists.MovePrefix(l.ID+"/", newPrefix)
		s.index.Queue(t.ID, false)
		s.usageOf(l.Owner, true)
		log.Printf("library %q of %s moved into %q (%s) by %s", l.Name, l.Owner, t.Name, dest, userOf(r))
		writeJSON(w, 200, map[string]any{"ok": true, "into": t.ID, "folder": filepath.Base(dest)})
	default:
		httpErr(w, 400, "mode is own or into")
	}
}

func (s *Server) handleMyLibraryScan(w http.ResponseWriter, r *http.Request) {
	l, ok := s.ownLib(w, r)
	if !ok {
		return
	}
	s.index.Queue(l.ID, r.URL.Query().Get("refresh") == "1")
	writeJSON(w, 200, map[string]bool{"ok": true})
}

// eraseTorrentsUnder removes rtorrent downloads stored under dir (so rtorrent
// doesn't keep seeding files that are being deleted) and drops their jobs.
func (s *Server) eraseTorrentsUnder(dir string) {
	rt, err := s.dl.rt()
	if err != nil {
		return
	}
	items, err := rt.List()
	if err != nil {
		return
	}
	for _, it := range items {
		if it.BasePath == dir || strings.HasPrefix(it.BasePath, dir+string(filepath.Separator)) || strings.HasPrefix(dir, it.BasePath+string(filepath.Separator)) {
			rt.Erase(it.Hash)
			if strings.HasPrefix(it.Tag, "smkv:") {
				s.dl.mu.Lock()
				delete(s.dl.jobs, strings.TrimPrefix(it.Tag, "smkv:"))
				s.dl.saveLocked()
				s.dl.mu.Unlock()
			}
		}
	}
}

// POST /api/files/delete {"paths": ["lib/rel", …]} — delete media files.
// Owners may delete in their own libraries; admins anywhere.
func (s *Server) handleDeleteFiles(w http.ResponseWriter, r *http.Request) {
	var b struct{ Paths []string }
	if !decodeJSON(w, r, &b) {
		return
	}
	if len(b.Paths) == 0 || len(b.Paths) > 200 {
		httpErr(w, 400, "nothing to delete")
		return
	}
	type target struct {
		abs string
		lib Library
	}
	var ts []target
	for _, p := range b.Paths {
		abs, _, lib, err := s.resolveLib(p)
		if err != nil || !s.canAccess(r, lib.ID) {
			httpErr(w, 404, "not found: "+p)
			return
		}
		if !isAdmin(r) && lib.Owner != userOf(r) {
			httpErr(w, 403, "you can only delete files in your own libraries")
			return
		}
		ts = append(ts, target{abs, lib})
	}
	libs := map[string]bool{}
	deleted := 0
	for _, t := range ts {
		s.eraseTorrentsUnder(t.abs)
		if err := os.Remove(t.abs); err != nil && !errors.Is(err, os.ErrNotExist) {
			httpErr(w, 500, err.Error())
			return
		}
		deleted++
		libs[t.lib.ID] = true
		// a movie folder with no media left (nfo, posters, subs…) goes too
		dir := filepath.Dir(t.abs)
		for dir != t.lib.Path && strings.HasPrefix(dir, t.lib.Path+string(filepath.Separator)) {
			if hasMedia(dir, func(n string) bool { return s.libs.Accepts(t.lib.Type, n) }) {
				break
			}
			s.eraseTorrentsUnder(dir)
			os.RemoveAll(dir)
			dir = filepath.Dir(dir)
		}
	}
	for id := range libs {
		s.index.Queue(id, false)
		if l, ok := s.libs.Get(id); ok && l.Owner != "" {
			s.usageOf(l.Owner, true)
		}
	}
	writeJSON(w, 200, map[string]int{"deleted": deleted})
}

func hasMedia(dir string, accepts func(string) bool) bool {
	found := false
	filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() && accepts(d.Name()) {
			found = true
			return filepath.SkipAll
		}
		return nil
	})
	return found
}

// POST /api/admin/users/{name}/limits {"maxItems": n, "maxBytes": n} (0 = unlimited)
func (s *Server) handleAdminLimits(w http.ResponseWriter, r *http.Request) {
	var b struct {
		MaxItems int   `json:"maxItems"`
		MaxBytes int64 `json:"maxBytes"`
	}
	if !decodeJSON(w, r, &b) {
		return
	}
	if err := s.users.SetLimits(r.PathValue("name"), b.MaxItems, b.MaxBytes); err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}
