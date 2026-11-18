package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// Library types.
const (
	LibMovies = "movies" // scraped from TMDB as films
	LibTV     = "tv"     // Show/Season/Episode, scraped from TMDB as series
	LibMusic  = "music"  // audio files, tags + MusicBrainz cover art
	LibVideos = "videos" // plain folders, no scraping
)

var libTypes = map[string]bool{LibMovies: true, LibTV: true, LibMusic: true, LibVideos: true}

var audioExts = map[string]bool{
	".mp3": true, ".flac": true, ".m4a": true, ".aac": true, ".ogg": true, ".oga": true, ".opus": true,
	".wav": true, ".wma": true, ".ape": true, ".alac": true, ".aiff": true, ".aif": true, ".wv": true, ".mka": true,
}

const defaultVideoExts = ".mkv,.mp4,.m4v,.avi,.webm,.mov,.ts,.m2ts,.wmv,.mpg,.mpeg,.flv"

type Library struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Type    string `json:"type"`
	Path    string `json:"path"`
	Created int64  `json:"created"`
	// Exclude: folders to leave out. An entry with a "/" is a path relative to
	// the library root ("Extras/Featurettes"); without one it is a folder-name
	// pattern matched at any depth ("Sample", "Behind*").
	Exclude []string `json:"exclude,omitempty"`
	// Owner: a user's personal library (created by a downloader under the
	// user-library folder); empty = an admin library. Shared: everyone sees it.
	Owner  string `json:"owner,omitempty"`
	Shared bool   `json:"shared,omitempty"`
}

// cleanExclude normalises the exclude list (trims, drops blanks/dupes, no "..").
func cleanExclude(in []string) []string {
	out := []string{}
	seen := map[string]bool{}
	for _, e := range in {
		e = strings.Trim(strings.TrimSpace(filepath.ToSlash(e)), "/")
		if e == "" || e == "." || strings.Contains("/"+e+"/", "/../") || seen[strings.ToLower(e)] {
			continue
		}
		if _, err := path.Match(e, "x"); err != nil {
			continue // bad pattern
		}
		seen[strings.ToLower(e)] = true
		out = append(out, e)
	}
	return out
}

// ExcludedDir reports whether the folder rel (slash path from the library
// root, "" = root) or any of its parents is excluded.
func (l Library) ExcludedDir(rel string) bool {
	if len(l.Exclude) == 0 || rel == "" || rel == "." {
		return false
	}
	parts := strings.Split(strings.ToLower(rel), "/")
	for _, e := range l.Exclude {
		e = strings.ToLower(e)
		if strings.Contains(e, "/") {
			n := strings.Count(e, "/") + 1
			if len(parts) >= n {
				if ok, _ := path.Match(e, strings.Join(parts[:n], "/")); ok {
					return true
				}
			}
			continue
		}
		for _, p := range parts {
			if ok, _ := path.Match(e, p); ok {
				return true
			}
		}
	}
	return false
}

type LibraryStore struct {
	mu        sync.RWMutex
	file      string
	libs      []*Library
	videoExts map[string]bool
}

type librariesFile struct {
	Version   int        `json:"version"`
	Libraries []*Library `json:"libraries"`
}

var slugRe = regexp.MustCompile(`[^a-z0-9]+`)

func slugify(s string) string {
	s = strings.Trim(slugRe.ReplaceAllString(strings.ToLower(s), "-"), "-")
	if len(s) > 24 {
		s = strings.Trim(s[:24], "-")
	}
	return s
}

// NewLibraryStore loads libraries.json. When it does not exist yet (upgrade from a
// single-root install) a "main" library of type videos is created for [root]; the
// returned bool reports that migration so progress keys can be prefixed.
func NewLibraryStore(dir, root string, videoExts map[string]bool) (*LibraryStore, bool, error) {
	ls := &LibraryStore{file: filepath.Join(dir, "libraries.json"), videoExts: videoExts}
	b, err := os.ReadFile(ls.file)
	if err == nil {
		var f librariesFile
		if err := json.Unmarshal(b, &f); err != nil {
			return nil, false, err
		}
		ls.libs = f.Libraries
		return ls, false, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, false, err
	}
	ls.libs = []*Library{{ID: "main", Name: "Library", Type: LibVideos, Path: root, Created: time.Now().Unix()}}
	return ls, true, ls.save()
}

func (ls *LibraryStore) save() error {
	b, _ := json.MarshalIndent(librariesFile{Version: 1, Libraries: ls.libs}, "", "  ")
	tmp := ls.file + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, ls.file)
}

func (ls *LibraryStore) List() []Library {
	ls.mu.RLock()
	defer ls.mu.RUnlock()
	out := make([]Library, len(ls.libs))
	for i, l := range ls.libs {
		out[i] = *l
	}
	return out
}

func (ls *LibraryStore) Get(id string) (Library, bool) {
	ls.mu.RLock()
	defer ls.mu.RUnlock()
	for _, l := range ls.libs {
		if l.ID == id {
			return *l, true
		}
	}
	return Library{}, false
}

func (ls *LibraryStore) validate(name, typ, path string) (string, error) {
	if strings.TrimSpace(name) == "" {
		return "", errors.New("name is required")
	}
	if !libTypes[typ] {
		return "", errors.New("type must be movies, tv, music or videos")
	}
	abs, err := filepath.Abs(path)
	if err != nil || path == "" {
		return "", errors.New("invalid path")
	}
	if st, err := os.Stat(abs); err != nil || !st.IsDir() {
		return "", errors.New("path is not a directory on the server")
	}
	return abs, nil
}

func (ls *LibraryStore) Add(name, typ, dir string, exclude []string) (Library, error) {
	abs, err := ls.validate(name, typ, dir)
	if err != nil {
		return Library{}, err
	}
	ls.mu.Lock()
	defer ls.mu.Unlock()
	id := slugify(name)
	if id == "" {
		id = "lib"
	}
	for taken := true; taken; {
		taken = false
		for _, l := range ls.libs {
			if l.ID == id {
				b := make([]byte, 2)
				rand.Read(b)
				id = slugify(name) + "-" + hex.EncodeToString(b)
				taken = true
			}
		}
	}
	l := &Library{ID: id, Name: strings.TrimSpace(name), Type: typ, Path: abs, Created: time.Now().Unix(), Exclude: cleanExclude(exclude)}
	ls.libs = append(ls.libs, l)
	return *l, ls.save()
}

func (ls *LibraryStore) Update(id, name, typ, dir string, exclude *[]string) (Library, error) {
	abs, err := ls.validate(name, typ, dir)
	if err != nil {
		return Library{}, err
	}
	ls.mu.Lock()
	defer ls.mu.Unlock()
	for _, l := range ls.libs {
		if l.ID == id {
			l.Name, l.Type, l.Path = strings.TrimSpace(name), typ, abs
			if exclude != nil {
				l.Exclude = cleanExclude(*exclude)
			}
			return *l, ls.save()
		}
	}
	return Library{}, errors.New("no such library")
}

func (ls *LibraryStore) Delete(id string) error {
	ls.mu.Lock()
	defer ls.mu.Unlock()
	for i, l := range ls.libs {
		if l.ID == id {
			ls.libs = append(ls.libs[:i], ls.libs[i+1:]...)
			return ls.save()
		}
	}
	return errors.New("no such library")
}

// Accepts reports whether a file name belongs in a library of this type.
func (ls *LibraryStore) Accepts(typ, name string) bool {
	ext := strings.ToLower(filepath.Ext(name))
	if typ == LibMusic {
		return audioExts[ext]
	}
	return ls.videoExts[ext]
}

// ---------------------------------------------------------------- path ids
// A media path sent to clients is "<library id>/<path relative to the library root>".

func splitPath(p string) (lib, rel string) {
	lib, rel, _ = strings.Cut(strings.TrimPrefix(p, "/"), "/")
	return
}

// canAccess reports whether the request's user may see the library.
func (s *Server) canAccess(r *http.Request, libID string) bool {
	if isAdmin(r) {
		return true
	}
	if lib, ok := s.libs.Get(libID); ok && lib.Owner != "" {
		if lib.Owner == userOf(r) {
			return true // your own library
		}
		if !lib.Shared {
			return false // someone else's private library
		}
	}
	allowed := s.users.Libraries(userOf(r))
	if allowed == nil {
		return true
	}
	for _, id := range allowed {
		if id == libID {
			return true
		}
	}
	return false
}

// visibleLibraries returns the libraries the request's user may see, sorted by name.
func (s *Server) visibleLibraries(r *http.Request) []Library {
	var out []Library
	for _, l := range s.libs.List() {
		if s.canAccess(r, l.ID) {
			out = append(out, l)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name) })
	return out
}

// resolveLib maps "<lib>/<rel>" to an absolute file path inside that library.
func (s *Server) resolveLib(p string) (string, os.FileInfo, Library, error) {
	libID, rel := splitPath(p)
	lib, ok := s.libs.Get(libID)
	if !ok || rel == "" {
		return "", nil, Library{}, errors.New("not found")
	}
	abs := filepath.Join(lib.Path, filepath.FromSlash(rel))
	r2, err := filepath.Rel(lib.Path, abs)
	if err != nil || r2 == ".." || strings.HasPrefix(r2, ".."+string(filepath.Separator)) || filepath.IsAbs(r2) {
		return "", nil, Library{}, errors.New("invalid path")
	}
	if !s.libs.Accepts(lib.Type, abs) {
		return "", nil, Library{}, errors.New("file type not allowed")
	}
	if d := path.Dir(rel); d != "." && lib.ExcludedDir(d) {
		return "", nil, Library{}, errors.New("not found")
	}
	st, err := os.Stat(abs)
	if err != nil || !st.Mode().IsRegular() {
		return "", nil, Library{}, errors.New("not found")
	}
	return abs, st, lib, nil
}

// resolveFor is resolveLib plus the per-user library permission check.
func (s *Server) resolveFor(r *http.Request, p string) (string, os.FileInfo, error) {
	if p == "" {
		return "", nil, errors.New("missing path")
	}
	libID, _ := splitPath(p)
	if !s.canAccess(r, libID) {
		return "", nil, errors.New("not found")
	}
	abs, st, _, err := s.resolveLib(p)
	return abs, st, err
}
