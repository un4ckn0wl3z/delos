package main

// YouTube downloads (videos, music, whole playlists) with yt-dlp.
//
// Pasting a YouTube / YouTube Music link into Downloads makes a "youtube" job. Into a music
// library it saves the audio (m4a, tagged, cover art); into a video library it saves the video
// (≤1080p, mkv). A playlist link (or a video link with "whole playlist" ticked) downloads every
// entry into a folder named after the playlist; a download archive per folder means running the
// same playlist again only fetches what's new.
//
// yt-dlp and a JavaScript runtime (Deno, which YouTube now needs) are found on PATH, or set with
// STREAMMKV_YTDLP / STREAMMKV_YTDLP_JS, or else downloaded once into <data>/bin and kept updated.

import (
	"archive/zip"
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

func isYouTubeURL(u *url.URL) bool {
	h := strings.ToLower(strings.TrimPrefix(u.Hostname(), "www."))
	switch h {
	case "youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "youtube-nocookie.com":
		return true
	}
	return false
}

// isYouTubePlaylist: the link is a playlist page (not a video that happens to be in one).
func isYouTubePlaylist(u *url.URL) bool {
	return strings.HasPrefix(u.Path, "/playlist") || (u.Query().Get("list") != "" && u.Query().Get("v") == "" && !strings.Contains(u.Host, "youtu.be"))
}

// ---------------------------------------------------------------- tools

type ytTools struct {
	mu      sync.Mutex
	bin     string
	js      string // --js-runtimes value ("deno:/path" / "node"), "" = none found
	managed bool   // we downloaded yt-dlp (so we keep it updated)
	version string
	updated time.Time
}

var yt ytTools

func (d *Downloads) binDir() string { return filepath.Join(d.s.cfg.DataDir, "bin") }

// ytdlp returns the yt-dlp binary and the JS runtime option, installing them if needed.
func (d *Downloads) ytdlp(ctx context.Context) (string, string, error) {
	yt.mu.Lock()
	defer yt.mu.Unlock()
	if yt.bin == "" {
		switch p := os.Getenv("STREAMMKV_YTDLP"); {
		case p != "":
			yt.bin = p
		default:
			if p, err := exec.LookPath("yt-dlp"); err == nil {
				yt.bin = p
			} else {
				own := filepath.Join(d.binDir(), "yt-dlp"+exeSuffix())
				if _, err := os.Stat(own); err != nil {
					if err := d.installYtdlp(ctx, own); err != nil {
						return "", "", fmt.Errorf("couldn't install yt-dlp: %w", err)
					}
				}
				yt.bin, yt.managed = own, true
				if fi, err := os.Stat(own); err == nil {
					yt.updated = fi.ModTime()
				}
			}
		}
		yt.js = d.findJSRuntime(ctx)
		if out, err := exec.CommandContext(ctx, yt.bin, "--version").Output(); err == nil {
			yt.version = strings.TrimSpace(string(out))
		}
		log.Printf("yt-dlp %s at %s (JS runtime: %s)", yt.version, yt.bin, cmpOr(yt.js, "none"))
	}
	// YouTube changes often: keep our own copy fresh (at most once a day)
	if yt.managed && time.Since(yt.updated) > 24*time.Hour {
		uctx, cancel := context.WithTimeout(ctx, 3*time.Minute)
		out, err := exec.CommandContext(uctx, yt.bin, "-U").CombinedOutput()
		cancel()
		if err != nil {
			log.Printf("yt-dlp update: %v: %s", err, lastLine(string(out)))
		}
		yt.updated = time.Now()
		os.Chtimes(yt.bin, yt.updated, yt.updated)
	}
	return yt.bin, yt.js, nil
}

func exeSuffix() string {
	if runtime.GOOS == "windows" {
		return ".exe"
	}
	return ""
}

func isMusl() bool {
	_, err := os.Stat("/etc/alpine-release")
	return err == nil
}

func (d *Downloads) installYtdlp(ctx context.Context, dst string) error {
	asset := ""
	switch {
	case runtime.GOOS == "windows":
		asset = "yt-dlp.exe"
	case runtime.GOOS == "darwin":
		asset = "yt-dlp_macos"
	case runtime.GOOS == "linux" && !isMusl() && runtime.GOARCH == "amd64":
		asset = "yt-dlp_linux"
	case runtime.GOOS == "linux" && !isMusl() && runtime.GOARCH == "arm64":
		asset = "yt-dlp_linux_aarch64"
	case runtime.GOOS == "linux" && !isMusl() && runtime.GOARCH == "arm":
		asset = "yt-dlp_linux_armv7l"
	default:
		if _, err := exec.LookPath("python3"); err != nil {
			return errors.New("no yt-dlp build for this system — install yt-dlp (or python3)")
		}
		asset = "yt-dlp" // zipapp, runs on python3
	}
	log.Printf("downloading yt-dlp (%s)…", asset)
	return fetchTo(ctx, "https://github.com/yt-dlp/yt-dlp/releases/latest/download/"+asset, dst, 0o755)
}

// findJSRuntime: YouTube needs a JavaScript runtime for its challenges (Deno preferred).
func (d *Downloads) findJSRuntime(ctx context.Context) string {
	if v := os.Getenv("STREAMMKV_YTDLP_JS"); v != "" {
		return v
	}
	if p, err := exec.LookPath("deno"); err == nil {
		return "deno:" + p
	}
	own := filepath.Join(d.binDir(), "deno"+exeSuffix())
	if _, err := os.Stat(own); err == nil {
		return "deno:" + own
	}
	if p, err := exec.LookPath("node"); err == nil {
		return "node:" + p
	}
	asset := ""
	switch {
	case runtime.GOOS == "linux" && !isMusl() && runtime.GOARCH == "amd64":
		asset = "deno-x86_64-unknown-linux-gnu.zip"
	case runtime.GOOS == "linux" && !isMusl() && runtime.GOARCH == "arm64":
		asset = "deno-aarch64-unknown-linux-gnu.zip"
	case runtime.GOOS == "darwin" && runtime.GOARCH == "arm64":
		asset = "deno-aarch64-apple-darwin.zip"
	case runtime.GOOS == "darwin":
		asset = "deno-x86_64-apple-darwin.zip"
	case runtime.GOOS == "windows":
		asset = "deno-x86_64-pc-windows-msvc.zip"
	default:
		log.Printf("yt-dlp: no JavaScript runtime (install deno or node) — some YouTube downloads may fail")
		return ""
	}
	log.Printf("downloading deno for yt-dlp (%s)…", asset)
	zipPath := own + ".zip"
	if err := fetchTo(ctx, "https://github.com/denoland/deno/releases/latest/download/"+asset, zipPath, 0o644); err != nil {
		log.Printf("yt-dlp: couldn't get deno: %v", err)
		return ""
	}
	defer os.Remove(zipPath)
	if err := unzipOne(zipPath, "deno"+exeSuffix(), own); err != nil {
		log.Printf("yt-dlp: couldn't unpack deno: %v", err)
		return ""
	}
	return "deno:" + own
}

func fetchTo(ctx context.Context, src, dst string, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", src, nil)
	req.Header.Set("User-Agent", "Delos/"+version)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("%s: HTTP %d", src, resp.StatusCode)
	}
	tmp := dst + ".part"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, resp.Body); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	f.Close()
	return os.Rename(tmp, dst)
}

func unzipOne(zipPath, name, dst string) error {
	z, err := zip.OpenReader(zipPath)
	if err != nil {
		return err
	}
	defer z.Close()
	for _, f := range z.File {
		if filepath.Base(f.Name) != name {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			return err
		}
		defer rc.Close()
		out, err := os.OpenFile(dst+".part", os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
		if err != nil {
			return err
		}
		if _, err := io.Copy(out, rc); err != nil {
			out.Close()
			return err
		}
		out.Close()
		return os.Rename(dst+".part", dst)
	}
	return fmt.Errorf("%s not in the archive", name)
}

func lastLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.LastIndexByte(s, '\n'); i >= 0 {
		s = s[i+1:]
	}
	return s
}

// ---------------------------------------------------------------- jobs

func (d *Downloads) runYouTube(id string) {
	d.slots <- struct{}{}
	defer func() { <-d.slots }()
	j := d.get(id)
	if j == nil || j.State != JobQueued {
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	d.mu.Lock()
	d.cancel[id] = cancel
	d.mu.Unlock()
	defer func() {
		cancel()
		d.mu.Lock()
		delete(d.cancel, id)
		d.mu.Unlock()
	}()
	d.update(id, func(j *DownloadJob) { j.State, j.Error = JobDownloading, "" })
	saved, err := d.youtube(ctx, j)
	d.update(id, func(j *DownloadJob) {
		j.Rate = 0
		switch {
		case ctx.Err() != nil && j.State == JobCanceled:
		case err != nil && saved == 0:
			j.State, j.Error = JobFailed, err.Error()
		default:
			j.State, j.Finished, j.Error = JobDone, time.Now().Unix(), ""
			if err != nil {
				j.Error = err.Error() // some playlist entries failed
			}
		}
	})
	if saved > 0 {
		d.s.index.Queue(j.Lib, false)
	}
}

func (d *Downloads) youtube(ctx context.Context, j *DownloadJob) (int, error) {
	dir, lib, err := d.targetDir(j.Lib, j.Subdir)
	if err != nil {
		return 0, err
	}
	bin, js, err := d.ytdlp(ctx)
	if err != nil {
		return 0, err
	}
	music := lib.Type == "music"
	args := []string{"--newline", "--no-colors", "--ignore-errors", "--no-overwrites", "--continue",
		"--progress", "--no-simulate", "--trim-filenames", "160", "--retries", "5", "--no-mtime",
		"--replace-in-metadata", "uploader,channel", " - Topic$", "",
		"--progress-template", "download:SMKVP|%(progress.downloaded_bytes)s|%(progress.total_bytes,progress.total_bytes_estimate)s|%(progress.speed)s",
		"--print", "before_dl:SMKVI|%(playlist_index|)s|%(n_entries|)s|%(playlist_title|)s|%(title)s",
		"--print", "after_move:SMKVF|%(id)s|%(filepath)s",
		"-P", dir, "-P", "temp:" + filepath.Join(dir, ".ytdl-tmp"),
		"--download-archive", filepath.Join(dir, ".ytdl-archive.txt"),
	}
	if j.Playlist {
		args = append(args, "--yes-playlist")
	} else {
		args = append(args, "--no-playlist")
	}
	yt.mu.Lock()
	ver := yt.version
	yt.mu.Unlock()
	if js != "" && ver >= "2025.11.12" { // older yt-dlp doesn't know these options
		args = append(args, "--js-runtimes", js, "--remote-components", "ejs:github")
	}
	if ff := d.s.cfg.FFmpeg; strings.ContainsRune(ff, filepath.Separator) {
		args = append(args, "--ffmpeg-location", ff)
	}
	if music {
		args = append(args, "-f", "bestaudio[ext=m4a]/bestaudio/best", "-x", "--audio-format", "m4a", "--audio-quality", "0",
			"--embed-metadata", "--embed-thumbnail", "--convert-thumbnails", "jpg",
			"--parse-metadata", "%(artist,creator,uploader|)s:%(meta_artist)s",
			"--parse-metadata", "%(track,title)s:%(meta_title)s")
		if j.Playlist {
			args = append(args,
				"--parse-metadata", "%(playlist_title|YouTube)s:%(meta_album)s",
				"--parse-metadata", "%(playlist_index|)s:%(meta_track)s",
				"-o", "%(playlist_title|Playlist)s/%(playlist_index)03d - %(track,title)s.%(ext)s")
		} else {
			args = append(args,
				"--parse-metadata", "%(album|YouTube)s:%(meta_album)s",
				"-o", "%(artist,creator,uploader|Unknown)s/%(album|YouTube)s/%(track,title)s.%(ext)s")
		}
	} else {
		args = append(args, "-f", "bv*[height<=?1080]+ba/b", "--merge-output-format", "mkv", "--embed-metadata", "--embed-thumbnail")
		if j.Playlist {
			args = append(args, "-o", "%(playlist_title|Playlist)s/%(playlist_index)03d - %(title)s.%(ext)s")
		} else {
			args = append(args, "-o", "%(uploader|YouTube)s/%(title)s.%(ext)s")
		}
	}
	args = append(args, "--", j.Source)

	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.Env = append(os.Environ(), "PYTHONUNBUFFERED=1")
	stdout, _ := cmd.StdoutPipe()
	stderr, _ := cmd.StderrPipe()
	if err := cmd.Start(); err != nil {
		return 0, err
	}
	var lastErr string
	var errMu sync.Mutex
	go func() {
		sc := bufio.NewScanner(stderr)
		for sc.Scan() {
			l := strings.TrimSpace(sc.Text())
			if strings.HasPrefix(l, "ERROR:") {
				errMu.Lock()
				lastErr = strings.TrimSpace(strings.TrimPrefix(l, "ERROR:"))
				errMu.Unlock()
			}
		}
	}()
	saved, failed := 0, 0
	lib2 := lib
	sc := bufio.NewScanner(stdout)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	lastSave := time.Now()
	for sc.Scan() {
		f := strings.Split(sc.Text(), "|")
		switch f[0] {
		case "SMKVI":
			if len(f) < 5 {
				continue
			}
			idx, _ := strconv.Atoi(f[1])
			n, _ := strconv.Atoi(f[2])
			title := strings.Join(f[4:], "|")
			d.update(j.ID, func(x *DownloadJob) {
				x.Current, x.Done, x.Size = title, 0, -1
				if n > 0 {
					x.Items = n
				}
				if idx > 0 {
					x.ItemIndex = idx
				}
				if x.Name == "" || x.Name == x.Source {
					x.Name = title
					if j.Playlist && f[3] != "" {
						x.Name = f[3]
					}
				}
			})
		case "SMKVP":
			if len(f) < 4 {
				continue
			}
			done, _ := strconv.ParseFloat(f[1], 64)
			total, _ := strconv.ParseFloat(f[2], 64)
			speed, _ := strconv.ParseFloat(f[3], 64)
			d.update(j.ID, func(x *DownloadJob) {
				x.Done, x.Rate = int64(done), int64(speed)
				if total > 0 {
					x.Size = int64(total)
				}
			})
		case "SMKVF":
			if len(f) < 3 {
				continue
			}
			vid, p := f[1], strings.Join(f[2:], "|")
			rel, err := filepath.Rel(lib2.Path, p)
			if err != nil || strings.HasPrefix(rel, "..") {
				continue
			}
			saved++
			d.update(j.ID, func(x *DownloadJob) {
				x.Paths = append(x.Paths, p)
				x.VideoIDs = append(x.VideoIDs, vid)
				x.ItemsDone++
			})
			if time.Since(lastSave) > 20*time.Second { // long playlists: show what's in so far
				lastSave = time.Now()
				d.s.index.Queue(j.Lib, false)
			}
		}
	}
	err = cmd.Wait()
	os.RemoveAll(filepath.Join(dir, ".ytdl-tmp"))
	if ctx.Err() != nil {
		return saved, ctx.Err()
	}
	errMu.Lock()
	le := lastErr
	errMu.Unlock()
	if err != nil {
		if le == "" {
			le = err.Error()
		}
		if x := d.get(j.ID); x != nil && x.Items > 0 {
			failed = x.Items - x.ItemsDone
		}
		if saved > 0 && failed > 0 {
			return saved, fmt.Errorf("%d of %d couldn't be downloaded (last error: %s)", failed, failed+saved, le)
		}
		if saved == 0 && strings.Contains(le, "has already been recorded in the archive") {
			return 0, nil
		}
		return saved, errors.New(le)
	}
	return saved, nil
}

func cmpOr(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

// forgetArchived removes ids from a folder's download archive, so deleted entries can be downloaded again.
func forgetArchived(dir string, ids []string) {
	f := filepath.Join(dir, ".ytdl-archive.txt")
	b, err := os.ReadFile(f)
	if err != nil || len(ids) == 0 {
		return
	}
	drop := map[string]bool{}
	for _, id := range ids {
		drop[id] = true
	}
	var keep []string
	for _, l := range strings.Split(strings.TrimRight(string(b), "\n"), "\n") {
		if fs := strings.Fields(l); len(fs) == 2 && drop[fs[1]] {
			continue
		}
		keep = append(keep, l)
	}
	os.WriteFile(f, []byte(strings.Join(keep, "\n")+"\n"), 0o644)
}
