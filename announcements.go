package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
)

// Announcements: admins post a message to everyone (or to chosen users).
// It shows up right away in the web app and the apps (pushed over
// /api/events), stays until it expires or is deleted, and each user can mark
// it read. Admins see how many have read it.

type Announcement struct {
	ID      string   `json:"id"`
	Title   string   `json:"title"`
	Body    string   `json:"body"`
	Level   string   `json:"level"`           // info | warning | important (important = shown as a dialog)
	Users   []string `json:"users,omitempty"` // empty = everyone
	Author  string   `json:"author"`
	Created int64    `json:"created"`
	Updated int64    `json:"updated,omitempty"`
	Expires int64    `json:"expires,omitempty"` // unix; 0 = never
	Pinned  bool     `json:"pinned,omitempty"`  // stays in the list after it's read
}

type annStore struct {
	Items []*Announcement             `json:"items"`
	Read  map[string]map[string]int64 `json:"read"` // user → announcement id → when read
}

type Announcements struct {
	s    *Server
	path string
	mu   sync.Mutex
	st   annStore
}

func NewAnnouncements(s *Server) *Announcements {
	a := &Announcements{s: s, path: filepath.Join(s.cfg.DataDir, "announcements.json")}
	if b, err := os.ReadFile(a.path); err == nil {
		json.Unmarshal(b, &a.st)
	}
	if a.st.Read == nil {
		a.st.Read = map[string]map[string]int64{}
	}
	return a
}

func (a *Announcements) saveLocked() {
	b, _ := json.MarshalIndent(a.st, "", " ")
	tmp := a.path + ".tmp"
	if os.WriteFile(tmp, b, 0o600) == nil {
		os.Rename(tmp, a.path)
	}
}

func (an *Announcement) active(now int64) bool { return an.Expires == 0 || an.Expires > now }
func (an *Announcement) forUser(u string) bool {
	return len(an.Users) == 0 || slices.Contains(an.Users, u)
}

type annView struct {
	*Announcement
	Read bool `json:"read"`
}

// For: what a user sees (newest first; unread ones and pinned ones).
func (a *Announcements) For(user string, all bool) []annView {
	a.mu.Lock()
	defer a.mu.Unlock()
	now := time.Now().Unix()
	out := []annView{}
	for i := len(a.st.Items) - 1; i >= 0; i-- { // newest first
		an := a.st.Items[i]
		if !an.active(now) || !an.forUser(user) {
			continue
		}
		_, read := a.st.Read[user][an.ID]
		if read && !an.Pinned && !all {
			continue
		}
		out = append(out, annView{an, read})
	}
	return out
}

func (a *Announcements) push(an *Announcement) {
	targets := an.Users
	if len(targets) == 0 {
		for _, u := range a.s.users.List() {
			targets = append(targets, u.Name)
		}
	}
	for _, u := range targets {
		a.s.chat.send(u, "announcement", map[string]any{"id": an.ID})
	}
}

func cleanAnn(an *Announcement) string {
	an.Title = strings.TrimSpace(an.Title)
	an.Body = strings.TrimSpace(strings.ReplaceAll(an.Body, "\r\n", "\n"))
	if an.Title == "" && an.Body == "" {
		return "write a title or a message"
	}
	if len([]rune(an.Title)) > 200 || len([]rune(an.Body)) > 5000 {
		return "too long (title 200, message 5000 characters)"
	}
	switch an.Level {
	case "", "info":
		an.Level = "info"
	case "warning", "important":
	default:
		return "level must be info, warning or important"
	}
	us := an.Users[:0]
	for _, u := range an.Users {
		if u = strings.TrimSpace(u); u != "" && !slices.Contains(us, u) {
			us = append(us, u)
		}
	}
	an.Users = us
	return ""
}

// ---------------------------------------------------------------- API

func (s *Server) announcementRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/announcements", s.auth(s.handleAnnouncements))
	mux.HandleFunc("POST /api/announcements/{id}/read", s.auth(s.handleAnnouncementRead))
	mux.HandleFunc("POST /api/announcements/read-all", s.auth(s.handleAnnouncementReadAll))
	mux.HandleFunc("GET /api/admin/announcements", s.adminOnly(s.handleAdminAnnouncements))
	mux.HandleFunc("POST /api/admin/announcements", s.adminOnly(s.handleAdminAnnouncementSave))
	mux.HandleFunc("PUT /api/admin/announcements/{id}", s.adminOnly(s.handleAdminAnnouncementSave))
	mux.HandleFunc("DELETE /api/admin/announcements/{id}", s.adminOnly(s.handleAdminAnnouncementDelete))
}

// GET /api/announcements[?all=1] → unread + pinned (all=1: also read ones still active)
func (s *Server) handleAnnouncements(w http.ResponseWriter, r *http.Request) {
	list := s.ann.For(userOf(r), r.URL.Query().Get("all") == "1")
	unread := 0
	for _, v := range list {
		if !v.Read {
			unread++
		}
	}
	writeJSON(w, 200, map[string]any{"items": list, "unread": unread})
}

func (s *Server) handleAnnouncementRead(w http.ResponseWriter, r *http.Request) {
	a, u, id := s.ann, userOf(r), r.PathValue("id")
	a.mu.Lock()
	if a.st.Read[u] == nil {
		a.st.Read[u] = map[string]int64{}
	}
	a.st.Read[u][id] = time.Now().Unix()
	a.saveLocked()
	a.mu.Unlock()
	writeJSON(w, 200, map[string]bool{"ok": true})
}

func (s *Server) handleAnnouncementReadAll(w http.ResponseWriter, r *http.Request) {
	u := userOf(r)
	ids := []string{}
	for _, v := range s.ann.For(u, false) {
		ids = append(ids, v.ID)
	}
	a := s.ann
	a.mu.Lock()
	if a.st.Read[u] == nil {
		a.st.Read[u] = map[string]int64{}
	}
	now := time.Now().Unix()
	for _, id := range ids {
		a.st.Read[u][id] = now
	}
	a.saveLocked()
	a.mu.Unlock()
	writeJSON(w, 200, map[string]bool{"ok": true})
}

// GET /api/admin/announcements → all, with who has read each
func (s *Server) handleAdminAnnouncements(w http.ResponseWriter, r *http.Request) {
	a := s.ann
	a.mu.Lock()
	defer a.mu.Unlock()
	now := time.Now().Unix()
	type row struct {
		*Announcement
		Active   bool     `json:"active"`
		ReadBy   []string `json:"readBy"`
		Audience int      `json:"audience"`
	}
	allUsers := s.users.List()
	out := []row{}
	for i := len(a.st.Items) - 1; i >= 0; i-- {
		an := a.st.Items[i]
		rw := row{Announcement: an, Active: an.active(now), ReadBy: []string{}}
		for _, u := range allUsers {
			if an.forUser(u.Name) {
				rw.Audience++
				if _, ok := a.st.Read[u.Name][an.ID]; ok {
					rw.ReadBy = append(rw.ReadBy, u.Name)
				}
			}
		}
		out = append(out, rw)
	}
	writeJSON(w, 200, map[string]any{"items": out})
}

// POST /api/admin/announcements (new) · PUT /api/admin/announcements/{id} (edit)
// {"title","body","level","users":[],"expires":unix|0,"pinned":bool,"resend":bool}
func (s *Server) handleAdminAnnouncementSave(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Announcement
		Resend bool `json:"resend"` // edit: show it again to everyone (clears "read")
	}
	if !decodeJSON(w, r, &b) {
		return
	}
	in := b.Announcement
	if msg := cleanAnn(&in); msg != "" {
		httpErr(w, 400, msg)
		return
	}
	for _, u := range in.Users {
		if !s.users.Exists(u) {
			httpErr(w, 400, "no user named "+u)
			return
		}
	}
	now := time.Now().Unix()
	if in.Expires != 0 && in.Expires <= now {
		httpErr(w, 400, "the expiry time has already passed")
		return
	}
	a := s.ann
	a.mu.Lock()
	var an *Announcement
	if id := r.PathValue("id"); id != "" {
		for _, x := range a.st.Items {
			if x.ID == id {
				an = x
			}
		}
		if an == nil {
			a.mu.Unlock()
			httpErr(w, 404, "no such announcement")
			return
		}
		an.Title, an.Body, an.Level, an.Users, an.Expires, an.Pinned = in.Title, in.Body, in.Level, in.Users, in.Expires, in.Pinned
		an.Updated = now
		if b.Resend {
			for _, m := range a.st.Read {
				delete(m, an.ID)
			}
		}
	} else {
		raw := make([]byte, 6)
		rand.Read(raw)
		an = &in
		an.ID, an.Author, an.Created = hex.EncodeToString(raw), userOf(r), now
		a.st.Items = append(a.st.Items, an)
		if len(a.st.Items) > 300 { // keep the newest
			a.st.Items = a.st.Items[len(a.st.Items)-300:]
		}
	}
	a.saveLocked()
	cp := *an
	a.mu.Unlock()
	if r.PathValue("id") == "" || b.Resend {
		a.push(&cp)
	} else {
		a.push(&Announcement{ID: cp.ID, Users: cp.Users}) // refresh lists
	}
	writeJSON(w, 200, cp)
}

func (s *Server) handleAdminAnnouncementDelete(w http.ResponseWriter, r *http.Request) {
	a, id := s.ann, r.PathValue("id")
	a.mu.Lock()
	var gone *Announcement
	a.st.Items = slices.DeleteFunc(a.st.Items, func(x *Announcement) bool {
		if x.ID == id {
			gone = x
			return true
		}
		return false
	})
	for _, m := range a.st.Read {
		delete(m, id)
	}
	a.saveLocked()
	a.mu.Unlock()
	if gone == nil {
		httpErr(w, 404, "no such announcement")
		return
	}
	a.push(&Announcement{ID: id, Users: gone.Users}) // clients drop it
	writeJSON(w, 200, map[string]bool{"ok": true})
}
