// Delos (formerly StreamMKV) — films and music from a seedbox, in the browser and the apps.
// The UI is a web app the server serves itself (web/app.js); the player can
// decode the original file in the browser (web/player-wasm.mjs).
package main

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

//go:embed web/index.html web/admin.html web/app.js web/player-wasm.mjs web/streammkv.user.js web/manifest.webmanifest web/tls.html web/emoji.json web/*.png web/vendor/*.mjs
var webFS embed.FS

var tlsMode string

type Config struct {
	Root       string
	Listen     string
	User       string
	Pass       string
	Secret     []byte
	FFmpeg     string
	FFprobe    string
	CacheDir   string
	DataDir    string
	TLSCert    string
	TLSKey     string
	Exts       map[string]bool
	MaxStreams int
	TokenTTL   time.Duration
}

type Server struct {
	cfg       Config
	media     *Media
	progress  *ProgressStore
	users     *UserStore
	conns     *ConnRegistry
	limiter   *StreamLimiter
	settings  *SettingsStore
	updater   *Updater
	libs      *LibraryStore
	index     *Indexer
	dl        *Downloads
	chat      *Chat
	avatars   *Avatars
	tls       *TLSManager
	playlists *Playlists
	stats     *Stats
	parties   *Parties
	clients   *Clients
	remotes   *Remotes
	ann       *Announcements
	started   time.Time
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "user" {
		runUserCLI(os.Args[2:])
		return
	}
	if len(os.Args) > 1 && (os.Args[1] == "version" || os.Args[1] == "-version") {
		fmt.Println("streammkv", version)
		return
	}
	var cfg Config
	var exts, secret string
	var maxStreams int
	flag.StringVar(&cfg.Root, "root", envOr("STREAMMKV_ROOT", "."), "media root for the first library (later libraries are managed in /admin)")
	flag.StringVar(&cfg.Listen, "listen", envOr("STREAMMKV_LISTEN", ":8090"), "listen address")
	flag.StringVar(&cfg.User, "user", envOr("STREAMMKV_USER", ""), "initial admin username (used only when no users exist yet)")
	flag.StringVar(&cfg.Pass, "pass", envOr("STREAMMKV_PASS", ""), "initial admin password (used only when no users exist yet)")
	flag.StringVar(&secret, "secret", envOr("STREAMMKV_SECRET", ""), "token signing secret (default: random, saved in <data>/secret.key)")
	flag.StringVar(&cfg.FFmpeg, "ffmpeg", envOr("STREAMMKV_FFMPEG", "ffmpeg"), "ffmpeg binary")
	flag.StringVar(&cfg.FFprobe, "ffprobe", envOr("STREAMMKV_FFPROBE", "ffprobe"), "ffprobe binary")
	flag.StringVar(&cfg.CacheDir, "cache", envOr("STREAMMKV_CACHE", ""), "subtitle cache dir (default: user cache dir)")
	flag.StringVar(&cfg.DataDir, "data", envOr("STREAMMKV_DATA", ""), "data dir for watch progress (default: cache dir)")
	flag.StringVar(&cfg.TLSCert, "tls-cert", envOr("STREAMMKV_TLS_CERT", ""), "TLS certificate (optional)")
	flag.StringVar(&cfg.TLSKey, "tls-key", envOr("STREAMMKV_TLS_KEY", ""), "TLS key (optional)")
	flag.StringVar(&tlsMode, "tls", envOr("STREAMMKV_TLS", "on"), "HTTPS on the same port: on (built-in certificate unless -tls-cert is set) or off")
	flag.StringVar(&exts, "ext", envOr("STREAMMKV_EXT", defaultVideoExts), "comma-separated video file extensions")
	flag.IntVar(&maxStreams, "max-streams", envInt("STREAMMKV_MAX_STREAMS", 3), "default max concurrent transcodes (re-encoding); adjustable in /admin")
	flag.Parse()

	root, err := filepath.Abs(cfg.Root)
	if err != nil {
		log.Fatal(err)
	}
	if st, err := os.Stat(root); err != nil || !st.IsDir() {
		log.Fatalf("root %q is not a directory", root)
	}
	cfg.Root = root
	if cfg.CacheDir == "" {
		d, err := os.UserCacheDir()
		if err != nil {
			d = os.TempDir()
		}
		cfg.CacheDir = filepath.Join(d, "streammkv")
	}
	if err := os.MkdirAll(cfg.CacheDir, 0o755); err != nil {
		log.Fatal(err)
	}
	if cfg.DataDir == "" {
		cfg.DataDir = cfg.CacheDir
	}
	if err := os.MkdirAll(cfg.DataDir, 0o700); err != nil {
		log.Fatal(err)
	}
	cfg.Exts = map[string]bool{}
	for _, e := range strings.Split(exts, ",") {
		e = strings.ToLower(strings.TrimSpace(e))
		if e == "" {
			continue
		}
		if !strings.HasPrefix(e, ".") {
			e = "." + e
		}
		cfg.Exts[e] = true
	}
	cfg.MaxStreams = maxStreams
	cfg.TokenTTL = 30 * 24 * time.Hour

	if secret == "" {
		// persist a random signing key so sessions survive restarts and self-updates
		keyFile := filepath.Join(cfg.DataDir, "secret.key")
		if b, err := os.ReadFile(keyFile); err == nil && len(b) >= 32 {
			cfg.Secret = b
		} else {
			b := make([]byte, 32)
			rand.Read(b)
			if err := os.WriteFile(keyFile, b, 0o600); err != nil {
				log.Printf("warning: cannot save %s: %v (sessions reset on restart)", keyFile, err)
			}
			cfg.Secret = b
		}
	} else {
		cfg.Secret = []byte(secret)
	}
	users, err := NewUserStore(cfg.DataDir)
	if err != nil {
		log.Fatal(err)
	}
	if users.Count() == 0 {
		if cfg.User == "" || cfg.Pass == "" {
			log.Fatal("no users yet: set -user and -pass (STREAMMKV_USER / STREAMMKV_PASS) for the first admin, or run `streammkv user add NAME --admin`")
		}
		if err := users.AddBootstrap(cfg.User, cfg.Pass); err != nil {
			log.Fatalf("create admin %q: %v", cfg.User, err)
		}
		log.Printf("created admin user %q", cfg.User)
	}
	go users.Watch()
	legacy := cfg.User
	if legacy == "" {
		for _, u := range users.List() {
			if u.Admin {
				legacy = u.Name
				break
			}
		}
	}
	libs, migrated, err := NewLibraryStore(cfg.DataDir, cfg.Root, cfg.Exts)
	if err != nil {
		log.Fatal(err)
	}
	s := &Server{cfg: cfg, media: NewMedia(&cfg), progress: NewProgressStore(cfg.DataDir, legacy),
		users: users, conns: NewConnRegistry(), limiter: NewStreamLimiter(), started: time.Now(), settings: NewSettingsStore(cfg.DataDir), libs: libs}
	if migrated {
		s.progress.PrefixKeys("main/") // paths are now "<library>/<relative path>"
		log.Printf("created library \"main\" for %s; add more in /admin", cfg.Root)
	}
	s.index = NewIndexer(s)
	s.dl = NewDownloads(s)
	s.chat = NewChat(s)
	s.parties = NewParties(s, cfg.DataDir)
	s.clients = NewClients(cfg.DataDir)
	s.avatars = NewAvatars(cfg.DataDir)
	s.ann = NewAnnouncements(s)
	s.playlists = NewPlaylists(cfg.DataDir)
	s.stats = NewStats(cfg.DataDir)
	if s.tls, err = NewTLSManager(cfg, tlsMode); err != nil {
		log.Printf("tls: %v — HTTPS disabled", err)
		s.tls = &TLSManager{mode: "off"}
	}
	go s.index.Loop()
	s.updater = NewUpdater(s, s.settings)
	go s.updater.Loop()

	mux := http.NewServeMux()
	s.staticRoutes(mux)
	mux.HandleFunc("POST /api/login", s.handleLogin)
	mux.HandleFunc("POST /api/logout", s.handleLogout)
	mux.HandleFunc("GET /api/me", s.auth(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"user": userOf(r), "admin": isAdmin(r), "roles": s.users.RoleNames(userOf(r)), "editor": s.canEdit(r), "downloader": s.users.IsDownloader(userOf(r)), "offline": s.users.IsOffline(userOf(r)), "avatar": s.avatars.Version(userOf(r)), "version": version, "https": s.tls.Enabled(), "chatMaxMB": s.settings.Get().ChatMaxMB})
	}))
	mux.HandleFunc("POST /api/me/password", s.auth(s.handleOwnPassword))
	mux.HandleFunc("GET /admin", s.handleAdminPage)
	s.adminRoutes(mux)
	mux.HandleFunc("GET /api/list", s.auth(s.handleList))
	mux.HandleFunc("GET /api/probe", s.auth(s.handleProbe))
	mux.HandleFunc("GET /api/keyframe", s.auth(s.handleKeyframe))
	mux.HandleFunc("GET /api/stream", s.auth(s.handleStream))
	mux.HandleFunc("GET /api/stream/check", s.auth(s.handleStreamCheck))
	mux.HandleFunc("GET /api/subtitle", s.auth(s.handleSubtitle))
	mux.HandleFunc("GET /api/lyrics", s.auth(s.handleLyrics))
	mux.HandleFunc("GET /api/trickplay", s.auth(s.handleTrickplay))
	mux.HandleFunc("GET /api/trickplay/sheet", s.auth(s.handleTrickSheet))
	mux.HandleFunc("GET /api/raw", s.auth(s.handleRaw))
	mux.HandleFunc("GET /api/progress", s.auth(s.handleProgressGet))
	mux.HandleFunc("POST /api/progress", s.auth(s.handleProgressPost))
	s.libraryRoutes(mux)
	s.editRoutes(mux)
	s.downloadRoutes(mux)
	s.personalRoutes(mux)
	s.chatRoutes(mux)
	s.offlineRoutes(mux)
	s.torrentRoutes(mux)
	s.avatarRoutes(mux)
	s.announcementRoutes(mux)
	s.tlsRoutes(mux)
	s.playlistRoutes(mux)
	s.statsRoutes(mux)
	s.partyRoutes(mux)
	s.remoteRoutes(mux)
	s.roleRoutes(mux)

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           logRequests(mux),
		ReadHeaderTimeout: 15 * time.Second,
	}
	log.Printf("Delos %s on %s (%d libraries, %d users)", version, cfg.Listen, len(libs.List()), users.Count())
	ln, err := net.Listen("tcp", cfg.Listen)
	if err != nil {
		log.Fatal(err)
	}
	if !s.tls.Enabled() {
		log.Fatal(srv.Serve(ln))
	}
	sn := newSniffListener(ln)
	srv.TLSConfig = &tls.Config{GetCertificate: s.tls.GetCertificate, MinVersion: tls.VersionTLS12, NextProtos: []string{"h2", "http/1.1"}}
	log.Printf("HTTP and HTTPS (%s certificate) on the same port", s.tls.mode)
	go func() { log.Fatal(srv.ServeTLS(sn.tls, "", "")) }()
	log.Fatal(srv.Serve(sn.plain))
}

func logRequests(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		h.ServeHTTP(w, r)
		if strings.HasPrefix(r.URL.Path, "/api/stream") || strings.HasPrefix(r.URL.Path, "/api/subtitle") || strings.HasPrefix(r.URL.Path, "/api/raw") {
			log.Printf("%s %s %s (%s)", r.RemoteAddr, r.Method, r.URL.Path, time.Since(start).Round(time.Millisecond))
		}
	})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func httpErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

// ---------- static ----------

// ---------- auth ----------

const cookieName = "streammkv"

// Plain-http logins use their own cookie. A browser won't let an http:// page replace a
// "Secure" cookie an https:// visit left behind (same name), so logging in over http after
// using https would silently fail and loop back to the login page.
const cookieNameHTTP = "streammkv_h"

func (s *Server) setSession(w http.ResponseWriter, r *http.Request, tok string, exp time.Time) {
	name, secure := cookieNameHTTP, false
	if secureReq(r) {
		name, secure = cookieName, true
	}
	http.SetCookie(w, &http.Cookie{Name: name, Value: tok, Path: "/", Expires: exp, HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: secure})
}

func clearSession(w http.ResponseWriter, r *http.Request) {
	http.SetCookie(w, &http.Cookie{Name: cookieNameHTTP, Value: "", Path: "/", MaxAge: -1, HttpOnly: true})
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: "", Path: "/", MaxAge: -1, HttpOnly: true, Secure: secureReq(r)})
}

func (s *Server) sign(payload string) string {
	m := hmac.New(sha256.New, s.cfg.Secret)
	m.Write([]byte(payload))
	return base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

type ctxKey int

const (
	ctxUser ctxKey = iota
	ctxAdmin
)

func userOf(r *http.Request) string { v, _ := r.Context().Value(ctxUser).(string); return v }
func isAdmin(r *http.Request) bool  { v, _ := r.Context().Value(ctxAdmin).(bool); return v }

func (s *Server) makeToken(user string, gen int) (string, time.Time) {
	exp := time.Now().Add(s.cfg.TokenTTL)
	payload := base64.RawURLEncoding.EncodeToString([]byte(user + "|" + strconv.FormatInt(exp.Unix(), 10) + "|" + strconv.Itoa(gen)))
	return payload + "." + s.sign(payload), exp
}

// validToken returns the user name and admin flag for a valid token.
func (s *Server) validToken(tok string) (string, bool, bool) {
	payload, sig, ok := strings.Cut(tok, ".")
	if !ok || !hmac.Equal([]byte(sig), []byte(s.sign(payload))) {
		return "", false, false
	}
	raw, err := base64.RawURLEncoding.DecodeString(payload)
	if err != nil {
		return "", false, false
	}
	parts := strings.Split(string(raw), "|")
	if len(parts) != 3 {
		return "", false, false
	}
	exp, err1 := strconv.ParseInt(parts[1], 10, 64)
	gen, err2 := strconv.Atoi(parts[2])
	if err1 != nil || err2 != nil || time.Now().Unix() >= exp {
		return "", false, false
	}
	admin, ok := s.users.Valid(parts[0], gen)
	return parts[0], admin, ok
}

func (s *Server) auth(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// candidates: ?token=, Bearer, then every session cookie (an old one may sit beside a fresh one)
		var toks []string
		if q := r.URL.Query().Get("token"); q != "" {
			toks = append(toks, q)
		}
		if a := r.Header.Get("Authorization"); strings.HasPrefix(a, "Bearer ") {
			toks = append(toks, strings.TrimPrefix(a, "Bearer "))
		}
		for _, c := range r.Cookies() {
			if (c.Name == cookieName || c.Name == cookieNameHTTP) && c.Value != "" {
				toks = append(toks, c.Value)
			}
		}
		var user string
		var admin, ok bool
		for _, tok := range toks {
			if user, admin, ok = s.validToken(tok); ok {
				break
			}
		}
		if !ok {
			httpErr(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		if r.Header.Get("X-Delos-Client") != "" {
			s.clients.Seen(user, r)
		}
		ctx := context.WithValue(context.WithValue(r.Context(), ctxUser, user), ctxAdmin, admin)
		h(w, r.WithContext(ctx))
	}
}

func (s *Server) adminOnly(h http.HandlerFunc) http.HandlerFunc {
	return s.auth(func(w http.ResponseWriter, r *http.Request) {
		if !isAdmin(r) {
			httpErr(w, http.StatusForbidden, "admin only")
			return
		}
		if s.tls != nil {
			s.tls.Learn(r.Host)
		}
		h(w, r)
	})
}

func secureReq(r *http.Request) bool {
	return r.TLS != nil || strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https")
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	var body struct{ Username, Password string }
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body); err != nil {
		httpErr(w, 400, "bad request")
		return
	}
	gen, ok := s.users.Authenticate(body.Username, body.Password)
	if !ok {
		time.Sleep(time.Second) // slow down brute force
		log.Printf("failed login from %s", r.RemoteAddr)
		httpErr(w, 401, "invalid username or password")
		return
	}
	admin, _ := s.users.Valid(body.Username, gen) // also marks last seen
	tok, exp := s.makeToken(body.Username, gen)
	s.setSession(w, r, tok, exp)
	log.Printf("login %q from %s", body.Username, r.RemoteAddr)
	writeJSON(w, 200, map[string]any{"token": tok, "expires": exp.Unix(), "user": body.Username, "admin": admin})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	clearSession(w, r)
	writeJSON(w, 200, map[string]bool{"ok": true})
}

// ---------- files ----------

type FileEntry struct {
	Path  string `json:"path"`
	Name  string `json:"name"`
	Dir   string `json:"dir"`
	Size  int64  `json:"size"`
	MTime int64  `json:"mtime"`
	// watch progress (shared across clients)
	Pos      float64 `json:"pos,omitempty"`
	Duration float64 `json:"duration,omitempty"`
}

// handleList is the v1 flat file list (userscript ≤1.3, app ≤1.3): every video
// file of every library the user can see. Dir is prefixed with the library name.
func (s *Server) handleList(w http.ResponseWriter, r *http.Request) {
	files := []FileEntry{}
	prog := s.progress.All(userOf(r))
	for _, lib := range s.visibleLibraries(r) {
		if lib.Type == LibMusic {
			continue
		}
		for _, it := range s.index.Items(lib.ID) {
			dir := lib.Name
			if it.Dir != "" {
				dir += "/" + it.Dir
			}
			f := FileEntry{Path: it.Path, Name: it.Name, Dir: dir, Size: it.Size, MTime: it.MTime}
			if p, ok := prog[it.Path]; ok {
				f.Pos, f.Duration = p.Pos, p.Duration
			}
			files = append(files, f)
		}
	}
	sort.Slice(files, func(i, j int) bool {
		return strings.ToLower(files[i].Dir+"/"+files[i].Name) < strings.ToLower(files[j].Dir+"/"+files[j].Name)
	})
	writeJSON(w, 200, map[string]any{"files": files})
}

func cacheKey(parts ...string) string {
	h := sha256.Sum256([]byte(strings.Join(parts, "\x00")))
	return hex.EncodeToString(h[:12])
}

func qInt(r *http.Request, k string, def int) int {
	if v, err := strconv.Atoi(r.URL.Query().Get(k)); err == nil {
		return v
	}
	return def
}

func qFloat(r *http.Request, k string, def float64) float64 {
	if v, err := strconv.ParseFloat(r.URL.Query().Get(k), 64); err == nil && v >= 0 {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(key)); err == nil && v > 0 {
		return v
	}
	return def
}
