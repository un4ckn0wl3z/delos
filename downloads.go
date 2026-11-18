package main

// Download manager: HTTP(S) downloads done by the server itself, torrents
// handed to the seedbox's rtorrent. Files land in a library folder and the
// library is rescanned when a job finishes.

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	JobQueued      = "queued"
	JobDownloading = "downloading"
	JobDone        = "done"
	JobFailed      = "failed"
	JobCanceled    = "canceled"
)

type DownloadJob struct {
	ID       string `json:"id"`
	Kind     string `json:"kind"`   // http | torrent
	Source   string `json:"source"` // URL / magnet / "file.torrent"
	Lib      string `json:"lib"`
	Subdir   string `json:"subdir,omitempty"`
	Name     string `json:"name,omitempty"` // file (http) or torrent name
	User     string `json:"user"`
	State    string `json:"state"`
	Error    string `json:"error,omitempty"`
	Size     int64  `json:"size"`
	Done     int64  `json:"done"`
	Rate     int64  `json:"rate"` // bytes/s
	Up       int64  `json:"up,omitempty"`
	Seeding  bool   `json:"seeding,omitempty"`
	Created  int64  `json:"created"`
	Finished int64  `json:"finished,omitempty"`
	Hash     string `json:"hash,omitempty"`
	BasePath string `json:"-"` // torrent: d.base_path
	Saved    string `json:"basePath,omitempty"`
	// Dupes: other copies of the same movie / episode found after it was matched
	Dupes []string `json:"dupes,omitempty"`
}

type Downloads struct {
	s      *Server
	mu     sync.Mutex
	file   string
	jobs   map[string]*DownloadJob
	cancel map[string]context.CancelFunc
	slots  chan struct{} // concurrent HTTP downloads

	rtMu      sync.Mutex
	rtEP      string // resolved endpoint
	rtChecked time.Time
	rtVersion string
	rtErr     string
}

func NewDownloads(s *Server) *Downloads {
	d := &Downloads{s: s, file: filepath.Join(s.cfg.DataDir, "downloads.json"), jobs: map[string]*DownloadJob{},
		cancel: map[string]context.CancelFunc{}, slots: make(chan struct{}, 2)}
	if b, err := os.ReadFile(d.file); err == nil {
		var list []*DownloadJob
		if json.Unmarshal(b, &list) == nil {
			for _, j := range list {
				d.jobs[j.ID] = j
			}
		}
	}
	// HTTP jobs that were running when the server stopped: resume them
	for _, j := range d.jobs {
		if j.Kind == "http" && (j.State == JobQueued || j.State == JobDownloading) {
			j.State = JobQueued
			j.Rate = 0
			go d.runHTTP(j.ID)
		}
	}
	go d.pollLoop()
	return d
}

func (d *Downloads) saveLocked() {
	list := make([]*DownloadJob, 0, len(d.jobs))
	for _, j := range d.jobs {
		list = append(list, j)
	}
	b, _ := json.MarshalIndent(list, "", " ")
	if os.WriteFile(d.file+".tmp", b, 0o600) == nil {
		os.Rename(d.file+".tmp", d.file)
	}
}

func newJobID() string {
	b := make([]byte, 6)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func (d *Downloads) update(id string, f func(j *DownloadJob)) *DownloadJob {
	d.mu.Lock()
	defer d.mu.Unlock()
	j := d.jobs[id]
	if j == nil {
		return nil
	}
	f(j)
	d.saveLocked()
	c := *j
	return &c
}

func (d *Downloads) get(id string) *DownloadJob {
	d.mu.Lock()
	defer d.mu.Unlock()
	if j := d.jobs[id]; j != nil {
		c := *j
		return &c
	}
	return nil
}

func cleanSubdir(subdir string) string {
	return strings.Trim(path.Clean("/"+filepath.ToSlash(strings.TrimSpace(subdir))), "/")
}

// targetDir resolves (and creates) the folder a job writes into.
func (d *Downloads) targetDir(libID, subdir string) (string, Library, error) {
	lib, ok := d.s.libs.Get(libID)
	if !ok {
		return "", Library{}, errors.New("no such library")
	}
	sub := cleanSubdir(subdir)
	for _, p := range strings.Split(sub, "/") {
		if strings.HasPrefix(p, ".") {
			return "", lib, errors.New("folder names may not start with a dot")
		}
	}
	if sub != "" && lib.ExcludedDir(sub) {
		return "", lib, errors.New("that folder is excluded from the library")
	}
	dir := filepath.Join(lib.Path, filepath.FromSlash(sub))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", lib, err
	}
	return dir, lib, nil
}

// ---------------------------------------------------------------- HTTP

func sanitizeFileName(n string) string {
	n = strings.Map(func(r rune) rune {
		if r < 32 || strings.ContainsRune(`/\:*?"<>|`, r) {
			return '_'
		}
		return r
	}, strings.TrimSpace(n))
	n = strings.TrimLeft(n, ". ")
	if len(n) > 200 {
		ext := filepath.Ext(n)
		if len(ext) > 12 {
			ext = ""
		}
		n = n[:200-len(ext)] + ext
	}
	return n
}

// fileNameFor picks a name from Content-Disposition or the final URL.
func fileNameFor(resp *http.Response) string {
	if cd := resp.Header.Get("Content-Disposition"); cd != "" {
		if _, p, err := mime.ParseMediaType(cd); err == nil {
			if n := sanitizeFileName(p["filename"]); n != "" {
				return n
			}
		}
	}
	base := path.Base(resp.Request.URL.Path)
	if u, err := url.PathUnescape(base); err == nil {
		base = u
	}
	if n := sanitizeFileName(base); n != "" && n != "_" {
		return n
	}
	return "download-" + time.Now().Format("20060102-150405")
}

func uniquePath(dir, name string) string {
	p := filepath.Join(dir, name)
	ext := filepath.Ext(name)
	stem := strings.TrimSuffix(name, ext)
	for i := 1; ; i++ {
		if _, err := os.Stat(p); errors.Is(err, os.ErrNotExist) {
			return p
		}
		p = filepath.Join(dir, fmt.Sprintf("%s (%d)%s", stem, i, ext))
	}
}

// httpClientFor blocks private / loopback addresses for non-admins (SSRF).
func httpClientFor(allowPrivate bool) *http.Client {
	dialer := &net.Dialer{Timeout: 20 * time.Second, KeepAlive: 30 * time.Second}
	if !allowPrivate {
		dialer.Control = func(network, address string, _ syscall.RawConn) error {
			host, _, _ := net.SplitHostPort(address)
			ip := net.ParseIP(host)
			if ip == nil || ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsUnspecified() {
				return fmt.Errorf("address %s is not allowed", host)
			}
			return nil
		}
	}
	tr := &http.Transport{Proxy: http.ProxyFromEnvironment, DialContext: dialer.DialContext, TLSHandshakeTimeout: 20 * time.Second,
		ResponseHeaderTimeout: 60 * time.Second, MaxIdleConns: 4}
	return &http.Client{Transport: tr, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) >= 10 {
			return errors.New("too many redirects")
		}
		if req.URL.Scheme != "http" && req.URL.Scheme != "https" {
			return errors.New("redirect to a non-HTTP URL")
		}
		return nil
	}}
}

func (d *Downloads) runHTTP(id string) {
	d.slots <- struct{}{}
	defer func() { <-d.slots }()
	j := d.get(id)
	if j == nil || j.State != JobQueued {
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	d.mu.Lock()
	d.cancel[id] = cancel
	d.mu.Unlock()
	defer func() {
		cancel()
		d.mu.Lock()
		delete(d.cancel, id)
		d.mu.Unlock()
	}()
	err := d.fetch(ctx, j)
	d.update(id, func(j *DownloadJob) {
		j.Rate = 0
		switch {
		case ctx.Err() != nil && j.State == JobCanceled:
		case err != nil:
			j.State, j.Error = JobFailed, err.Error()
		default:
			j.State, j.Finished, j.Error = JobDone, time.Now().Unix(), ""
		}
	})
	if err == nil {
		d.s.index.Queue(j.Lib, false)
		go d.noteDupes(id)
	}
}

func (d *Downloads) fetch(ctx context.Context, j *DownloadJob) error {
	dir, _, err := d.targetDir(j.Lib, j.Subdir)
	if err != nil {
		return err
	}
	d.update(j.ID, func(j *DownloadJob) { j.State, j.Error = JobDownloading, "" })
	client := httpClientFor(d.s.users.IsAdmin(j.User))
	// resume a partial file from an earlier run
	part := ""
	var have int64
	if j.Name != "" {
		part = filepath.Join(dir, "."+j.Name+".part")
		if st, err := os.Stat(part); err == nil {
			have = st.Size()
		}
	}
	req, err := http.NewRequestWithContext(ctx, "GET", j.Source, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (StreamMKV/"+version+")")
	if have > 0 {
		req.Header.Set("Range", fmt.Sprintf("bytes=%d-", have))
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 && resp.StatusCode != 206 {
		return fmt.Errorf("server answered %s", resp.Status)
	}
	if j.Name == "" {
		name := fileNameFor(resp)
		final := uniquePath(dir, name)
		j.Name = filepath.Base(final)
		part = filepath.Join(dir, "."+j.Name+".part")
		d.update(j.ID, func(x *DownloadJob) { x.Name = j.Name })
	}
	flags := os.O_CREATE | os.O_WRONLY
	if resp.StatusCode == 206 && have > 0 {
		flags |= os.O_APPEND
	} else {
		flags |= os.O_TRUNC
		have = 0
	}
	total := int64(-1)
	if resp.ContentLength >= 0 {
		total = have + resp.ContentLength
	}
	if total > 0 {
		if lib, ok := d.s.libs.Get(j.Lib); ok && lib.Owner != "" && !d.s.users.IsAdmin(j.User) {
			if err := d.s.checkQuota(lib.Owner, lib, total-have); err != nil {
				return err
			}
		}
		if _, free, ok := diskUsage(dir); ok && uint64(total-have) > free {
			return fmt.Errorf("not enough disk space (%s needed, %s free)", fmtBytes(total-have), fmtBytes(int64(free)))
		}
	}
	f, err := os.OpenFile(part, flags, 0o644)
	if err != nil {
		return err
	}
	d.update(j.ID, func(x *DownloadJob) { x.Size, x.Done = total, have })

	buf := make([]byte, 256<<10)
	done := have
	last, lastDone := time.Now(), done
	for {
		n, rerr := resp.Body.Read(buf)
		if n > 0 {
			if _, werr := f.Write(buf[:n]); werr != nil {
				f.Close()
				return werr
			}
			done += int64(n)
		}
		if now := time.Now(); now.Sub(last) >= time.Second || rerr != nil {
			rate := int64(float64(done-lastDone) / now.Sub(last).Seconds())
			last, lastDone = now, done
			d.mu.Lock()
			if x := d.jobs[j.ID]; x != nil {
				x.Done, x.Rate = done, rate
			}
			d.mu.Unlock()
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			f.Close()
			return rerr
		}
	}
	if err := f.Close(); err != nil {
		return err
	}
	if total > 0 && done < total {
		return fmt.Errorf("connection closed early (%s of %s)", fmtBytes(done), fmtBytes(total))
	}
	final := filepath.Join(dir, j.Name)
	if _, err := os.Stat(final); err == nil {
		final = uniquePath(dir, j.Name)
		d.update(j.ID, func(x *DownloadJob) { x.Name = filepath.Base(final) })
	}
	d.update(j.ID, func(x *DownloadJob) { x.Size, x.Done = done, done })
	return os.Rename(part, final)
}

func fmtBytes(n int64) string {
	f := float64(n)
	for _, u := range []string{"B", "KB", "MB", "GB", "TB"} {
		if f < 1024 || u == "TB" {
			if u == "B" {
				return fmt.Sprintf("%d B", n)
			}
			return fmt.Sprintf("%.1f %s", f, u)
		}
		f /= 1024
	}
	return ""
}

// ---------------------------------------------------------------- torrents

// rt returns an rtorrent client, auto-detecting the endpoint when not set.
func (d *Downloads) rt() (*RTorrent, error) {
	d.rtMu.Lock()
	defer d.rtMu.Unlock()
	want := strings.TrimSpace(d.s.settings.Get().RTorrent)
	if want != "" {
		d.rtEP = want
	} else if d.rtEP == "" && time.Since(d.rtChecked) > 30*time.Second {
		d.rtChecked = time.Now()
		d.rtEP = DetectRTorrent()
	}
	if d.rtEP == "" {
		d.rtErr = "rtorrent not found — set its SCGI socket / address in the dashboard"
		return nil, errors.New(d.rtErr)
	}
	return &RTorrent{Endpoint: d.rtEP}, nil
}

// TorrentStatus checks the connection (cached for 15 s).
func (d *Downloads) TorrentStatus(force bool) map[string]any {
	d.rtMu.Lock()
	fresh := !force && time.Since(d.rtChecked) < 15*time.Second && d.rtEP != ""
	d.rtMu.Unlock()
	if !fresh {
		if force {
			d.rtMu.Lock()
			if strings.TrimSpace(d.s.settings.Get().RTorrent) == "" {
				d.rtEP = ""
				d.rtChecked = time.Time{}
			}
			d.rtMu.Unlock()
		}
		rt, err := d.rt()
		d.rtMu.Lock()
		d.rtChecked = time.Now()
		if err != nil {
			d.rtVersion = ""
		} else if v, err := rt.Version(); err != nil {
			d.rtVersion, d.rtErr = "", "cannot talk to rtorrent at "+rt.Endpoint+": "+err.Error()
		} else {
			d.rtVersion, d.rtErr = v, ""
		}
		d.rtMu.Unlock()
	}
	d.rtMu.Lock()
	defer d.rtMu.Unlock()
	out := map[string]any{"ok": d.rtVersion != "", "endpoint": d.rtEP, "auto": strings.TrimSpace(d.s.settings.Get().RTorrent) == ""}
	if d.rtVersion != "" {
		out["version"] = d.rtVersion
	} else {
		out["error"] = d.rtErr
	}
	return out
}

func (d *Downloads) addTorrent(j *DownloadJob, src any) error {
	dir, _, err := d.targetDir(j.Lib, j.Subdir)
	if err != nil {
		return err
	}
	rt, err := d.rt()
	if err != nil {
		return err
	}
	return rt.Add(src, dir, "smkv:"+j.ID)
}

// pollLoop mirrors rtorrent's progress into torrent jobs.
func (d *Downloads) pollLoop() {
	for {
		d.mu.Lock()
		active := false
		for _, j := range d.jobs {
			if j.Kind == "torrent" && (j.State == JobQueued || j.State == JobDownloading || j.Seeding) {
				active = true
			}
		}
		d.mu.Unlock()
		if active {
			d.syncTorrents()
		}
		time.Sleep(3 * time.Second)
	}
}

func (d *Downloads) syncTorrents() {
	rt, err := d.rt()
	if err != nil {
		return
	}
	items, err := rt.List()
	if err != nil {
		return
	}
	byTag := map[string]rtItem{}
	for _, it := range items {
		if strings.HasPrefix(it.Tag, "smkv:") {
			byTag[strings.TrimPrefix(it.Tag, "smkv:")] = it
		}
	}
	var finished, finishedIDs []string
	d.mu.Lock()
	for id, j := range d.jobs {
		if j.Kind != "torrent" || j.State == JobCanceled || j.State == JobFailed {
			continue
		}
		it, ok := byTag[id]
		if !ok {
			if j.State != JobDone && time.Since(time.Unix(j.Created, 0)) > time.Minute {
				j.State, j.Error = JobFailed, "removed from rtorrent"
			}
			j.Seeding = false
			continue
		}
		if j.Size <= 0 && it.Size > 0 && !it.Complete {
			// size just became known (magnets): enforce the owner's storage limit
			if lib, ok := d.s.libs.Get(j.Lib); ok && lib.Owner != "" && !d.s.users.IsAdmin(j.User) {
				if _, maxBytes := d.s.users.Limits(lib.Owner); maxBytes > 0 {
					u := d.s.usageOf(lib.Owner, true)
					if u.Bytes-it.Done+it.Size > maxBytes {
						rt.Erase(it.Hash)
						if it.BasePath != "" && strings.HasPrefix(it.BasePath, lib.Path+string(filepath.Separator)) {
							os.RemoveAll(it.BasePath)
						}
						j.State, j.Error, j.Size = JobFailed, fmt.Sprintf("too big for the storage limit (%s, %s used of %s)", fmtBytes(it.Size), fmtBytes(u.Bytes-it.Done), fmtBytes(maxBytes)), it.Size
						continue
					}
				}
			}
		}
		j.Hash, j.Name, j.Size, j.Done, j.Rate, j.Up, j.BasePath = it.Hash, it.Name, it.Size, it.Done, it.DownRate, it.UpRate, it.BasePath
		j.Seeding = it.Complete && it.Active
		if it.Message != "" && !it.Complete {
			j.Error = it.Message
		} else {
			j.Error = ""
		}
		if it.Complete && j.State != JobDone {
			j.State, j.Finished = JobDone, time.Now().Unix()
			finished = append(finished, j.Lib)
			finishedIDs = append(finishedIDs, id)
			// magnets leave "<HASH>.meta" next to the download
			if dir, _, err := d.targetDir(j.Lib, j.Subdir); err == nil && it.Hash != "" {
				os.Remove(filepath.Join(dir, strings.ToUpper(it.Hash)+".meta"))
			}
		} else if !it.Complete {
			j.State = JobDownloading
		}
	}
	d.saveLocked()
	d.mu.Unlock()
	for _, lib := range finished {
		d.s.index.Queue(lib, false)
	}
	for _, id := range finishedIDs {
		go d.noteDupes(id)
	}
}

// ---------------------------------------------------------------- API

func (s *Server) canDownload(r *http.Request) bool {
	return isAdmin(r) || s.users.IsDownloader(userOf(r))
}

func (s *Server) downloader(h http.HandlerFunc) http.HandlerFunc {
	return s.auth(func(w http.ResponseWriter, r *http.Request) {
		if !s.canDownload(r) {
			httpErr(w, 403, "you are not allowed to add downloads")
			return
		}
		h(w, r)
	})
}

func (s *Server) downloadRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/downloads", s.downloader(s.handleDownloads))
	mux.HandleFunc("GET /api/downloads/dirs", s.downloader(s.handleDownloadDirs))
	mux.HandleFunc("POST /api/downloads", s.downloader(s.handleDownloadAdd))
	mux.HandleFunc("POST /api/downloads/torrent", s.downloader(s.handleDownloadTorrentFile))
	mux.HandleFunc("POST /api/downloads/{id}/retry", s.downloader(s.handleDownloadRetry))
	mux.HandleFunc("DELETE /api/downloads/{id}", s.downloader(s.handleDownloadDelete))
	mux.HandleFunc("POST /api/admin/users/{name}/downloader", s.adminOnly(s.handleAdminDownloader))
	mux.HandleFunc("POST /api/admin/rtorrent/test", s.adminOnly(s.handleRTorrentTest))
}

func (s *Server) handleDownloads(w http.ResponseWriter, r *http.Request) {
	s.dl.mu.Lock()
	jobs := []DownloadJob{}
	for _, j := range s.dl.jobs {
		if s.canAccess(r, j.Lib) {
			c := *j
			if isAdmin(r) || c.User == userOf(r) {
				c.Saved = c.BasePath
			}
			jobs = append(jobs, c)
		}
	}
	s.dl.mu.Unlock()
	sort.Slice(jobs, func(a, b int) bool { return jobs[a].Created > jobs[b].Created })
	libs := []map[string]any{}
	for _, l := range s.visibleLibraries(r) {
		if !isAdmin(r) && l.Owner != "" && l.Owner != userOf(r) {
			continue // others' personal libraries are read-only
		}
		if mi, mb := s.users.Limits(userOf(r)); (mi > 0 || mb > 0) && l.Owner != userOf(r) {
			continue // limited accounts download into their own libraries
		}
		libs = append(libs, map[string]any{"id": l.ID, "name": l.Name, "type": l.Type, "owner": l.Owner, "shared": l.Shared})
	}
	writeJSON(w, 200, map[string]any{"jobs": jobs, "torrent": s.dl.TorrentStatus(false), "libraries": libs})
}

// GET /api/downloads/dirs?lib= → existing sub-folders (2 levels) to drop files into
func (s *Server) handleDownloadDirs(w http.ResponseWriter, r *http.Request) {
	lib, ok := s.libs.Get(r.URL.Query().Get("lib"))
	if !ok || !s.canAccess(r, lib.ID) {
		httpErr(w, 404, "no such library")
		return
	}
	out := []string{}
	var walk func(rel string, depth int)
	walk = func(rel string, depth int) {
		ents, _ := os.ReadDir(filepath.Join(lib.Path, filepath.FromSlash(rel)))
		for _, e := range ents {
			if !e.IsDir() || strings.HasPrefix(e.Name(), ".") || len(out) >= 400 {
				continue
			}
			p := strings.TrimPrefix(rel+"/"+e.Name(), "/")
			if lib.ExcludedDir(p) {
				continue
			}
			out = append(out, p)
			if depth < 2 {
				walk(p, depth+1)
			}
		}
	}
	walk("", 1)
	sort.Slice(out, func(a, b int) bool { return strings.ToLower(out[a]) < strings.ToLower(out[b]) })
	writeJSON(w, 200, map[string]any{"dirs": out})
}

func (s *Server) newJob(r *http.Request, kind, source, lib, subdir, name string) (*DownloadJob, error) {
	l, ok := s.libs.Get(lib)
	if !ok || !s.canAccess(r, l.ID) {
		return nil, errors.New("choose a library")
	}
	if !isAdmin(r) && l.Owner != "" && l.Owner != userOf(r) {
		return nil, errors.New("you can't download into someone else's library")
	}
	if !isAdmin(r) {
		if err := s.checkQuota(userOf(r), l, 0); err != nil {
			return nil, err
		}
	}
	if _, _, err := s.dl.targetDir(lib, subdir); err != nil {
		return nil, err
	}
	return &DownloadJob{ID: newJobID(), Kind: kind, Source: source, Lib: lib, Subdir: cleanSubdir(subdir),
		Name: sanitizeFileName(name), User: userOf(r), State: JobQueued, Size: -1, Created: time.Now().Unix()}, nil
}

// POST /api/downloads {"source": url|magnet, "lib", "subdir"?, "name"?}
func (s *Server) handleDownloadAdd(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Source, Lib, Subdir, Name string
		Force                     bool // download even if it looks like a duplicate
	}
	if !decodeJSON(w, r, &b) {
		return
	}
	src := strings.TrimSpace(b.Source)
	kind := "http"
	switch {
	case strings.HasPrefix(strings.ToLower(src), "magnet:?"):
		kind = "torrent"
	case strings.HasPrefix(src, "http://") || strings.HasPrefix(src, "https://"):
		u, err := url.Parse(src)
		if err != nil || u.Host == "" {
			httpErr(w, 400, "invalid URL")
			return
		}
		if strings.HasSuffix(strings.ToLower(u.Path), ".torrent") {
			kind = "torrent" // rtorrent fetches .torrent URLs itself
		}
	default:
		httpErr(w, 400, "paste an http(s) link or a magnet link")
		return
	}
	j, err := s.newJob(r, kind, src, b.Lib, b.Subdir, b.Name)
	if err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	lib, _ := s.libs.Get(j.Lib)
	if kind == "torrent" {
		var payload any = src
		var hash, name string
		if strings.HasPrefix(strings.ToLower(src), "magnet:?") {
			hash, name = magnetInfo(src)
		} else {
			// fetch the .torrent here so its hash can be checked (and rtorrent gets the data)
			data, err := fetchSmall(src, isAdmin(r), 10<<20)
			if err != nil {
				httpErr(w, 502, "couldn't get the .torrent: "+err.Error())
				return
			}
			if hash, name, err = torrentInfo(data); err != nil {
				httpErr(w, 400, "that link isn't a .torrent file")
				return
			}
			payload = data
		}
		if d, hard := s.torrentDup(r, hash); d != nil && (hard || !b.Force) {
			writeDup(w, d, !hard)
			return
		}
		if !b.Force {
			if d := s.titleDup(r, lib, name); d != nil {
				writeDup(w, d, true)
				return
			}
		}
		j.Name, j.Hash = "", hash
		if err := s.dl.addTorrent(j, payload); err != nil {
			httpErr(w, 502, err.Error())
			return
		}
		j.State = JobDownloading
	} else {
		name := j.Name
		if name == "" {
			name, _ = probeName(src, isAdmin(r))
			j.Name = name
		}
		if !b.Force {
			if d := s.fileDup(r, lib, j.Subdir, src, name); d != nil {
				writeDup(w, d, true)
				return
			}
			if d := s.titleDup(r, lib, name); d != nil {
				writeDup(w, d, true)
				return
			}
		}
	}
	s.dl.mu.Lock()
	s.dl.jobs[j.ID] = j
	s.dl.saveLocked()
	s.dl.mu.Unlock()
	if kind == "http" {
		go s.dl.runHTTP(j.ID)
	}
	writeJSON(w, 200, j)
}

// POST /api/downloads/torrent (multipart: file, lib, subdir)
func (s *Server) handleDownloadTorrentFile(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 12<<20)
	if err := r.ParseMultipartForm(12 << 20); err != nil {
		httpErr(w, 400, "upload a .torrent file (max 10 MB)")
		return
	}
	f, hdr, err := r.FormFile("file")
	if err != nil {
		httpErr(w, 400, "missing file")
		return
	}
	data, _ := io.ReadAll(f)
	f.Close()
	if len(data) == 0 || data[0] != 'd' {
		httpErr(w, 400, "that is not a .torrent file")
		return
	}
	j, err := s.newJob(r, "torrent", hdr.Filename, r.FormValue("lib"), r.FormValue("subdir"), "")
	if err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	hash, name, err := torrentInfo(data)
	if err != nil {
		httpErr(w, 400, "that is not a valid .torrent file")
		return
	}
	force := r.FormValue("force") == "1" || r.FormValue("force") == "true"
	if d, hard := s.torrentDup(r, hash); d != nil && (hard || !force) {
		writeDup(w, d, !hard)
		return
	}
	if !force {
		lib, _ := s.libs.Get(j.Lib)
		if d := s.titleDup(r, lib, name); d != nil {
			writeDup(w, d, true)
			return
		}
	}
	j.Hash = hash
	if err := s.dl.addTorrent(j, data); err != nil {
		httpErr(w, 502, err.Error())
		return
	}
	j.State = JobDownloading
	s.dl.mu.Lock()
	s.dl.jobs[j.ID] = j
	s.dl.saveLocked()
	s.dl.mu.Unlock()
	writeJSON(w, 200, j)
}

func (s *Server) jobFor(w http.ResponseWriter, r *http.Request) *DownloadJob {
	j := s.dl.get(r.PathValue("id"))
	if j == nil || !s.canAccess(r, j.Lib) {
		httpErr(w, 404, "no such download")
		return nil
	}
	if !isAdmin(r) && j.User != userOf(r) {
		httpErr(w, 403, "only the person who added it (or an admin) can change it")
		return nil
	}
	return j
}

func (s *Server) handleDownloadRetry(w http.ResponseWriter, r *http.Request) {
	j := s.jobFor(w, r)
	if j == nil {
		return
	}
	if j.Kind != "http" || (j.State != JobFailed && j.State != JobCanceled) {
		httpErr(w, 400, "only failed or canceled HTTP downloads can be retried")
		return
	}
	s.dl.update(j.ID, func(x *DownloadJob) { x.State, x.Error, x.Rate = JobQueued, "", 0 })
	go s.dl.runHTTP(j.ID)
	writeJSON(w, 200, map[string]bool{"ok": true})
}

// DELETE /api/downloads/{id}[?files=1] — cancel / remove from the list, optionally deleting what was downloaded.
func (s *Server) handleDownloadDelete(w http.ResponseWriter, r *http.Request) {
	j := s.jobFor(w, r)
	if j == nil {
		return
	}
	withFiles := r.URL.Query().Get("files") == "1"
	lib, _ := s.libs.Get(j.Lib)
	inside := func(p string) bool {
		rel, err := filepath.Rel(lib.Path, p)
		return err == nil && rel != "." && !strings.HasPrefix(rel, "..") && !filepath.IsAbs(rel)
	}
	s.dl.mu.Lock()
	if c := s.dl.cancel[j.ID]; c != nil {
		if x := s.dl.jobs[j.ID]; x != nil {
			x.State = JobCanceled
		}
		c()
	}
	s.dl.mu.Unlock()
	var errs []string
	if j.Kind == "torrent" {
		if rt, err := s.dl.rt(); err == nil && j.Hash != "" {
			if err := rt.Erase(j.Hash); err != nil && !strings.Contains(err.Error(), "Could not find") {
				errs = append(errs, err.Error())
			}
		}
		if withFiles && j.BasePath != "" && inside(j.BasePath) {
			if err := os.RemoveAll(j.BasePath); err != nil {
				errs = append(errs, err.Error())
			}
		}
	} else if dir, _, err := s.dl.targetDir(j.Lib, j.Subdir); err == nil && j.Name != "" {
		time.Sleep(200 * time.Millisecond) // let the writer stop
		os.Remove(filepath.Join(dir, "."+j.Name+".part"))
		if withFiles && j.State == JobDone {
			if p := filepath.Join(dir, j.Name); inside(p) {
				if err := os.Remove(p); err != nil && !errors.Is(err, os.ErrNotExist) {
					errs = append(errs, err.Error())
				}
			}
		}
	}
	s.dl.mu.Lock()
	delete(s.dl.jobs, j.ID)
	s.dl.saveLocked()
	s.dl.mu.Unlock()
	if withFiles {
		s.index.Queue(j.Lib, false)
	}
	if len(errs) > 0 {
		httpErr(w, 500, strings.Join(errs, "; "))
		return
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}

func (s *Server) handleAdminDownloader(w http.ResponseWriter, r *http.Request) {
	var b struct{ Downloader bool }
	if !decodeJSON(w, r, &b) {
		return
	}
	if err := s.users.SetDownloader(r.PathValue("name"), b.Downloader); err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}

// POST /api/admin/rtorrent/test {"endpoint"?} — try an endpoint (or the saved / detected one)
func (s *Server) handleRTorrentTest(w http.ResponseWriter, r *http.Request) {
	var b struct{ Endpoint string }
	if r.ContentLength > 0 && !decodeJSON(w, r, &b) {
		return
	}
	if ep := strings.TrimSpace(b.Endpoint); ep != "" {
		rt := &RTorrent{Endpoint: ep}
		v, err := rt.Version()
		if err != nil {
			writeJSON(w, 200, map[string]any{"ok": false, "endpoint": ep, "error": err.Error()})
			return
		}
		writeJSON(w, 200, map[string]any{"ok": true, "endpoint": ep, "version": v})
		return
	}
	writeJSON(w, 200, s.dl.TorrentStatus(true))
}
