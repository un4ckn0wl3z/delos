package main

// Seek-bar previews ("trickplay"): a few sprite sheets of small frames, made once
// per video and kept in the cache (<cache>/previews). Each frame is grabbed by
// jumping to its moment and decoding a single keyframe, so big files cost no more
// than small ones. Hovering the seek bar shows the frame nearest that time.

import (
	"bytes"
	"context"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/draw"
	"image/jpeg"
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
	// frames per video at most (a 2 h film: one every 15 s)
	trickMaxFrames = 480
	// ffmpeg processes per video: each one jumps to a moment and decodes one keyframe
	trickWorkers = 3
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

// trickInterval: seconds between frames — 2 s for short videos, 5 s up to half an
// hour, 10 s beyond, then wider so a long film stays under trickMaxFrames.
func trickInterval(dur float64) float64 {
	iv := 10.0
	switch {
	case dur <= 10*60:
		iv = 2
	case dur <= 30*60:
		iv = 5
	}
	if dur/iv > trickMaxFrames {
		iv = math.Ceil(dur / trickMaxFrames)
	}
	return iv
}

func (s *Server) trickDir(abs string, fi os.FileInfo) string {
	sum := sha1.Sum([]byte(fmt.Sprintf("%s|%d|%d", abs, fi.Size(), fi.ModTime().Unix())))
	return filepath.Join(s.cfg.CacheDir, "previews", hex.EncodeToString(sum[:10]))
}

// GET /api/trickplay?path= — the sheet layout; 202 + {pending} while it is being made.
func (s *Server) handleTrickplay(w http.ResponseWriter, r *http.Request) {
	if s.settings.Get().TrickplayOff {
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
			// a failure is retried after a few hours (the disk may have been busy, ffmpeg updated…)
			if ti.Ready || time.Now().Unix()-ti.Made < 6*3600 {
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

// makeTrickplay grabs one frame per Interval by jumping straight to that moment
// (ffmpeg -ss before -i, keyframes only), so only a few MB around each point are
// read — a 60 GB remux on a busy seedbox disk costs the same as a small file.
// The frames are laid out into JPEG sheets here.
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
	if h < 2 || h > 4*trickW {
		h = 136
	}
	count := int(math.Ceil(info.Duration / iv))
	if count < 1 {
		count = 1
	}
	per := trickCols * trickRows
	ti := TrickInfo{Interval: iv, W: trickW, H: h, Cols: trickCols, Rows: trickRows, Count: count,
		Sheets: (count + per - 1) / per, Made: time.Now().Unix()}
	t0 := time.Now()
	log.Printf("previews %s: %d frames every %gs", filepath.Base(abs), count, iv)

	sheets := make([]*image.RGBA, ti.Sheets)
	for i := range sheets {
		sheets[i] = image.NewRGBA(image.Rect(0, 0, trickCols*trickW, trickRows*h))
		draw.Draw(sheets[i], sheets[i].Bounds(), image.Black, image.Point{}, draw.Src)
	}
	var (
		mu      sync.Mutex
		done    int
		failed  int
		lastErr string
		wg      sync.WaitGroup
	)
	jobs := make(chan int)
	for w := 0; w < trickWorkers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range jobs {
				img, err := s.trickFrame(abs, float64(i)*iv, trickW, h)
				mu.Lock()
				if err != nil {
					failed++
					lastErr = err.Error()
				} else {
					c := i % per
					x, y := (c%trickCols)*trickW, (c/trickCols)*h
					draw.Draw(sheets[i/per], image.Rect(x, y, x+trickW, y+h), img, img.Bounds().Min, draw.Src)
				}
				done++
				p := float64(done) / float64(count) * 0.98
				mu.Unlock()
				trickMu.Lock()
				if j := trickJobs[key]; j != nil {
					j.progress = p
				}
				trickMu.Unlock()
			}
		}()
	}
	for i := 0; i < count; i++ {
		jobs <- i
	}
	close(jobs)
	wg.Wait()

	fail := func(why string) {
		log.Printf("previews %s: FAILED — %s", filepath.Base(abs), why)
		os.MkdirAll(dir, 0o755)
		b, _ := json.Marshal(TrickInfo{Error: why, Made: time.Now().Unix()})
		os.WriteFile(filepath.Join(dir, "info.json"), b, 0o644)
	}
	if failed*2 > count { // the last few seconds can't always be reached; most frames must be
		fail(fmt.Sprintf("%d of %d frames failed: %s", failed, count, lastErr))
		return
	}
	tmp := dir + ".part"
	os.RemoveAll(tmp)
	if err := os.MkdirAll(tmp, 0o755); err != nil {
		fail(err.Error())
		return
	}
	defer os.RemoveAll(tmp)
	for i, sh := range sheets {
		f, err := os.Create(filepath.Join(tmp, fmt.Sprintf("s%03d.jpg", i+1)))
		if err == nil {
			err = jpeg.Encode(f, sh, &jpeg.Options{Quality: 72})
			if cerr := f.Close(); err == nil {
				err = cerr
			}
		}
		if err != nil {
			fail("writing the sheets: " + err.Error())
			return
		}
	}
	ti.Ready = true
	b, _ := json.Marshal(ti)
	os.WriteFile(filepath.Join(tmp, "info.json"), b, 0o644)
	os.RemoveAll(dir)
	if err := os.Rename(tmp, dir); err != nil {
		fail(err.Error())
		return
	}
	log.Printf("previews %s: %d frames (%d missed) in %s", filepath.Base(abs), count, failed, time.Since(t0).Round(time.Second))
}

// trickFrame: one small frame at t seconds (the keyframe at or just before it).
func (s *Server) trickFrame(abs string, t float64, w, h int) (image.Image, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, s.cfg.FFmpeg, "-hide_banner", "-nostdin", "-loglevel", "error",
		"-threads", "1", "-skip_frame", "nokey", "-ss", strconv.FormatFloat(t, 'f', 3, 64), "-i", abs,
		"-map", "0:V:0", "-an", "-sn", "-dn", "-frames:v", "1",
		"-vf", fmt.Sprintf("scale=%d:%d", w, h), "-f", "image2pipe", "-c:v", "mjpeg", "-q:v", "4", "pipe:1")
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(errb.String())
		if len(msg) > 200 {
			msg = msg[len(msg)-200:]
		}
		if msg == "" {
			msg = err.Error()
		}
		return nil, errors.New(msg)
	}
	if out.Len() == 0 {
		return nil, errors.New("no frame there")
	}
	return jpeg.Decode(&out)
}

// the old way (one pass over the whole file) kept its sheets in "trickplay": gone now
func (s *Server) cleanOldTrickplay() {
	os.RemoveAll(filepath.Join(s.cfg.CacheDir, "trickplay"))
}
