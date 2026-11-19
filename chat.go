package main

// Who's online (and what they're watching), direct messages, group chats and
// sharing a movie / song into a chat. Live updates go out over Server-Sent
// Events (GET /api/events).

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---------------------------------------------------------------- presence

type Activity struct {
	Kind  string  `json:"kind"`            // video | music
	Title string  `json:"title"`           // "Children of Men" / "One More Time"
	Sub   string  `json:"sub,omitempty"`   // "S01E02 · …" / "Daft Punk"
	Path  string  `json:"path,omitempty"`  // lib/rel (only shown to people who can open it)
	Image string  `json:"image,omitempty"` // poster / cover URL or "cover:<key>"
	Pos   float64 `json:"pos,omitempty"`
	Dur   float64 `json:"dur,omitempty"`
	At    int64   `json:"at"`
}

type presence struct {
	seen     int64
	activity *Activity
}

type OnlinePerson struct {
	Name     string    `json:"name"`
	Online   bool      `json:"online"`
	LastSeen int64     `json:"lastSeen,omitempty"`
	Activity *Activity `json:"activity,omitempty"`
	Admin    bool      `json:"admin,omitempty"`
	Avatar   int64     `json:"avatar,omitempty"` // picture version; 0 = none (show initials)
}

// ---------------------------------------------------------------- chat store

type Ref struct { // a movie / episode / song shared into a chat
	Path  string `json:"path"`
	Title string `json:"title"`
	Sub   string `json:"sub,omitempty"`
	Image string `json:"image,omitempty"`
	Kind  string `json:"kind,omitempty"` // video | music
}

type Message struct {
	Seq  int64  `json:"seq"`
	From string `json:"from"`
	Text string `json:"text,omitempty"`
	Ref  *Ref   `json:"ref,omitempty"`
	Sys  bool   `json:"sys,omitempty"` // "bob added alice"
	TS   int64  `json:"ts"`
}

type Conversation struct {
	ID        string           `json:"id"`
	Kind      string           `json:"kind"` // dm | group
	Name      string           `json:"name,omitempty"`
	Members   []string         `json:"members"`
	CreatedBy string           `json:"createdBy"`
	Created   int64            `json:"created"`
	Seq       int64            `json:"seq"` // last message seq
	Last      *Message         `json:"last,omitempty"`
	Read      map[string]int64 `json:"read"` // user → last read seq
}

type Chat struct {
	s     *Server
	dir   string
	mu    sync.Mutex
	convs map[string]*Conversation

	pmu   sync.Mutex
	pres  map[string]*presence
	subs  map[string]map[chan []byte]struct{} // user → event channels
	rate  map[string][]time.Time
	dirty bool
}

func NewChat(s *Server) *Chat {
	c := &Chat{s: s, dir: filepath.Join(s.cfg.DataDir, "chat"), convs: map[string]*Conversation{},
		pres: map[string]*presence{}, subs: map[string]map[chan []byte]struct{}{}, rate: map[string][]time.Time{}}
	os.MkdirAll(c.dir, 0o700)
	if b, err := os.ReadFile(filepath.Join(c.dir, "conversations.json")); err == nil {
		var list []*Conversation
		if json.Unmarshal(b, &list) == nil {
			for _, cv := range list {
				if cv.Read == nil {
					cv.Read = map[string]int64{}
				}
				c.convs[cv.ID] = cv
			}
		}
	}
	go c.presenceLoop()
	return c
}

func (c *Chat) saveLocked() {
	list := make([]*Conversation, 0, len(c.convs))
	for _, cv := range c.convs {
		list = append(list, cv)
	}
	b, _ := json.Marshal(list)
	f := filepath.Join(c.dir, "conversations.json")
	if os.WriteFile(f+".tmp", b, 0o600) == nil {
		os.Rename(f+".tmp", f)
	}
}

func (cv *Conversation) has(user string) bool {
	for _, m := range cv.Members {
		if m == user {
			return true
		}
	}
	return false
}

func chatID() string {
	b := make([]byte, 8)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func (c *Chat) appendMsg(cv *Conversation, m *Message) error {
	cv.Seq++
	m.Seq = cv.Seq
	m.TS = time.Now().Unix()
	b, _ := json.Marshal(m)
	f, err := os.OpenFile(filepath.Join(c.dir, cv.ID+".jsonl"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := f.Write(append(b, '\n')); err != nil {
		return err
	}
	cv.Last = m
	if !m.Sys {
		cv.Read[m.From] = m.Seq
	}
	return nil
}

func (c *Chat) messages(cv *Conversation, before int64, limit int) []Message {
	f, err := os.Open(filepath.Join(c.dir, cv.ID+".jsonl"))
	if err != nil {
		return []Message{}
	}
	defer f.Close()
	var all []Message
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		var m Message
		if json.Unmarshal(sc.Bytes(), &m) == nil && (before <= 0 || m.Seq < before) {
			all = append(all, m)
		}
	}
	if len(all) > limit {
		all = all[len(all)-limit:]
	}
	if all == nil {
		all = []Message{}
	}
	return all
}

// ---------------------------------------------------------------- events

func (c *Chat) subscribe(user string) chan []byte {
	ch := make(chan []byte, 64)
	c.pmu.Lock()
	if c.subs[user] == nil {
		c.subs[user] = map[chan []byte]struct{}{}
	}
	first := len(c.subs[user]) == 0
	c.subs[user][ch] = struct{}{}
	c.touchLocked(user)
	c.pmu.Unlock()
	if first {
		c.broadcastPresence()
	}
	return ch
}

func (c *Chat) unsubscribe(user string, ch chan []byte) {
	c.pmu.Lock()
	delete(c.subs[user], ch)
	last := len(c.subs[user]) == 0
	if last {
		if p := c.pres[user]; p != nil {
			p.activity = nil
		}
	}
	c.pmu.Unlock()
	if last {
		c.broadcastPresence()
	}
}

func (c *Chat) send(user, event string, v any) {
	b, _ := json.Marshal(v)
	msg := []byte("event: " + event + "\ndata: " + string(b) + "\n\n")
	c.pmu.Lock()
	defer c.pmu.Unlock()
	for ch := range c.subs[user] {
		select {
		case ch <- msg:
		default: // slow client: drop; it re-syncs on reconnect
		}
	}
}

func (c *Chat) touchLocked(user string) {
	p := c.pres[user]
	if p == nil {
		p = &presence{}
		c.pres[user] = p
	}
	p.seen = time.Now().Unix()
}

func (c *Chat) online(user string) bool {
	p := c.pres[user]
	return len(c.subs[user]) > 0 || (p != nil && time.Now().Unix()-p.seen < 90)
}

// People as seen by viewer: activity paths only for libraries the viewer can open.
func (c *Chat) People(viewer string, viewerAdmin bool) []OnlinePerson {
	users := c.s.users.List()
	c.pmu.Lock()
	out := make([]OnlinePerson, 0, len(users))
	for _, u := range users {
		p := OnlinePerson{Name: u.Name, Admin: u.Admin, LastSeen: u.LastSeen, Online: c.online(u.Name), Avatar: c.s.avatars.Version(u.Name)}
		if pr := c.pres[u.Name]; pr != nil {
			if pr.seen > p.LastSeen {
				p.LastSeen = pr.seen
			}
			if p.Online && pr.activity != nil && !c.s.users.HidesActivity(u.Name) {
				a := *pr.activity
				if a.Path != "" && !c.s.userCanAccess(viewer, viewerAdmin, strings.SplitN(a.Path, "/", 2)[0]) {
					a.Path, a.Image = "", "" // can't open it: just the title
				}
				p.Activity = &a
			}
		}
		out = append(out, p)
	}
	c.pmu.Unlock()
	sort.Slice(out, func(i, j int) bool {
		if out[i].Online != out[j].Online {
			return out[i].Online
		}
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	return out
}

func (c *Chat) broadcastPresence() {
	c.pmu.Lock()
	users := make([]string, 0, len(c.subs))
	for u, set := range c.subs {
		if len(set) > 0 {
			users = append(users, u)
		}
	}
	c.pmu.Unlock()
	for _, u := range users {
		c.send(u, "people", c.People(u, c.s.users.IsAdmin(u)))
	}
}

// presenceLoop: people drop to offline 90 s after their last heartbeat.
func (c *Chat) presenceLoop() {
	last := map[string]bool{}
	for range time.Tick(20 * time.Second) {
		changed := false
		c.pmu.Lock()
		now := map[string]bool{}
		for u := range c.pres {
			now[u] = c.online(u)
			if now[u] != last[u] {
				changed = true
			}
			if !now[u] && c.pres[u].activity != nil {
				c.pres[u].activity = nil
			}
		}
		c.pmu.Unlock()
		last = now
		if changed {
			c.broadcastPresence()
		}
	}
}

// ---------------------------------------------------------------- API

func (s *Server) chatRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/events", s.auth(s.handleEvents))
	mux.HandleFunc("POST /api/presence", s.auth(s.handlePresence))
	mux.HandleFunc("GET /api/people", s.auth(s.handlePeople))
	mux.HandleFunc("POST /api/me/privacy", s.auth(s.handlePrivacy))
	mux.HandleFunc("GET /api/chat", s.auth(s.handleChatList))
	mux.HandleFunc("POST /api/chat/dm", s.auth(s.handleChatDM))
	mux.HandleFunc("POST /api/chat/groups", s.auth(s.handleChatGroup))
	mux.HandleFunc("PUT /api/chat/{id}", s.auth(s.handleChatUpdate))
	mux.HandleFunc("POST /api/chat/{id}/leave", s.auth(s.handleChatLeave))
	mux.HandleFunc("GET /api/chat/{id}/messages", s.auth(s.handleChatMessages))
	mux.HandleFunc("POST /api/chat/{id}/messages", s.auth(s.handleChatSend))
	mux.HandleFunc("POST /api/chat/{id}/read", s.auth(s.handleChatRead))
}

// GET /api/events — text/event-stream: people, message, conversation, read
func (s *Server) handleEvents(w http.ResponseWriter, r *http.Request) {
	fl, ok := w.(http.Flusher)
	if !ok {
		httpErr(w, 500, "streaming unsupported")
		return
	}
	user := userOf(r)
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(200)
	ch := s.chat.subscribe(user)
	defer s.chat.unsubscribe(user, ch)
	b, _ := json.Marshal(s.chat.People(user, isAdmin(r)))
	fmt.Fprintf(w, "retry: 3000\nevent: people\ndata: %s\n\n", b)
	fl.Flush()
	ping := time.NewTicker(25 * time.Second)
	defer ping.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case m := <-ch:
			if _, err := w.Write(m); err != nil {
				return
			}
			fl.Flush()
		case <-ping.C:
			s.chat.pmu.Lock()
			s.chat.touchLocked(user)
			s.chat.pmu.Unlock()
			if _, err := w.Write([]byte(": ping\n\n")); err != nil {
				return
			}
			fl.Flush()
		}
	}
}

// POST /api/presence {"activity": {...} | null} — heartbeat + what I'm playing
func (s *Server) handlePresence(w http.ResponseWriter, r *http.Request) {
	var b struct{ Activity *Activity }
	if r.ContentLength > 0 && !decodeJSON(w, r, &b) {
		return
	}
	user := userOf(r)
	if a := b.Activity; a != nil {
		a.Title = clip(a.Title, 200)
		a.Sub = clip(a.Sub, 200)
		a.Image = clip(a.Image, 500)
		if a.Kind != "music" {
			a.Kind = "video"
		}
		if a.Path != "" && !s.canAccess(r, strings.SplitN(a.Path, "/", 2)[0]) {
			a.Path = ""
		}
		a.At = time.Now().Unix()
	}
	c := s.chat
	c.pmu.Lock()
	wasOnline := c.online(user)
	c.touchLocked(user)
	p := c.pres[user]
	changed := !wasOnline || activityKey(p.activity) != activityKey(b.Activity)
	p.activity = b.Activity
	c.pmu.Unlock()
	if changed {
		c.broadcastPresence()
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}

func activityKey(a *Activity) string {
	if a == nil {
		return ""
	}
	return a.Kind + "|" + a.Path + "|" + a.Title + "|" + a.Sub
}

func clip(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) > n {
		s = s[:n]
	}
	return s
}

func (s *Server) handlePeople(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, map[string]any{"people": s.chat.People(userOf(r), isAdmin(r)), "hideActivity": s.users.HidesActivity(userOf(r))})
}

// POST /api/me/privacy {"hideActivity": bool}
func (s *Server) handlePrivacy(w http.ResponseWriter, r *http.Request) {
	var b struct{ HideActivity bool }
	if !decodeJSON(w, r, &b) {
		return
	}
	if err := s.users.SetHideActivity(userOf(r), b.HideActivity); err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	s.chat.broadcastPresence()
	writeJSON(w, 200, map[string]bool{"ok": true})
}

type convView struct {
	*Conversation
	Unread int64  `json:"unread"`
	Title  string `json:"title"` // group name, or the other person in a DM
}

func (c *Chat) view(cv *Conversation, user string) convView {
	title := cv.Name
	if cv.Kind == "dm" {
		for _, m := range cv.Members {
			if m != user {
				title = m
			}
		}
	}
	unread := cv.Seq - cv.Read[user]
	if unread < 0 {
		unread = 0
	}
	cp := *cv
	cp.Read = nil
	return convView{Conversation: &cp, Unread: unread, Title: title}
}

func (s *Server) handleChatList(w http.ResponseWriter, r *http.Request) {
	user := userOf(r)
	c := s.chat
	c.mu.Lock()
	out := []convView{}
	for _, cv := range c.convs {
		if cv.has(user) {
			out = append(out, c.view(cv, user))
		}
	}
	c.mu.Unlock()
	sort.Slice(out, func(i, j int) bool { return lastTS(out[i].Conversation) > lastTS(out[j].Conversation) })
	writeJSON(w, 200, map[string]any{"conversations": out})
}

func lastTS(cv *Conversation) int64 {
	if cv.Last != nil {
		return cv.Last.TS
	}
	return cv.Created
}

// notify sends every member the conversation's new state (+ the message).
func (c *Chat) notify(cv *Conversation, m *Message, extra ...string) {
	members := append(append([]string{}, cv.Members...), extra...)
	for _, u := range members {
		v := c.view(cv, u)
		if !cv.has(u) {
			v.Members = nil
		}
		c.send(u, "conversation", v)
		if m != nil && cv.has(u) {
			c.send(u, "message", map[string]any{"conv": cv.ID, "message": m})
		}
	}
}

// POST /api/chat/dm {"user": "bob"} → the (new or existing) conversation
func (s *Server) handleChatDM(w http.ResponseWriter, r *http.Request) {
	var b struct{ User string }
	if !decodeJSON(w, r, &b) {
		return
	}
	me := userOf(r)
	if b.User == me || !s.users.Exists(b.User) {
		httpErr(w, 400, "no such user")
		return
	}
	c := s.chat
	c.mu.Lock()
	for _, cv := range c.convs {
		if cv.Kind == "dm" && cv.has(me) && cv.has(b.User) {
			v := c.view(cv, me)
			c.mu.Unlock()
			writeJSON(w, 200, v)
			return
		}
	}
	cv := &Conversation{ID: chatID(), Kind: "dm", Members: []string{me, b.User}, CreatedBy: me, Created: time.Now().Unix(), Read: map[string]int64{}}
	c.convs[cv.ID] = cv
	c.saveLocked()
	v := c.view(cv, me)
	c.mu.Unlock()
	writeJSON(w, 200, v)
}

func (s *Server) cleanMembers(names []string) ([]string, error) {
	seen := map[string]bool{}
	var out []string
	for _, n := range names {
		n = strings.TrimSpace(n)
		if n == "" || seen[n] {
			continue
		}
		if !s.users.Exists(n) {
			return nil, fmt.Errorf("no such user: %s", n)
		}
		seen[n] = true
		out = append(out, n)
	}
	return out, nil
}

// POST /api/chat/groups {"name", "members": [...]}
func (s *Server) handleChatGroup(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Name    string
		Members []string
	}
	if !decodeJSON(w, r, &b) {
		return
	}
	me := userOf(r)
	name := clip(b.Name, 80)
	if name == "" {
		httpErr(w, 400, "name the group")
		return
	}
	members, err := s.cleanMembers(append([]string{me}, b.Members...))
	if err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	if len(members) > 100 {
		httpErr(w, 400, "too many members")
		return
	}
	c := s.chat
	c.mu.Lock()
	cv := &Conversation{ID: chatID(), Kind: "group", Name: name, Members: members, CreatedBy: me, Created: time.Now().Unix(), Read: map[string]int64{}}
	c.convs[cv.ID] = cv
	m := &Message{From: me, Sys: true, Text: me + " created the group"}
	c.appendMsg(cv, m)
	c.saveLocked()
	c.notify(cv, m)
	v := c.view(cv, me)
	c.mu.Unlock()
	writeJSON(w, 200, v)
}

func (s *Server) convFor(w http.ResponseWriter, r *http.Request) *Conversation {
	cv := s.chat.convs[r.PathValue("id")]
	if cv == nil || !cv.has(userOf(r)) {
		httpErr(w, 404, "no such conversation")
		return nil
	}
	return cv
}

// PUT /api/chat/{id} {"name"?, "add"?: [...], "remove"?: [...]} — groups only.
// Any member may rename and add people; removing others needs the creator or an admin.
func (s *Server) handleChatUpdate(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Name        *string
		Add, Remove []string
	}
	if !decodeJSON(w, r, &b) {
		return
	}
	me := userOf(r)
	c := s.chat
	c.mu.Lock()
	defer c.mu.Unlock()
	cv := s.convFor(w, r)
	if cv == nil {
		return
	}
	if cv.Kind != "group" {
		httpErr(w, 400, "only groups can be changed")
		return
	}
	var sys []string
	if b.Name != nil {
		if n := clip(*b.Name, 80); n != "" && n != cv.Name {
			cv.Name = n
			sys = append(sys, fmt.Sprintf("%s renamed the group to “%s”", me, n))
		}
	}
	add, err := s.cleanMembers(b.Add)
	if err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	for _, u := range add {
		if !cv.has(u) {
			cv.Members = append(cv.Members, u)
			sys = append(sys, me+" added "+u)
		}
	}
	var removed []string
	for _, u := range b.Remove {
		if !cv.has(u) || u == me {
			continue
		}
		if cv.CreatedBy != me && !isAdmin(r) {
			httpErr(w, 403, "only the group's creator can remove people")
			return
		}
		cv.Members = without(cv.Members, u)
		removed = append(removed, u)
		sys = append(sys, me+" removed "+u)
	}
	var last *Message
	for _, t := range sys {
		last = &Message{From: me, Sys: true, Text: t}
		c.appendMsg(cv, last)
		c.notify(cv, last, removed...)
	}
	c.saveLocked()
	writeJSON(w, 200, c.view(cv, me))
}

func without(list []string, x string) []string {
	out := list[:0:0]
	for _, v := range list {
		if v != x {
			out = append(out, v)
		}
	}
	return out
}

func (s *Server) handleChatLeave(w http.ResponseWriter, r *http.Request) {
	me := userOf(r)
	c := s.chat
	c.mu.Lock()
	defer c.mu.Unlock()
	cv := s.convFor(w, r)
	if cv == nil {
		return
	}
	if cv.Kind != "group" {
		httpErr(w, 400, "you can't leave a direct chat")
		return
	}
	cv.Members = without(cv.Members, me)
	if len(cv.Members) == 0 {
		delete(c.convs, cv.ID)
		os.Remove(filepath.Join(c.dir, cv.ID+".jsonl"))
	} else {
		m := &Message{From: me, Sys: true, Text: me + " left the group"}
		c.appendMsg(cv, m)
		c.notify(cv, m, me)
	}
	c.saveLocked()
	writeJSON(w, 200, map[string]bool{"ok": true})
}

// GET /api/chat/{id}/messages?before=<seq>&limit=50
func (s *Server) handleChatMessages(w http.ResponseWriter, r *http.Request) {
	c := s.chat
	c.mu.Lock()
	cv := s.convFor(w, r)
	if cv == nil {
		c.mu.Unlock()
		return
	}
	before, _ := strconv.ParseInt(r.URL.Query().Get("before"), 10, 64)
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	msgs := c.messages(cv, before, limit)
	v := c.view(cv, userOf(r))
	c.mu.Unlock()
	writeJSON(w, 200, map[string]any{"conversation": v, "messages": msgs})
}

// POST /api/chat/{id}/messages {"text", "ref"?: {path, title, sub, image, kind}}
func (s *Server) handleChatSend(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Text string
		Ref  *Ref
	}
	if !decodeJSON(w, r, &b) {
		return
	}
	me := userOf(r)
	text := strings.TrimSpace(b.Text)
	if len(text) > 4000 {
		text = text[:4000]
	}
	if text == "" && b.Ref == nil {
		httpErr(w, 400, "empty message")
		return
	}
	if err := s.chat.allow(me); err != nil {
		httpErr(w, 429, err.Error())
		return
	}
	var cannot []string
	if b.Ref != nil {
		lib := strings.SplitN(b.Ref.Path, "/", 2)[0]
		if b.Ref.Path == "" || !s.canAccess(r, lib) {
			httpErr(w, 400, "you can't share that")
			return
		}
		b.Ref.Title, b.Ref.Sub, b.Ref.Image = clip(b.Ref.Title, 200), clip(b.Ref.Sub, 200), clip(b.Ref.Image, 500)
		if b.Ref.Kind != "music" {
			b.Ref.Kind = "video"
		}
		s.chat.mu.Lock()
		if cv := s.chat.convs[r.PathValue("id")]; cv != nil {
			for _, m := range cv.Members {
				if m != me && !s.userCanAccess(m, s.users.IsAdmin(m), lib) {
					cannot = append(cannot, m)
				}
			}
		}
		s.chat.mu.Unlock()
	}
	c := s.chat
	c.mu.Lock()
	defer c.mu.Unlock()
	cv := s.convFor(w, r)
	if cv == nil {
		return
	}
	m := &Message{From: me, Text: text, Ref: b.Ref}
	if err := c.appendMsg(cv, m); err != nil {
		httpErr(w, 500, err.Error())
		return
	}
	c.saveLocked()
	c.notify(cv, m)
	out := map[string]any{"message": m}
	if len(cannot) > 0 {
		out["warning"] = strings.Join(cannot, ", ") + " can't open it (no access to that library)"
	}
	writeJSON(w, 200, out)
}

// allow: at most 20 messages per 10 seconds per user.
func (c *Chat) allow(user string) error {
	c.pmu.Lock()
	defer c.pmu.Unlock()
	now := time.Now()
	recent := c.rate[user][:0]
	for _, t := range c.rate[user] {
		if now.Sub(t) < 10*time.Second {
			recent = append(recent, t)
		}
	}
	if len(recent) >= 20 {
		c.rate[user] = recent
		return errors.New("slow down a little")
	}
	c.rate[user] = append(recent, now)
	return nil
}

// POST /api/chat/{id}/read {"seq": n}
func (s *Server) handleChatRead(w http.ResponseWriter, r *http.Request) {
	var b struct{ Seq int64 }
	if !decodeJSON(w, r, &b) {
		return
	}
	me := userOf(r)
	c := s.chat
	c.mu.Lock()
	defer c.mu.Unlock()
	cv := s.convFor(w, r)
	if cv == nil {
		return
	}
	if b.Seq > cv.Seq || b.Seq <= 0 {
		b.Seq = cv.Seq
	}
	if b.Seq > cv.Read[me] {
		cv.Read[me] = b.Seq
		c.saveLocked()
		c.send(me, "conversation", c.view(cv, me))
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}
