package main

import (
	"os"
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

func TestCleanSubdir(t *testing.T) {
	for in, want := range map[string]string{"../../etc": "etc", " Movies/New/ ": "Movies/New", "a/../b": "b", "": "", `x\y`: "x/y"} {
		if got := cleanSubdir(in); got != want && !(in == `x\y` && got == `x\y`) {
			t.Errorf("cleanSubdir(%q) = %q, want %q", in, got, want)
		}
	}
	if sanitizeFileName("../.hidden/evil:name?.mkv") != "_.hidden_evil_name_.mkv" {
		t.Errorf("sanitizeFileName = %q", sanitizeFileName("../.hidden/evil:name?.mkv"))
	}
}

func TestTorrentIdentity(t *testing.T) {
	data, err := os.ReadFile("/home/claude/rtt/test.torrent")
	if err != nil {
		t.Skip("no test torrent")
	}
	h, n, err := torrentInfo(data)
	if err != nil || h != "D350D1DBFD81EADD82E3DED2CEB76783DBCF1510" || n != "Test Movie (2024).mkv" {
		t.Fatalf("torrentInfo = %q %q %v", h, n, err)
	}
	// same hash as base32
	b32 := "2NINDW75QHVN3AXD33JM5N3HQPN46FIQ"
	if h2, _ := magnetInfo("magnet:?xt=urn:btih:" + b32 + "&dn=x"); h2 != h {
		t.Errorf("magnet base32 = %q", h2)
	}
	if h3, dn := magnetInfo("magnet:?xt=urn:btih:d350d1dbfd81eadd82e3ded2ceb76783dbcf1510&dn=Some+Movie"); h3 != h || dn != "Some Movie" {
		t.Errorf("magnet hex = %q %q", h3, dn)
	}
	if _, _, err := torrentInfo([]byte("not a torrent")); err == nil {
		t.Error("garbage accepted")
	}
}

func TestMultiEpisode(t *testing.T) {
	cases := []struct {
		name           string
		season, ep, e2 int
		strong         bool
	}{
		{"The.Remarried.Empress.S01E07-S01E08.1080p.DSNP.WEB-DL.DDP5.1.H.265-THEREINFORCE.mkv", 1, 7, 8, true},
		{"Show.S02E03E04.720p.mkv", 2, 3, 4, true},
		{"Show S01E05-E06 1080p.mkv", 1, 5, 6, true},
		{"Show.S01E09.1080p.x265.mkv", 1, 9, 0, true},
		{"Show.S01E09.E10bit.mkv", 1, 9, 0, true},
		{"Show 1x02.mkv", 1, 2, 0, true},
	}
	for _, c := range cases {
		ei, ok := parseEpisode(c.name, nil)
		if !ok || ei.Season != c.season || ei.Episode != c.ep || ei.EpisodeEnd != c.e2 || ei.Strong != c.strong {
			t.Errorf("%s → %+v ok=%v", c.name, ei, ok)
		}
	}
	if ei, _ := parseEpisode("The.Remarried.Empress.S01E07-S01E08.1080p.mkv", nil); ei.Show != "The Remarried Empress" {
		t.Errorf("show = %q", ei.Show)
	}
}
