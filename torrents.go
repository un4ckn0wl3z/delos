package main

import (
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Torrent management: seed / stop seeding / pause / resume / recheck,
// remove (keep files) or remove with data, per-torrent and default seeding
// limits, and — for admins — every torrent in rtorrent, not just StreamMKV's.

func (s *Server) torrentRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/downloads/{id}/torrent", s.downloader(s.handleJobTorrentAction))
	mux.HandleFunc("POST /api/downloads/{id}/seed", s.downloader(s.handleJobSeedLimit))
	mux.HandleFunc("GET /api/downloads/{id}/detail", s.downloader(s.handleJobTorrentDetail))
	mux.HandleFunc("GET /api/admin/torrents", s.adminOnly(s.handleAdminTorrents))
	mux.HandleFunc("GET /api/admin/torrents/{hash}", s.adminOnly(s.handleAdminTorrentDetail))
	mux.HandleFunc("POST /api/admin/torrents/{hash}", s.adminOnly(s.handleAdminTorrentAction))
	mux.HandleFunc("POST /api/admin/torrents/throttle", s.adminOnly(s.handleAdminThrottle))
	mux.HandleFunc("GET /api/admin/torrents/orphans", s.adminOnly(s.handleOrphans))
	mux.HandleFunc("POST /api/admin/torrents/orphans/delete", s.adminOnly(s.handleOrphansDelete))
}

// dataPath: where a torrent's files are. rtorrent clears d.base_path while a
// torrent is closed, so fall back to d.directory (+ name for single files).
func (it rtItem) dataPath() string {
	if it.BasePath != "" {
		return it.BasePath
	}
	if it.Dir == "" {
		return ""
	}
	if it.Multi {
		return it.Dir
	}
	return filepath.Join(it.Dir, it.Name)
}

// deletablePath refuses anything that isn't clearly this torrent's own data.
func (s *Server) deletablePath(p, name string) (string, error) {
	if p == "" || name == "" {
		return "", errors.New("rtorrent doesn't say where this torrent's files are")
	}
	p = filepath.Clean(p)
	if !filepath.IsAbs(p) || filepath.Base(p) != name {
		return "", errors.New("refusing to delete " + p + ": it doesn't look like this torrent's own folder/file")
	}
	home, _ := os.UserHomeDir()
	protected := []string{"/", home, filepath.Dir(home), s.userLibRoot()}
	for _, l := range s.libs.List() {
		protected = append(protected, l.Path)
	}
	for _, x := range protected {
		if x != "" && filepath.Clean(x) == p {
			return "", errors.New("refusing to delete " + p)
		}
	}
	if strings.Count(p, string(filepath.Separator)) < 2 {
		return "", errors.New("refusing to delete " + p)
	}
	return p, nil
}

// libOfPath: the library a path lies in (to rescan after deleting).
func (s *Server) libOfPath(p string) string {
	for _, l := range s.libs.List() {
		if rel, err := filepath.Rel(l.Path, p); err == nil && !strings.HasPrefix(rel, "..") {
			return l.ID
		}
	}
	return ""
}

func (d *Downloads) item(hash string) (*RTorrent, rtItem, error) {
	rt, err := d.rt()
	if err != nil {
		return nil, rtItem{}, err
	}
	items, err := rt.List()
	if err != nil {
		return nil, rtItem{}, err
	}
	for _, it := range items {
		if strings.EqualFold(it.Hash, hash) {
			return rt, it, nil
		}
	}
	return rt, rtItem{}, errors.New("rtorrent doesn't have this torrent any more")
}

var torrentActions = map[string]bool{"start": true, "stop": true, "pause": true, "resume": true, "recheck": true}

func (s *Server) jobCopy(id string) any {
	s.dl.mu.Lock()
	defer s.dl.mu.Unlock()
	if j := s.dl.jobs[id]; j != nil {
		c := *j
		c.Saved = c.BasePath
		return c
	}
	return nil
}

// POST /api/downloads/{id}/torrent {"action": start|stop|pause|resume|recheck}
func (s *Server) handleJobTorrentAction(w http.ResponseWriter, r *http.Request) {
	j := s.jobFor(w, r)
	if j == nil {
		return
	}
	var b struct{ Action string }
	if !decodeJSON(w, r, &b) {
		return
	}
	if j.Kind != "torrent" || j.Hash == "" {
		httpErr(w, 400, "not a torrent (or rtorrent hasn't picked it up yet)")
		return
	}
	if !torrentActions[b.Action] {
		httpErr(w, 400, "action must be start, stop, pause, resume or recheck")
		return
	}
	rt, err := s.dl.rt()
	if err == nil {
		err = rt.Do(j.Hash, b.Action)
	}
	if err != nil {
		httpErr(w, 502, err.Error())
		return
	}
	time.Sleep(300 * time.Millisecond)
	s.dl.syncTorrents()
	writeJSON(w, 200, s.jobCopy(j.ID))
}

// POST /api/downloads/{id}/seed {"ratio": 2, "hours": 48} — 0 = server default, -1 = no limit
func (s *Server) handleJobSeedLimit(w http.ResponseWriter, r *http.Request) {
	j := s.jobFor(w, r)
	if j == nil {
		return
	}
	var b struct{ Ratio, Hours float64 }
	if !decodeJSON(w, r, &b) {
		return
	}
	if b.Ratio < -1 || b.Ratio > 1000 || b.Hours < -1 || b.Hours > 24*365 {
		httpErr(w, 400, "ratio 0–1000, hours 0–8760 (0 = default, -1 = no limit)")
		return
	}
	s.dl.update(j.ID, func(x *DownloadJob) {
		x.SeedRatio, x.SeedHours = b.Ratio, b.Hours
		x.AutoStopped = "" // the new limit applies from now
	})
	s.dl.syncTorrents()
	writeJSON(w, 200, s.jobCopy(j.ID))
}

// GET /api/downloads/{id}/detail → trackers + files
func (s *Server) handleJobTorrentDetail(w http.ResponseWriter, r *http.Request) {
	j := s.jobFor(w, r)
	if j == nil {
		return
	}
	if j.Kind != "torrent" || j.Hash == "" {
		httpErr(w, 400, "not a torrent")
		return
	}
	s.writeTorrentDetail(w, j.Hash)
}

func (s *Server) writeTorrentDetail(w http.ResponseWriter, hash string) {
	rt, err := s.dl.rt()
	if err != nil {
		httpErr(w, 502, err.Error())
		return
	}
	trs, files, err := rt.Detail(hash)
	if err != nil {
		httpErr(w, 502, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"trackers": trs, "files": files})
}

type torrentView struct {
	Hash       string         `json:"hash"`
	Name       string         `json:"name"`
	Status     string         `json:"status"`
	Size       int64          `json:"size"`
	Done       int64          `json:"done"`
	Ratio      float64        `json:"ratio"`
	Uploaded   int64          `json:"uploaded"`
	Downloaded int64          `json:"downloaded"`
	Up         int64          `json:"up"`
	Down       int64          `json:"down"`
	Peers      int            `json:"peers"`
	Seeds      int            `json:"seeds"`
	Files      int            `json:"files"`
	Path       string         `json:"path"`
	Label      string         `json:"label,omitempty"`
	Message    string         `json:"message,omitempty"`
	Added      int64          `json:"added,omitempty"`
	Finished   int64          `json:"finished,omitempty"`
	Job        map[string]any `json:"job,omitempty"` // added through StreamMKV
}

// GET /api/admin/torrents — everything in rtorrent
func (s *Server) handleAdminTorrents(w http.ResponseWriter, r *http.Request) {
	st := s.dl.TorrentStatus(false)
	rt, err := s.dl.rt()
	var items []rtItem
	if err == nil {
		items, err = rt.List()
	}
	out := map[string]any{"rtorrent": st, "torrents": []torrentView{}}
	set := s.settings.Get()
	if set.SeedAction == "" {
		set.SeedAction = "stop"
	}
	out["seed"] = map[string]any{"ratio": set.SeedRatio, "hours": set.SeedHours, "action": set.SeedAction}
	if err != nil {
		out["error"] = err.Error()
		writeJSON(w, 200, out)
		return
	}
	s.dl.mu.Lock()
	jobs := map[string]*DownloadJob{}
	for id, j := range s.dl.jobs {
		jobs[id] = j
	}
	byHash := map[string]map[string]any{}
	for _, j := range s.dl.jobs {
		if j.Hash != "" && j.TState != "removed" && j.State != JobFailed {
			byHash[strings.ToUpper(j.Hash)] = map[string]any{"id": j.ID, "user": j.User, "lib": j.Lib, "autoStopped": j.AutoStopped, "seedRatio": j.SeedRatio, "seedHours": j.SeedHours}
		}
	}
	s.dl.mu.Unlock()
	counts := map[string]int{}
	list := make([]torrentView, 0, len(items))
	for _, it := range items {
		v := torrentView{Hash: it.Hash, Name: it.Name, Status: it.Status(), Size: it.Size, Done: it.Done, Ratio: it.Ratio,
			Uploaded: it.UpTotal, Downloaded: it.DownTotal, Up: it.UpRate, Down: it.DownRate, Peers: it.Peers, Seeds: it.Seeds,
			Files: it.Files, Path: it.dataPath(), Label: it.Label, Message: it.Message, Added: it.StartedAt, Finished: it.FinishedAt}
		// the job that added this copy (its tag), else one that knew the hash
		var jm map[string]any
		if id, ok := strings.CutPrefix(it.Tag, "smkv:"); ok && jobs[id] != nil {
			j := jobs[id]
			jm = map[string]any{"id": j.ID, "user": j.User, "lib": j.Lib, "autoStopped": j.AutoStopped, "seedRatio": j.SeedRatio, "seedHours": j.SeedHours}
		} else {
			jm = byHash[strings.ToUpper(it.Hash)]
		}
		if jm != nil {
			if l, ok := s.libs.Get(jm["lib"].(string)); ok {
				jm["libName"] = l.Name
			}
			v.Job = jm
		}
		counts[v.Status]++
		list = append(list, v)
	}
	sort.Slice(list, func(a, b int) bool { return list[a].Added > list[b].Added })
	out["torrents"] = list
	out["counts"] = counts
	if th, err := rt.Throttle(); err == nil {
		out["throttle"] = th
	}
	writeJSON(w, 200, out)
}

func (s *Server) handleAdminTorrentDetail(w http.ResponseWriter, r *http.Request) {
	s.writeTorrentDetail(w, r.PathValue("hash"))
}

// POST /api/admin/torrents/{hash} {"action": start|stop|pause|resume|recheck|remove|remove_data}
func (s *Server) handleAdminTorrentAction(w http.ResponseWriter, r *http.Request) {
	var b struct{ Action string }
	if !decodeJSON(w, r, &b) {
		return
	}
	rt, it, err := s.dl.item(r.PathValue("hash"))
	if err != nil {
		httpErr(w, 404, err.Error())
		return
	}
	jobID, _ := strings.CutPrefix(it.Tag, "smkv:")
	if !strings.HasPrefix(it.Tag, "smkv:") {
		jobID = ""
		s.dl.mu.Lock()
		for id, j := range s.dl.jobs {
			if strings.EqualFold(j.Hash, it.Hash) {
				jobID = id
			}
		}
		s.dl.mu.Unlock()
	}
	switch {
	case torrentActions[b.Action]:
		if err := rt.Do(it.Hash, b.Action); err != nil {
			httpErr(w, 502, err.Error())
			return
		}
	case b.Action == "remove" || b.Action == "remove_data":
		var path string
		if b.Action == "remove_data" {
			if path, err = s.deletablePath(it.dataPath(), it.Name); err != nil {
				httpErr(w, 400, err.Error())
				return
			}
		}
		if err := rt.Erase(it.Hash); err != nil {
			httpErr(w, 502, err.Error())
			return
		}
		if path != "" {
			time.Sleep(200 * time.Millisecond) // let rtorrent close the files
			if err := os.RemoveAll(path); err != nil {
				httpErr(w, 500, "removed from rtorrent, but deleting the files failed: "+err.Error())
				return
			}
			if lib := s.libOfPath(path); lib != "" {
				s.index.Queue(lib, false)
			}
		}
		if jobID != "" {
			s.dl.mu.Lock()
			if j := s.dl.jobs[jobID]; j != nil {
				if path != "" || j.State != JobDone {
					delete(s.dl.jobs, jobID)
				} else {
					j.TState, j.Seeding, j.Up, j.Rate = "removed", false, 0, 0
				}
				s.dl.saveLocked()
			}
			s.dl.mu.Unlock()
		}
		writeJSON(w, 200, map[string]bool{"ok": true})
		return
	default:
		httpErr(w, 400, "unknown action")
		return
	}
	time.Sleep(300 * time.Millisecond)
	s.dl.syncTorrents()
	writeJSON(w, 200, map[string]bool{"ok": true})
}

// POST /api/admin/torrents/throttle {"up": bytes/s, "down": bytes/s} — 0 = unlimited
func (s *Server) handleAdminThrottle(w http.ResponseWriter, r *http.Request) {
	var b struct{ Up, Down int64 }
	if !decodeJSON(w, r, &b) {
		return
	}
	if b.Up < 0 || b.Down < 0 {
		httpErr(w, 400, "limits can't be negative")
		return
	}
	rt, err := s.dl.rt()
	if err == nil {
		err = rt.SetThrottle(b.Up, b.Down)
	}
	if err != nil {
		httpErr(w, 502, err.Error())
		return
	}
	th, _ := rt.Throttle()
	writeJSON(w, 200, th)
}
