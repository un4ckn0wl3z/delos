package main

import (
	"strings"
	"testing"
)

func TestParseMovie(t *testing.T) {
	cases := []struct {
		file, parent, title string
		year                int
	}{
		{"[Mini HD] Children.of.Men.2006.BluRay.1080p.AC3.5.1.x265.mkv", "[Mini HD] Children of Men (2006) พลิกวิกฤต", "Children of Men", 2006},
		{"Blade.Runner.2049.2017.2160p.UHD.BluRay.x265.mkv", "", "Blade Runner 2049", 2017},
		{"2001.A.Space.Odyssey.1968.1080p.mkv", "", "2001 A Space Odyssey", 1968},
		{"The Matrix (1999).mkv", "", "The Matrix", 1999},
		{"movie.mkv", "Inception (2010)", "Inception", 2010},
		{"Parasite.1080p.WEB-DL.mkv", "", "Parasite", 0},
		{"1917.2019.1080p.mkv", "", "1917", 2019},
	}
	for _, c := range cases {
		title, year := parseMovie(c.file, c.parent)
		if title != c.title || year != c.year {
			t.Errorf("parseMovie(%q,%q) = %q,%d want %q,%d", c.file, c.parent, title, year, c.title, c.year)
		}
	}
}

func TestParseEpisode(t *testing.T) {
	cases := []struct {
		file string
		dirs []string
		show string
		year int
		s, e int
		ok   bool
	}{
		{"Breaking.Bad.S01E02.720p.mkv", nil, "Breaking Bad", 0, 1, 2, true},
		{"The.Office.US.s03e10.mkv", []string{"The Office"}, "The Office US", 0, 3, 10, true},
		{"Dark (2017) - 2x05 - Lost.mkv", nil, "Dark", 2017, 2, 5, true},
		{"01 - Pilot.mkv", []string{"Fargo", "Season 1"}, "Fargo", 0, 1, 1, true},
		{"[SubsPlease] Frieren - E07 (1080p).mkv", []string{"Frieren", "Season 1"}, "Frieren", 0, 1, 7, true},
		{"S02E03.mkv", []string{"Severance (2022)", "S02"}, "Severance", 2022, 2, 3, true},
		{"random.mkv", []string{"Stuff"}, "", 0, 0, 0, false},
	}
	for _, c := range cases {
		ei, ok := parseEpisode(c.file, c.dirs)
		if ok != c.ok || (ok && (ei.Show != c.show || ei.Year != c.year || ei.Season != c.s || ei.Episode != c.e)) {
			t.Errorf("parseEpisode(%q,%v) = %+v,%v want %q %d S%dE%d %v", c.file, c.dirs, ei, ok, c.show, c.year, c.s, c.e, c.ok)
		}
	}
}

func TestParseArtistTitle(t *testing.T) {
	a, ti, tr := parseArtistTitle("03 - Daft Punk - One More Time.mp3")
	if a != "Daft Punk" || ti != "One More Time" || tr != 3 {
		t.Errorf("got %q %q %d", a, ti, tr)
	}
}

func TestTitleVariants(t *testing.T) {
	cases := map[string][]string{
		"Now You See Me 3 Now You Don't": {"Now You See Me 3 Now You Don't", "Now You See Me Now You Don't"},
		"Inception":                      {"Inception"},
		"Star Wars - A New Hope":         {"Star Wars - A New Hope", "Star Wars"},
		"2012":                           {"2012"},
	}
	for in, want := range cases {
		got := titleVariants(in)
		if strings.Join(got, "|") != strings.Join(want, "|") {
			t.Errorf("titleVariants(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestExcludedDir(t *testing.T) {
	l := Library{Exclude: cleanExclude([]string{" Sample ", "Extras/Featurettes/", "behind*", "../etc", "a/[b"})}
	if strings.Join(l.Exclude, "|") != "Sample|Extras/Featurettes|behind*" {
		t.Fatalf("cleanExclude = %q", l.Exclude)
	}
	cases := map[string]bool{
		"":                         false,
		"Movies":                   false,
		"Movies/sample":            true,
		"Movies/Foo (2020)/Sample": true,
		"Extras":                   false,
		"Extras/Featurettes":       true,
		"Extras/Featurettes/Deep":  true,
		"Other/Extras/Featurettes": false,
		"Show/Behind the Scenes":   true,
		"Show/Season 1":            false,
	}
	for rel, want := range cases {
		if got := l.ExcludedDir(rel); got != want {
			t.Errorf("ExcludedDir(%q) = %v, want %v", rel, got, want)
		}
	}
}
