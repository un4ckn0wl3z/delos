package main

// Seek-bar previews ("trickplay"): a few sprite sheets of small frames, made
// once per video by ffmpeg from keyframes only (fast: nothing else is decoded)
// and kept in the cache. Hovering the seek bar shows the frame nearest that time.

import (
	"bufio"
	"context"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	trickW    = 240 // frame width in the sheets
	trickCols = 10
	trickRows = 10
)

// TrickInfo describes the sheets of one video: frame i (at i*Interval seconds)
// is in sheet i/(Cols*Rows), cell i%(Cols*Rows) counted left to right, top to bottom.
type TrickInfo struct {
	Ready    bool    `json:"ready"`
	Pending  bool    `json:"pending,omitempty"`
	Progress float64 `json:"progress,omitempty"` // 0..1 while pending
	Error    string  `json:"error,omitempty"`
	Interval float64 `json:"interval,omitempty"`
	W        int     `json:"w,omitempty"`
	H        int     `json:"h,omitempty"`
	Cols     int     `json:"cols,omitempty"`
	Rows     int     `json:"rows,omitempty"`
	Sheets   int     `json:"sheets,omitempty"`
	Count    int     `json:"count,omitempty"`
	Made     int64   `json:"made,omitempty"`
}

type trickJob struct {
	progress float64
}

var (
	trickMu   sync.Mutex
	trickJobs = map[string]*trickJob{}
	trickSem  = make(chan struct{}, 1) // one video at a time: be kind to the seedbox
)

func trickInterval(dur float64) float64 {
	switch {
	case dur <= 10*60:
		return 2
	case dur <= 30*60:
		return 5
	default:
		return 10
	}
}

func (s *Server) trickDir(abs string, fi os.FileInfo) string {
	sum := sha1.Sum([]byte(fmt.Sprintf("%s|%d|%d", abs, fi.Size(), fi.ModTime().Unix())))
	return filepath.Join(s.cfg.CacheDir, "trickplay", hex.EncodeToString(sum[:10]))
}

// GET /api/trickplay?path= — the sheet layout; 202 + {pending} while it is being made.
func (s *Server) handleTrickplay(w http.ResponseWriter, r *http.Request) {
	if os.Getenv("STREAMMKV_TRICKPLAY") == "0" {
		httpErr(w, 404, "seek previews are turned off")
		return
	}
	abs, fi, err := s.resolveFor(r, r.URL.Query().Get("path"))
	if err != nil {
		httpErr(w, 404, err.Error())
		return
	}
	dir := s.trickDir(abs, fi)
	if b, err := os.ReadFile(filepath.Join(dir, "info.json")); err == nil {
		var ti TrickInfo
		if json.Unmarshal(b, &ti) == nil {
			// a failure is retried after a day (ffmpeg may have been updated)
			if ti.Ready || time.Now().Unix()-ti.Made < 86400 {
				w.Header().Set("Cache-Control", "private, max-age=300")
				writeJSON(w, 200, ti)
				return
			}
		}
	}
	key := dir
	trickMu.Lock()
	job := trickJobs[key]
	if job == nil {
		info, err := s.media.Probe(r.Context(), abs, fi)
		if err != nil || info.Video == nil || info.Video.Width == 0 || info.Duration <= 0 {
			trickMu.Unlock()
			httpErr(w, 404, "no video to preview")
			return
		}
		job = &trickJob{}
		trickJobs[key] = job
		go s.makeTrickplay(key, abs, dir, info)
	}
	p := job.progress
	trickMu.Unlock()
	writeJSON(w, 202, TrickInfo{Pending: true, Progress: p})
}

// GET /api/trickplay/sheet?path=&n= — one sprite sheet (JPEG).
func (s *Server) handleTrickSheet(w http.ResponseWriter, r *http.Request) {
	abs, fi, err := s.resolveFor(r, r.URL.Query().Get("path"))
	if err != nil {
		httpErr(w, 404, err.Error())
		return
	}
	n, err := strconv.Atoi(r.URL.Query().Get("n"))
	if err != nil || n < 0 || n > 9999 {
		httpErr(w, 400, "bad sheet")
		return
	}
	f := filepath.Join(s.trickDir(abs, fi), fmt.Sprintf("s%03d.jpg", n+1))
	if _, err := os.Stat(f); err != nil {
		httpErr(w, 404, "no such sheet")
		return
	}
	w.Header().Set("Cache-Control", "private, max-age=2592000, immutable")
	w.Header().Set("Content-Type", "image/jpeg")
	http.ServeFile(w, r, f)
}

func (s *Server) makeTrickplay(key, abs, dir string, info *ProbeInfo) {
	defer func() {
		trickMu.Lock()
		delete(trickJobs, key)
		trickMu.Unlock()
	}()
	trickSem <- struct{}{}
	defer func() { <-trickSem }()

	iv := trickInterval(info.Duration)
	h := int(math.Round(float64(trickW)*float64(info.Video.Height)/float64(info.Video.Width)/2)) * 2
	if h < 2 {
		h = 136
	}
	count := int(math.Ceil(info.Duration / iv))
	ti := TrickInfo{Interval: iv, W: trickW, H: h, Cols: trickCols, Rows: trickRows, Count: count, Made: time.Now().Unix()}

	tmp := dir + ".part"
	os.RemoveAll(tmp)
	os.MkdirAll(tmp, 0o755)
	defer os.RemoveAll(tmp)

	// a film's keyframes decode in a minute or two; give up on anything stuck
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Minute)
	defer cancel()
	t0 := time.Now()
	cmd := exec.CommandContext(ctx, s.cfg.FFmpeg, "-hide_banner", "-nostdin", "-loglevel", "error",
		"-threads", "2", "-skip_frame", "nokey", "-i", abs,
		"-map", "0:v:0", "-an", "-sn", "-dn",
		"-vf", fmt.Sprintf("fps=1/%g,scale=%d:%d,tile=%dx%d", iv, trickW, h, trickCols, trickRows),
		"-q:v", "6", "-progress", "pipe:1",
		filepath.Join(tmp, "s%03d.jpg"))
	out, _ := cmd.StdoutPipe()
	var stderr strings.Builder
	cmd.Stderr = &stderr
	err := cmd.Start()
	if err == nil {
		sc := bufio.NewScanner(out)
		for sc.Scan() {
			// out_time follows the output clock, which moves a sheet (100 frames) at a time
			if v, ok := strings.CutPrefix(sc.Text(), "out_time_us="); ok {
				if us, err := strconv.ParseFloat(v, 64); err == nil && info.Duration > 0 {
					p := math.Min(0.99, us/1e6/info.Duration)
					trickMu.Lock()
					if j := trickJobs[key]; j != nil && p > j.progress {
						j.progress = p
					}
					trickMu.Unlock()
				}
			}
		}
		err = cmd.Wait()
	}
	sheets, _ := filepath.Glob(filepath.Join(tmp, "s*.jpg"))
	if err != nil || len(sheets) == 0 {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" && err != nil {
			msg = err.Error()
		}
		if len(msg) > 300 {
			msg = msg[len(msg)-300:]
		}
		log.Printf("trickplay %s: %v %s", filepath.Base(abs), err, msg)
		os.MkdirAll(dir, 0o755)
		b, _ := json.Marshal(TrickInfo{Error: "could not make previews", Made: time.Now().Unix()})
		os.WriteFile(filepath.Join(dir, "info.json"), b, 0o644)
		return
	}
	ti.Ready = true
	ti.Sheets = len(sheets)
	if max := ti.Sheets * trickCols * trickRows; ti.Count > max {
		ti.Count = max
	}
	b, _ := json.Marshal(ti)
	os.WriteFile(filepath.Join(tmp, "info.json"), b, 0o644)
	os.RemoveAll(dir)
	if err := os.Rename(tmp, dir); err != nil {
		log.Printf("trickplay %s: %v", filepath.Base(abs), err)
		return
	}
	log.Printf("trickplay %s: %d sheets in %s", filepath.Base(abs), ti.Sheets, time.Since(t0).Round(time.Second))
}
