package main

import (
	"bytes"
	"errors"
	"image"
	"image/color"
	"image/draw"
	_ "image/gif"
	"image/jpeg"
	_ "image/png"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sync"
	"time"
)

// Profile pictures: a 256×256 JPEG per user in <data>/avatars/<user>.jpg.
// Uploads (JPEG / PNG / GIF, up to 10 MB) are center-cropped and scaled here,
// so clients can send any photo as it is.

const avatarSize = 256

var reSafeUser = regexp.MustCompile(`^[A-Za-z0-9._@-]{1,64}$`)

type Avatars struct {
	dir string
	mu  sync.Mutex
	ver map[string]int64 // user → mtime (cache-busting version), 0 = none
}

func NewAvatars(dataDir string) *Avatars {
	a := &Avatars{dir: filepath.Join(dataDir, "avatars"), ver: map[string]int64{}}
	os.MkdirAll(a.dir, 0o755)
	if ents, err := os.ReadDir(a.dir); err == nil {
		for _, e := range ents {
			if n, ok := cutSuffix(e.Name(), ".jpg"); ok {
				if fi, err := e.Info(); err == nil {
					a.ver[n] = fi.ModTime().Unix()
				}
			}
		}
	}
	return a
}

func cutSuffix(s, suf string) (string, bool) {
	if len(s) > len(suf) && s[len(s)-len(suf):] == suf {
		return s[:len(s)-len(suf)], true
	}
	return "", false
}

func (a *Avatars) path(user string) string { return filepath.Join(a.dir, user+".jpg") }

// Version: 0 when the user has no picture (clients show initials).
func (a *Avatars) Version(user string) int64 {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.ver[user]
}

func (a *Avatars) Set(user string, data []byte) error {
	if !reSafeUser.MatchString(user) {
		return errors.New("unsupported user name")
	}
	src, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return errors.New("that isn't a JPG, PNG or GIF image")
	}
	b := src.Bounds()
	if b.Dx() < 16 || b.Dy() < 16 {
		return errors.New("the image is too small")
	}
	if b.Dx()*b.Dy() > 50_000_000 {
		return errors.New("the image is too large")
	}
	out := squareThumb(src, avatarSize)
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, out, &jpeg.Options{Quality: 86}); err != nil {
		return err
	}
	tmp := a.path(user) + ".tmp"
	if err := os.WriteFile(tmp, buf.Bytes(), 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, a.path(user)); err != nil {
		return err
	}
	a.mu.Lock()
	a.ver[user] = max(time.Now().Unix(), a.ver[user]+1)
	a.mu.Unlock()
	return nil
}

func (a *Avatars) Delete(user string) {
	os.Remove(a.path(user))
	a.mu.Lock()
	delete(a.ver, user)
	a.mu.Unlock()
}

// squareThumb center-crops to a square and scales to n×n by area averaging.
func squareThumb(src image.Image, n int) *image.RGBA {
	b := src.Bounds()
	side := min(b.Dx(), b.Dy())
	x0, y0 := b.Min.X+(b.Dx()-side)/2, b.Min.Y+(b.Dy()-side)/2
	// flatten onto white (transparent PNGs) in RGBA for fast access
	flat := image.NewRGBA(image.Rect(0, 0, side, side))
	draw.Draw(flat, flat.Bounds(), image.NewUniform(color.White), image.Point{}, draw.Src)
	draw.Draw(flat, flat.Bounds(), src, image.Pt(x0, y0), draw.Over)
	if side <= n {
		out := image.NewRGBA(image.Rect(0, 0, n, n))
		for y := 0; y < n; y++ {
			for x := 0; x < n; x++ {
				out.Set(x, y, flat.At(x*side/n, y*side/n))
			}
		}
		return out
	}
	out := image.NewRGBA(image.Rect(0, 0, n, n))
	for y := 0; y < n; y++ {
		sy0, sy1 := y*side/n, (y+1)*side/n
		for x := 0; x < n; x++ {
			sx0, sx1 := x*side/n, (x+1)*side/n
			var r, g, bl, cnt uint64
			for sy := sy0; sy < sy1; sy++ {
				row := flat.Pix[sy*flat.Stride:]
				for sx := sx0; sx < sx1; sx++ {
					p := row[sx*4:]
					r += uint64(p[0])
					g += uint64(p[1])
					bl += uint64(p[2])
					cnt++
				}
			}
			if cnt == 0 {
				cnt = 1
			}
			i := y*out.Stride + x*4
			out.Pix[i], out.Pix[i+1], out.Pix[i+2], out.Pix[i+3] = uint8(r/cnt), uint8(g/cnt), uint8(bl/cnt), 255
		}
	}
	return out
}

// ---------------------------------------------------------------- API

func (s *Server) avatarRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/avatar/{name}", s.auth(s.handleAvatarGet))
	mux.HandleFunc("POST /api/me/avatar", s.auth(s.handleAvatarSet))
	mux.HandleFunc("DELETE /api/me/avatar", s.auth(s.handleAvatarDelete))
	mux.HandleFunc("DELETE /api/admin/users/{name}/avatar", s.adminOnly(s.handleAdminAvatarDelete))
}

func (s *Server) handleAvatarGet(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if !reSafeUser.MatchString(name) || s.avatars.Version(name) == 0 {
		http.NotFound(w, r)
		return
	}
	f, err := os.Open(s.avatars.path(name))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer f.Close()
	fi, _ := f.Stat()
	w.Header().Set("Content-Type", "image/jpeg")
	// URLs carry ?v=<version>, so the image itself never changes
	if r.URL.Query().Get("v") != "" {
		w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	} else {
		w.Header().Set("Cache-Control", "private, no-cache")
	}
	http.ServeContent(w, r, "", fi.ModTime(), f)
}

// POST /api/me/avatar — the image as the body, or multipart field "file"
func (s *Server) handleAvatarSet(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 10<<20)
	var data []byte
	var err error
	if ct := r.Header.Get("Content-Type"); len(ct) >= 19 && ct[:19] == "multipart/form-data" {
		f, _, ferr := r.FormFile("file")
		if ferr != nil {
			httpErr(w, 400, "send the picture in the \"file\" field")
			return
		}
		defer f.Close()
		data, err = io.ReadAll(f)
	} else {
		data, err = io.ReadAll(r.Body)
	}
	if err != nil {
		httpErr(w, 413, "pictures can be up to 10 MB")
		return
	}
	if err := s.avatars.Set(userOf(r), data); err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	s.chat.broadcastPresence()
	writeJSON(w, 200, map[string]any{"avatar": s.avatars.Version(userOf(r))})
}

func (s *Server) handleAvatarDelete(w http.ResponseWriter, r *http.Request) {
	s.avatars.Delete(userOf(r))
	s.chat.broadcastPresence()
	writeJSON(w, 200, map[string]any{"avatar": 0})
}

func (s *Server) handleAdminAvatarDelete(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if !reSafeUser.MatchString(name) {
		httpErr(w, 400, "bad name")
		return
	}
	s.avatars.Delete(name)
	s.chat.broadcastPresence()
	writeJSON(w, 200, map[string]any{"ok": true})
}
