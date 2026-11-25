package main

// Remote control: your phone drives Delos on your PC / TV (same account).
// Every app and web page says hello every ~30 s as a device; a remote lists your online
// devices, sends commands to one, and follows its playback state.
//
// Events on /api/events (to the user's own sessions only):
//   remote-cmd   {to, cmd, from, …args}   for the device with id "to"
//   remote-state {id, state}               a device's playback (for the remotes)
//   remote-devices {}                      the device list changed

import (
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
)

type RemoteDevice struct {
	ID       string         `json:"id"`
	Name     string         `json:"name"`
	Platform string         `json:"platform"`
	Kind     string         `json:"kind"` // app | web
	Seen     int64          `json:"seen"`
	State    map[string]any `json:"state,omitempty"`
}

type Remotes struct {
	mu sync.Mutex
	by map[string]map[string]*RemoteDevice // user → device id → device
}

const remoteAlive = 75 // seconds since the last hello

func (s *Server) remoteRoutes(mux *http.ServeMux) {
	s.remotes = &Remotes{by: map[string]map[string]*RemoteDevice{}}
	mux.HandleFunc("POST /api/remote/hello", s.auth(s.handleRemoteHello))
	mux.HandleFunc("POST /api/remote/bye", s.auth(s.handleRemoteBye))
	mux.HandleFunc("GET /api/remote/devices", s.auth(s.handleRemoteDevices))
	mux.HandleFunc("POST /api/remote/devices/{id}/cmd", s.auth(s.handleRemoteCmd))
}

// POST /api/remote/hello {id, name, platform, kind, state?}
func (s *Server) handleRemoteHello(w http.ResponseWriter, r *http.Request) {
	var b struct {
		ID, Name, Platform, Kind string
		State                    map[string]any
	}
	if !decodeJSON(w, r, &b) {
		return
	}
	b.ID = strings.TrimSpace(b.ID)
	if b.ID == "" || len(b.ID) > 64 {
		httpErr(w, 400, "id is required")
		return
	}
	me := userOf(r)
	now := time.Now().Unix()
	rm := s.remotes
	rm.mu.Lock()
	m := rm.by[me]
	if m == nil {
		m = map[string]*RemoteDevice{}
		rm.by[me] = m
	}
	d := m[b.ID]
	isNew := d == nil || now-d.Seen > remoteAlive
	if d == nil {
		d = &RemoteDevice{ID: b.ID}
		m[b.ID] = d
	}
	d.Name, d.Platform, d.Kind, d.Seen = clip(strings.TrimSpace(b.Name), 60), clip(b.Platform, 40), clip(b.Kind, 10), now
	if d.Name == "" {
		d.Name = "Device"
	}
	if b.State != nil {
		d.State = b.State
	}
	st := d.State
	rm.mu.Unlock()
	if b.State != nil {
		s.chat.send(me, "remote-state", map[string]any{"id": b.ID, "state": st})
	}
	if isNew {
		s.chat.send(me, "remote-devices", map[string]any{})
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}

// POST /api/remote/bye {id} — the app / page is closing.
func (s *Server) handleRemoteBye(w http.ResponseWriter, r *http.Request) {
	var b struct{ ID string }
	if !decodeJSON(w, r, &b) {
		return
	}
	me := userOf(r)
	s.remotes.mu.Lock()
	delete(s.remotes.by[me], b.ID)
	s.remotes.mu.Unlock()
	s.chat.send(me, "remote-devices", map[string]any{})
	writeJSON(w, 200, map[string]bool{"ok": true})
}

// GET /api/remote/devices?self=<my id> → my other devices that are online now.
func (s *Server) handleRemoteDevices(w http.ResponseWriter, r *http.Request) {
	me, self := userOf(r), r.URL.Query().Get("self")
	now := time.Now().Unix()
	out := []RemoteDevice{}
	s.remotes.mu.Lock()
	for id, d := range s.remotes.by[me] {
		if now-d.Seen > remoteAlive {
			delete(s.remotes.by[me], id)
			continue
		}
		if id != self {
			out = append(out, *d)
		}
	}
	s.remotes.mu.Unlock()
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	writeJSON(w, 200, map[string]any{"devices": out})
}

var remoteCmds = map[string]bool{"open": true, "toggle": true, "play": true, "pause": true, "seek": true, "seekBy": true,
	"stop": true, "next": true, "previous": true, "volume": true, "fullscreen": true, "subs": true, "audio": true,
	"subDelay": true, "nextEp": true, "home": true}

// POST /api/remote/devices/{id}/cmd {cmd, path?, pos?, by?, volume?, from?}
func (s *Server) handleRemoteCmd(w http.ResponseWriter, r *http.Request) {
	var b map[string]any
	if !decodeJSON(w, r, &b) {
		return
	}
	cmd, _ := b["cmd"].(string)
	if !remoteCmds[cmd] {
		httpErr(w, 400, "unknown command")
		return
	}
	me, id := userOf(r), r.PathValue("id")
	s.remotes.mu.Lock()
	d := s.remotes.by[me][id]
	alive := d != nil && time.Now().Unix()-d.Seen <= remoteAlive
	s.remotes.mu.Unlock()
	if !alive {
		httpErr(w, 404, "that device isn't online — open Delos on it")
		return
	}
	if p, _ := b["path"].(string); cmd == "open" {
		if p == "" || !s.canOpen(me, p) {
			httpErr(w, 403, "can't open that file")
			return
		}
	}
	b["to"] = id
	s.chat.send(me, "remote-cmd", b)
	writeJSON(w, 200, map[string]bool{"ok": true})
}
