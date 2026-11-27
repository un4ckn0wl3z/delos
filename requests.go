package main

// Requests: users search TMDB for a film or a series that isn't in any library
// and ask for it; others can vote for the same title. An admin approves or
// declines it, and once the title shows up in a library (after a scan) the
// request turns "available" by itself. The people who asked or voted get a
// live notice (event "request") and see the state on the Requests page.

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	ReqPending   = "pending"
	ReqApproved  = "approved"
	ReqDeclined  = "declined"
	ReqAvailable = "available"
)

type MediaRequest struct {
	ID       string   `json:"id"`
	Kind     string   `json:"kind"` // movie | tv
	TMDBID   int      `json:"tmdbId"`
	Title    string   `json:"title"`
	Year     int      `json:"year,omitempty"`
	Poster   string   `json:"poster,omitempty"`
	Overview string   `json:"overview,omitempty"`
	By       string   `json:"by"`
	Votes    []string `json:"votes"` // users who want it too (the requester included)
	Status   string   `json:"status"`
	Note     string   `json:"note,omitempty"` // from the admin, e.g. why it was declined
	Created  int64    `json:"created"`
	Updated  int64    `json:"updated"`
	StatusAt int64    `json:"statusAt,omitempty"` // when the status last changed (for "new" marks)
	Lib      string   `json:"lib,omitempty"`      // where it landed
	Where    string   `json:"where,omitempty"`    // movie: item path · tv: show key
}

type Requests struct {
	s    *Server
	path string
	mu   sync.Mutex
	list []*MediaRequest
	seen map[string]int64 // user → when they last looked at the Requests page
}

func NewRequests(s *Server) *Requests {
	q := &Requests{s: s, path: filepath.Join(s.cfg.DataDir, "requests.json"), seen: map[string]int64{}}
	if b, err := os.ReadFile(q.path); err == nil {
		json.Unmarshal(b, &q.list)
	}
	if b, err := os.ReadFile(q.seenPath()); err == nil {
		json.Unmarshal(b, &q.seen)
	}
	return q
}

func (q *Requests) seenPath() string { return strings.TrimSuffix(q.path, ".json") + "-seen.json" }

// isNew: something happened to a request u asked or voted for since u last looked.
func (q *Requests) isNewLocked(x *MediaRequest, u string) bool {
	return x.StatusAt > q.seen[u] && slices.Contains(x.Votes, u)
}

// Counts for the menu badge: changes the user hasn't seen, and (admins) requests waiting.
func (q *Requests) Counts(u string, admin bool) (unread, pending int) {
	q.mu.Lock()
	defer q.mu.Unlock()
	for _, x := range q.list {
		if q.isNewLocked(x, u) {
			unread++
		}
		if admin && x.Status == ReqPending {
			pending++
		}
	}
	return
}

func (q *Requests) markSeen(u string) {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.seen[u] = time.Now().Unix()
	b, _ := json.Marshal(q.seen)
	tmp := q.seenPath() + ".tmp"
	if os.WriteFile(tmp, b, 0o600) == nil {
		os.Rename(tmp, q.seenPath())
	}
}

func (q *Requests) saveLocked() {
	b, _ := json.MarshalIndent(q.list, "", " ")
	tmp := q.path + ".tmp"
	if os.WriteFile(tmp, b, 0o600) == nil {
		os.Rename(tmp, q.path)
	}
}

func (q *Requests) find(id string) *MediaRequest {
	for _, x := range q.list {
		if x.ID == id {
			return x
		}
	}
	return nil
}

func (q *Requests) byTMDB(kind string, id int) *MediaRequest {
	for _, x := range q.list {
		if x.Kind == kind && x.TMDBID == id {
			return x
		}
	}
	return nil
}

// owned: TMDB id → where it is, over every library (kind "movie" or "tv").
type ownedAt struct{ Lib, Where string }

func (ix *Indexer) OwnedTMDB() (movies, shows map[int]ownedAt) {
	movies, shows = map[int]ownedAt{}, map[int]ownedAt{}
	ix.mu.RLock()
	defer ix.mu.RUnlock()
	for id, li := range ix.libs {
		for _, it := range li.Items {
			if it.Show == "" && it.MovieID > 0 {
				if _, ok := movies[it.MovieID]; !ok {
					movies[it.MovieID] = ownedAt{id, it.Path}
				}
			}
		}
		for k, sm := range li.Shows {
			if sm != nil && sm.TMDBID > 0 {
				if _, ok := shows[sm.TMDBID]; !ok {
					shows[sm.TMDBID] = ownedAt{id, k}
				}
			}
		}
	}
	return
}

// notify tells everyone who asked for it that something changed.
func (q *Requests) notify(x *MediaRequest, actor string) {
	ev := map[string]any{"id": x.ID, "title": x.Title, "year": x.Year, "status": x.Status, "note": x.Note, "lib": x.Lib, "where": x.Where, "kind": x.Kind}
	for _, u := range x.Votes {
		if u != actor {
			q.s.chat.send(u, "request", ev)
		}
	}
}

// CheckAvailable marks requests whose title is now in a library (run after scans).
func (q *Requests) CheckAvailable() {
	movies, shows := q.s.index.OwnedTMDB()
	q.mu.Lock()
	var done []*MediaRequest
	changed := false
	for _, x := range q.list {
		if x.Status == ReqDeclined || (x.Status == ReqAvailable && x.Lib != "") {
			continue
		}
		at, ok := movies[x.TMDBID]
		if x.Kind == "tv" {
			at, ok = shows[x.TMDBID]
		}
		if !ok {
			continue
		}
		was := x.Status
		x.Status, x.Lib, x.Where, x.Updated = ReqAvailable, at.Lib, at.Where, time.Now().Unix()
		if was != ReqAvailable {
			x.StatusAt = x.Updated
		}
		if was != ReqAvailable { // marked by hand: they were told then
			done = append(done, x)
		} else {
			changed = true
		}
	}
	if len(done) > 0 || changed {
		q.saveLocked()
	}
	q.mu.Unlock()
	for _, x := range done {
		q.notify(x, "")
	}
}

type requestView struct {
	*MediaRequest
	VoteCount int  `json:"voteCount"`
	Voted     bool `json:"voted"`
	Mine      bool `json:"mine"`
	CanOpen   bool `json:"canOpen"` // available in a library this user can see
	New       bool `json:"new"`     // changed since this user last looked
}

func (s *Server) requestRoutes(mux *http.ServeMux) {
	q := s.requests
	// the admin can turn requests off; the list stays, nothing new comes in
	on := func(h http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			if s.settings.Get().RequestsOff && !isAdmin(r) {
				httpErr(w, 404, "requests are turned off on this server")
				return
			}
			h(w, r)
		}
	}
	view := func(r *http.Request, x *MediaRequest) requestView {
		u := userOf(r)
		c := *x
		c.Votes = slices.Clone(x.Votes)
		if !isAdmin(r) {
			c.Votes = nil // who voted is the admin's business
		}
		return requestView{MediaRequest: &c, VoteCount: len(x.Votes), Voted: slices.Contains(x.Votes, u), Mine: x.By == u,
			CanOpen: x.Status == ReqAvailable && x.Lib != "" && s.canAccess(r, x.Lib), New: q.isNewLocked(x, u)}
	}

	// menu badge: {unread, pending}
	mux.HandleFunc("GET /api/requests/counts", s.auth(func(w http.ResponseWriter, r *http.Request) {
		if s.settings.Get().RequestsOff {
			writeJSON(w, 200, map[string]int{"unread": 0, "pending": 0})
			return
		}
		u, p := q.Counts(userOf(r), isAdmin(r))
		writeJSON(w, 200, map[string]int{"unread": u, "pending": p})
	}))
	// the user has looked at the Requests page: their "new" marks are read
	mux.HandleFunc("POST /api/requests/seen", s.auth(func(w http.ResponseWriter, r *http.Request) {
		q.markSeen(userOf(r))
		writeJSON(w, 200, map[string]any{"ok": true})
	}))

	mux.HandleFunc("GET /api/requests", s.auth(on(func(w http.ResponseWriter, r *http.Request) {
		q.mu.Lock()
		out := make([]requestView, 0, len(q.list))
		for _, x := range q.list {
			out = append(out, view(r, x))
		}
		q.mu.Unlock()
		// open ones first (most wanted on top), then the rest by last change
		rank := map[string]int{ReqPending: 0, ReqApproved: 1, ReqAvailable: 2, ReqDeclined: 3}
		sort.SliceStable(out, func(i, j int) bool {
			a, b := out[i], out[j]
			if rank[a.Status] != rank[b.Status] {
				return rank[a.Status] < rank[b.Status]
			}
			if a.Status == ReqPending && a.VoteCount != b.VoteCount {
				return a.VoteCount > b.VoteCount
			}
			return a.Updated > b.Updated
		})
		writeJSON(w, 200, map[string]any{"requests": out, "tmdb": s.index.tmdb() != nil, "manage": isAdmin(r)})
	})))

	// TMDB search, each result marked: already here / already asked for
	mux.HandleFunc("GET /api/requests/search", s.auth(on(func(w http.ResponseWriter, r *http.Request) {
		tm := s.index.tmdb()
		if tm == nil {
			httpErr(w, 400, "no TMDB API key — an admin can add one in the dashboard")
			return
		}
		kind := r.URL.Query().Get("kind")
		if kind != "tv" {
			kind = "movie"
		}
		text := strings.TrimSpace(r.URL.Query().Get("q"))
		if text == "" {
			writeJSON(w, 200, map[string]any{"results": []any{}})
			return
		}
		yr := 0
		// "Dune 2021" → year filter
		if f := strings.Fields(text); len(f) > 1 {
			if n, err := strconv.Atoi(f[len(f)-1]); err == nil && n > 1880 && n < 2100 {
				yr, text = n, strings.Join(f[:len(f)-1], " ")
			}
		}
		res, err := tm.SearchList(kind, text, yr)
		if err != nil {
			httpErr(w, 502, err.Error())
			return
		}
		movies, shows := s.index.OwnedTMDB()
		own := movies
		if kind == "tv" {
			own = shows
		}
		type hit struct {
			SearchResult
			Kind    string       `json:"kind"`
			Have    bool         `json:"have"`
			Lib     string       `json:"lib,omitempty"`
			Where   string       `json:"where,omitempty"`
			Request *requestView `json:"request,omitempty"`
		}
		out := []hit{}
		q.mu.Lock()
		for _, x := range res {
			h := hit{SearchResult: x, Kind: kind}
			if at, ok := own[x.ID]; ok && s.canAccess(r, at.Lib) {
				h.Have, h.Lib, h.Where = true, at.Lib, at.Where
			}
			if rq := q.byTMDB(kind, x.ID); rq != nil {
				v := view(r, rq)
				h.Request = &v
			}
			out = append(out, h)
		}
		q.mu.Unlock()
		writeJSON(w, 200, map[string]any{"results": out})
	})))

	// ask for a title (or vote for it when someone already did)
	mux.HandleFunc("POST /api/requests", s.auth(on(func(w http.ResponseWriter, r *http.Request) {
		var b struct {
			Kind   string `json:"kind"`
			TMDBID int    `json:"tmdbId"`
		}
		if !decodeJSON(w, r, &b) {
			return
		}
		if b.Kind != "tv" {
			b.Kind = "movie"
		}
		u := userOf(r)
		q.mu.Lock()
		if x := q.byTMDB(b.Kind, b.TMDBID); x != nil {
			if !slices.Contains(x.Votes, u) {
				x.Votes = append(x.Votes, u)
				q.saveLocked()
			}
			v := view(r, x)
			q.mu.Unlock()
			writeJSON(w, 200, v)
			return
		}
		mine := 0
		for _, x := range q.list {
			if x.By == u && x.Status == ReqPending {
				mine++
			}
		}
		q.mu.Unlock()
		if mine >= 50 && !isAdmin(r) {
			httpErr(w, 429, "you already have 50 open requests")
			return
		}
		tm := s.index.tmdb()
		if tm == nil || b.TMDBID <= 0 {
			httpErr(w, 400, "no TMDB API key — an admin can add one in the dashboard")
			return
		}
		movies, shows := s.index.OwnedTMDB()
		own := movies
		if b.Kind == "tv" {
			own = shows
		}
		if at, ok := own[b.TMDBID]; ok && s.canAccess(r, at.Lib) {
			httpErr(w, 409, "this is already in a library")
			return
		}
		// the title, year and poster come from TMDB, not from the client
		x := &MediaRequest{ID: newReqID(), Kind: b.Kind, TMDBID: b.TMDBID, By: u, Votes: []string{u}, Status: ReqPending,
			Created: time.Now().Unix(), Updated: time.Now().Unix()}
		if b.Kind == "tv" {
			m, err := tm.TV(b.TMDBID)
			if err != nil {
				httpErr(w, 502, err.Error())
				return
			}
			x.Title, x.Year, x.Poster, x.Overview = m.Title, m.Year, m.Poster, m.Overview
		} else {
			m, err := tm.Movie(b.TMDBID)
			if err != nil {
				httpErr(w, 502, err.Error())
				return
			}
			x.Title, x.Year, x.Poster, x.Overview = m.Title, m.Year, m.Poster, m.Overview
		}
		q.mu.Lock()
		if y := q.byTMDB(b.Kind, b.TMDBID); y != nil { // someone was faster
			if !slices.Contains(y.Votes, u) {
				y.Votes = append(y.Votes, u)
			}
			x = y
		} else {
			q.list = append(q.list, x)
		}
		q.saveLocked()
		v := view(r, x)
		q.mu.Unlock()
		for _, a := range s.users.List() {
			if a.Admin && a.Name != u {
				s.chat.send(a.Name, "request-new", map[string]any{"id": x.ID, "title": x.Title, "year": x.Year, "by": u})
			}
		}
		writeJSON(w, 200, v)
	})))

	mux.HandleFunc("POST /api/requests/{id}/vote", s.auth(on(func(w http.ResponseWriter, r *http.Request) {
		var b struct {
			On bool `json:"on"`
		}
		if !decodeJSON(w, r, &b) {
			return
		}
		u := userOf(r)
		q.mu.Lock()
		defer q.mu.Unlock()
		x := q.find(r.PathValue("id"))
		if x == nil {
			httpErr(w, 404, "no such request")
			return
		}
		has := slices.Contains(x.Votes, u)
		switch {
		case b.On && !has:
			x.Votes = append(x.Votes, u)
		case !b.On && has && x.By != u: // the requester withdraws by deleting it
			x.Votes = slices.DeleteFunc(x.Votes, func(v string) bool { return v == u })
		}
		q.saveLocked()
		writeJSON(w, 200, view(r, x))
	})))

	// the requester may withdraw an open request; an admin may delete any
	mux.HandleFunc("DELETE /api/requests/{id}", s.auth(on(func(w http.ResponseWriter, r *http.Request) {
		q.mu.Lock()
		defer q.mu.Unlock()
		x := q.find(r.PathValue("id"))
		if x == nil {
			httpErr(w, 404, "no such request")
			return
		}
		if !isAdmin(r) && !(x.By == userOf(r) && x.Status == ReqPending) {
			httpErr(w, 403, "only the requester (while it's open) or an admin can remove it")
			return
		}
		q.list = slices.DeleteFunc(q.list, func(y *MediaRequest) bool { return y == x })
		q.saveLocked()
		writeJSON(w, 200, map[string]any{"ok": true})
	})))

	mux.HandleFunc("POST /api/requests/{id}/status", s.adminOnly(func(w http.ResponseWriter, r *http.Request) {
		var b struct {
			Status string `json:"status"`
			Note   string `json:"note"`
		}
		if !decodeJSON(w, r, &b) {
			return
		}
		switch b.Status {
		case ReqPending, ReqApproved, ReqDeclined, ReqAvailable:
		default:
			httpErr(w, 400, "status must be pending, approved, declined or available")
			return
		}
		q.mu.Lock()
		x := q.find(r.PathValue("id"))
		if x == nil {
			q.mu.Unlock()
			httpErr(w, 404, "no such request")
			return
		}
		if x.Status != b.Status || x.Note != strings.TrimSpace(b.Note) {
			x.StatusAt = time.Now().Unix()
		}
		x.Status, x.Note, x.Updated = b.Status, strings.TrimSpace(b.Note), time.Now().Unix()
		if len(x.Note) > 500 {
			x.Note = x.Note[:500]
		}
		if b.Status != ReqAvailable {
			x.Lib, x.Where = "", ""
		}
		q.saveLocked()
		v := view(r, x)
		c := *x
		q.mu.Unlock()
		if b.Status == ReqAvailable && c.Lib == "" {
			go q.CheckAvailable() // fill in where it is, if it's there already
		}
		q.notify(&c, userOf(r))
		writeJSON(w, 200, v)
	}))
}

func newReqID() string {
	b := make([]byte, 8)
	rand.Read(b)
	return hex.EncodeToString(b)
}
