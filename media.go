package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Media struct {
	cfg   *Config
	mu    sync.Mutex
	probe map[string]*ProbeInfo // key: path|mtime
	locks map[string]*sync.Mutex
}

func NewMedia(cfg *Config) *Media {
	return &Media{
		cfg:   cfg,
		probe: map[string]*ProbeInfo{},
		locks: map[string]*sync.Mutex{},
	}
}

// ---------- probe ----------

type ffStream struct {
	Index       int               `json:"index"`
	CodecType   string            `json:"codec_type"`
	CodecName   string            `json:"codec_name"`
	Profile     string            `json:"profile"`
	PixFmt      string            `json:"pix_fmt"`
	Width       int               `json:"width"`
	Height      int               `json:"height"`
	Channels    int               `json:"channels"`
	Layout      string            `json:"channel_layout"`
	Tags        map[string]string `json:"tags"`
	Disposition map[string]int    `json:"disposition"`
}

type ffProbe struct {
	Streams []ffStream `json:"streams"`
	Format  struct {
		Duration  string `json:"duration"`
		StartTime string `json:"start_time"`
	} `json:"format"`
}

type VideoInfo struct {
	Codec   string `json:"codec"`
	Profile string `json:"profile"`
	PixFmt  string `json:"pixFmt"`
	Width   int    `json:"width"`
	Height  int    `json:"height"`
}

type AudioInfo struct {
	Index    int    `json:"index"` // audio-relative index (0:a:N)
	Codec    string `json:"codec"`
	Channels int    `json:"channels"`
	Layout   string `json:"layout"`
	Language string `json:"language"`
	Title    string `json:"title"`
	Default  bool   `json:"default"`
}

type SubInfo struct {
	Index    int    `json:"index"` // subtitle-relative index (0:s:N)
	Codec    string `json:"codec"`
	Language string `json:"language"`
	Title    string `json:"title"`
	Default  bool   `json:"default"`
	Forced   bool   `json:"forced"`
	Text     bool   `json:"text"` // can be converted to WebVTT
	Width    int    `json:"width,omitempty"`
	Height   int    `json:"height,omitempty"`
}

type ProbeInfo struct {
	Duration float64     `json:"duration"`
	Start    float64     `json:"start"` // container start_time (raw pts of t=0)
	Size     int64       `json:"size"`
	Video    *VideoInfo  `json:"video"`
	Audio    []AudioInfo `json:"audio"`
	Subs     []SubInfo   `json:"subs"`
}

var textSubCodecs = map[string]bool{
	"subrip": true, "srt": true, "ass": true, "ssa": true, "webvtt": true,
	"mov_text": true, "text": true, "microdvd": true, "subviewer": true,
}

func (m *Media) Probe(ctx context.Context, path string, st os.FileInfo) (*ProbeInfo, error) {
	key := path + "|" + strconv.FormatInt(st.ModTime().UnixNano(), 10)
	m.mu.Lock()
	if p, ok := m.probe[key]; ok {
		m.mu.Unlock()
		return p, nil
	}
	m.mu.Unlock()

	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, m.cfg.FFprobe, "-v", "error", "-print_format", "json",
		"-show_format", "-show_streams", path).Output()
	if err != nil {
		return nil, fmt.Errorf("ffprobe: %w", err)
	}
	var fp ffProbe
	if err := json.Unmarshal(out, &fp); err != nil {
		return nil, err
	}
	info := &ProbeInfo{Size: st.Size(), Audio: []AudioInfo{}, Subs: []SubInfo{}}
	info.Duration, _ = strconv.ParseFloat(fp.Format.Duration, 64)
	info.Start, _ = strconv.ParseFloat(fp.Format.StartTime, 64)
	ai, si := 0, 0
	for _, s := range fp.Streams {
		lang, title := s.Tags["language"], s.Tags["title"]
		if lang == "" {
			lang = s.Tags["LANGUAGE"]
		}
		switch s.CodecType {
		case "video":
			// skip cover art / attached pictures
			if info.Video == nil && s.Disposition["attached_pic"] == 0 {
				info.Video = &VideoInfo{Codec: s.CodecName, Profile: s.Profile, PixFmt: s.PixFmt, Width: s.Width, Height: s.Height}
			}
		case "audio":
			info.Audio = append(info.Audio, AudioInfo{Index: ai, Codec: s.CodecName, Channels: s.Channels, Layout: s.Layout,
				Language: lang, Title: title, Default: s.Disposition["default"] == 1})
			ai++
		case "subtitle":
			info.Subs = append(info.Subs, SubInfo{Index: si, Codec: s.CodecName, Language: lang, Title: title,
				Default: s.Disposition["default"] == 1, Forced: s.Disposition["forced"] == 1,
				Text: textSubCodecs[s.CodecName], Width: s.Width, Height: s.Height})
			si++
		}
	}
	m.mu.Lock()
	m.probe[key] = info
	m.mu.Unlock()
	return info, nil
}

func (s *Server) handleProbe(w http.ResponseWriter, r *http.Request) {
	p, st, err := s.resolveFor(r, r.URL.Query().Get("path"))
	if err != nil {
		httpErr(w, 404, err.Error())
		return
	}
	info, err := s.media.Probe(r.Context(), p, st)
	if err != nil {
		httpErr(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, info)
}

// ---------- keyframe lookup ----------
// With -c:v copy, ffmpeg can only start at a keyframe. The client asks for the
// keyframe at/before the requested time so it knows the real stream offset
// (needed for the seek bar and subtitle timing).

// t and the result are relative to the container start (what ffmpeg -ss uses).
func (m *Media) Keyframe(ctx context.Context, path string, t, start float64) (float64, error) {
	if t <= 0 {
		return 0, nil
	}
	rel := t
	t += start
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	from := math.Max(0, t-30)
	interval := fmt.Sprintf("%.3f%%%.3f", from, t+0.5)
	out, err := exec.CommandContext(ctx, m.cfg.FFprobe, "-v", "error", "-select_streams", "v:0",
		"-show_entries", "packet=pts_time,flags", "-read_intervals", interval, "-of", "json", path).Output()
	if err != nil {
		return rel, err
	}
	var res struct {
		Packets []struct {
			PTS   string `json:"pts_time"`
			Flags string `json:"flags"`
		} `json:"packets"`
	}
	if err := json.Unmarshal(out, &res); err != nil {
		return rel, err
	}
	best := -1.0
	for _, p := range res.Packets {
		if !strings.HasPrefix(p.Flags, "K") {
			continue
		}
		v, err := strconv.ParseFloat(p.PTS, 64)
		if err != nil {
			continue
		}
		if v <= t+0.001 && v > best {
			best = v
		}
	}
	if best < 0 {
		return rel, errors.New("no keyframe found")
	}
	return math.Max(0, best-start), nil
}

func (s *Server) handleKeyframe(w http.ResponseWriter, r *http.Request) {
	p, st, err := s.resolveFor(r, r.URL.Query().Get("path"))
	if err != nil {
		httpErr(w, 404, err.Error())
		return
	}
	info, err := s.media.Probe(r.Context(), p, st)
	if err != nil {
		httpErr(w, 500, err.Error())
		return
	}
	t := qFloat(r, "t", 0)
	k, err := s.media.Keyframe(r.Context(), p, t, info.Start)
	if err != nil {
		log.Printf("keyframe lookup failed (%v), using requested time", err)
	}
	writeJSON(w, 200, map[string]float64{"t": k})
}

// ---------- stream ----------
// Output: fragmented MP4 over a plain HTTP response (no Content-Length).
// Seeking is done by the client re-requesting with ?start=.

func (s *Server) handleStream(w http.ResponseWriter, r *http.Request) {
	path, st, err := s.resolveFor(r, r.URL.Query().Get("path"))
	if err != nil {
		httpErr(w, 404, err.Error())
		return
	}
	info, err := s.media.Probe(r.Context(), path, st)
	if err != nil {
		httpErr(w, 500, err.Error())
		return
	}
	if info.Video == nil {
		httpErr(w, 400, "no video stream")
		return
	}
	start := qFloat(r, "start", 0)
	audio := qInt(r, "audio", 0)
	burn := qInt(r, "burn", -1)
	maxh := qInt(r, "maxh", 1080)
	if maxh < 144 || maxh > 4320 {
		maxh = 1080
	}
	crf := qInt(r, "crf", 22)
	if crf < 14 || crf > 35 {
		crf = 22
	}
	mode := r.URL.Query().Get("v")
	if mode != "copy" {
		mode = "transcode"
	}
	if burn >= len(info.Subs) || (burn >= 0 && info.Subs[burn].Text) {
		burn = -1 // only image subs are burned; text subs are rendered client-side
	}
	if burn >= 0 {
		mode = "transcode"
	}
	if audio >= len(info.Audio) {
		audio = 0
	}
	// fmt=mkv|ts for TVs (DLNA via the app): keeps 5.1 as AC3 (acodec=ac3) and, in mkv, the subtitles
	format := r.URL.Query().Get("fmt")
	if format != "mkv" && format != "ts" {
		format = "mp4"
	}
	acodec := r.URL.Query().Get("acodec")
	if acodec != "ac3" {
		acodec = "aac"
	}

	args := []string{"-hide_banner", "-loglevel", "error", "-nostdin"}
	if start > 0 {
		if mode == "copy" {
			args = append(args, "-noaccurate_seek")
		}
		args = append(args, "-ss", strconv.FormatFloat(start, 'f', 3, 64))
	}
	args = append(args, "-i", path)

	scale := fmt.Sprintf("scale=-2:'min(%d,ih)',format=yuv420p", maxh)
	if burn >= 0 {
		v := info.Video
		cw, ch := s.media.subCanvas(r.Context(), path, st.ModTime(), info, burn, start)
		subScale := min(max(qInt(r, "subscale", 100), 40), 250)
		subRaise := min(max(qInt(r, "subpos", 0), -15), 60)
		fc := burnFilter(v.Width, v.Height, cw, ch, burn, subScale, subRaise)
		args = append(args, "-filter_complex", fc+","+scale+"[vout]", "-map", "[vout]")
	} else {
		args = append(args, "-map", "0:v:0")
	}
	if len(info.Audio) > 0 && audio >= 0 {
		args = append(args, "-map", fmt.Sprintf("0:a:%d", audio))
	}

	// subtitles ride along in mkv, unless one can't go into matroska as-is (mp4 text)
	subsOK := format == "mkv" && burn < 0
	for _, sb := range info.Subs {
		if sb.Codec == "mov_text" || sb.Codec == "eia_608" {
			subsOK = false
		}
	}
	if subsOK {
		args = append(args, "-map", "0:s?", "-c:s", "copy")
	}
	if mode == "copy" {
		args = append(args, "-c:v", "copy")
		if info.Video.Codec == "hevc" && format == "mp4" {
			args = append(args, "-tag:v", "hvc1")
		}
	} else {
		if burn < 0 {
			args = append(args, "-vf", scale)
		}
		args = append(args, "-c:v", "libx264", "-preset", "veryfast", "-crf", strconv.Itoa(crf),
			"-profile:v", "high", "-g", "60")
	}
	if acodec == "ac3" {
		ch := 2
		if audio >= 0 && audio < len(info.Audio) && info.Audio[audio].Channels > 0 {
			ch = min(info.Audio[audio].Channels, 6)
		}
		args = append(args, "-c:a", "ac3", "-ac", strconv.Itoa(ch), "-b:a", map[bool]string{true: "640k", false: "224k"}[ch > 2])
	} else {
		args = append(args, "-c:a", "aac", "-ac", "2", "-b:a", "192k")
	}
	if !subsOK {
		args = append(args, "-sn")
	}
	args = append(args, "-dn", "-map_metadata", "-1", "-map_chapters", "-1",
		"-avoid_negative_ts", "make_zero", "-max_muxing_queue_size", "4096")
	contentType := "video/mp4"
	switch format {
	case "mkv":
		args = append(args, "-f", "matroska", "-live", "1", "pipe:1")
		contentType = "video/x-matroska"
	case "ts":
		args = append(args, "-f", "mpegts", "pipe:1")
		contentType = "video/mp2t"
	default:
		args = append(args, "-f", "mp4", "-movflags", "frag_keyframe+empty_moov+default_base_moof", "pipe:1")
	}

	// limit concurrent ffmpeg processes: copy (remux) is light, re-encoding is heavy
	class := ClassTranscode
	if mode == "copy" {
		class = ClassRemux
	}
	release, ok := s.startStream(w, r, class)
	if !ok {
		return
	}
	defer release()

	cmd := exec.CommandContext(r.Context(), s.cfg.FFmpeg, args...)
	var stderr bytes.Buffer
	cmd.Stderr = &limitedWriter{buf: &stderr, max: 8192}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		httpErr(w, 500, err.Error())
		return
	}
	if err := cmd.Start(); err != nil {
		httpErr(w, 500, "ffmpeg: "+err.Error())
		return
	}
	log.Printf("stream %q user=%s start=%.1f audio=%d mode=%s burn=%d", r.URL.Query().Get("path"), userOf(r), start, audio, mode, burn)
	kind := mode
	if burn >= 0 {
		kind = "transcode+burn"
	}
	defer s.conns.Add(userOf(r), r, r.URL.Query().Get("path"), kind)()

	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Accel-Buffering", "no") // nginx: don't buffer
	w.WriteHeader(200)

	rc := http.NewResponseController(w)
	buf := make([]byte, 256*1024)
	for {
		n, rerr := stdout.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				break
			}
			rc.Flush()
		}
		if rerr != nil {
			break
		}
	}
	err = cmd.Wait()
	if err != nil && r.Context().Err() == nil {
		log.Printf("ffmpeg exited: %v: %s", err, strings.TrimSpace(stderr.String()))
	}
}

type limitedWriter struct {
	buf *bytes.Buffer
	max int
}

func (l *limitedWriter) Write(p []byte) (int, error) {
	if l.buf.Len() < l.max {
		l.buf.Write(p[:min(len(p), l.max-l.buf.Len())])
	}
	return len(p), nil
}

// ---------- subtitles ----------
// Text subtitle tracks are extracted to WebVTT once and cached on disk.
// Extraction has to read the whole MKV, so the first load of a track can take
// a while on large files.

func (m *Media) keyLock(k string) *sync.Mutex {
	m.mu.Lock()
	defer m.mu.Unlock()
	l, ok := m.locks[k]
	if !ok {
		l = &sync.Mutex{}
		m.locks[k] = l
	}
	return l
}

func (s *Server) handleSubtitle(w http.ResponseWriter, r *http.Request) {
	path, st, err := s.resolveFor(r, r.URL.Query().Get("path"))
	if err != nil {
		httpErr(w, 404, err.Error())
		return
	}
	info, err := s.media.Probe(r.Context(), path, st)
	if err != nil {
		httpErr(w, 500, err.Error())
		return
	}
	idx := qInt(r, "sub", -1)
	if idx < 0 || idx >= len(info.Subs) {
		httpErr(w, 400, "invalid subtitle index")
		return
	}
	if !info.Subs[idx].Text {
		httpErr(w, 400, "image-based subtitle; use burn-in")
		return
	}
	key := cacheKey(path, strconv.FormatInt(st.ModTime().UnixNano(), 10), strconv.Itoa(idx))
	file := filepath.Join(s.cfg.CacheDir, key+".vtt")

	lock := s.media.keyLock(key)
	lock.Lock()
	defer lock.Unlock()

	if _, err := os.Stat(file); err != nil {
		// detached from the request so the cache still fills if the client gives up
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
		defer cancel()
		cmd := exec.CommandContext(ctx, s.cfg.FFmpeg, "-hide_banner", "-loglevel", "error", "-nostdin",
			"-i", path, "-map", fmt.Sprintf("0:s:%d", idx), "-c:s", "webvtt", "-f", "webvtt", "pipe:1")
		var stderr bytes.Buffer
		cmd.Stderr = &limitedWriter{buf: &stderr, max: 4096}
		out, err := cmd.Output()
		if err != nil {
			httpErr(w, 500, "subtitle extraction failed: "+strings.TrimSpace(stderr.String()))
			return
		}
		tmp := file + ".tmp"
		if err := os.WriteFile(tmp, out, 0o644); err == nil {
			os.Rename(tmp, file)
		}
	}
	f, err := os.Open(file)
	if err != nil {
		httpErr(w, 500, err.Error())
		return
	}
	defer f.Close()
	w.Header().Set("Content-Type", "text/vtt; charset=utf-8")
	w.Header().Set("Cache-Control", "private, max-age=86400")
	io.Copy(w, f)
}

// ---------- active connections (for the admin dashboard) ----------

type Conn struct {
	ID     int64  `json:"id"`
	User   string `json:"user"`
	Path   string `json:"path"`
	Kind   string `json:"kind"` // direct | copy | transcode | transcode+burn
	Remote string `json:"remote"`
	Agent  string `json:"agent"`
	Since  int64  `json:"since"`
}

type ConnRegistry struct {
	mu    sync.Mutex
	next  int64
	conns map[int64]*Conn
}

func NewConnRegistry() *ConnRegistry { return &ConnRegistry{conns: map[int64]*Conn{}} }

// Add registers a connection and returns the function that removes it.
func (c *ConnRegistry) Add(user string, r *http.Request, path, kind string) func() {
	remote := r.Header.Get("X-Forwarded-For")
	if remote == "" {
		remote = r.RemoteAddr
	}
	c.mu.Lock()
	c.next++
	id := c.next
	c.conns[id] = &Conn{ID: id, User: user, Path: path, Kind: kind, Remote: remote, Agent: r.UserAgent(), Since: time.Now().Unix()}
	c.mu.Unlock()
	return func() {
		c.mu.Lock()
		delete(c.conns, id)
		c.mu.Unlock()
	}
}

func (c *ConnRegistry) List() []Conn {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]Conn, 0, len(c.conns))
	for _, v := range c.conns {
		out = append(out, *v)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}
