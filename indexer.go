package main

import (
	"encoding/json"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Item is one media file in a library, with whatever metadata the indexer found.
type Item struct {
	Path     string  `json:"path"` // "<library>/<relative path>"
	Name     string  `json:"name"`
	Dir      string  `json:"dir,omitempty"`
	Size     int64   `json:"size"`
	MTime    int64   `json:"mtime"`
	Added    int64   `json:"added"`
	Duration float64 `json:"duration,omitempty"`

	// movies & tv (parsed from names, refined by TMDB)
	Title           string `json:"title,omitempty"`
	Year            int    `json:"year,omitempty"`
	MovieID         int    `json:"movieId,omitempty"`
	Show            string `json:"show,omitempty"` // key into Shows
	Season          int    `json:"season,omitempty"`
	Episode         int    `json:"episode,omitempty"`
	EpisodeEnd      int    `json:"episodeEnd,omitempty"` // "S01E07-E08" in one file
	EpisodeTitle    string `json:"episodeTitle,omitempty"`
	EpisodeOverview string `json:"episodeOverview,omitempty"`
	Still           string `json:"still,omitempty"`

	// music (from tags, falling back to names)
	Artist      string   `json:"artist,omitempty"`
	AlbumArtist string   `json:"albumArtist,omitempty"`
	Album       string   `json:"album,omitempty"`
	Genres      []string `json:"genres,omitempty"`
	Track       int      `json:"track,omitempty"`
	Disc        int      `json:"disc,omitempty"`
	Cover       string   `json:"cover,omitempty"`
	Pic         bool     `json:"pic,omitempty"` // has an embedded picture
}

type LibIndex struct {
	Lib        string                         `json:"lib"`
	Type       string                         `json:"type"`
	Items      map[string]*Item               `json:"items"`
	Movies     map[int]*MovieMeta             `json:"movies,omitempty"`
	Shows      map[string]*ShowMeta           `json:"shows,omitempty"`
	Seasons    map[string]map[int]EpisodeMeta `json:"seasons,omitempty"` // "<tmdb id>/<season>"
	MovieMatch map[string]int                 `json:"movieMatch,omitempty"`
	ShowMatch  map[string]int                 `json:"showMatch,omitempty"`
	Manual     map[string]int                 `json:"manual,omitempty"` // item path or "show:<key>" → TMDB id
	CoverMiss  map[string]int64               `json:"coverMiss,omitempty"`
	Edits      map[string]map[string]string   `json:"edits,omitempty"` // manual corrections, see edits.go
	Scanned    int64                          `json:"scanned"`
}

func newLibIndex(lib Library) *LibIndex {
	li := &LibIndex{Lib: lib.ID, Type: lib.Type}
	li.init()
	return li
}

func (li *LibIndex) init() {
	if li.Items == nil {
		li.Items = map[string]*Item{}
	}
	if li.Movies == nil {
		li.Movies = map[int]*MovieMeta{}
	}
	if li.Shows == nil {
		li.Shows = map[string]*ShowMeta{}
	}
	if li.Seasons == nil {
		li.Seasons = map[string]map[int]EpisodeMeta{}
	}
	if li.MovieMatch == nil {
		li.MovieMatch = map[string]int{}
	}
	if li.ShowMatch == nil {
		li.ShowMatch = map[string]int{}
	}
	if li.Manual == nil {
		li.Manual = map[string]int{}
	}
	if li.CoverMiss == nil {
		li.CoverMiss = map[string]int64{}
	}
	if li.Edits == nil {
		li.Edits = map[string]map[string]string{}
	}
}

type ScanStatus struct {
	Running   bool   `json:"running"`
	Lib       string `json:"lib,omitempty"`
	Phase     string `json:"phase,omitempty"`
	Done      int    `json:"done,omitempty"`
	Total     int    `json:"total,omitempty"`
	LastError string `json:"lastError,omitempty"`
}

type Indexer struct {
	s       *Server
	mu      sync.RWMutex // guards libs and everything inside each LibIndex
	libs    map[string]*LibIndex
	work    chan scanReq
	pendMu  sync.Mutex
	pending map[string]bool
	stMu    sync.Mutex
	status  ScanStatus
}

type scanReq struct {
	lib     string
	refresh bool
}

func (ix *Indexer) dir() string { return filepath.Join(ix.s.cfg.DataDir, "index") }

func NewIndexer(s *Server) *Indexer {
	ix := &Indexer{s: s, libs: map[string]*LibIndex{}, work: make(chan scanReq, 64), pending: map[string]bool{}}
	os.MkdirAll(ix.dir(), 0o700)
	os.MkdirAll(s.coverDir(), 0o700)
	for _, lib := range s.libs.List() {
		li := newLibIndex(lib)
		if b, err := os.ReadFile(filepath.Join(ix.dir(), lib.ID+".json")); err == nil {
			if err := json.Unmarshal(b, li); err != nil {
				log.Printf("index %s unreadable, rescanning: %v", lib.ID, err)
				li = newLibIndex(lib)
			}
			li.init()
		}
		ix.libs[lib.ID] = li
	}
	return ix
}

// Queue asks for a scan; refresh also re-fetches all metadata.
func (ix *Indexer) Queue(lib string, refresh bool) {
	ix.pendMu.Lock()
	key := lib + "|" + strconv.FormatBool(refresh)
	if ix.pending[key] {
		ix.pendMu.Unlock()
		return
	}
	ix.pending[key] = true
	ix.pendMu.Unlock()
	ix.work <- scanReq{lib, refresh}
}

func (ix *Indexer) QueueAll() {
	for _, l := range ix.s.libs.List() {
		ix.Queue(l.ID, false)
	}
}

func (ix *Indexer) Loop() {
	go func() {
		ix.QueueAll()
		for range time.Tick(30 * time.Minute) {
			ix.QueueAll()
		}
	}()
	for req := range ix.work {
		ix.pendMu.Lock()
		delete(ix.pending, req.lib+"|"+strconv.FormatBool(req.refresh))
		ix.pendMu.Unlock()
		lib, ok := ix.s.libs.Get(req.lib)
		if !ok {
			continue
		}
		start := time.Now()
		if err := ix.scan(lib, req.refresh); err != nil {
			log.Printf("scan %s: %v", lib.ID, err)
			ix.setErr(err.Error())
		} else {
			log.Printf("scanned %s (%s) in %s", lib.ID, lib.Type, time.Since(start).Round(time.Millisecond))
		}
		ix.setStatus(ScanStatus{})
	}
}

func (ix *Indexer) setStatus(st ScanStatus) {
	ix.stMu.Lock()
	st.LastError = ix.status.LastError
	ix.status = st
	ix.stMu.Unlock()
}

func (ix *Indexer) setErr(e string) {
	ix.stMu.Lock()
	ix.status.LastError = e
	ix.stMu.Unlock()
}

func (ix *Indexer) Status() ScanStatus {
	ix.stMu.Lock()
	defer ix.stMu.Unlock()
	return ix.status
}

func (ix *Indexer) Forget(lib string) {
	ix.mu.Lock()
	delete(ix.libs, lib)
	ix.mu.Unlock()
	os.Remove(filepath.Join(ix.dir(), lib+".json"))
}

func (ix *Indexer) save(li *LibIndex) {
	ix.mu.RLock()
	b, err := json.Marshal(li)
	ix.mu.RUnlock()
	if err != nil {
		return
	}
	f := filepath.Join(ix.dir(), li.Lib+".json")
	if os.WriteFile(f+".tmp", b, 0o600) == nil {
		os.Rename(f+".tmp", f)
	}
}

func (ix *Indexer) tmdb() *TMDB {
	st := ix.s.settings.Get()
	if st.TMDBKey == "" {
		return nil
	}
	return NewTMDB(st.TMDBKey, st.TMDBLang)
}

// ---------------------------------------------------------------- read access

// Items returns copies of a library's items sorted by path.
func (ix *Indexer) Items(lib string) []Item {
	ix.mu.RLock()
	defer ix.mu.RUnlock()
	li := ix.libs[lib]
	if li == nil {
		return nil
	}
	out := make([]Item, 0, len(li.Items))
	for _, it := range li.Items {
		out = append(out, *it)
	}
	sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i].Path) < strings.ToLower(out[j].Path) })
	return out
}

type LibSnapshot struct {
	Items   []Item
	Movies  map[int]*MovieMeta
	Shows   map[string]*ShowMeta
	Seasons map[string]map[int]EpisodeMeta // "<tmdb id>/<season>" → episodes (to show the missing ones)
	Edits   map[string]map[string]string
	Scanned int64
}

func (ix *Indexer) Snapshot(lib string) LibSnapshot {
	items := ix.Items(lib)
	ix.mu.RLock()
	defer ix.mu.RUnlock()
	li := ix.libs[lib]
	if li == nil {
		return LibSnapshot{}
	}
	snap := LibSnapshot{Items: items, Movies: map[int]*MovieMeta{}, Shows: map[string]*ShowMeta{}, Edits: map[string]map[string]string{}, Scanned: li.Scanned}
	for k, v := range li.Edits {
		c := map[string]string{}
		for f, x := range v {
			c[f] = x
		}
		snap.Edits[k] = c
	}
	for k, v := range li.Movies {
		c := *v
		snap.Movies[k] = &c
	}
	snap.Seasons = map[string]map[int]EpisodeMeta{}
	for k, v := range li.Shows {
		c := *v
		snap.Shows[k] = &c
	}
	for k, v := range li.Seasons {
		snap.Seasons[k] = v // never modified in place: a scan replaces the whole map
	}
	return snap
}

func (ix *Indexer) Count(lib string) int {
	ix.mu.RLock()
	defer ix.mu.RUnlock()
	if li := ix.libs[lib]; li != nil {
		return len(li.Items)
	}
	return 0
}

func (ix *Indexer) Scanned(lib string) int64 {
	ix.mu.RLock()
	defer ix.mu.RUnlock()
	if li := ix.libs[lib]; li != nil {
		return li.Scanned
	}
	return 0
}

// RefreshAllMetadata is called when the TMDB key or language changes: forget failed
// matches (and, for a language change, all fetched details) and rescan.
func (ix *Indexer) RefreshAllMetadata(langChanged bool) {
	ix.mu.Lock()
	for _, li := range ix.libs {
		for k, v := range li.MovieMatch {
			if v < 0 {
				delete(li.MovieMatch, k)
			}
		}
		for k, v := range li.ShowMatch {
			if v < 0 {
				delete(li.ShowMatch, k)
			}
		}
		if langChanged {
			li.Movies = map[int]*MovieMeta{}
			li.Seasons = map[string]map[int]EpisodeMeta{}
			for _, sm := range li.Shows {
				sm.Fetched = 0
			}
		}
	}
	ix.mu.Unlock()
	ix.QueueAll()
}

// SetManual pins a movie (path) or show ("show:<key>") to a TMDB id and rescans.
func (ix *Indexer) SetManual(lib, key string, tmdbID int) {
	ix.mu.Lock()
	if li := ix.libs[lib]; li != nil {
		if tmdbID > 0 {
			li.Manual[key] = tmdbID
		} else {
			delete(li.Manual, key)
		}
	}
	ix.mu.Unlock()
	ix.Queue(lib, false)
}

// ---------------------------------------------------------------- scanning

func (ix *Indexer) scan(lib Library, refresh bool) error {
	ix.mu.Lock()
	li := ix.libs[lib.ID]
	if li == nil || li.Type != lib.Type {
		manual := map[string]int{}
		if li != nil && li.Type == lib.Type {
			manual = li.Manual
		}
		li = newLibIndex(lib)
		li.Manual = manual
		ix.libs[lib.ID] = li
	}
	if refresh {
		manual, edits := li.Manual, li.Edits
		old := li.Items
		*li = LibIndex{Lib: lib.ID, Type: lib.Type, Manual: manual, Edits: edits}
		li.init()
		for k, v := range old { // keep "added" dates
			li.Items[k] = &Item{Added: v.Added}
		}
	}
	old := make(map[string]Item, len(li.Items))
	for k, v := range li.Items {
		old[k] = *v
	}
	ix.mu.Unlock()

	ix.setErr("") // only report errors from the latest scan
	ix.setStatus(ScanStatus{Running: true, Lib: lib.ID, Phase: "Scanning files"})
	found := map[string]*Item{}
	var needTags []string
	now := time.Now().Unix()
	filepath.WalkDir(lib.Path, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if strings.HasPrefix(d.Name(), ".") && p != lib.Path {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() && p != lib.Path {
			if rel, err := filepath.Rel(lib.Path, p); err == nil && lib.ExcludedDir(filepath.ToSlash(rel)) {
				return filepath.SkipDir
			}
		}
		if d.IsDir() || !ix.s.libs.Accepts(lib.Type, d.Name()) {
			return nil
		}
		info, err := d.Info()
		if err != nil || !info.Mode().IsRegular() {
			return nil
		}
		rel, _ := filepath.Rel(lib.Path, p)
		rel = filepath.ToSlash(rel)
		prev, had := old[rel]
		if had && prev.Size == info.Size() && prev.MTime == info.ModTime().Unix() && prev.Name != "" {
			c := prev
			if lib.Type != LibMusic { // names are cheap to re-read (and the rules improve); music keeps its tags
				parseItem(lib.Type, &c)
			}
			found[rel] = &c
			return nil
		}
		dir := filepath.ToSlash(filepath.Dir(rel))
		if dir == "." {
			dir = ""
		}
		it := &Item{Path: lib.ID + "/" + rel, Name: d.Name(), Dir: dir, Size: info.Size(), MTime: info.ModTime().Unix(), Added: now}
		if had && prev.Added > 0 {
			it.Added = prev.Added
		}
		parseItem(lib.Type, it)
		if lib.Type == LibMusic {
			needTags = append(needTags, rel)
		}
		found[rel] = it
		return nil
	})

	// music: tags for new / changed files
	for i, rel := range needTags {
		if i%20 == 0 {
			ix.setStatus(ScanStatus{Running: true, Lib: lib.ID, Phase: "Reading tags", Done: i, Total: len(needTags)})
		}
		it := found[rel]
		if t, err := ix.s.readTags(filepath.Join(lib.Path, filepath.FromSlash(rel))); err == nil {
			applyTags(it, t)
		}
	}

	ix.mu.Lock()
	li.Items = found
	if lib.Type == LibMusic {
		ix.applyEdits(lib, li) // album/artist edits decide the cover groups
	}
	ix.mu.Unlock()

	switch lib.Type {
	case LibMovies, LibVideos:
		if lib.Type == LibMovies {
			ix.scrapeMovies(lib, li)
		}
		// episodes in a movie / plain-folder library still group into series
		ix.mu.RLock()
		hasEp := false
		for _, it := range li.Items {
			if it.Show != "" {
				hasEp = true
				break
			}
		}
		ix.mu.RUnlock()
		if hasEp || len(li.Shows) > 0 {
			ix.scrapeShows(lib, li)
		}
	case LibTV:
		ix.scrapeShows(lib, li)
	case LibMusic:
		ix.covers(lib, li)
		ix.applyCoverEdits(li)
	}
	ix.mu.Lock()
	if lib.Type != LibMusic {
		ix.applyEdits(lib, li)
	}
	li.Scanned = time.Now().Unix()
	ix.mu.Unlock()
	ix.save(li)
	return nil
}

func parseItem(typ string, it *Item) {
	parent := ""
	dirs := []string{}
	if it.Dir != "" {
		dirs = strings.Split(it.Dir, "/")
		parent = dirs[len(dirs)-1]
	}
	it.Show, it.Season, it.Episode, it.EpisodeEnd = "", 0, 0, 0
	switch typ {
	case LibMovies, LibVideos:
		// "Show.S01E02…" is an episode wherever it is; anything else stays a movie / a plain file
		if ei, ok := parseEpisode(it.Name, dirs); ok && ei.Strong {
			it.Title, it.Year, it.Season, it.Episode, it.EpisodeEnd = ei.Show, ei.Year, ei.Season, ei.Episode, ei.EpisodeEnd
			it.Show = showKey(it.Title, it.Year)
			it.MovieID = 0
		} else if typ == LibMovies {
			it.Title, it.Year = parseMovie(it.Name, parent)
		} else {
			it.Title, it.Year = "", 0
		}
	case LibTV:
		if ei, ok := parseEpisode(it.Name, dirs); ok {
			it.Title, it.Year, it.Season, it.Episode, it.EpisodeEnd = ei.Show, ei.Year, ei.Season, ei.Episode, ei.EpisodeEnd
		} else {
			// not recognisable: group by the top folder, no season/episode
			top := cleanName(it.Name)
			if len(dirs) > 0 {
				top = cleanName(dirs[0] + ".x")
			}
			it.Title, it.Year = parseMovie(top+".x", "")
		}
		it.Show = showKey(it.Title, it.Year)
	case LibMusic:
		artist, title, track := parseArtistTitle(it.Name)
		it.Title, it.Artist, it.Track = title, artist, track
		if len(dirs) > 0 {
			it.Album = dirs[len(dirs)-1]
			if artist == "" && len(dirs) > 1 {
				it.Artist = dirs[len(dirs)-2]
			}
		}
	}
}

func applyTags(it *Item, t audioTags) {
	if t.Title != "" {
		it.Title = t.Title
	}
	if t.Artist != "" {
		it.Artist = t.Artist
	}
	if t.Album != "" {
		it.Album = t.Album
	}
	it.AlbumArtist = firstNonEmpty(t.AlbumArtist, it.Artist)
	if t.Track > 0 {
		it.Track = t.Track
	}
	it.Disc, it.Year, it.Duration, it.Pic = t.Disc, t.Year, t.Duration, t.HasPicture
	it.Genres = splitGenres(t.Genre)
}

// ---------------------------------------------------------------- movies

func (ix *Indexer) scrapeMovies(lib Library, li *LibIndex) {
	tm := ix.tmdb()
	type q struct {
		title string
		year  int
	}
	ix.mu.RLock()
	queries := map[string]q{}
	for _, it := range li.Items {
		if it.Show != "" {
			continue
		}
		k := strings.ToLower(it.Title) + "|" + strconv.Itoa(it.Year)
		if _, done := li.MovieMatch[k]; !done && li.Manual[it.Path] == 0 && it.Title != "" {
			queries[k] = q{it.Title, it.Year}
		}
	}
	ix.mu.RUnlock()

	if tm != nil {
		n := 0
		for k, qq := range queries {
			n++
			ix.setStatus(ScanStatus{Running: true, Lib: lib.ID, Phase: "Matching movies", Done: n, Total: len(queries)})
			id, err := tm.SearchMovie(qq.title, qq.year)
			if err != nil {
				ix.setErr(err.Error())
				if strings.Contains(err.Error(), "API key") {
					break
				}
				continue
			}
			if id == 0 {
				id = -1
			}
			ix.mu.Lock()
			li.MovieMatch[k] = id
			ix.mu.Unlock()
		}
	}

	// assign ids, collect missing details
	need := map[int]bool{}
	ix.mu.Lock()
	for _, it := range li.Items {
		if it.Show != "" {
			it.MovieID = 0
			continue
		}
		id := li.Manual[it.Path]
		if id == 0 {
			id = li.MovieMatch[strings.ToLower(it.Title)+"|"+strconv.Itoa(it.Year)]
		}
		if id < 0 {
			id = 0
		}
		it.MovieID = id
		if m := li.Movies[id]; id > 0 && (m == nil || time.Since(time.Unix(m.Fetched, 0)) > 60*24*time.Hour) {
			need[id] = true
		}
	}
	ix.mu.Unlock()
	if tm == nil {
		return
	}
	n := 0
	for id := range need {
		n++
		ix.setStatus(ScanStatus{Running: true, Lib: lib.ID, Phase: "Fetching movie details", Done: n, Total: len(need)})
		m, err := tm.Movie(id)
		if err != nil {
			ix.setErr(err.Error())
			continue
		}
		ix.mu.Lock()
		li.Movies[id] = m
		ix.mu.Unlock()
	}
}

// ---------------------------------------------------------------- tv

func (ix *Indexer) scrapeShows(lib Library, li *LibIndex) {
	tm := ix.tmdb()
	type q struct {
		title string
		year  int
	}
	ix.mu.Lock()
	shows := map[string]q{}
	for _, it := range li.Items {
		if it.Show == "" {
			continue
		}
		if _, ok := shows[it.Show]; !ok {
			shows[it.Show] = q{it.Title, it.Year}
		}
		if li.Shows[it.Show] == nil { // placeholder so clients can group before / without TMDB
			li.Shows[it.Show] = &ShowMeta{Key: it.Show, Title: it.Title, Year: it.Year}
		}
	}
	for k := range li.Shows {
		if _, ok := shows[k]; !ok {
			delete(li.Shows, k)
		}
	}
	ix.mu.Unlock()
	if tm == nil {
		return
	}

	n := 0
	for key, qq := range shows {
		n++
		ix.setStatus(ScanStatus{Running: true, Lib: lib.ID, Phase: "Matching shows", Done: n, Total: len(shows)})
		ix.mu.RLock()
		id := li.Manual["show:"+key]
		matched, done := li.ShowMatch[key]
		cur := li.Shows[key]
		ix.mu.RUnlock()
		if id == 0 {
			if !done {
				var err error
				if matched, err = tm.SearchTV(qq.title, qq.year); err != nil {
					ix.setErr(err.Error())
					if strings.Contains(err.Error(), "API key") {
						return
					}
					continue
				}
				if matched == 0 {
					matched = -1
				}
				ix.mu.Lock()
				li.ShowMatch[key] = matched
				ix.mu.Unlock()
			}
			id = matched
		}
		if id <= 0 || (cur != nil && cur.TMDBID == id && time.Since(time.Unix(cur.Fetched, 0)) < 30*24*time.Hour) {
			continue
		}
		sm, err := tm.TV(id)
		if err != nil {
			ix.setErr(err.Error())
			continue
		}
		sm.Key = key
		ix.mu.Lock()
		li.Shows[key] = sm
		ix.mu.Unlock()
	}

	// episode titles: one request per (show, season) we have files for
	type ss struct{ id, season int }
	seasons := map[ss]bool{}
	ix.mu.RLock()
	for _, it := range li.Items {
		if sm := li.Shows[it.Show]; sm != nil && sm.TMDBID > 0 && it.Season > 0 {
			if _, ok := li.Seasons[strconv.Itoa(sm.TMDBID)+"/"+strconv.Itoa(it.Season)]; !ok {
				seasons[ss{sm.TMDBID, it.Season}] = true
			}
		}
	}
	ix.mu.RUnlock()
	n = 0
	for k := range seasons {
		n++
		ix.setStatus(ScanStatus{Running: true, Lib: lib.ID, Phase: "Fetching episodes", Done: n, Total: len(seasons)})
		eps, err := tm.Season(k.id, k.season)
		if err != nil {
			ix.setErr(err.Error())
			eps = map[int]EpisodeMeta{} // don't retry every scan
		}
		ix.mu.Lock()
		li.Seasons[strconv.Itoa(k.id)+"/"+strconv.Itoa(k.season)] = eps
		ix.mu.Unlock()
	}
	ix.mu.Lock()
	for _, it := range li.Items {
		if sm := li.Shows[it.Show]; sm != nil && sm.TMDBID > 0 {
			if ep, ok := li.Seasons[strconv.Itoa(sm.TMDBID)+"/"+strconv.Itoa(it.Season)][it.Episode]; ok {
				it.EpisodeTitle, it.EpisodeOverview, it.Still = ep.Title, ep.Overview, ep.Still
			}
		}
	}
	ix.mu.Unlock()
}

// ---------------------------------------------------------------- music covers

func (ix *Indexer) covers(lib Library, li *LibIndex) {
	type group struct {
		artist, album, dir string
		pic                string // a file with an embedded picture
		paths              []string
	}
	groups := map[string]*group{}
	ix.mu.RLock()
	for rel, it := range li.Items {
		key := cacheKey("cover", strings.ToLower(it.AlbumArtist), strings.ToLower(it.Album))
		if it.Album == "" {
			key = cacheKey("cover-dir", it.Dir)
		}
		g := groups[key]
		if g == nil {
			g = &group{artist: it.AlbumArtist, album: it.Album, dir: filepath.Join(lib.Path, filepath.FromSlash(it.Dir))}
			groups[key] = g
		}
		if it.Pic && g.pic == "" {
			g.pic = filepath.Join(lib.Path, filepath.FromSlash(rel))
		}
		g.paths = append(g.paths, rel)
	}
	ix.mu.RUnlock()

	n := 0
	for key, g := range groups {
		n++
		file := ix.s.coverFile(key)
		ok := false
		if _, err := os.Stat(file); err == nil {
			ok = true
		} else {
			ix.mu.RLock()
			miss := li.CoverMiss[key]
			ix.mu.RUnlock()
			if time.Since(time.Unix(miss, 0)) > 7*24*time.Hour {
				ix.setStatus(ScanStatus{Running: true, Lib: lib.ID, Phase: "Album covers", Done: n, Total: len(groups)})
				if img := folderImage(g.dir); img != "" && copyFile(img, file) == nil {
					ok = true
				} else if g.pic != "" && ix.s.extractEmbedded(g.pic, file) == nil {
					ok = true
				} else if g.album != "" && ix.s.fetchCAA(g.artist, g.album, file) == nil {
					ok = true
				}
				if !ok {
					ix.mu.Lock()
					li.CoverMiss[key] = time.Now().Unix()
					ix.mu.Unlock()
				}
			}
		}
		ix.mu.Lock()
		for _, rel := range g.paths {
			if it := li.Items[rel]; it != nil {
				if ok {
					it.Cover = key
				} else {
					it.Cover = ""
				}
			}
		}
		ix.mu.Unlock()
	}
}
