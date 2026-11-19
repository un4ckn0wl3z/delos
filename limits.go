package main

// Stream limits, adjustable from the dashboard without a restart:
//   - remux:     light ffmpeg work — browser playback that only changes the
//                container (copy), and on-the-fly audio conversion (wma/ape → mp3)
//   - transcode: re-encoding video (Transcode mode, PGS burn-in) — CPU heavy
//   - per user:  different videos one user may watch at once (all kinds,
//                including Direct play; music doesn't count)

import (
	"context"
	"fmt"
	"net/http"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	ClassRemux     = "remux"
	ClassTranscode = "transcode"
	defaultRemux   = 10
)

type StreamLimiter struct {
	mu      sync.Mutex
	changed chan struct{} // closed + replaced whenever a slot frees up
	active  map[string]int
	users   map[string]map[string]int // user → video path → open requests
}

func NewStreamLimiter() *StreamLimiter {
	return &StreamLimiter{changed: make(chan struct{}), active: map[string]int{}, users: map[string]map[string]int{}}
}

// Limits currently in force (0 = unlimited for per-user).
func (s *Server) streamLimits() (remux, transcode, perUser int) {
	st := s.settings.Get()
	remux, transcode, perUser = st.MaxRemux, st.MaxTranscode, st.MaxPerUser
	if remux <= 0 {
		remux = defaultRemux
	}
	if transcode <= 0 {
		transcode = s.cfg.MaxStreams
		if transcode <= 0 {
			transcode = 3
		}
	}
	return
}

type limitError struct {
	code int
	msg  string
}

func (e *limitError) Error() string { return e.msg }

// acquire takes a slot of class (or none when class == "") and counts path
// against the user's limit. It waits up to 10 s for a slot — a seek starts a
// new request while the old one is still shutting down.
func (s *Server) acquireStream(ctx context.Context, class, user, path string, counts bool) (func(), error) {
	l := s.limiter
	deadline := time.After(10 * time.Second)
	for {
		maxRemux, maxTrans, maxUser := s.streamLimits()
		limit := 0
		switch class {
		case ClassRemux:
			limit = maxRemux
		case ClassTranscode:
			limit = maxTrans
		}
		l.mu.Lock()
		classFull := class != "" && l.active[class] >= limit
		userFull := false
		if counts && maxUser > 0 && !s.users.IsAdmin(user) {
			open := l.users[user]
			if open[path] == 0 && len(open) >= maxUser {
				userFull = true
			}
		}
		if !classFull && !userFull {
			if class != "" {
				l.active[class]++
			}
			if counts {
				if l.users[user] == nil {
					l.users[user] = map[string]int{}
				}
				l.users[user][path]++
			}
			l.mu.Unlock()
			var once sync.Once
			return func() {
				once.Do(func() {
					l.mu.Lock()
					if class != "" {
						l.active[class]--
					}
					if counts {
						if l.users[user][path]--; l.users[user][path] <= 0 {
							delete(l.users[user], path)
						}
					}
					close(l.changed)
					l.changed = make(chan struct{})
					l.mu.Unlock()
				})
			}, nil
		}
		wait := l.changed
		l.mu.Unlock()
		select {
		case <-wait:
		case <-deadline:
			if userFull {
				return nil, &limitError{429, fmt.Sprintf("You're already watching %d video(s) at once (limit %d) — close one first", maxUser, maxUser)}
			}
			if class == ClassTranscode {
				return nil, &limitError{503, fmt.Sprintf("The server is busy: %d of %d transcodes running — try Direct mode or wait a moment", limit, limit)}
			}
			return nil, &limitError{503, fmt.Sprintf("The server is busy: %d of %d streams running — try again in a moment", limit, limit)}
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
}

// startStream: acquire or answer the error. ok=false means the response is written.
func (s *Server) startStream(w http.ResponseWriter, r *http.Request, class string) (release func(), ok bool) {
	path := r.URL.Query().Get("path")
	counts := !audioExts[strings.ToLower(filepath.Ext(path))] // music doesn't count per user
	release, err := s.acquireStream(r.Context(), class, userOf(r), path, counts)
	if err != nil {
		if le, isLimit := err.(*limitError); isLimit {
			httpErr(w, le.code, le.msg)
		}
		return nil, false
	}
	return release, true
}

// wouldBlock: can this user start a stream of class for path right now?
func (s *Server) wouldBlock(class, user, path string) *limitError {
	maxRemux, maxTrans, maxUser := s.streamLimits()
	l := s.limiter
	l.mu.Lock()
	defer l.mu.Unlock()
	if maxUser > 0 && !s.users.IsAdmin(user) && !audioExts[strings.ToLower(filepath.Ext(path))] {
		if open := l.users[user]; open[path] == 0 && len(open) >= maxUser {
			return &limitError{429, fmt.Sprintf("You're already watching %d video(s) at once (limit %d) — close one first", maxUser, maxUser)}
		}
	}
	if class == ClassTranscode && l.active[class] >= maxTrans {
		return &limitError{503, fmt.Sprintf("The server is busy: %d of %d transcodes running — try Direct mode or wait a moment", maxTrans, maxTrans)}
	}
	if class == ClassRemux && l.active[class] >= maxRemux {
		return &limitError{503, fmt.Sprintf("The server is busy: %d of %d streams running — try again in a moment", maxRemux, maxRemux)}
	}
	return nil
}

// GET /api/stream/check?path=&kind=direct|copy|transcode — lets players show
// the reason instead of a bare playback error.
func (s *Server) handleStreamCheck(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Query().Get("path")
	if _, _, err := s.resolveFor(r, path); err != nil {
		httpErr(w, 404, err.Error())
		return
	}
	class := ""
	switch r.URL.Query().Get("kind") {
	case "copy":
		class = ClassRemux
	case "transcode":
		class = ClassTranscode
	}
	if le := s.wouldBlock(class, userOf(r), path); le != nil {
		httpErr(w, le.code, le.msg)
		return
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}

func (s *Server) streamUsage() map[string]any {
	remux, trans, perUser := s.streamLimits()
	l := s.limiter
	l.mu.Lock()
	defer l.mu.Unlock()
	return map[string]any{
		"remux": l.active[ClassRemux], "maxRemux": remux,
		"transcode": l.active[ClassTranscode], "maxTranscode": trans,
		"maxPerUser": perUser,
	}
}
