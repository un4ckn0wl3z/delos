package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Self-update from GitHub releases.
//
// Releases carry streammkv-linux-<arch> binaries and a SHA256SUMS file. The updater
// downloads the binary for this platform, verifies the checksum, atomically replaces
// the running executable and re-execs it (same PID, so run.sh / cron keep working).

func releasesAPI() string {
	if u := os.Getenv("STREAMMKV_UPDATE_URL"); u != "" { // tests / forks
		return u
	}
	repo := os.Getenv("STREAMMKV_UPDATE_REPO")
	if repo == "" {
		repo = "un4ckn0wl3z/streammkv"
	}
	return "https://api.github.com/repos/" + repo + "/releases/latest"
}

var version = "dev" // set with -ldflags "-X main.version=1.2.0"

type ReleaseInfo struct {
	Tag     string `json:"tag"`
	Version string `json:"version"`
	Notes   string `json:"notes"`
	URL     string `json:"url"`
	Date    string `json:"date"`
	assets  map[string]string
}

type UpdateStatus struct {
	Current    string       `json:"current"`
	Latest     *ReleaseInfo `json:"latest"`
	Available  bool         `json:"available"`
	AutoUpdate bool         `json:"autoUpdate"`
	LastCheck  int64        `json:"lastCheck"`
	Error      string       `json:"error,omitempty"`
	Installing bool         `json:"installing"`
	Supported  bool         `json:"supported"` // self-replace + re-exec works on this platform
}

type Updater struct {
	s          *Server
	mu         sync.Mutex
	latest     *ReleaseInfo
	lastCheck  time.Time
	lastErr    string
	installing bool
	settings   *SettingsStore
	client     *http.Client
}

func NewUpdater(s *Server, st *SettingsStore) *Updater {
	return &Updater{s: s, settings: st, client: &http.Client{Timeout: 10 * time.Minute}}
}

// semver-ish compare of "1.2.10" vs "1.2.9"; non-numeric parts compare as 0.
func newerThan(a, b string) bool {
	pa, pb := strings.Split(strings.TrimPrefix(a, "v"), "."), strings.Split(strings.TrimPrefix(b, "v"), ".")
	for i := 0; i < 3; i++ {
		var x, y int
		if i < len(pa) {
			x, _ = strconv.Atoi(strings.SplitN(pa[i], "-", 2)[0])
		}
		if i < len(pb) {
			y, _ = strconv.Atoi(strings.SplitN(pb[i], "-", 2)[0])
		}
		if x != y {
			return x > y
		}
	}
	return false
}

func (u *Updater) Check() error {
	req, _ := http.NewRequest("GET", releasesAPI(), nil)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "streammkv/"+version)
	c := &http.Client{Timeout: 30 * time.Second}
	resp, err := c.Do(req)
	u.mu.Lock()
	defer u.mu.Unlock()
	u.lastCheck = time.Now()
	if err != nil {
		u.lastErr = err.Error()
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		u.lastErr = "GitHub API: " + resp.Status
		return errors.New(u.lastErr)
	}
	var r struct {
		TagName     string `json:"tag_name"`
		Body        string `json:"body"`
		HTMLURL     string `json:"html_url"`
		PublishedAt string `json:"published_at"`
		Assets      []struct {
			Name string `json:"name"`
			URL  string `json:"browser_download_url"`
		} `json:"assets"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		u.lastErr = err.Error()
		return err
	}
	ri := &ReleaseInfo{Tag: r.TagName, Version: strings.TrimPrefix(r.TagName, "v"), Notes: r.Body,
		URL: r.HTMLURL, Date: r.PublishedAt, assets: map[string]string{}}
	for _, a := range r.Assets {
		ri.assets[a.Name] = a.URL
	}
	u.latest, u.lastErr = ri, ""
	return nil
}

func (u *Updater) Status() UpdateStatus {
	u.mu.Lock()
	defer u.mu.Unlock()
	st := UpdateStatus{Current: version, Latest: u.latest, AutoUpdate: u.settings.Get().AutoUpdate,
		Error: u.lastErr, Installing: u.installing, Supported: selfUpdateSupported()}
	if !u.lastCheck.IsZero() {
		st.LastCheck = u.lastCheck.Unix()
	}
	st.Available = u.latest != nil && version != "dev" && newerThan(u.latest.Version, version)
	return st
}

func (u *Updater) assetName() string {
	return fmt.Sprintf("streammkv-%s-%s", runtime.GOOS, runtime.GOARCH)
}

func (u *Updater) download(url string, w io.Writer) error {
	req, _ := http.NewRequest("GET", url, nil)
	req.Header.Set("User-Agent", "streammkv/"+version)
	resp, err := u.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("download %s: %s", url, resp.Status)
	}
	_, err = io.Copy(w, resp.Body)
	return err
}

// Install downloads, verifies and swaps the binary, then restarts. It only returns on error.
func (u *Updater) Install() error {
	if !selfUpdateSupported() {
		return errors.New("self-update is not supported on " + runtime.GOOS)
	}
	u.mu.Lock()
	if u.installing {
		u.mu.Unlock()
		return errors.New("update already in progress")
	}
	rel := u.latest
	u.installing = true
	u.mu.Unlock()
	defer func() { u.mu.Lock(); u.installing = false; u.mu.Unlock() }()

	if rel == nil {
		return errors.New("no release information; check first")
	}
	name := u.assetName()
	binURL, sumURL := rel.assets[name], rel.assets["SHA256SUMS"]
	if binURL == "" || sumURL == "" {
		return fmt.Errorf("release %s has no %s or SHA256SUMS", rel.Tag, name)
	}

	// expected checksum
	var sums strings.Builder
	if err := u.download(sumURL, &sums); err != nil {
		return err
	}
	want := ""
	sc := bufio.NewScanner(strings.NewReader(sums.String()))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) == 2 && strings.TrimPrefix(f[1], "*") == name {
			want = strings.ToLower(f[0])
		}
	}
	if want == "" {
		return fmt.Errorf("SHA256SUMS has no entry for %s", name)
	}

	exe, err := os.Executable()
	if err != nil {
		return err
	}
	if exe, err = filepath.EvalSymlinks(exe); err != nil {
		return err
	}
	tmp := exe + ".new"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o755)
	if err != nil {
		return fmt.Errorf("cannot write next to the binary: %w", err)
	}
	h := sha256.New()
	err = u.download(binURL, io.MultiWriter(f, h))
	f.Close()
	if err != nil {
		os.Remove(tmp)
		return err
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != want {
		os.Remove(tmp)
		return fmt.Errorf("checksum mismatch for %s (got %s, want %s)", name, got, want)
	}
	os.Rename(exe, exe+".old") // keep one rollback copy
	if err := os.Rename(tmp, exe); err != nil {
		os.Rename(exe+".old", exe)
		return err
	}
	log.Printf("updated %s → %s, restarting", version, rel.Version)
	u.s.progress.flush()
	time.Sleep(300 * time.Millisecond) // let the HTTP response go out
	return restartSelf(exe)
}

// Loop checks every 6h and installs automatically when enabled and nobody is watching.
func (u *Updater) Loop() {
	time.Sleep(time.Minute)
	for {
		if err := u.Check(); err != nil {
			log.Printf("update check: %v", err)
		}
		st := u.Status()
		if st.Available && st.AutoUpdate && st.Supported {
			if n := len(u.s.conns.List()); n > 0 {
				log.Printf("update %s available; waiting, %d active streams", st.Latest.Version, n)
			} else if err := u.Install(); err != nil {
				log.Printf("auto-update failed: %v", err)
			}
		}
		next := 6 * time.Hour
		if st.Available && st.AutoUpdate {
			next = 15 * time.Minute // retry soon when blocked by viewers
		}
		time.Sleep(next)
	}
}

// ---------------------------------------------------------------- settings.json

type ServerSettings struct {
	AutoUpdate bool   `json:"autoUpdate"`
	TMDBKey    string `json:"tmdbKey,omitempty"`
	TMDBLang   string `json:"tmdbLang,omitempty"` // e.g. en-US, th-TH
	// RTorrent: rtorrent XML-RPC endpoint — SCGI socket path, host:port, or
	// http(s)://user:pass@host/RPC2 (ruTorrent). Empty = auto-detect.
	RTorrent string `json:"rtorrent,omitempty"`
}

type SettingsStore struct {
	mu   sync.Mutex
	file string
	v    ServerSettings
}

func NewSettingsStore(dir string) *SettingsStore {
	st := &SettingsStore{file: filepath.Join(dir, "settings.json"), v: ServerSettings{AutoUpdate: true}}
	if b, err := os.ReadFile(st.file); err == nil {
		json.Unmarshal(b, &st.v)
	}
	return st
}

func (st *SettingsStore) Get() ServerSettings {
	st.mu.Lock()
	defer st.mu.Unlock()
	return st.v
}

func (st *SettingsStore) Set(v ServerSettings) error {
	st.mu.Lock()
	defer st.mu.Unlock()
	st.v = v
	b, _ := json.MarshalIndent(v, "", "  ")
	return os.WriteFile(st.file, b, 0o600)
}

// ---------------------------------------------------------------- admin API

func (s *Server) handleUpdateStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, s.updater.Status())
}

func (s *Server) handleUpdateCheck(w http.ResponseWriter, r *http.Request) {
	if err := s.updater.Check(); err != nil {
		httpErr(w, 502, err.Error())
		return
	}
	writeJSON(w, 200, s.updater.Status())
}

func (s *Server) handleUpdateInstall(w http.ResponseWriter, r *http.Request) {
	st := s.updater.Status()
	if !st.Available {
		httpErr(w, 400, "already up to date")
		return
	}
	errc := make(chan error, 1)
	go func() { errc <- s.updater.Install() }()
	select {
	case err := <-errc: // failed before restarting
		httpErr(w, 500, err.Error())
	case <-time.After(250 * time.Millisecond):
		// still downloading: report that it started; the dashboard polls /api/me until the new version answers
		writeJSON(w, 202, map[string]any{"ok": true, "installing": st.Latest.Version})
		go func() {
			if err := <-errc; err != nil {
				log.Printf("update failed: %v", err)
				s.updater.mu.Lock()
				s.updater.lastErr = err.Error()
				s.updater.mu.Unlock()
			}
		}()
	}
}

// POST /api/admin/settings — partial update: {"autoUpdate"?, "tmdbKey"?, "tmdbLang"?}
func (s *Server) handleSettings(w http.ResponseWriter, r *http.Request) {
	var b struct {
		AutoUpdate *bool   `json:"autoUpdate"`
		TMDBKey    *string `json:"tmdbKey"`
		TMDBLang   *string `json:"tmdbLang"`
		RTorrent   *string `json:"rtorrent"`
	}
	if !decodeJSON(w, r, &b) {
		return
	}
	cur := s.settings.Get()
	metaChanged := false
	if b.AutoUpdate != nil {
		cur.AutoUpdate = *b.AutoUpdate
	}
	if b.TMDBKey != nil && strings.TrimSpace(*b.TMDBKey) != cur.TMDBKey {
		cur.TMDBKey = strings.TrimSpace(*b.TMDBKey)
		metaChanged = true
	}
	if b.TMDBLang != nil && *b.TMDBLang != cur.TMDBLang {
		cur.TMDBLang = *b.TMDBLang
		metaChanged = true
	}
	if b.RTorrent != nil {
		cur.RTorrent = strings.TrimSpace(*b.RTorrent)
	}
	if err := s.settings.Set(cur); err != nil {
		httpErr(w, 500, err.Error())
		return
	}
	if metaChanged {
		go s.index.RefreshAllMetadata(b.TMDBLang != nil)
	}
	writeJSON(w, 200, s.adminSettings())
}

func (s *Server) adminSettings() map[string]any {
	cur := s.settings.Get()
	return map[string]any{"autoUpdate": cur.AutoUpdate, "tmdbKeySet": cur.TMDBKey != "", "tmdbLang": cur.TMDBLang, "rtorrent": cur.RTorrent, "update": s.updater.Status()}
}

func (s *Server) handleSettingsGet(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, s.adminSettings())
}
