package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// TMDB v3 client. The key can be a v3 API key or a v4 read access token ("eyJ…").

const tmdbImg = "https://image.tmdb.org/t/p/"

type TMDB struct {
	key, lang, base string
	client          *http.Client
	mu              sync.Mutex
	last            time.Time
}

func NewTMDB(key, lang string) *TMDB {
	base := os.Getenv("STREAMMKV_TMDB_URL") // tests
	if base == "" {
		base = "https://api.themoviedb.org/3"
	}
	if lang == "" {
		lang = "en-US"
	}
	return &TMDB{key: strings.TrimSpace(key), lang: lang, base: strings.TrimRight(base, "/"),
		client: &http.Client{Timeout: 20 * time.Second}}
}

type Person struct {
	Name  string `json:"name"`
	Role  string `json:"role,omitempty"`
	Photo string `json:"photo,omitempty"`
}

type MovieMeta struct {
	ID            int      `json:"id"`
	Title         string   `json:"title"`
	OriginalTitle string   `json:"originalTitle,omitempty"`
	Year          int      `json:"year,omitempty"`
	Overview      string   `json:"overview,omitempty"`
	Genres        []string `json:"genres,omitempty"`
	Poster        string   `json:"poster,omitempty"`
	Backdrop      string   `json:"backdrop,omitempty"`
	Rating        float64  `json:"rating,omitempty"`
	Runtime       int      `json:"runtime,omitempty"`
	Director      string   `json:"director,omitempty"`
	Cast          []Person `json:"cast,omitempty"`
	Fetched       int64    `json:"fetched"`
}

type ShowMeta struct {
	Key           string   `json:"key"`
	TMDBID        int      `json:"tmdbId,omitempty"`
	Title         string   `json:"title"`
	OriginalTitle string   `json:"originalTitle,omitempty"`
	Year          int      `json:"year,omitempty"`
	Overview      string   `json:"overview,omitempty"`
	Genres        []string `json:"genres,omitempty"`
	Poster        string   `json:"poster,omitempty"`
	Backdrop      string   `json:"backdrop,omitempty"`
	Rating        float64  `json:"rating,omitempty"`
	Cast          []Person `json:"cast,omitempty"`
	Fetched       int64    `json:"fetched,omitempty"`
}

type EpisodeMeta struct {
	Title    string `json:"title,omitempty"`
	Overview string `json:"overview,omitempty"`
	Still    string `json:"still,omitempty"`
	Aired    string `json:"aired,omitempty"`
}

func img(size, path string) string {
	if path == "" {
		return ""
	}
	return tmdbImg + size + path
}

func year(date string) int {
	if len(date) >= 4 {
		y, _ := strconv.Atoi(date[:4])
		return y
	}
	return 0
}

func (t *TMDB) get(path string, q url.Values, lang string, out any) error {
	if t.key == "" {
		return errors.New("no TMDB API key")
	}
	// stay well under TMDB's rate limit
	t.mu.Lock()
	if d := time.Since(t.last); d < 60*time.Millisecond {
		time.Sleep(60*time.Millisecond - d)
	}
	t.last = time.Now()
	t.mu.Unlock()

	if q == nil {
		q = url.Values{}
	}
	if lang == "" {
		lang = t.lang
	}
	q.Set("language", lang)
	req, _ := http.NewRequest("GET", t.base+path, nil)
	if strings.HasPrefix(t.key, "eyJ") {
		req.Header.Set("Authorization", "Bearer "+t.key)
	} else {
		q.Set("api_key", t.key)
	}
	req.URL.RawQuery = q.Encode()
	req.Header.Set("Accept", "application/json")
	resp, err := t.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == 401 {
		return errors.New("TMDB rejected the API key")
	}
	if resp.StatusCode != 200 {
		return fmt.Errorf("TMDB %s: %s", path, resp.Status)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

type tmdbSearch struct {
	Results []struct {
		ID           int     `json:"id"`
		Title        string  `json:"title"`
		Name         string  `json:"name"`
		ReleaseDate  string  `json:"release_date"`
		FirstAirDate string  `json:"first_air_date"`
		Popularity   float64 `json:"popularity"`
	} `json:"results"`
}

func (t *TMDB) search(kind, title string, yr int) (int, error) {
	try := func(withYear bool) (int, error) {
		q := url.Values{"query": {title}, "include_adult": {"false"}}
		if withYear && yr > 0 {
			if kind == "movie" {
				q.Set("year", strconv.Itoa(yr))
			} else {
				q.Set("first_air_date_year", strconv.Itoa(yr))
			}
		}
		var r tmdbSearch
		if err := t.get("/search/"+kind, q, "", &r); err != nil {
			return 0, err
		}
		if len(r.Results) == 0 {
			return 0, nil
		}
		return r.Results[0].ID, nil
	}
	for _, v := range titleVariants(title) {
		title = v
		id, err := try(true)
		if err == nil && id == 0 && yr > 0 {
			id, err = try(false)
		}
		if err != nil || id != 0 {
			return id, err
		}
	}
	return 0, nil
}

var (
	reSequelNum = regexp.MustCompile(`(\S)\s+\d{1,2}(\s|$)`)
	reSpaces    = regexp.MustCompile(`\s+`)
)

// titleVariants: the parsed title first, then looser forms that TMDB is more
// likely to find, e.g. "Now You See Me 3 Now You Don't" → "Now You See Me Now You Don't",
// "Show - Subtitle" → "Show".
func titleVariants(t string) []string {
	out := []string{t}
	add := func(v string) {
		v = strings.TrimSpace(reSpaces.ReplaceAllString(v, " "))
		if v == "" || len(v) < 2 {
			return
		}
		for _, x := range out {
			if strings.EqualFold(x, v) {
				return
			}
		}
		out = append(out, v)
	}
	add(reSequelNum.ReplaceAllString(t, "$1$2"))
	for _, sep := range []string{" - ", ": "} {
		if i := strings.Index(t, sep); i > 0 {
			add(t[:i])
		}
	}
	return out
}

type SearchResult struct {
	ID            int    `json:"id"`
	Title         string `json:"title"`
	OriginalTitle string `json:"originalTitle,omitempty"`
	Year          int    `json:"year,omitempty"`
	Poster        string `json:"poster,omitempty"`
	Overview      string `json:"overview,omitempty"`
}

// SearchList returns up to 12 candidates (for the "fix match" picker).
func (t *TMDB) SearchList(kind, title string, yr int) ([]SearchResult, error) {
	q := url.Values{"query": {title}, "include_adult": {"false"}}
	if yr > 0 {
		if kind == "movie" {
			q.Set("year", strconv.Itoa(yr))
		} else {
			q.Set("first_air_date_year", strconv.Itoa(yr))
		}
	}
	var r struct {
		Results []struct {
			ID            int    `json:"id"`
			Title         string `json:"title"`
			Name          string `json:"name"`
			OriginalTitle string `json:"original_title"`
			OriginalName  string `json:"original_name"`
			ReleaseDate   string `json:"release_date"`
			FirstAirDate  string `json:"first_air_date"`
			PosterPath    string `json:"poster_path"`
			Overview      string `json:"overview"`
		} `json:"results"`
	}
	if err := t.get("/search/"+kind, q, "", &r); err != nil {
		return nil, err
	}
	out := []SearchResult{}
	for i, x := range r.Results {
		if i >= 12 {
			break
		}
		sr := SearchResult{ID: x.ID, Title: firstNonEmpty(x.Title, x.Name), OriginalTitle: firstNonEmpty(x.OriginalTitle, x.OriginalName),
			Year: year(firstNonEmpty(x.ReleaseDate, x.FirstAirDate)), Poster: img("w185", x.PosterPath), Overview: x.Overview}
		if sr.OriginalTitle == sr.Title {
			sr.OriginalTitle = ""
		}
		out = append(out, sr)
	}
	return out, nil
}

func (t *TMDB) SearchMovie(title string, yr int) (int, error) { return t.search("movie", title, yr) }
func (t *TMDB) SearchTV(title string, yr int) (int, error)    { return t.search("tv", title, yr) }

type tmdbDetails struct {
	ID            int     `json:"id"`
	Title         string  `json:"title"`
	Name          string  `json:"name"`
	OriginalTitle string  `json:"original_title"`
	OriginalName  string  `json:"original_name"`
	Overview      string  `json:"overview"`
	ReleaseDate   string  `json:"release_date"`
	FirstAirDate  string  `json:"first_air_date"`
	Runtime       int     `json:"runtime"`
	PosterPath    string  `json:"poster_path"`
	BackdropPath  string  `json:"backdrop_path"`
	VoteAverage   float64 `json:"vote_average"`
	Genres        []struct {
		Name string `json:"name"`
	} `json:"genres"`
	Credits struct {
		Cast []struct {
			Name        string `json:"name"`
			Character   string `json:"character"`
			ProfilePath string `json:"profile_path"`
		} `json:"cast"`
		Crew []struct {
			Name string `json:"name"`
			Job  string `json:"job"`
		} `json:"crew"`
	} `json:"credits"`
}

func (d *tmdbDetails) cast(n int) []Person {
	var out []Person
	for i, c := range d.Credits.Cast {
		if i >= n {
			break
		}
		out = append(out, Person{Name: c.Name, Role: c.Character, Photo: img("w185", c.ProfilePath)})
	}
	return out
}

func (d *tmdbDetails) genres() []string {
	var g []string
	for _, x := range d.Genres {
		g = append(g, x.Name)
	}
	return g
}

// overview in the configured language, falling back to English when TMDB has no translation.
func (t *TMDB) details(kind string, id int) (*tmdbDetails, error) {
	var d tmdbDetails
	if err := t.get(fmt.Sprintf("/%s/%d", kind, id), url.Values{"append_to_response": {"credits"}}, "", &d); err != nil {
		return nil, err
	}
	if d.Overview == "" && !strings.HasPrefix(t.lang, "en") {
		var en tmdbDetails
		if t.get(fmt.Sprintf("/%s/%d", kind, id), nil, "en-US", &en) == nil {
			d.Overview = en.Overview
			if d.Title == "" {
				d.Title = en.Title
			}
			if d.Name == "" {
				d.Name = en.Name
			}
		}
	}
	return &d, nil
}

func (t *TMDB) Movie(id int) (*MovieMeta, error) {
	d, err := t.details("movie", id)
	if err != nil {
		return nil, err
	}
	m := &MovieMeta{ID: d.ID, Title: d.Title, OriginalTitle: d.OriginalTitle, Year: year(d.ReleaseDate),
		Overview: d.Overview, Genres: d.genres(), Poster: img("w342", d.PosterPath), Backdrop: img("w1280", d.BackdropPath),
		Rating: d.VoteAverage, Runtime: d.Runtime, Cast: d.cast(12), Fetched: time.Now().Unix()}
	if m.OriginalTitle == m.Title {
		m.OriginalTitle = ""
	}
	for _, c := range d.Credits.Crew {
		if c.Job == "Director" {
			m.Director = c.Name
			break
		}
	}
	return m, nil
}

func (t *TMDB) TV(id int) (*ShowMeta, error) {
	d, err := t.details("tv", id)
	if err != nil {
		return nil, err
	}
	sm := &ShowMeta{TMDBID: d.ID, Title: d.Name, OriginalTitle: d.OriginalName, Year: year(d.FirstAirDate),
		Overview: d.Overview, Genres: d.genres(), Poster: img("w342", d.PosterPath), Backdrop: img("w1280", d.BackdropPath),
		Rating: d.VoteAverage, Cast: d.cast(12), Fetched: time.Now().Unix()}
	if sm.OriginalTitle == sm.Title {
		sm.OriginalTitle = ""
	}
	return sm, nil
}

func (t *TMDB) Season(id, season int) (map[int]EpisodeMeta, error) {
	var r struct {
		Episodes []struct {
			EpisodeNumber int    `json:"episode_number"`
			Name          string `json:"name"`
			Overview      string `json:"overview"`
			StillPath     string `json:"still_path"`
			AirDate       string `json:"air_date"`
		} `json:"episodes"`
	}
	if err := t.get(fmt.Sprintf("/tv/%d/season/%d", id, season), nil, "", &r); err != nil {
		return nil, err
	}
	out := map[int]EpisodeMeta{}
	for _, e := range r.Episodes {
		out[e.EpisodeNumber] = EpisodeMeta{Title: e.Name, Overview: e.Overview, Still: img("w300", e.StillPath), Aired: e.AirDate}
	}
	return out, nil
}
