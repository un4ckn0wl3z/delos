package main

import (
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

var (
	bracketRe  = regexp.MustCompile(`\[[^\]]*\]|\{[^}]*\}`)
	sepRe      = regexp.MustCompile(`[._]+`)
	spaceRe    = regexp.MustCompile(`\s+`)
	yearRe     = regexp.MustCompile(`\(?\b(19[2-9]\d|20[0-4]\d)\b\)?`)
	qualityRe  = regexp.MustCompile(`(?i)\b(2160p|1080[pi]|720p|576p|480p|4k|uhd|bluray|blu-ray|bdrip|brrip|bdremux|remux|web-?dl|web-?rip|webrip|hdtv|hdrip|dvdrip|dvd|x264|x265|h ?264|h ?265|hevc|avc|xvid|aac\d?|ac3|eac3|ddp?\d?|dts(-hd)?|truehd|atmos|flac|10bit|8bit|hdr10?|dv|dolby|proper|repack|extended|unrated|remastered|imax|limited|internal|multi|dual|subbed|dubbed|mini ?hd)\b`)
	episodeRes = []*regexp.Regexp{
		regexp.MustCompile(`(?i)^(.*?)[\s._\-\[(]*s(\d{1,2})[\s._-]*e(\d{1,3})`),
		regexp.MustCompile(`(?i)^(.*?)[\s._\-\[(]+(\d{1,2})x(\d{2,3})\b`),
		regexp.MustCompile(`(?i)^(.*?)[\s._\-]*season[\s._-]*(\d{1,2})[\s._-]*episode[\s._-]*(\d{1,3})`),
	}
	looseEpRe = regexp.MustCompile(`(?i)(?:^|[\s._\-\[(])(?:e|ep|episode)[\s._-]*(\d{1,3})\b`)
	seasonDir = regexp.MustCompile(`(?i)^(?:season|series|s)[\s._-]*(\d{1,2})$`)
)

// cleanName turns "[Group] Some.Movie_Name (2006) [1080p].mkv" into "Some Movie Name (2006)".
func cleanName(name string) string {
	name = strings.TrimSuffix(name, filepath.Ext(name))
	name = bracketRe.ReplaceAllString(name, " ")
	name = sepRe.ReplaceAllString(name, " ")
	return strings.TrimSpace(spaceRe.ReplaceAllString(name, " "))
}

func trimTitle(s string) string {
	s = strings.TrimSpace(s)
	s = strings.Trim(s, " -–(:,")
	return strings.TrimSpace(spaceRe.ReplaceAllString(s, " "))
}

// cutQuality drops everything from the first release/quality tag on.
func cutQuality(s string) string {
	if loc := qualityRe.FindStringIndex(s); loc != nil && loc[0] > 0 {
		s = s[:loc[0]]
	}
	return trimTitle(s)
}

// parseMovie extracts a title and year from a file name, falling back to the folder name.
func parseMovie(file, parent string) (string, int) {
	for _, cand := range []string{file, parent} {
		if cand == "" || cand == "." {
			continue
		}
		n := cleanName(cand)
		if cand == parent {
			n = cleanName(cand + ".x") // folder names have no extension
		}
		// the last year that has some title before it ("2001 A Space Odyssey 1968" → 1968)
		locs := yearRe.FindAllStringSubmatchIndex(n, -1)
		for i := len(locs) - 1; i >= 0; i-- {
			if t := cutQuality(n[:locs[i][0]]); t != "" {
				y, _ := strconv.Atoi(n[locs[i][2]:locs[i][3]])
				return t, y
			}
		}
		if t := cutQuality(n); t != "" && cand == file {
			// no year in the file name: prefer a folder that has one
			if pt, py := parseMovie("", parent); py > 0 && parent != "" {
				return pt, py
			}
			return t, 0
		}
	}
	return trimTitle(cleanName(file)), 0
}

type episodeInfo struct {
	Show    string
	Year    int
	Season  int
	Episode int
}

// parseEpisode understands "Show.S01E02", "Show 1x02", "Show/Season 1/02 - Title" and similar.
// dirs are the folders between the library root and the file, outermost first.
func parseEpisode(file string, dirs []string) (episodeInfo, bool) {
	n := cleanName(file)
	var ei episodeInfo
	found := false
	for _, re := range episodeRes {
		if m := re.FindStringSubmatch(n); m != nil {
			ei.Show = cutQuality(m[1])
			ei.Season, _ = strconv.Atoi(m[2])
			ei.Episode, _ = strconv.Atoi(m[3])
			found = true
			break
		}
	}
	// season from a "Season 2" folder
	dirSeason, showDir := 0, ""
	for i := len(dirs) - 1; i >= 0; i-- {
		d := cleanName(dirs[i] + ".x")
		if m := seasonDir.FindStringSubmatch(d); m != nil {
			if dirSeason == 0 {
				dirSeason, _ = strconv.Atoi(m[1])
			}
			continue
		}
		if showDir == "" {
			showDir = d
		}
	}
	if !found {
		if m := looseEpRe.FindStringSubmatch(n); m != nil {
			ei.Episode, _ = strconv.Atoi(m[1])
			ei.Season = dirSeason
			if ei.Season == 0 {
				ei.Season = 1
			}
			found = true
		} else if dirSeason > 0 {
			// "01 - Pilot.mkv" inside "Season 1"
			if m := regexp.MustCompile(`^(\d{1,3})\b`).FindStringSubmatch(n); m != nil {
				ei.Episode, _ = strconv.Atoi(m[1])
				ei.Season = dirSeason
				found = true
			}
		}
	}
	if !found {
		return ei, false
	}
	if ei.Show == "" {
		ei.Show = cutQuality(showDir)
	}
	if ei.Show == "" {
		return ei, false
	}
	// "Show (2019)" or "Show 2019"
	if m := yearRe.FindStringSubmatchIndex(ei.Show); m != nil && m[0] > 0 {
		ei.Year, _ = strconv.Atoi(ei.Show[m[2]:m[3]])
		ei.Show = trimTitle(ei.Show[:m[0]])
	}
	return ei, true
}

func showKey(title string, year int) string {
	k := strings.ToLower(spaceRe.ReplaceAllString(strings.TrimSpace(title), " "))
	if year > 0 {
		k += " (" + strconv.Itoa(year) + ")"
	}
	return k
}

// parseArtistTitle splits "Artist - Title" / "01 - Artist - Title" / "01. Title".
func parseArtistTitle(file string) (artist, title string, track int) {
	n := strings.TrimSpace(strings.TrimSuffix(file, filepath.Ext(file)))
	if m := regexp.MustCompile(`^(\d{1,3})[\s.\-_]+(.*)$`).FindStringSubmatch(n); m != nil {
		track, _ = strconv.Atoi(m[1])
		n = m[2]
	}
	if a, t, ok := strings.Cut(n, " - "); ok {
		return strings.TrimSpace(a), strings.TrimSpace(t), track
	}
	return "", n, track
}
