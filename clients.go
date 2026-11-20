package main

// Which apps people use: kind (web / app), version, platform, browser — from the
// X-Delos-Client header the apps send (and the User-Agent for the web app).
// Shown to admins (Users, Watching now).

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

type ClientInfo struct {
	Kind     string `json:"kind"`              // web | app
	Version  string `json:"version,omitempty"` // app / web-page version
	OS       string `json:"os,omitempty"`      // Android 14, Windows, iOS 18.1, …
	Browser  string `json:"browser,omitempty"` // web: Chrome 131, Safari, …
	Last     int64  `json:"last"`
	Outdated bool   `json:"outdated,omitempty"` // older than this server
}

func (c ClientInfo) key() string { return c.Kind + "|" + c.OS + "|" + c.Browser }

// Label: "Android 14 app 2.7.2", "Chrome 131 on Windows".
func (c ClientInfo) Label() string {
	if c.Kind == "app" {
		return strings.TrimSpace(c.OS + " app " + c.Version)
	}
	s := c.Browser
	if s == "" {
		s = "Browser"
	}
	if c.OS != "" {
		s += " on " + c.OS
	}
	return s
}

type Clients struct {
	mu    sync.Mutex
	file  string
	by    map[string]map[string]*ClientInfo
	dirty bool
}

func NewClients(dataDir string) *Clients {
	c := &Clients{file: filepath.Join(dataDir, "clients.json"), by: map[string]map[string]*ClientInfo{}}
	if b, err := os.ReadFile(c.file); err == nil {
		json.Unmarshal(b, &c.by)
	}
	go func() {
		for range time.Tick(time.Minute) {
			c.flush()
		}
	}()
	return c
}

func (c *Clients) flush() {
	c.mu.Lock()
	if !c.dirty {
		c.mu.Unlock()
		return
	}
	b, err := json.Marshal(c.by)
	c.dirty = false
	c.mu.Unlock()
	if err == nil && os.WriteFile(c.file+".tmp", b, 0o600) == nil {
		os.Rename(c.file+".tmp", c.file)
	}
}

var (
	reChrome  = regexp.MustCompile(`(?:Chrome|CriOS)/(\d+)`)
	reEdge    = regexp.MustCompile(`Edg(?:e|A|iOS)?/(\d+)`)
	reFirefox = regexp.MustCompile(`(?:Firefox|FxiOS)/(\d+)`)
	reSafari  = regexp.MustCompile(`Version/(\d+)[.\d]* .*Safari/`)
	reAndroid = regexp.MustCompile(`Android (\d+(?:\.\d+)?)`)
	reIOS     = regexp.MustCompile(`(?:iPhone|iPad|iPod).*? OS (\d+)`)
	clean     = regexp.MustCompile(`[^\x20-\x7e]`)
)

// clientOf reads the request: "X-Delos-Client: app/2.7.2/android/14" or "web/2.7.2"; the web adds the User-Agent.
func clientOf(r *http.Request) ClientInfo {
	h := clean.ReplaceAllString(r.Header.Get("X-Delos-Client"), "")
	parts := strings.SplitN(h, "/", 4)
	ci := ClientInfo{Kind: "web"}
	if len(parts) > 0 && parts[0] == "app" {
		ci.Kind = "app"
	}
	if len(parts) > 1 {
		ci.Version = clip(parts[1], 30)
	}
	ua := r.UserAgent()
	if ci.Kind == "app" {
		osName := ""
		if len(parts) > 2 {
			osName = map[string]string{"android": "Android", "ios": "iOS", "windows": "Windows", "macos": "macOS", "linux": "Linux"}[strings.ToLower(parts[2])]
			if osName == "" {
				osName = clip(parts[2], 20)
			}
		}
		ci.OS = osName
		return ci
	}
	switch {
	case reEdge.MatchString(ua):
		ci.Browser = "Edge " + reEdge.FindStringSubmatch(ua)[1]
	case reFirefox.MatchString(ua):
		ci.Browser = "Firefox " + reFirefox.FindStringSubmatch(ua)[1]
	case strings.Contains(ua, "OPR/"):
		ci.Browser = "Opera"
	case reChrome.MatchString(ua):
		ci.Browser = "Chrome " + reChrome.FindStringSubmatch(ua)[1]
	case reSafari.MatchString(ua):
		ci.Browser = "Safari " + reSafari.FindStringSubmatch(ua)[1]
	}
	switch {
	case reAndroid.MatchString(ua):
		ci.OS = "Android " + reAndroid.FindStringSubmatch(ua)[1]
	case reIOS.MatchString(ua):
		ci.OS = "iOS " + reIOS.FindStringSubmatch(ua)[1]
	case strings.Contains(ua, "Windows"):
		ci.OS = "Windows"
	case strings.Contains(ua, "Mac OS X"):
		ci.OS = "macOS"
	case strings.Contains(ua, "CrOS"):
		ci.OS = "ChromeOS"
	case strings.Contains(ua, "Linux"):
		ci.OS = "Linux"
	}
	return ci
}

// Seen: a signed-in request from user (cheap; updates at most every 30 s per client).
func (c *Clients) Seen(user string, r *http.Request) ClientInfo {
	ci := clientOf(r)
	if ci.Kind == "web" && ci.Browser == "" && ci.Version == "" && r.Header.Get("X-Delos-Client") == "" {
		return ci // a media request / script without any hint: don't record
	}
	now := time.Now().Unix()
	c.mu.Lock()
	defer c.mu.Unlock()
	m := c.by[user]
	if m == nil {
		m = map[string]*ClientInfo{}
		c.by[user] = m
	}
	k := ci.key()
	if old := m[k]; old != nil && now-old.Last < 30 && old.Version == ci.Version {
		return *old
	}
	ci.Last = now
	m[k] = &ci
	// keep the 6 most recent, nothing older than 90 days
	if len(m) > 6 {
		var oldest string
		for k2, v := range m {
			if oldest == "" || v.Last < m[oldest].Last {
				oldest = k2
			}
		}
		delete(m, oldest)
	}
	for k2, v := range m {
		if now-v.Last > 90*86400 {
			delete(m, k2)
		}
	}
	c.dirty = true
	return ci
}

// Of: a user's clients, most recent first; outdated = an app older than this server.
func (c *Clients) Of(user string) []ClientInfo {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]ClientInfo, 0, len(c.by[user]))
	for _, v := range c.by[user] {
		x := *v
		if x.Version != "" && x.Version != "dev" && version != "" && version != "dev" && newerThan(version, x.Version) {
			x.Outdated = true
		}
		out = append(out, x)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Last > out[j].Last })
	return out
}

func (c *Clients) Forget(user string) {
	c.mu.Lock()
	delete(c.by, user)
	c.dirty = true
	c.mu.Unlock()
}
