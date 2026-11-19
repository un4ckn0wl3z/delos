// File-name parsing for local folders (a port of the server's parse.go).

final _bracketRe = RegExp(r'\[[^\]]*\]|\{[^}]*\}');
final _sepRe = RegExp(r'[._]+');
final _spaceRe = RegExp(r'\s+');
final _yearRe = RegExp(r'\(?\b(19[2-9]\d|20[0-4]\d)\b\)?');
final _qualityRe = RegExp(
  r'\b(2160p|1080[pi]|720p|576p|480p|4k|uhd|bluray|blu-ray|bdrip|brrip|bdremux|remux|web-?dl|web-?rip|webrip|hdtv|hdrip|dvdrip|dvd|x264|x265|h ?264|h ?265|hevc|avc|xvid|aac\d?|ac3|eac3|ddp?\d?|dts(-hd)?|truehd|atmos|flac|10bit|8bit|hdr10?|dv|dolby|proper|repack|extended|unrated|remastered|imax|limited|internal|multi|dual|subbed|dubbed|mini ?hd)\b',
  caseSensitive: false,
);
final _episodeRes = [
  RegExp(r'^(.*?)[\s._\-\[(]*s(\d{1,2})[\s._-]*e(\d{1,3})', caseSensitive: false),
  RegExp(r'^(.*?)[\s._\-\[(]+(\d{1,2})x(\d{2,3})\b', caseSensitive: false),
  RegExp(r'^(.*?)[\s._\-]*season[\s._-]*(\d{1,2})[\s._-]*episode[\s._-]*(\d{1,3})', caseSensitive: false),
];
final _looseEpRe = RegExp(r'(?:^|[\s._\-\[(])(?:e|ep|episode)[\s._-]*(\d{1,3})\b', caseSensitive: false);
final _seasonDir = RegExp(r'^(?:season|series|s)[\s._-]*(\d{1,2})$', caseSensitive: false);
final _leadNum = RegExp(r'^(\d{1,3})\b');

String _stripExt(String name) {
  final i = name.lastIndexOf('.');
  return i > 0 ? name.substring(0, i) : name;
}

/// "[Group] Some.Movie_Name (2006) [1080p].mkv" → "Some Movie Name (2006)"
String cleanName(String name) {
  var n = _stripExt(name);
  n = n.replaceAll(_bracketRe, ' ').replaceAll(_sepRe, ' ');
  return n.replaceAll(_spaceRe, ' ').trim();
}

String _trimTitle(String s) {
  s = s.trim();
  const junk = ' -–(:,';
  var a = 0, b = s.length;
  while (a < b && junk.contains(s[a])) {
    a++;
  }
  while (b > a && junk.contains(s[b - 1])) {
    b--;
  }
  return s.substring(a, b).replaceAll(_spaceRe, ' ').trim();
}

String _cutQuality(String s) {
  final m = _qualityRe.firstMatch(s);
  if (m != null && m.start > 0) s = s.substring(0, m.start);
  return _trimTitle(s);
}

class MovieName {
  const MovieName(this.title, this.year);
  final String title;
  final int year;
}

/// Title + year from a file name, falling back to the parent folder's name.
MovieName parseMovie(String file, [String parent = '']) {
  for (final cand in [file, parent]) {
    if (cand.isEmpty || cand == '.') continue;
    final n = cand == parent && cand != file ? cleanName('$cand.x') : cleanName(cand);
    final years = _yearRe.allMatches(n).toList();
    for (var i = years.length - 1; i >= 0; i--) {
      final t = _cutQuality(n.substring(0, years[i].start));
      if (t.isNotEmpty) return MovieName(t, int.parse(years[i].group(1)!));
    }
    final t = _cutQuality(n);
    if (t.isNotEmpty && cand == file) {
      if (parent.isNotEmpty) {
        final p = parseMovie('', parent);
        if (p.year > 0) return p;
      }
      return MovieName(t, 0);
    }
  }
  return MovieName(_trimTitle(cleanName(file)), 0);
}

class EpisodeName {
  EpisodeName(this.show, this.year, this.season, this.episode);
  String show;
  int year, season, episode;
}

/// "Show.S01E02", "Show 1x02", "Show/Season 1/02 - Title"… [dirs]: folders between
/// the library root and the file, outermost first.
EpisodeName? parseEpisode(String file, List<String> dirs) {
  final n = cleanName(file);
  final ei = EpisodeName('', 0, 0, 0);
  var found = false;
  for (final re in _episodeRes) {
    final m = re.firstMatch(n);
    if (m != null) {
      ei.show = _cutQuality(m.group(1)!);
      ei.season = int.parse(m.group(2)!);
      ei.episode = int.parse(m.group(3)!);
      found = true;
      break;
    }
  }
  var dirSeason = 0;
  var showDir = '';
  for (var i = dirs.length - 1; i >= 0; i--) {
    final d = cleanName('${dirs[i]}.x');
    final m = _seasonDir.firstMatch(d);
    if (m != null) {
      if (dirSeason == 0) dirSeason = int.parse(m.group(1)!);
      continue;
    }
    if (showDir.isEmpty) showDir = d;
  }
  if (!found) {
    final m = _looseEpRe.firstMatch(n);
    if (m != null) {
      ei.episode = int.parse(m.group(1)!);
      ei.season = dirSeason == 0 ? 1 : dirSeason;
      found = true;
    } else if (dirSeason > 0) {
      final m2 = _leadNum.firstMatch(n);
      if (m2 != null) {
        ei.episode = int.parse(m2.group(1)!);
        ei.season = dirSeason;
        found = true;
      }
    }
  }
  if (!found) return null;
  if (ei.show.isEmpty) ei.show = _cutQuality(showDir);
  if (ei.show.isEmpty) return null;
  final y = _yearRe.firstMatch(ei.show);
  if (y != null && y.start > 0) {
    ei.year = int.parse(y.group(1)!);
    ei.show = _trimTitle(ei.show.substring(0, y.start));
  }
  return ei;
}

String showKey(String title, int year) {
  var k = title.trim().replaceAll(_spaceRe, ' ').toLowerCase();
  if (year > 0) k += ' ($year)';
  return k;
}

const videoExts = {'.mkv', '.mp4', '.m4v', '.avi', '.webm', '.mov', '.ts', '.m2ts', '.wmv', '.mpg', '.mpeg', '.flv'};

bool isVideoFile(String path) {
  final i = path.lastIndexOf('.');
  return i >= 0 && videoExts.contains(path.substring(i).toLowerCase());
}
