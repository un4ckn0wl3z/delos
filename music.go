package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

type audioTags struct {
	Title, Artist, AlbumArtist, Album, Genre string
	Track, Disc, Year                        int
	Duration                                 float64
	HasPicture                               bool
}

func atoiPrefix(s string) int {
	s = strings.TrimSpace(s)
	if i := strings.IndexAny(s, "/-"); i > 0 {
		s = s[:i]
	}
	n, _ := strconv.Atoi(strings.TrimSpace(s))
	return n
}

// readTags uses ffprobe to read title/artist/album/... and the duration of an audio file.
func (s *Server) readTags(path string) (audioTags, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, s.cfg.FFprobe, "-v", "error", "-print_format", "json",
		"-show_entries", "format=duration:format_tags:stream=codec_type:stream_tags:stream_disposition=attached_pic", path).Output()
	if err != nil {
		return audioTags{}, err
	}
	var r struct {
		Format struct {
			Duration string            `json:"duration"`
			Tags     map[string]string `json:"tags"`
		} `json:"format"`
		Streams []struct {
			CodecType   string            `json:"codec_type"`
			Tags        map[string]string `json:"tags"`
			Disposition map[string]int    `json:"disposition"`
		} `json:"streams"`
	}
	if err := json.Unmarshal(out, &r); err != nil {
		return audioTags{}, err
	}
	tags := map[string]string{}
	// ogg/opus keep tags on the stream; mp3/flac/m4a on the format
	for _, st := range r.Streams {
		if st.CodecType == "audio" {
			for k, v := range st.Tags {
				tags[strings.ToLower(k)] = v
			}
		}
	}
	for k, v := range r.Format.Tags {
		tags[strings.ToLower(k)] = v
	}
	t := audioTags{
		Title: tags["title"], Artist: tags["artist"], Album: tags["album"], Genre: tags["genre"],
		AlbumArtist: firstNonEmpty(tags["album_artist"], tags["albumartist"], tags["album artist"]),
		Track:       atoiPrefix(firstNonEmpty(tags["track"], tags["tracknumber"])),
		Disc:        atoiPrefix(firstNonEmpty(tags["disc"], tags["discnumber"])),
		Year:        atoiPrefix(firstNonEmpty(tags["date"], tags["year"], tags["originaldate"])),
	}
	t.Duration, _ = strconv.ParseFloat(r.Format.Duration, 64)
	for _, st := range r.Streams {
		if st.CodecType == "video" && st.Disposition["attached_pic"] == 1 {
			t.HasPicture = true
		}
	}
	return t, nil
}

func firstNonEmpty(v ...string) string {
	for _, s := range v {
		if s = strings.TrimSpace(s); s != "" {
			return s
		}
	}
	return ""
}

var genreSplit = regexp.MustCompile(`\s*[;/,|]\s*`)

func splitGenres(g string) []string {
	var out []string
	seen := map[string]bool{}
	for _, x := range genreSplit.Split(strings.TrimSpace(g), -1) {
		if x != "" && !seen[strings.ToLower(x)] {
			seen[strings.ToLower(x)] = true
			out = append(out, x)
		}
	}
	return out
}

// ---------------------------------------------------------------- covers

var coverNames = []string{"cover", "folder", "front", "album", "albumart", "albumartsmall", "artwork"}
var coverKeyRe = regexp.MustCompile(`^[0-9a-f]{24}$`)

func (s *Server) coverDir() string { return filepath.Join(s.cfg.DataDir, "covers") }

func (s *Server) coverFile(key string) string { return filepath.Join(s.coverDir(), key+".img") }

// folderImage finds cover.jpg / folder.png / … next to the audio files.
func folderImage(dir string) string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return ""
	}
	for _, want := range coverNames {
		for _, e := range entries {
			n := strings.ToLower(e.Name())
			ext := filepath.Ext(n)
			if (ext == ".jpg" || ext == ".jpeg" || ext == ".png" || ext == ".webp") && strings.TrimSuffix(n, ext) == want {
				return filepath.Join(dir, e.Name())
			}
		}
	}
	return ""
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := dst + ".tmp"
	out, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	out.Close()
	return os.Rename(tmp, dst)
}

// extractEmbedded writes the attached picture of an audio file as a ≤600px JPEG.
func (s *Server) extractEmbedded(audio, dst string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	tmp := dst + ".tmp.jpg"
	err := exec.CommandContext(ctx, s.cfg.FFmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
		"-i", audio, "-an", "-map", "0:v:0", "-frames:v", "1", "-vf", "scale='min(600,iw)':-2", "-q:v", "3", tmp).Run()
	if err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, dst)
}

// MusicBrainz / Cover Art Archive (no key; MusicBrainz allows ~1 request per second)
var (
	mbMu   sync.Mutex
	mbLast time.Time
)

func mbBase() string {
	if u := os.Getenv("STREAMMKV_MB_URL"); u != "" {
		return strings.TrimRight(u, "/")
	}
	return "https://musicbrainz.org/ws/2"
}

func caaBase() string {
	if u := os.Getenv("STREAMMKV_CAA_URL"); u != "" {
		return strings.TrimRight(u, "/")
	}
	return "https://coverartarchive.org"
}

var luceneEsc = strings.NewReplacer(`\`, `\\`, `"`, `\"`)

func (s *Server) fetchCAA(artist, album, dst string) error {
	if album == "" {
		return errors.New("no album")
	}
	mbMu.Lock()
	if d := time.Since(mbLast); d < 1100*time.Millisecond {
		time.Sleep(1100*time.Millisecond - d)
	}
	mbLast = time.Now()
	mbMu.Unlock()

	q := `releasegroup:"` + luceneEsc.Replace(album) + `"`
	if artist != "" {
		q += ` AND artist:"` + luceneEsc.Replace(artist) + `"`
	}
	u := mbBase() + "/release-group/?" + url.Values{"query": {q}, "fmt": {"json"}, "limit": {"3"}}.Encode()
	req, _ := http.NewRequest("GET", u, nil)
	req.Header.Set("User-Agent", "StreamMKV/"+version+" ( https://github.com/un4ckn0wl3z/streammkv )")
	req.Header.Set("Accept", "application/json")
	c := &http.Client{Timeout: 20 * time.Second}
	resp, err := c.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("musicbrainz: %s", resp.Status)
	}
	var r struct {
		Groups []struct {
			ID    string `json:"id"`
			Score int    `json:"score"`
		} `json:"release-groups"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		return err
	}
	for _, g := range r.Groups {
		if g.Score < 85 {
			continue
		}
		img, err := c.Get(caaBase() + "/release-group/" + g.ID + "/front-500")
		if err != nil {
			return err
		}
		if img.StatusCode != 200 {
			img.Body.Close()
			continue
		}
		tmp := dst + ".tmp"
		f, err := os.Create(tmp)
		if err != nil {
			img.Body.Close()
			return err
		}
		_, err = io.Copy(f, img.Body)
		img.Body.Close()
		f.Close()
		if err != nil {
			os.Remove(tmp)
			return err
		}
		return os.Rename(tmp, dst)
	}
	return errors.New("no cover art found")
}

func (s *Server) handleCover(w http.ResponseWriter, r *http.Request) {
	key := r.PathValue("key")
	if !coverKeyRe.MatchString(key) {
		httpErr(w, 404, "not found")
		return
	}
	f, err := os.Open(s.coverFile(key))
	if err != nil {
		httpErr(w, 404, "not found")
		return
	}
	defer f.Close()
	st, _ := f.Stat()
	head := make([]byte, 512)
	n, _ := f.Read(head)
	f.Seek(0, io.SeekStart)
	w.Header().Set("Content-Type", http.DetectContentType(head[:n]))
	w.Header().Set("Cache-Control", "private, max-age=604800")
	http.ServeContent(w, r, key, st.ModTime(), f)
}
