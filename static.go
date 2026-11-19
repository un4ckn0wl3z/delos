package main

import (
	"bytes"
	"compress/gzip"
	"net/http"
	"path"
	"strings"
	"sync"
)

// The web app: index.html (templated with the version), app.js, the in-browser
// player engine, Mediabunny (vendor/), icons and the PWA manifest — all embedded.
// Text files are gzipped once and kept in memory.

var staticFiles = map[string]string{ // URL path → embedded file
	"/app.js":                "web/app.js",
	"/player-wasm.mjs":       "web/player-wasm.mjs",
	"/manifest.webmanifest":  "web/manifest.webmanifest",
	"/icon-192.png":          "web/icon-192.png",
	"/icon-512.png":          "web/icon-512.png",
	"/icon-maskable-512.png": "web/icon-maskable-512.png",
	"/apple-touch-icon.png":  "web/apple-touch-icon.png",
	"/favicon.png":           "web/favicon.png",
	"/favicon.ico":           "web/favicon.png",
	"/streammkv.user.js":     "web/streammkv.user.js",
	"/tls":                   "web/tls.html",
	"/emoji.json":            "web/emoji.json",
}

type staticEntry struct {
	raw, gz []byte
	ctype   string
}

var (
	staticMu    sync.Mutex
	staticCache = map[string]*staticEntry{}
)

func staticType(name string) string {
	switch path.Ext(name) {
	case ".js", ".mjs":
		return "text/javascript; charset=utf-8"
	case ".html":
		return "text/html; charset=utf-8"
	case ".webmanifest":
		return "application/manifest+json"
	case ".png":
		return "image/png"
	case ".json":
		return "application/json; charset=utf-8"
	}
	return "application/octet-stream"
}

func loadStatic(file string) (*staticEntry, bool) {
	staticMu.Lock()
	defer staticMu.Unlock()
	if e, ok := staticCache[file]; ok {
		return e, true
	}
	b, err := webFS.ReadFile(file)
	if err != nil {
		return nil, false
	}
	if file == "web/index.html" {
		b = bytes.ReplaceAll(b, []byte("{{VERSION}}"), []byte(version))
	}
	e := &staticEntry{raw: b, ctype: staticType(file)}
	if !strings.HasSuffix(file, ".png") && len(b) > 1024 {
		var buf bytes.Buffer
		zw, _ := gzip.NewWriterLevel(&buf, gzip.BestCompression)
		zw.Write(b)
		zw.Close()
		e.gz = buf.Bytes()
	}
	staticCache[file] = e
	return e, true
}

func serveStatic(w http.ResponseWriter, r *http.Request, file string) {
	e, ok := loadStatic(file)
	if !ok {
		http.NotFound(w, r)
		return
	}
	h := w.Header()
	h.Set("Content-Type", e.ctype)
	h.Set("X-Content-Type-Options", "nosniff")
	// versioned URLs (?v=…) never change; everything else revalidates
	if r.URL.Query().Get("v") != "" {
		h.Set("Cache-Control", "public, max-age=31536000, immutable")
	} else {
		h.Set("Cache-Control", "no-cache")
	}
	etag := `"` + version + `"`
	h.Set("ETag", etag)
	h.Add("Vary", "Accept-Encoding")
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	body := e.raw
	if e.gz != nil && strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
		h.Set("Content-Encoding", "gzip")
		body = e.gz
	}
	if r.Method == http.MethodHead {
		return
	}
	w.Write(body)
}

func (s *Server) staticRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Frame-Options", "SAMEORIGIN")
		serveStatic(w, r, "web/index.html")
	})
	for u, f := range staticFiles {
		mux.HandleFunc("GET "+u, func(w http.ResponseWriter, r *http.Request) { serveStatic(w, r, f) })
	}
	mux.HandleFunc("GET /vendor/{file}", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("file")
		if strings.ContainsAny(name, "/\\") || !strings.HasSuffix(name, ".mjs") {
			http.NotFound(w, r)
			return
		}
		serveStatic(w, r, "web/vendor/"+name)
	})
}
