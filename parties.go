package main

// Watch parties: one host plays a movie / episode / song, everyone in the party
// follows along. Party chat with emoji reactions, invites, join requests,
// password-protected and private parties, scheduled parties, kicking, chat on/off.
//
// Live updates go over the existing /api/events stream:
//   party        {party: <detail as the recipient sees it>}  members, settings, requests changed
//   party-state  {id, path, kind, name, playing, pos, at, now} the host's playback
//   party-msg    {id, msg}
//   party-react  {id, from, emoji}                            floating emoji
//   party-notice {kind, party, from, …}                       invite / request / accepted / declined /
//                                                             kicked / ended / reminder / ask / ask-declined
//   parties      {}                                           the list changed (refetch)

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

type PartyMsg struct {
	Seq  int    `json:"seq"`
	From string `json:"from,omitempty"`
	Text string `json:"text"`
	TS   int64  `json:"ts"`
	Sys  bool   `json:"sys,omitempty"` // "dl joined", "u started …"
}

type Party struct {
	ID         string           `json:"id"`
	Title      string           `json:"title"`
	Host       string           `json:"host"`
	Kind       string           `json:"kind"`       // video | music
	Path       string           `json:"path"`       // what's playing ("<lib>/<file>")
	Name       string           `json:"name"`       // its title
	Visibility string           `json:"visibility"` // public | private
	PassHash   string           `json:"passHash,omitempty"`
	ChatOn     bool             `json:"chatOn"`
	Members    map[string]int64 `json:"members"` // user → when they joined
	Invited    map[string]int64 `json:"invited"`
	Requests   map[string]int64 `json:"requests"`
	Kicked     map[string]int64 `json:"kicked"`
	Playing    bool             `json:"playing"`
	Pos        float64          `json:"pos"`
	At         int64            `json:"at"`        // unix ms when Pos was true
	Scheduled  int64            `json:"scheduled"` // unix s; 0 = right away
	Note       string           `json:"note,omitempty"`
	Live       bool             `json:"live"`
	Reminded   bool             `json:"reminded,omitempty"`
	Created    int64            `json:"created"`
	Seq        int              `json:"seq"`
	Msgs       []PartyMsg       `json:"msgs"`
	lastActive time.Time
}

type Parties struct {
	mu    sync.Mutex
	s     *Server
	file  string
	by    map[string]*Party
	asks  map[string]map[string]int64 // friend → asker → when ("can I join you?")
	dirty bool
}

const partyMsgKeep = 300

func NewParties(s *Server, dataDir string) *Parties {
	p := &Parties{s: s, file: filepath.Join(dataDir, "parties.json"), by: map[string]*Party{}, asks: map[string]map[string]int64{}}
	if b, err := os.ReadFile(p.file); err == nil {
		if err := json.Unmarshal(b, &p.by); err != nil {
			log.Printf("parties: %v", err)
		}
	}
	for _, x := range p.by {
		x.lastActive = time.Now()
		x.Playing = false // nobody is playing right after a restart
		for _, m := range []*map[string]int64{&x.Members, &x.Invited, &x.Requests, &x.Kicked} {
			if *m == nil {
				*m = map[string]int64{}
			}
		}
	}
	go p.loop()
	return p
}

func (p *Parties) saveLocked() {
	p.dirty = true
}

func (p *Parties) flush() {
	p.mu.Lock()
	if !p.dirty {
		p.mu.Unlock()
		return
	}
	b, err := json.Marshal(p.by)
	p.dirty = false
	p.mu.Unlock()
	if err == nil && os.WriteFile(p.file+".tmp", b, 0o600) == nil {
		os.Rename(p.file+".tmp", p.file)
	}
}

// loop: save, start scheduled parties (reminders), end abandoned ones.
func (p *Parties) loop() {
	for range time.Tick(20 * time.Second) {
		now := time.Now()
		var remind []*Party
		var ended []string
		p.mu.Lock()
		for id, x := range p.by {
			if !x.Live && x.Scheduled > 0 && now.Unix() >= x.Scheduled-60 {
				x.Live, x.lastActive = true, now
				p.sysLocked(x, "🎉 The party is starting")
				if !x.Reminded {
					x.Reminded = true
					remind = append(remind, x)
				}
				p.saveLocked()
			}
			// live and nobody of it online for 30 min, or a scheduled one 6 h past its time
			if x.Live {
				anyone := false
				for u := range x.Members {
					if p.s.chat.isOnline(u) {
						anyone = true
						break
					}
				}
				if anyone {
					x.lastActive = now
				} else if now.Sub(x.lastActive) > 30*time.Minute && (x.Scheduled == 0 || now.Unix() > x.Scheduled+6*3600) {
					ended = append(ended, id)
				}
			}
		}
		for _, id := range ended {
			delete(p.by, id)
			p.saveLocked()
		}
		p.mu.Unlock()
		for _, x := range remind {
			p.mu.Lock()
			to := p.audienceLocked(x)
			sum := p.summaryLocked(x, "")
			p.mu.Unlock()
			for _, u := range to {
				p.s.chat.send(u, "party-notice", map[string]any{"kind": "reminder", "party": sum})
			}
			p.pushParty(x.ID)
		}
		if len(ended) > 0 || len(remind) > 0 {
			p.broadcastList()
		}
		p.flush()
	}
}

func passHash(id, pw string) string {
	h := sha256.Sum256([]byte("delos-party:" + id + ":" + pw))
	return hex.EncodeToString(h[:])
}

func (p *Parties) sysLocked(x *Party, text string) PartyMsg {
	return p.addMsgLocked(x, "", text, true)
}

func (p *Parties) addMsgLocked(x *Party, from, text string, sys bool) PartyMsg {
	x.Seq++
	m := PartyMsg{Seq: x.Seq, From: from, Text: text, TS: time.Now().UnixMilli(), Sys: sys}
	x.Msgs = append(x.Msgs, m)
	if len(x.Msgs) > partyMsgKeep {
		x.Msgs = x.Msgs[len(x.Msgs)-partyMsgKeep:]
	}
	p.saveLocked()
	return m
}

// audienceLocked: members + invited (who should hear about the party).
func (p *Parties) audienceLocked(x *Party) []string {
	set := map[string]bool{}
	for u := range x.Members {
		set[u] = true
	}
	for u := range x.Invited {
		set[u] = true
	}
	out := make([]string, 0, len(set))
	for u := range set {
		out = append(out, u)
	}
	return out
}

type partyPerson struct {
	Name   string `json:"name"`
	Online bool   `json:"online"`
	Since  int64  `json:"since,omitempty"`
}

func (p *Parties) people(m map[string]int64) []partyPerson {
	out := make([]partyPerson, 0, len(m))
	for u, t := range m {
		out = append(out, partyPerson{u, p.s.chat.isOnline(u), t})
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i].Since < out[j].Since || (out[i].Since == out[j].Since && out[i].Name < out[j].Name)
	})
	return out
}

// summaryLocked: what a party list shows. viewer "" = for anyone it may be shown to.
func (p *Parties) summaryLocked(x *Party, viewer string) map[string]any {
	path := x.Path
	if viewer != "" && path != "" && !p.s.userCanAccess(viewer, p.s.users.IsAdmin(viewer), strings.SplitN(path, "/", 2)[0]) {
		path = ""
	}
	v := map[string]any{
		"id": x.ID, "title": x.Title, "host": x.Host, "kind": x.Kind, "path": path, "name": x.Name,
		"visibility": x.Visibility, "locked": x.PassHash != "", "members": p.people(x.Members),
		"scheduled": x.Scheduled, "live": x.Live, "playing": x.Playing, "note": x.Note, "created": x.Created,
	}
	if viewer != "" {
		_, mem := x.Members[viewer]
		_, inv := x.Invited[viewer]
		_, req := x.Requests[viewer]
		_, kicked := x.Kicked[viewer]
		v["member"], v["invited"], v["requested"], v["kicked"] = mem, inv, req, kicked
	}
	return v
}

// detailLocked: the party as a member sees it (the host also gets requests).
func (p *Parties) detailLocked(x *Party, viewer string) map[string]any {
	v := p.summaryLocked(x, viewer)
	v["chatOn"] = x.ChatOn
	v["pos"], v["at"], v["now"] = x.Pos, x.At, time.Now().UnixMilli()
	v["msgs"] = x.Msgs
	inv := []string{}
	for u := range x.Invited {
		if _, m := x.Members[u]; !m {
			inv = append(inv, u)
		}
	}
	sort.Strings(inv)
	v["invitedUsers"] = inv
	if viewer == x.Host {
		v["requests"] = p.people(x.Requests)
	}
	return v
}

// pushParty: every member gets the party as they see it.
func (p *Parties) pushParty(id string) {
	p.mu.Lock()
	x := p.by[id]
	if x == nil {
		p.mu.Unlock()
		return
	}
	out := map[string]map[string]any{}
	for u := range x.Members {
		out[u] = p.detailLocked(x, u)
	}
	p.mu.Unlock()
	for u, d := range out {
		p.s.chat.send(u, "party", map[string]any{"party": d})
	}
}

func (p *Parties) broadcastList() {
	p.s.chat.pmu.Lock()
	users := make([]string, 0, len(p.s.chat.subs))
	for u, set := range p.s.chat.subs {
		if len(set) > 0 {
			users = append(users, u)
		}
	}
	p.s.chat.pmu.Unlock()
	for _, u := range users {
		p.s.chat.send(u, "parties", map[string]any{})
	}
}

func (p *Parties) toMembers(x *Party, event string, v any) {
	for u := range x.Members {
		p.s.chat.send(u, event, v)
	}
}

// ---------------------------------------------------------------- http

func (s *Server) partyRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/parties", s.auth(s.handlePartyList))
	mux.HandleFunc("POST /api/parties", s.auth(s.handlePartyCreate))
	mux.HandleFunc("POST /api/parties/ask", s.auth(s.handlePartyAsk))
	mux.HandleFunc("POST /api/parties/ask/answer", s.auth(s.handlePartyAskAnswer))
	mux.HandleFunc("GET /api/parties/{id}", s.auth(s.handlePartyGet))
	mux.HandleFunc("DELETE /api/parties/{id}", s.auth(s.handlePartyEnd))
	mux.HandleFunc("POST /api/parties/{id}/{action}", s.auth(s.handlePartyAction))
}

func (p *Parties) get(id string) *Party { return p.by[id] }

// GET /api/parties → {parties: [...], asks: [...]}: public ones, mine, ones I'm invited to.
func (s *Server) handlePartyList(w http.ResponseWriter, r *http.Request) {
	me := userOf(r)
	p := s.parties
	p.mu.Lock()
	out := []map[string]any{}
	for _, x := range p.by {
		_, mem := x.Members[me]
		_, inv := x.Invited[me]
		if x.Visibility == "public" || mem || inv || x.Host == me {
			out = append(out, p.summaryLocked(x, me))
		}
	}
	asks := []map[string]any{}
	for asker, t := range p.asks[me] {
		if time.Since(time.Unix(t, 0)) < 10*time.Minute {
			asks = append(asks, map[string]any{"from": asker, "ts": t})
		}
	}
	p.mu.Unlock()
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if a["live"] != b["live"] {
			return a["live"] == true
		}
		sa, sb := a["scheduled"].(int64), b["scheduled"].(int64)
		if sa != sb {
			return sa < sb
		}
		return a["created"].(int64) > b["created"].(int64)
	})
	writeJSON(w, 200, map[string]any{"parties": out, "asks": asks, "now": time.Now().UnixMilli()})
}

type partyCreate struct {
	Title      string   `json:"title"`
	Kind       string   `json:"kind"`
	Path       string   `json:"path"`
	Name       string   `json:"name"`
	Visibility string   `json:"visibility"`
	Password   string   `json:"password"`
	Scheduled  int64    `json:"scheduled"`
	Note       string   `json:"note"`
	Invite     []string `json:"invite"`
	Pos        float64  `json:"pos"`
	Playing    bool     `json:"playing"`
}

func (s *Server) canOpen(user, path string) bool {
	return path == "" || s.userCanAccess(user, s.users.IsAdmin(user), strings.SplitN(path, "/", 2)[0])
}

// POST /api/parties {title, kind, path, name, visibility, password, scheduled, note, invite, pos, playing}
func (s *Server) handlePartyCreate(w http.ResponseWriter, r *http.Request) {
	var b partyCreate
	if !decodeJSON(w, r, &b) {
		return
	}
	me := userOf(r)
	if b.Path != "" && !s.canOpen(me, b.Path) {
		httpErr(w, 403, "you can't open that file")
		return
	}
	x := s.parties.create(me, b)
	s.parties.invite(x.ID, me, b.Invite)
	s.parties.mu.Lock()
	d := s.parties.detailLocked(x, me)
	s.parties.mu.Unlock()
	if x.Visibility == "public" {
		s.parties.broadcastList()
	}
	writeJSON(w, 200, d)
}

func (p *Parties) create(host string, b partyCreate) *Party {
	now := time.Now()
	x := &Party{ID: chatID(), Title: clip(strings.TrimSpace(b.Title), 120), Host: host, Kind: b.Kind, Path: b.Path, Name: clip(b.Name, 200),
		Visibility: "private", ChatOn: true, Members: map[string]int64{host: now.Unix()}, Invited: map[string]int64{},
		Requests: map[string]int64{}, Kicked: map[string]int64{}, Note: clip(strings.TrimSpace(b.Note), 500),
		Created: now.Unix(), lastActive: now, Pos: b.Pos, Playing: b.Playing, At: now.UnixMilli()}
	if x.Kind != "music" {
		x.Kind = "video"
	}
	if b.Visibility == "public" {
		x.Visibility = "public"
	}
	if x.Title == "" {
		x.Title = host + "'s party"
	}
	if b.Password != "" {
		x.PassHash = passHash(x.ID, b.Password)
	}
	if b.Scheduled > now.Unix()+60 {
		x.Scheduled = b.Scheduled
	} else {
		x.Live = true
	}
	p.mu.Lock()
	p.by[x.ID] = x
	if x.Live {
		p.sysLocked(x, "🎉 "+host+" started the party")
	} else {
		p.sysLocked(x, "🗓 "+host+" scheduled the party")
	}
	p.saveLocked()
	p.mu.Unlock()
	return x
}

func (p *Parties) invite(id, from string, users []string) []string {
	p.mu.Lock()
	x := p.by[id]
	if x == nil {
		p.mu.Unlock()
		return nil
	}
	var sent []string
	for _, u := range users {
		if u == "" || u == from || !p.s.users.Exists(u) {
			continue
		}
		if _, m := x.Members[u]; m {
			continue
		}
		delete(x.Kicked, u) // inviting again forgives a kick
		x.Invited[u] = time.Now().Unix()
		sent = append(sent, u)
	}
	sum := p.summaryLocked(x, "")
	p.saveLocked()
	p.mu.Unlock()
	for _, u := range sent {
		p.s.chat.send(u, "party-notice", map[string]any{"kind": "invite", "party": sum, "from": from})
	}
	return sent
}

func (s *Server) handlePartyGet(w http.ResponseWriter, r *http.Request) {
	me := userOf(r)
	p := s.parties
	p.mu.Lock()
	defer p.mu.Unlock()
	x := p.get(r.PathValue("id"))
	if x == nil {
		httpErr(w, 404, "this party has ended")
		return
	}
	if _, m := x.Members[me]; !m {
		writeJSON(w, 200, p.summaryLocked(x, me))
		return
	}
	writeJSON(w, 200, p.detailLocked(x, me))
}

// DELETE /api/parties/{id} — the host ends it.
func (s *Server) handlePartyEnd(w http.ResponseWriter, r *http.Request) {
	me := userOf(r)
	p := s.parties
	p.mu.Lock()
	x := p.get(r.PathValue("id"))
	if x == nil {
		p.mu.Unlock()
		writeJSON(w, 200, map[string]bool{"ok": true})
		return
	}
	if x.Host != me && !isAdmin(r) {
		p.mu.Unlock()
		httpErr(w, 403, "only the host can end the party")
		return
	}
	delete(p.by, x.ID)
	p.saveLocked()
	to := p.audienceLocked(x)
	sum := p.summaryLocked(x, "")
	p.mu.Unlock()
	for _, u := range to {
		s.chat.send(u, "party-notice", map[string]any{"kind": "ended", "party": sum, "from": me})
	}
	p.broadcastList()
	writeJSON(w, 200, map[string]bool{"ok": true})
}

var errPartyGone = errors.New("this party has ended")

// POST /api/parties/{id}/{action}
//
//	join {password} · leave · request · answer {user, accept} · invite {users} · kick {user}
//	state {path, kind, name, playing, pos} (host) · settings {title, visibility, password, chatOn, note, scheduled, host} (host)
//	msg {text} · react {emoji} · start (host, a scheduled party now)
func (s *Server) handlePartyAction(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Password   *string  `json:"password"`
		User       string   `json:"user"`
		Users      []string `json:"users"`
		Accept     bool     `json:"accept"`
		Path       string   `json:"path"`
		Kind       string   `json:"kind"`
		Name       string   `json:"name"`
		Playing    bool     `json:"playing"`
		Pos        float64  `json:"pos"`
		Title      *string  `json:"title"`
		Visibility *string  `json:"visibility"`
		ChatOn     *bool    `json:"chatOn"`
		Note       *string  `json:"note"`
		Scheduled  *int64   `json:"scheduled"`
		Host       string   `json:"host"`
		Text       string   `json:"text"`
		Emoji      string   `json:"emoji"`
	}
	if r.ContentLength > 0 && !decodeJSON(w, r, &b) {
		return
	}
	me, id, action := userOf(r), r.PathValue("id"), r.PathValue("action")
	p := s.parties
	p.mu.Lock()
	x := p.get(id)
	if x == nil {
		p.mu.Unlock()
		httpErr(w, 404, errPartyGone.Error())
		return
	}
	_, member := x.Members[me]
	host := x.Host == me
	fail := func(code int, msg string) {
		p.mu.Unlock()
		httpErr(w, code, msg)
	}
	var after []func() // run after unlocking
	listChanged, partyChanged := false, false
	switch action {
	case "join":
		if member {
			break
		}
		if _, k := x.Kicked[me]; k {
			fail(403, "the host removed you from this party")
			return
		}
		if !s.canOpen(me, x.Path) {
			fail(403, "you don't have access to the library of what's playing")
			return
		}
		_, invited := x.Invited[me]
		if !invited && !isAdmin(r) {
			if x.Visibility != "public" {
				fail(403, "private party — ask the host to let you in")
				return
			}
			if x.PassHash != "" {
				if b.Password == nil || *b.Password == "" {
					fail(401, "this party has a password")
					return
				}
				if subtle.ConstantTimeCompare([]byte(passHash(x.ID, *b.Password)), []byte(x.PassHash)) != 1 {
					fail(401, "wrong password")
					return
				}
			}
		}
		x.Members[me] = time.Now().Unix()
		delete(x.Invited, me)
		delete(x.Requests, me)
		m := p.sysLocked(x, "👋 "+me+" joined")
		after = append(after, func() { p.toMembers(x, "party-msg", map[string]any{"id": x.ID, "msg": m}) })
		partyChanged, listChanged = true, true
	case "leave":
		if !member {
			break
		}
		delete(x.Members, me)
		if host {
			// the earliest other member takes over; nobody left → the party ends
			next, at := "", int64(0)
			for u, t := range x.Members {
				if next == "" || t < at {
					next, at = u, t
				}
			}
			if next == "" {
				delete(p.by, x.ID)
				listChanged = true
				p.saveLocked()
				break
			}
			x.Host = next
			p.sysLocked(x, "👑 "+next+" is the host now")
		}
		m := p.sysLocked(x, "🚪 "+me+" left")
		after = append(after, func() { p.toMembers(x, "party-msg", map[string]any{"id": x.ID, "msg": m}) })
		partyChanged, listChanged = true, true
	case "request":
		if member {
			break
		}
		if _, k := x.Kicked[me]; k {
			fail(403, "the host removed you from this party")
			return
		}
		x.Requests[me] = time.Now().Unix()
		sum, hostName := p.summaryLocked(x, ""), x.Host
		after = append(after, func() {
			s.chat.send(hostName, "party-notice", map[string]any{"kind": "request", "party": sum, "from": me})
		})
		partyChanged = true
	case "answer":
		if !host {
			fail(403, "only the host can let people in")
			return
		}
		if _, ok := x.Requests[b.User]; !ok {
			break
		}
		delete(x.Requests, b.User)
		sum := p.summaryLocked(x, b.User)
		u := b.User
		if b.Accept {
			x.Members[u] = time.Now().Unix()
			delete(x.Kicked, u)
			m := p.sysLocked(x, "👋 "+u+" joined")
			after = append(after, func() { p.toMembers(x, "party-msg", map[string]any{"id": x.ID, "msg": m}) })
			after = append(after, func() { s.chat.send(u, "party-notice", map[string]any{"kind": "accepted", "party": sum, "from": me}) })
			listChanged = true
		} else {
			after = append(after, func() { s.chat.send(u, "party-notice", map[string]any{"kind": "declined", "party": sum, "from": me}) })
		}
		partyChanged = true
	case "invite":
		if !member {
			fail(403, "join the party first")
			return
		}
		if !host && x.Visibility != "public" {
			fail(403, "only the host can invite people to a private party")
			return
		}
		users := append([]string{}, b.Users...)
		if b.User != "" {
			users = append(users, b.User)
		}
		after = append(after, func() { p.invite(x.ID, me, users) })
		partyChanged = true
	case "kick":
		if !host {
			fail(403, "only the host can remove people")
			return
		}
		if b.User == me || b.User == "" {
			break
		}
		delete(x.Members, b.User)
		delete(x.Invited, b.User)
		delete(x.Requests, b.User)
		x.Kicked[b.User] = time.Now().Unix()
		sum, u := p.summaryLocked(x, ""), b.User
		m := p.sysLocked(x, "🚫 "+u+" was removed")
		after = append(after, func() {
			s.chat.send(u, "party-notice", map[string]any{"kind": "kicked", "party": sum, "from": me})
			p.toMembers(x, "party-msg", map[string]any{"id": x.ID, "msg": m})
		})
		partyChanged, listChanged = true, true
	case "state":
		if !host {
			fail(403, "only the host controls playback")
			return
		}
		if b.Path != "" && b.Path != x.Path {
			if !s.canOpen(me, b.Path) {
				fail(403, "you can't open that file")
				return
			}
			x.Path, x.Name = b.Path, clip(b.Name, 200)
			if b.Kind == "music" || b.Kind == "video" {
				x.Kind = b.Kind
			}
			m := p.sysLocked(x, "▶ Now: "+x.Name)
			after = append(after, func() { p.toMembers(x, "party-msg", map[string]any{"id": x.ID, "msg": m}) })
			listChanged = true
		}
		x.Playing, x.Pos, x.At = b.Playing, b.Pos, time.Now().UnixMilli()
		x.Live, x.lastActive = true, time.Now()
		st := map[string]any{"id": x.ID, "path": x.Path, "kind": x.Kind, "name": x.Name, "playing": x.Playing, "pos": x.Pos, "at": x.At, "now": x.At}
		after = append(after, func() {
			for u := range x.Members {
				if u != me {
					s.chat.send(u, "party-state", st)
				}
			}
		})
		p.saveLocked()
	case "settings":
		if !host {
			fail(403, "only the host can change the party")
			return
		}
		if b.Title != nil && strings.TrimSpace(*b.Title) != "" {
			x.Title = clip(strings.TrimSpace(*b.Title), 120)
		}
		if b.Visibility != nil {
			if *b.Visibility == "public" {
				x.Visibility = "public"
			} else {
				x.Visibility = "private"
			}
		}
		if b.Password != nil {
			if *b.Password == "" {
				x.PassHash = ""
			} else {
				x.PassHash = passHash(x.ID, *b.Password)
			}
		}
		if b.ChatOn != nil && *b.ChatOn != x.ChatOn {
			x.ChatOn = *b.ChatOn
			text := "💬 Chat is on"
			if !x.ChatOn {
				text = "🤫 The host turned chat off"
			}
			m := p.sysLocked(x, text)
			after = append(after, func() { p.toMembers(x, "party-msg", map[string]any{"id": x.ID, "msg": m}) })
		}
		if b.Note != nil {
			x.Note = clip(strings.TrimSpace(*b.Note), 500)
		}
		if b.Scheduled != nil && !x.Live {
			x.Scheduled, x.Reminded = *b.Scheduled, false
		}
		if b.Host != "" && b.Host != me {
			if _, ok := x.Members[b.Host]; ok {
				x.Host = b.Host
				m := p.sysLocked(x, "👑 "+b.Host+" is the host now")
				after = append(after, func() { p.toMembers(x, "party-msg", map[string]any{"id": x.ID, "msg": m}) })
			}
		}
		partyChanged, listChanged = true, true
		p.saveLocked()
	case "start":
		if !host {
			fail(403, "only the host can start the party")
			return
		}
		x.Live, x.lastActive = true, time.Now()
		m := p.sysLocked(x, "🎉 The party is starting")
		to, sum := p.audienceLocked(x), p.summaryLocked(x, "")
		after = append(after, func() {
			p.toMembers(x, "party-msg", map[string]any{"id": x.ID, "msg": m})
			for _, u := range to {
				if u != me {
					s.chat.send(u, "party-notice", map[string]any{"kind": "reminder", "party": sum, "from": me})
				}
			}
		})
		x.Reminded = true
		partyChanged, listChanged = true, true
	case "msg":
		if !member {
			fail(403, "join the party first")
			return
		}
		if !x.ChatOn && !host {
			fail(403, "the host turned chat off")
			return
		}
		text := strings.TrimSpace(b.Text)
		if text == "" {
			break
		}
		p.mu.Unlock()
		if err := s.chat.allow(me); err != nil {
			httpErr(w, 429, err.Error())
			return
		}
		p.mu.Lock()
		if p.get(id) == nil {
			fail(404, errPartyGone.Error())
			return
		}
		m := p.addMsgLocked(x, me, clip(text, 1000), false)
		after = append(after, func() { p.toMembers(x, "party-msg", map[string]any{"id": x.ID, "msg": m}) })
	case "react":
		if !member {
			fail(403, "join the party first")
			return
		}
		e := strings.TrimSpace(b.Emoji)
		if e == "" || len(e) > 32 {
			fail(400, "pick an emoji")
			return
		}
		if !x.ChatOn && !host {
			fail(403, "the host turned chat off")
			return
		}
		ev := map[string]any{"id": x.ID, "from": me, "emoji": e}
		after = append(after, func() { p.toMembers(x, "party-react", ev) })
	default:
		fail(404, "unknown action")
		return
	}
	var resp map[string]any
	if p.by[id] != nil {
		if _, m := x.Members[me]; m {
			resp = p.detailLocked(x, me)
		} else {
			resp = p.summaryLocked(x, me)
		}
	} else {
		resp = map[string]any{"ended": true}
	}
	p.mu.Unlock()
	for _, f := range after {
		f()
	}
	if partyChanged {
		p.pushParty(id)
	}
	if listChanged {
		p.broadcastList()
	}
	writeJSON(w, 200, resp)
}

// POST /api/parties/ask {user} — "can I watch with you?" to a friend who's playing something.
func (s *Server) handlePartyAsk(w http.ResponseWriter, r *http.Request) {
	var b struct{ User string }
	if !decodeJSON(w, r, &b) {
		return
	}
	me := userOf(r)
	if b.User == me || !s.users.Exists(b.User) {
		httpErr(w, 400, "no such person")
		return
	}
	s.chat.pmu.Lock()
	pr := s.chat.pres[b.User]
	var act *Activity
	if pr != nil && pr.activity != nil && s.chat.online(b.User) && !s.users.HidesActivity(b.User) {
		c := *pr.activity
		act = &c
	}
	s.chat.pmu.Unlock()
	if act == nil || act.Path == "" {
		httpErr(w, 409, b.User+" isn't playing anything right now")
		return
	}
	if !s.canOpen(me, act.Path) {
		httpErr(w, 403, "you don't have access to that library")
		return
	}
	p := s.parties
	p.mu.Lock()
	// already hosting a party with that: a normal join request
	for _, x := range p.by {
		if x.Host == b.User && x.Live && x.Path == act.Path {
			if _, m := x.Members[me]; m {
				d := p.detailLocked(x, me)
				p.mu.Unlock()
				writeJSON(w, 200, map[string]any{"party": d})
				return
			}
			x.Requests[me] = time.Now().Unix()
			sum := p.summaryLocked(x, "")
			p.mu.Unlock()
			s.chat.send(b.User, "party-notice", map[string]any{"kind": "request", "party": sum, "from": me})
			p.pushParty(x.ID)
			writeJSON(w, 200, map[string]any{"requested": true})
			return
		}
	}
	if p.asks[b.User] == nil {
		p.asks[b.User] = map[string]int64{}
	}
	p.asks[b.User][me] = time.Now().Unix()
	p.mu.Unlock()
	s.chat.send(b.User, "party-notice", map[string]any{"kind": "ask", "from": me, "activity": act})
	writeJSON(w, 200, map[string]any{"asked": true})
}

// POST /api/parties/ask/answer {user, accept, pos, playing} — the friend answers; yes = their playback becomes a party.
func (s *Server) handlePartyAskAnswer(w http.ResponseWriter, r *http.Request) {
	var b struct {
		User    string  `json:"user"`
		Accept  bool    `json:"accept"`
		Pos     float64 `json:"pos"`
		Playing bool    `json:"playing"`
	}
	if !decodeJSON(w, r, &b) {
		return
	}
	me := userOf(r)
	p := s.parties
	p.mu.Lock()
	_, ok := p.asks[me][b.User]
	delete(p.asks[me], b.User)
	p.mu.Unlock()
	if !ok {
		httpErr(w, 404, "that request expired")
		return
	}
	if !b.Accept {
		s.chat.send(b.User, "party-notice", map[string]any{"kind": "ask-declined", "from": me})
		writeJSON(w, 200, map[string]bool{"ok": true})
		return
	}
	s.chat.pmu.Lock()
	var act *Activity
	if pr := s.chat.pres[me]; pr != nil && pr.activity != nil {
		c := *pr.activity
		act = &c
	}
	s.chat.pmu.Unlock()
	if act == nil || act.Path == "" {
		httpErr(w, 409, "start playing something first")
		return
	}
	pos := b.Pos
	if pos <= 0 {
		pos = act.Pos
	}
	// an existing live party of mine, else a new private one
	p.mu.Lock()
	var x *Party
	for _, y := range p.by {
		if y.Host == me && y.Live && y.Path == act.Path {
			x = y
			break
		}
	}
	p.mu.Unlock()
	if x == nil {
		name := act.Title
		if act.Sub != "" {
			name += " · " + act.Sub
		}
		x = p.create(me, partyCreate{Kind: act.Kind, Path: act.Path, Name: name, Visibility: "private", Pos: pos, Playing: b.Playing})
	}
	p.mu.Lock()
	x.Members[b.User] = time.Now().Unix()
	delete(x.Kicked, b.User)
	m := p.sysLocked(x, "👋 "+b.User+" joined")
	sum := p.summaryLocked(x, b.User)
	d := p.detailLocked(x, me)
	p.mu.Unlock()
	p.toMembers(x, "party-msg", map[string]any{"id": x.ID, "msg": m})
	s.chat.send(b.User, "party-notice", map[string]any{"kind": "accepted", "party": sum, "from": me})
	p.pushParty(x.ID)
	writeJSON(w, 200, d)
}
