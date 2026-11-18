package main

// Duplicate protection for downloads:
//   - torrents: the info hash is worked out before rtorrent sees it (magnet,
//     .torrent upload or .torrent URL) and checked against rtorrent and past jobs
//   - http: the file name is probed first; same file / same link is caught
//   - same title: a movie (or episode) already in a library of the same type
//     is reported before downloading, and once a finished download has been
//     matched (TMDB) any other versions of it are noted on the job.
// Hard duplicates (already in rtorrent) are refused; the others answer 409
// and the client may retry with "force": true.

import (
	"bytes"
	"crypto/sha1"
	"encoding/base32"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// ---------------------------------------------------------------- torrent identity

// bencodeEnd returns the index just past the bencoded value starting at i.
func bencodeEnd(b []byte, i int) (int, error) {
	if i >= len(b) {
		return 0, errors.New("truncated")
	}
	switch c := b[i]; {
	case c == 'i':
		j := bytes.IndexByte(b[i:], 'e')
		if j < 0 {
			return 0, errors.New("bad int")
		}
		return i + j + 1, nil
	case c == 'l' || c == 'd':
		i++
		for i < len(b) && b[i] != 'e' {
			var err error
			if i, err = bencodeEnd(b, i); err != nil {
				return 0, err
			}
		}
		if i >= len(b) {
			return 0, errors.New("truncated")
		}
		return i + 1, nil
	case c >= '0' && c <= '9':
		j := bytes.IndexByte(b[i:], ':')
		if j < 0 {
			return 0, errors.New("bad string")
		}
		n, err := strconv.Atoi(string(b[i : i+j]))
		if err != nil || n < 0 || i+j+1+n > len(b) {
			return 0, errors.New("bad string")
		}
		return i + j + 1 + n, nil
	}
	return 0, errors.New("bad bencode")
}

func bencodeString(b []byte, i int) (string, int, error) {
	j := bytes.IndexByte(b[i:], ':')
	if j < 0 {
		return "", 0, errors.New("bad string")
	}
	n, err := strconv.Atoi(string(b[i : i+j]))
	if err != nil || n < 0 || i+j+1+n > len(b) {
		return "", 0, errors.New("bad string")
	}
	return string(b[i+j+1 : i+j+1+n]), i + j + 1 + n, nil
}

// torrentInfo returns the info hash (upper-case hex) and the torrent's name.
func torrentInfo(data []byte) (hash, name string, err error) {
	if len(data) == 0 || data[0] != 'd' {
		return "", "", errors.New("not a .torrent file")
	}
	i := 1
	for i < len(data) && data[i] != 'e' {
		key, next, err := bencodeString(data, i)
		if err != nil {
			return "", "", err
		}
		end, err := bencodeEnd(data, next)
		if err != nil {
			return "", "", err
		}
		if key == "info" {
			sum := sha1.Sum(data[next:end])
			hash = strings.ToUpper(hex.EncodeToString(sum[:]))
			// name inside the info dict
			if data[next] == 'd' {
				k := next + 1
				for k < end-1 {
					ik, kn, err := bencodeString(data, k)
					if err != nil {
						break
					}
					ke, err := bencodeEnd(data, kn)
					if err != nil {
						break
					}
					if ik == "name" {
						name, _, _ = bencodeString(data, kn)
					}
					k = ke
				}
			}
		}
		i = end
	}
	if hash == "" {
		return "", "", errors.New("no info dictionary")
	}
	return hash, name, nil
}

// magnetInfo: btih (hex or base32) → upper-case hex hash, plus dn.
func magnetInfo(src string) (hash, name string) {
	u, err := url.Parse(src)
	if err != nil {
		return "", ""
	}
	q := u.Query()
	name = q.Get("dn")
	for _, xt := range q["xt"] {
		v := strings.TrimPrefix(strings.ToLower(xt), "urn:btih:")
		if v == strings.ToLower(xt) {
			continue
		}
		switch len(v) {
		case 40:
			if _, err := hex.DecodeString(v); err == nil {
				return strings.ToUpper(v), name
			}
		case 32:
			if b, err := base32.StdEncoding.DecodeString(strings.ToUpper(v)); err == nil {
				return strings.ToUpper(hex.EncodeToString(b)), name
			}
		}
	}
	return "", name
}

// fetchSmall downloads a small file (a .torrent) with the download SSRF rules.
func fetchSmall(src string, allowPrivate bool, max int64) ([]byte, error) {
	req, err := http.NewRequest("GET", src, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (StreamMKV/"+version+")")
	c := httpClientFor(allowPrivate)
	c.Timeout = 30 * time.Second
	resp, err := c.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("server answered %s", resp.Status)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, max+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > max {
		return nil, errors.New("file too big for a .torrent")
	}
	return b, nil
}

// probeName asks the server what file a link will give (HEAD, then a tiny GET).
func probeName(src string, allowPrivate bool) (string, int64) {
	c := httpClientFor(allowPrivate)
	c.Timeout = 20 * time.Second
	for _, m := range []string{"HEAD", "GET"} {
		req, err := http.NewRequest(m, src, nil)
		if err != nil {
			return "", -1
		}
		req.Header.Set("User-Agent", "Mozilla/5.0 (StreamMKV/"+version+")")
		if m == "GET" {
			req.Header.Set("Range", "bytes=0-0")
		}
		resp, err := c.Do(req)
		if err != nil {
			continue
		}
		resp.Body.Close()
		if resp.StatusCode == 200 || resp.StatusCode == 206 {
			size := resp.ContentLength
			if cr := resp.Header.Get("Content-Range"); cr != "" {
				if i := strings.LastIndexByte(cr, '/'); i >= 0 {
					size, _ = strconv.ParseInt(cr[i+1:], 10, 64)
				}
			}
			return fileNameFor(resp), size
		}
	}
	return "", -1
}

// ---------------------------------------------------------------- duplicate checks

type dupItem struct {
	Lib     string `json:"lib"`
	LibName string `json:"libName"`
	Path    string `json:"path,omitempty"`
	Name    string `json:"name"`
}

type dupResult struct {
	Kind  string    `json:"kind"` // same-torrent | same-file | same-link | same-title
	Items []dupItem `json:"items,omitempty"`
	msg   string
}

func (s *Server) dupItemFor(path, name string) dupItem {
	lib := strings.SplitN(path, "/", 2)[0]
	l, _ := s.libs.Get(lib)
	return dupItem{Lib: lib, LibName: l.Name, Path: path, Name: name}
}

func describe(items []dupItem) string {
	var parts []string
	for i, it := range items {
		if i == 3 {
			parts = append(parts, fmt.Sprintf("and %d more", len(items)-3))
			break
		}
		parts = append(parts, fmt.Sprintf("“%s” in %s", it.Name, it.LibName))
	}
	return strings.Join(parts, ", ")
}

// torrentDup: is this torrent already in rtorrent or downloaded before (files still there)?
// hard=true means it can't be added again at all.
func (s *Server) torrentDup(r *http.Request, hash string) (res *dupResult, hard bool) {
	if hash == "" {
		return nil, false
	}
	if rt, err := s.dl.rt(); err == nil {
		if items, err := rt.List(); err == nil {
			for _, it := range items {
				if !strings.EqualFold(it.Hash, hash) {
					continue
				}
				where := it.BasePath
				if strings.HasPrefix(it.Tag, "smkv:") {
					if j := s.dl.get(strings.TrimPrefix(it.Tag, "smkv:")); j != nil {
						l, _ := s.libs.Get(j.Lib)
						where = l.Name + optSub(j.Subdir)
						if !s.canAccess(r, j.Lib) {
							where = "a library you can't see"
						}
					}
				}
				state := "is already downloading"
				if it.Complete {
					state = "was already downloaded"
				}
				return &dupResult{Kind: "same-torrent", msg: fmt.Sprintf("This torrent %s: “%s” (%s)", state, it.Name, where)}, true
			}
		}
	}
	// finished before, removed from rtorrent, but the files are still on disk
	s.dl.mu.Lock()
	defer s.dl.mu.Unlock()
	for _, j := range s.dl.jobs {
		if j.Kind == "torrent" && strings.EqualFold(j.Hash, hash) && j.State == JobDone && j.BasePath != "" {
			if _, err := os.Stat(j.BasePath); err == nil && s.canAccess(r, j.Lib) {
				l, _ := s.libs.Get(j.Lib)
				return &dupResult{Kind: "same-torrent", Items: []dupItem{{Lib: j.Lib, LibName: l.Name, Name: j.Name}},
					msg: fmt.Sprintf("This torrent was downloaded before: “%s” in %s%s", j.Name, l.Name, optSub(j.Subdir))}, false
			}
		}
	}
	return nil, false
}

func optSub(sub string) string {
	if sub == "" {
		return ""
	}
	return " / " + sub
}

// fileDup: same link already queued/downloaded, or a file with that name in the target library.
func (s *Server) fileDup(r *http.Request, lib Library, subdir, src, name string) *dupResult {
	s.dl.mu.Lock()
	for _, j := range s.dl.jobs {
		if j.Kind == "http" && j.Source == src && j.Lib == lib.ID && (j.State == JobQueued || j.State == JobDownloading || j.State == JobDone) {
			s.dl.mu.Unlock()
			what := "is already downloading"
			if j.State == JobDone {
				what = "was already downloaded"
			}
			return &dupResult{Kind: "same-link", msg: fmt.Sprintf("This link %s into %s%s (“%s”)", what, lib.Name, optSub(j.Subdir), j.Name)}
		}
	}
	s.dl.mu.Unlock()
	if name == "" {
		return nil
	}
	if dir, _, err := s.dl.targetDir(lib.ID, subdir); err == nil {
		if _, err := os.Stat(filepath.Join(dir, name)); err == nil {
			rel := strings.Trim(path.Join(cleanSubdir(subdir), name), "/")
			return &dupResult{Kind: "same-file", Items: []dupItem{s.dupItemFor(lib.ID+"/"+rel, name)},
				msg: fmt.Sprintf("“%s” is already in %s%s", name, lib.Name, optSub(cleanSubdir(subdir)))}
		}
	}
	var hits []dupItem
	for _, it := range s.index.Items(lib.ID) {
		if strings.EqualFold(it.Name, name) {
			hits = append(hits, s.dupItemFor(it.Path, it.Name))
		}
	}
	if len(hits) > 0 {
		return &dupResult{Kind: "same-file", Items: hits, msg: "A file with this name is already in the library: " + describe(hits)}
	}
	return nil
}

// titleDup: the same movie / episode (by parsed title + year, or show + SxxEyy)
// already in a library of the same type that the user can see.
func (s *Server) titleDup(r *http.Request, lib Library, name string) *dupResult {
	if name == "" || (lib.Type != "movies" && lib.Type != "tv") {
		return nil
	}
	var hits []dupItem
	for _, l := range s.visibleLibraries(r) {
		if l.Type != lib.Type {
			continue
		}
		snap := s.index.Snapshot(l.ID)
		if lib.Type == "movies" {
			title, year := parseMovie(name, "")
			if title == "" {
				return nil
			}
			for _, it := range snap.Items {
				t, y := it.Title, it.Year
				if m := snap.Movies[it.MovieID]; m != nil {
					if !strings.EqualFold(m.Title, title) && !strings.EqualFold(m.OriginalTitle, title) && !strings.EqualFold(t, title) {
						continue
					}
					y = m.Year
				} else if !strings.EqualFold(t, title) {
					continue
				}
				if year > 0 && y > 0 && year != y {
					continue
				}
				hits = append(hits, s.dupItemFor(it.Path, it.Name))
			}
		} else {
			ep, ok := parseEpisode(name, nil)
			if !ok || ep.Episode == 0 {
				return nil
			}
			for _, it := range snap.Items {
				if it.Season != ep.Season || it.Episode != ep.Episode {
					continue
				}
				show := it.Title
				if m := snap.Shows[it.Show]; m != nil {
					show = m.Title
				}
				if strings.EqualFold(show, ep.Show) || strings.EqualFold(it.Show, showKey(ep.Show, ep.Year)) {
					hits = append(hits, s.dupItemFor(it.Path, it.Name))
				}
			}
		}
	}
	if len(hits) == 0 {
		return nil
	}
	what := "This movie"
	if lib.Type == "tv" {
		what = "This episode"
	}
	return &dupResult{Kind: "same-title", Items: hits, msg: what + " looks like one you already have: " + describe(hits)}
}

// writeDup answers 409 (may force) or 422 (can't).
func writeDup(w http.ResponseWriter, d *dupResult, canForce bool) {
	code := http.StatusConflict
	if !canForce {
		code = http.StatusUnprocessableEntity
	}
	writeJSON(w, code, map[string]any{"error": d.msg, "duplicate": d, "canForce": canForce})
}

// ---------------------------------------------------------------- after download

// noteDupes: once the finished download has been scanned (and matched), note
// any other versions of the same movie / episode.
func (d *Downloads) noteDupes(id string) {
	j := d.get(id)
	if j == nil {
		return
	}
	lib, ok := d.s.libs.Get(j.Lib)
	if !ok || (lib.Type != "movies" && lib.Type != "tv") {
		return
	}
	// files that belong to this job
	var root string
	if j.Kind == "http" {
		dir, _, err := d.targetDir(j.Lib, j.Subdir)
		if err != nil {
			return
		}
		root = filepath.Join(dir, j.Name)
	} else {
		root = j.BasePath
	}
	rel, err := filepath.Rel(lib.Path, root)
	if err != nil || strings.HasPrefix(rel, "..") {
		return
	}
	prefix := lib.ID + "/" + filepath.ToSlash(rel)
	// wait (up to 2 min) for a scan that has picked the new files up and matched them
	var snap LibSnapshot
	for i := 0; i < 60; i++ {
		time.Sleep(2 * time.Second)
		if d.s.index.Scanned(j.Lib) < j.Finished {
			continue
		}
		snap = d.s.index.Snapshot(lib.ID)
		ready := false
		for _, it := range snap.Items {
			if it.Path == prefix || strings.HasPrefix(it.Path, prefix+"/") {
				if (lib.Type == "movies" && it.MovieID != 0) || (lib.Type == "tv" && it.Show != "") {
					ready = true
					break
				}
			}
		}
		if ready {
			break
		}
	}
	mine := map[string]bool{}
	type key struct {
		movie int
		show  string
		s, e  int
	}
	keys := map[key]bool{}
	for _, it := range snap.Items {
		if it.Path == prefix || strings.HasPrefix(it.Path, prefix+"/") {
			mine[it.Path] = true
			if lib.Type == "movies" && it.MovieID != 0 {
				keys[key{movie: it.MovieID}] = true
			} else if lib.Type == "tv" && it.Show != "" {
				keys[key{show: it.Show, s: it.Season, e: it.Episode}] = true
			}
		}
	}
	if len(keys) == 0 {
		return
	}
	var dupes []string
	for _, l := range d.s.libs.List() {
		if l.Type != lib.Type || !d.s.userCanAccess(j.User, d.s.users.IsAdmin(j.User), l.ID) {
			continue
		}
		for _, it := range d.s.index.Items(l.ID) {
			if mine[it.Path] {
				continue
			}
			k := key{movie: it.MovieID}
			if lib.Type == "tv" {
				k = key{show: it.Show, s: it.Season, e: it.Episode}
			}
			if (lib.Type == "movies" && it.MovieID != 0 && keys[k]) || (lib.Type == "tv" && keys[k]) {
				dupes = append(dupes, l.Name+" · "+it.Name)
			}
		}
	}
	if len(dupes) > 0 {
		d.update(id, func(x *DownloadJob) { x.Dupes = dupes })
	}
}
