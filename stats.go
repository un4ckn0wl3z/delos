package main

// Who watches / listens the most: time per user per day, a leaderboard and badges.
//
// Watch time comes from the player's progress saves (the position moving forward
// while playing), listen time from the "now listening" heartbeats. Paused or idle
// time isn't counted, and jumps (seeking) count only the wall-clock time between saves.

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"sync"
	"time"
)

type DayStat struct {
	Video  float64 `json:"v,omitempty"` // seconds watched
	Music  float64 `json:"m,omitempty"` // seconds listened
	Titles int     `json:"t,omitempty"` // movies / episodes watched to the end
	Songs  int     `json:"s,omitempty"` // songs started
}

type Stats struct {
	mu    sync.Mutex
	file  string
	Days  map[string]map[string]*DayStat `json:"days"`     // user → "2006-01-02" → stats
	Done  map[string]map[string]int64    `json:"finished"` // user → path → when it was first watched to the end
	dirty bool
	// live: last progress save / music beat per user
	lastV map[string]statMark
	lastM map[string]statMark
}

type statMark struct {
	path string
	pos  float64
	at   time.Time
}

func NewStats(dataDir string) *Stats {
	st := &Stats{file: filepath.Join(dataDir, "stats.json"), Days: map[string]map[string]*DayStat{}, Done: map[string]map[string]int64{},
		lastV: map[string]statMark{}, lastM: map[string]statMark{}}
	if b, err := os.ReadFile(st.file); err == nil {
		if err := json.Unmarshal(b, st); err != nil {
			log.Printf("stats: %v", err)
		}
	}
	if st.Days == nil {
		st.Days = map[string]map[string]*DayStat{}
	}
	if st.Done == nil {
		st.Done = map[string]map[string]int64{}
	}
	go func() {
		for range time.Tick(time.Minute) {
			st.save()
		}
	}()
	return st
}

func (st *Stats) save() {
	st.mu.Lock()
	defer st.mu.Unlock()
	if !st.dirty {
		return
	}
	b, err := json.Marshal(st)
	if err != nil {
		return
	}
	if os.WriteFile(st.file+".tmp", b, 0o600) == nil && os.Rename(st.file+".tmp", st.file) == nil {
		st.dirty = false
	}
}

func (st *Stats) dayLocked(user string, t time.Time) *DayStat {
	d := st.Days[user]
	if d == nil {
		d = map[string]*DayStat{}
		st.Days[user] = d
	}
	k := t.Format("2006-01-02")
	if d[k] == nil {
		d[k] = &DayStat{}
	}
	st.dirty = true
	return d[k]
}

// Video: a progress save. Counts how far playback moved since the last save of the same file,
// at most the wall-clock time in between (so seeking ahead doesn't count).
func (st *Stats) Video(user, path string, pos, dur float64, done bool) {
	now := time.Now()
	st.mu.Lock()
	defer st.mu.Unlock()
	last := st.lastV[user]
	st.lastV[user] = statMark{path, pos, now}
	if last.path == path {
		wall := now.Sub(last.at).Seconds()
		if d := pos - last.pos; d > 0 && wall < 180 {
			if d > wall+5 {
				d = wall + 5
			}
			st.dayLocked(user, now).Video += d
		}
	}
	if (done || (dur > 0 && pos > dur*0.9)) && st.Done[user][path] == 0 {
		if st.Done[user] == nil {
			st.Done[user] = map[string]int64{}
		}
		st.Done[user][path] = now.Unix()
		st.dayLocked(user, now).Titles++
	}
}

// Music: a "now listening" heartbeat (only sent while playing). nil = stopped / paused.
func (st *Stats) Music(user string, a *Activity) {
	now := time.Now()
	st.mu.Lock()
	defer st.mu.Unlock()
	last, had := st.lastM[user]
	if a == nil || a.Kind != "music" {
		if had {
			// credit the time since the last beat (up to one heartbeat interval)
			if wall := now.Sub(last.at).Seconds(); wall < 45 {
				st.dayLocked(user, now).Music += wall
			}
			delete(st.lastM, user)
		}
		return
	}
	key := a.Path + "\x00" + a.Title
	if had {
		if wall := now.Sub(last.at).Seconds(); wall < 45 {
			st.dayLocked(user, now).Music += wall
		}
	}
	if !had || last.path != key {
		st.dayLocked(user, now).Songs++
	}
	st.lastM[user] = statMark{path: key, at: now}
}

// ---------------------------------------------------------------- leaderboard

type RankRow struct {
	User   string  `json:"user"`
	Video  float64 `json:"video"`
	Music  float64 `json:"music"`
	Titles int     `json:"titles"`
	Songs  int     `json:"songs"`
}

type Badge struct {
	ID   string `json:"id"`
	Icon string `json:"icon"`
	Name string `json:"name"`
	Desc string `json:"desc"`
}

func periodStart(period string, now time.Time) string {
	switch period {
	case "week":
		wd := (int(now.Weekday()) + 6) % 7 // Monday = 0
		return now.AddDate(0, 0, -wd).Format("2006-01-02")
	case "month":
		return now.Format("2006-01") + "-01"
	case "year":
		return now.Format("2006") + "-01-01"
	}
	return ""
}

func (st *Stats) totalsLocked(from string) map[string]*RankRow {
	out := map[string]*RankRow{}
	for u, days := range st.Days {
		r := &RankRow{User: u}
		for k, d := range days {
			if k < from {
				continue
			}
			r.Video += d.Video
			r.Music += d.Music
			r.Titles += d.Titles
			r.Songs += d.Songs
		}
		out[u] = r
	}
	return out
}

// streak: days in a row (ending today or yesterday) with at least 10 minutes of watching / listening
func (st *Stats) streakLocked(user string, now time.Time) int {
	days := st.Days[user]
	n := 0
	t := now
	if d := days[t.Format("2006-01-02")]; d == nil || d.Video+d.Music < 600 {
		t = t.AddDate(0, 0, -1)
	}
	for {
		d := days[t.Format("2006-01-02")]
		if d == nil || d.Video+d.Music < 600 {
			return n
		}
		n++
		t = t.AddDate(0, 0, -1)
	}
}

var hourBadges = []struct {
	hours             float64
	vID, vIcon, vName string
	mID, mIcon, mName string
}{
	{1, "v1", "🍿", "Popcorn", "m1", "🎧", "Listener"},
	{10, "v10", "🎬", "Movie buff", "m10", "🎵", "Music lover"},
	{50, "v50", "🎞️", "Cinephile", "m50", "🎼", "Audiophile"},
	{200, "v200", "🏛️", "Film legend", "m200", "💿", "Vinyl legend"},
	{1000, "v1000", "🌌", "Lives at the cinema", "m1000", "🌠", "Living soundtrack"},
}

func (st *Stats) badgesLocked(now time.Time, hidden func(string) bool) map[string][]Badge {
	all := st.totalsLocked("")
	month := st.totalsLocked(periodStart("month", now))
	out := map[string][]Badge{}
	topOf := func(get func(*RankRow) float64, min float64) string {
		best, who := min, ""
		for u, r := range month {
			if !hidden(u) && get(r) > best {
				best, who = get(r), u
			}
		}
		return who
	}
	if u := topOf(func(r *RankRow) float64 { return r.Video }, 60); u != "" {
		out[u] = append(out[u], Badge{"top-video", "👑", "Top watcher", "Watched the most this month"})
	}
	if u := topOf(func(r *RankRow) float64 { return r.Music }, 60); u != "" {
		out[u] = append(out[u], Badge{"top-music", "🎤", "Top listener", "Listened the most this month"})
	}
	for u, r := range all {
		if hidden(u) {
			continue
		}
		var v, m *Badge
		for _, b := range hourBadges {
			if r.Video >= b.hours*3600 {
				v = &Badge{b.vID, b.vIcon, b.vName, "Watched " + hoursText(b.hours) + " in total"}
			}
			if r.Music >= b.hours*3600 {
				m = &Badge{b.mID, b.mIcon, b.mName, "Listened " + hoursText(b.hours) + " in total"}
			}
		}
		if v != nil {
			out[u] = append(out[u], *v)
		}
		if m != nil {
			out[u] = append(out[u], *m)
		}
		if r.Titles >= 100 {
			out[u] = append(out[u], Badge{"titles100", "📼", "Completionist", "Finished 100 movies / episodes"})
		} else if r.Titles >= 25 {
			out[u] = append(out[u], Badge{"titles25", "📺", "Binge watcher", "Finished 25 movies / episodes"})
		}
		if r.Songs >= 1000 {
			out[u] = append(out[u], Badge{"songs1000", "📻", "Jukebox", "Played 1000 songs"})
		}
		if s := st.streakLocked(u, now); s >= 7 {
			out[u] = append(out[u], Badge{"streak", "🔥", strconv.Itoa(s) + "-day streak", "Watched or listened every day for " + strconv.Itoa(s) + " days"})
		}
	}
	return out
}

func hoursText(h float64) string {
	if h == 1 {
		return "1 hour"
	}
	return strconv.Itoa(int(h)) + " hours"
}

// Badges by user (for the people list); people who hide their activity get none.
func (s *Server) userBadges() map[string][]Badge {
	st := s.stats
	st.mu.Lock()
	defer st.mu.Unlock()
	return st.badgesLocked(time.Now(), s.users.HidesActivity)
}

func (s *Server) statsRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/ranking", s.auth(s.handleRanking))
}

// GET /api/ranking?period=week|month|year|all
func (s *Server) handleRanking(w http.ResponseWriter, r *http.Request) {
	period := r.URL.Query().Get("period")
	if periodStart(period, time.Now()) == "" {
		period = "all"
	}
	now := time.Now()
	st := s.stats
	st.mu.Lock()
	tot := st.totalsLocked(periodStart(period, now))
	badges := st.badgesLocked(now, s.users.HidesActivity)
	me := userOf(r)
	var mine *RankRow
	if t := tot[me]; t != nil {
		c := *t
		mine = &c
	} else {
		mine = &RankRow{User: me}
	}
	streak := st.streakLocked(me, now)
	st.mu.Unlock()

	var rows []RankRow
	for u, t := range tot {
		if !s.users.Exists(u) || s.users.HidesActivity(u) || t.Video+t.Music < 1 {
			continue
		}
		rows = append(rows, *t)
	}
	top := func(get func(RankRow) float64) []RankRow {
		l := make([]RankRow, 0, len(rows))
		for _, r := range rows {
			if get(r) >= 1 {
				l = append(l, r)
			}
		}
		sort.Slice(l, func(i, j int) bool { return get(l[i]) > get(l[j]) || (get(l[i]) == get(l[j]) && l[i].User < l[j].User) })
		if len(l) > 50 {
			l = l[:50]
		}
		return l
	}
	vis := map[string][]Badge{}
	for u, b := range badges {
		if s.users.Exists(u) {
			vis[u] = b
		}
	}
	writeJSON(w, 200, map[string]any{
		"period": period,
		"video":  top(func(r RankRow) float64 { return r.Video }),
		"music":  top(func(r RankRow) float64 { return r.Music }),
		"badges": vis,
		"me":     mine,
		"streak": streak,
		"hidden": s.users.HidesActivity(me),
		"tiers":  hourBadges2(),
	})
}

// the ladder, so the apps can show "next badge at …"
func hourBadges2() []map[string]any {
	var out []map[string]any
	for _, b := range hourBadges {
		out = append(out, map[string]any{"hours": b.hours, "video": b.vIcon + " " + b.vName, "music": b.mIcon + " " + b.mName})
	}
	return out
}
