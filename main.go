// StreamMKV — stream MKV files from a seedbox to a browser.
// The UI lives in a Tampermonkey userscript (web/streammkv.user.js).
package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

//go:embed web/index.html web/streammkv.user.js
var webFS embed.FS

type Config struct {
	Root       string
	Listen     string
	User       string
	Pass       string
	Secret     []byte
	FFmpeg     string
	FFprobe    string
	CacheDir   string
	TLSCert    string
	TLSKey     string
	Exts       map[string]bool
	MaxStreams int
	TokenTTL   time.Duration
}

type Server struct {
	cfg   Config
	media *Media
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	var cfg Config
	var exts, secret string
	var maxStreams int
	flag.StringVar(&cfg.Root, "root", envOr("STREAMMKV_ROOT", "."), "media root directory")
	flag.StringVar(&cfg.Listen, "listen", envOr("STREAMMKV_LISTEN", ":8090"), "listen address")
	flag.StringVar(&cfg.User, "user", envOr("STREAMMKV_USER", ""), "login username (required)")
	flag.StringVar(&cfg.Pass, "pass", envOr("STREAMMKV_PASS", ""), "login password (required)")
	flag.StringVar(&secret, "secret", envOr("STREAMMKV_SECRET", ""), "token signing secret (random if empty; tokens reset on restart)")
	flag.StringVar(&cfg.FFmpeg, "ffmpeg", envOr("STREAMMKV_FFMPEG", "ffmpeg"), "ffmpeg binary")
	flag.StringVar(&cfg.FFprobe, "ffprobe", envOr("STREAMMKV_FFPROBE", "ffprobe"), "ffprobe binary")
	flag.StringVar(&cfg.CacheDir, "cache", envOr("STREAMMKV_CACHE", ""), "subtitle cache dir (default: user cache dir)")
	flag.StringVar(&cfg.TLSCert, "tls-cert", envOr("STREAMMKV_TLS_CERT", ""), "TLS certificate (optional)")
	flag.StringVar(&cfg.TLSKey, "tls-key", envOr("STREAMMKV_TLS_KEY", ""), "TLS key (optional)")
	flag.StringVar(&exts, "ext", envOr("STREAMMKV_EXT", ".mkv"), "comma-separated file extensions to list")
	flag.IntVar(&maxStreams, "max-streams", 3, "max concurrent ffmpeg streams")
	flag.Parse()

	if cfg.User == "" || cfg.Pass == "" {
		log.Fatal("-user and -pass (or STREAMMKV_USER / STREAMMKV_PASS) are required")
	}
	root, err := filepath.Abs(cfg.Root)
	if err != nil {
		log.Fatal(err)
	}
	if st, err := os.Stat(root); err != nil || !st.IsDir() {
		log.Fatalf("root %q is not a directory", root)
	}
	cfg.Root = root
	if secret == "" {
		b := make([]byte, 32)
		rand.Read(b)
		cfg.Secret = b
	} else {
		cfg.Secret = []byte(secret)
	}
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

	s := &Server{cfg: cfg, media: NewMedia(&cfg)}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", s.handleIndex)
	mux.HandleFunc("GET /streammkv.user.js", s.handleUserscript)
	mux.HandleFunc("POST /api/login", s.handleLogin)
	mux.HandleFunc("POST /api/logout", s.handleLogout)
	mux.HandleFunc("GET /api/me", s.auth(func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, map[string]string{"user": s.cfg.User}) }))
	mux.HandleFunc("GET /api/list", s.auth(s.handleList))
	mux.HandleFunc("GET /api/probe", s.auth(s.handleProbe))
	mux.HandleFunc("GET /api/keyframe", s.auth(s.handleKeyframe))
	mux.HandleFunc("GET /api/stream", s.auth(s.handleStream))
	mux.HandleFunc("GET /api/subtitle", s.auth(s.handleSubtitle))

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           logRequests(mux),
		ReadHeaderTimeout: 15 * time.Second,
	}
	log.Printf("StreamMKV serving %s on %s (exts=%s)", cfg.Root, cfg.Listen, exts)
	if cfg.TLSCert != "" {
		log.Fatal(srv.ListenAndServeTLS(cfg.TLSCert, cfg.TLSKey))
	}
	log.Fatal(srv.ListenAndServe())
}

func logRequests(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		h.ServeHTTP(w, r)
		if strings.HasPrefix(r.URL.Path, "/api/stream") || strings.HasPrefix(r.URL.Path, "/api/subtitle") {
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

func (s *Server) handleIndex(w http.ResponseWriter, r *http.Request) {
	b, _ := webFS.ReadFile("web/index.html")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	w.Write(b)
}

func (s *Server) handleUserscript(w http.ResponseWriter, r *http.Request) {
	b, _ := webFS.ReadFile("web/streammkv.user.js")
	w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
	w.Write(b)
}

// ---------- auth ----------

const cookieName = "streammkv"

func (s *Server) sign(payload string) string {
	m := hmac.New(sha256.New, s.cfg.Secret)
	m.Write([]byte(payload))
	return base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

func (s *Server) makeToken() (string, time.Time) {
	exp := time.Now().Add(s.cfg.TokenTTL)
	payload := base64.RawURLEncoding.EncodeToString([]byte(s.cfg.User + "|" + strconv.FormatInt(exp.Unix(), 10)))
	return payload + "." + s.sign(payload), exp
}

func (s *Server) validToken(tok string) bool {
	payload, sig, ok := strings.Cut(tok, ".")
	if !ok || !hmac.Equal([]byte(sig), []byte(s.sign(payload))) {
		return false
	}
	raw, err := base64.RawURLEncoding.DecodeString(payload)
	if err != nil {
		return false
	}
	user, expStr, ok := strings.Cut(string(raw), "|")
	exp, err := strconv.ParseInt(expStr, 10, 64)
	return ok && err == nil && user == s.cfg.User && time.Now().Unix() < exp
}

func (s *Server) auth(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tok := ""
		if c, err := r.Cookie(cookieName); err == nil {
			tok = c.Value
		}
		if a := r.Header.Get("Authorization"); strings.HasPrefix(a, "Bearer ") {
			tok = strings.TrimPrefix(a, "Bearer ")
		}
		if q := r.URL.Query().Get("token"); q != "" {
			tok = q
		}
		if tok == "" || !s.validToken(tok) {
			httpErr(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		h(w, r)
	}
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
	uOK := subtle.ConstantTimeCompare([]byte(body.Username), []byte(s.cfg.User)) == 1
	pOK := subtle.ConstantTimeCompare([]byte(body.Password), []byte(s.cfg.Pass)) == 1
	if !uOK || !pOK {
		time.Sleep(time.Second) // slow down brute force
		log.Printf("failed login from %s", r.RemoteAddr)
		httpErr(w, 401, "invalid username or password")
		return
	}
	tok, exp := s.makeToken()
	http.SetCookie(w, &http.Cookie{
		Name: cookieName, Value: tok, Path: "/", Expires: exp,
		HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: secureReq(r),
	})
	writeJSON(w, 200, map[string]any{"token": tok, "expires": exp.Unix()})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: "", Path: "/", MaxAge: -1, HttpOnly: true})
	writeJSON(w, 200, map[string]bool{"ok": true})
}

// ---------- files ----------

type FileEntry struct {
	Path  string `json:"path"`
	Name  string `json:"name"`
	Dir   string `json:"dir"`
	Size  int64  `json:"size"`
	MTime int64  `json:"mtime"`
}

func (s *Server) handleList(w http.ResponseWriter, r *http.Request) {
	files := []FileEntry{}
	filepath.WalkDir(s.cfg.Root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		name := d.Name()
		if strings.HasPrefix(name, ".") && p != s.cfg.Root {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() || !s.cfg.Exts[strings.ToLower(filepath.Ext(name))] {
			return nil
		}
		info, err := d.Info()
		if err != nil || !info.Mode().IsRegular() {
			return nil
		}
		rel, _ := filepath.Rel(s.cfg.Root, p)
		rel = filepath.ToSlash(rel)
		dir := filepath.ToSlash(filepath.Dir(rel))
		if dir == "." {
			dir = ""
		}
		files = append(files, FileEntry{Path: rel, Name: name, Dir: dir, Size: info.Size(), MTime: info.ModTime().Unix()})
		return nil
	})
	sort.Slice(files, func(i, j int) bool { return strings.ToLower(files[i].Path) < strings.ToLower(files[j].Path) })
	writeJSON(w, 200, map[string]any{"files": files})
}

// resolve maps a client-supplied relative path to an absolute path inside root.
func (s *Server) resolve(rel string) (string, os.FileInfo, error) {
	if rel == "" {
		return "", nil, errors.New("missing path")
	}
	p := filepath.Join(s.cfg.Root, filepath.FromSlash(rel))
	r2, err := filepath.Rel(s.cfg.Root, p)
	if err != nil || r2 == ".." || strings.HasPrefix(r2, ".."+string(filepath.Separator)) || filepath.IsAbs(r2) {
		return "", nil, errors.New("invalid path")
	}
	if !s.cfg.Exts[strings.ToLower(filepath.Ext(p))] {
		return "", nil, errors.New("file type not allowed")
	}
	st, err := os.Stat(p)
	if err != nil || !st.Mode().IsRegular() {
		return "", nil, errors.New("not found")
	}
	return p, st, nil
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
