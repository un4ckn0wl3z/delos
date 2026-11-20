/// Which series a download (or file) name belongs to:
/// "Show.Name.S01E07-S01E08.1080p…", "Show Name Season 2", "Show.Name.2x05".
class SeriesName {
  const SeriesName(this.key, this.title);
  final String key, title;
}

final _seriesRe = RegExp(r'^(.+?)[\s._\-\[(]+(?:S\d{1,2}(?:[\s._-]?E\d{1,3})?|Season[\s._-]?\d{1,2}|\d{1,2}x\d{2,3})(?![\p{L}\p{N}])',
    caseSensitive: false, unicode: true);
final _yearTail = RegExp(r'\s*[\[(]?(19|20)\d{2}[\])]?\s*$');
final _notWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

SeriesName? seriesOf(String name) {
  final m = _seriesRe.firstMatch(name);
  if (m == null) return null;
  final title = m.group(1)!.replaceAll(RegExp(r'[._]+'), ' ').replaceAll(_yearTail, '').replaceAll(RegExp(r'[\s-]+$'), '').trim();
  final key = title.toLowerCase().replaceAll(_notWord, ' ').trim();
  return key.isEmpty ? null : SeriesName(key, title);
}

/// Splits [list] into single entries and groups of 2+ of the same series, in list order
/// (a group sits where its first member was). Group members are sorted by name (S01E01 first).
List<({String? key, String title, List<T> members})> groupBySeries<T>(List<T> list, String Function(T) nameOf) {
  final byKey = <String, List<T>>{};
  final titles = <String, String>{};
  for (final x in list) {
    final s = seriesOf(nameOf(x));
    if (s == null) continue;
    byKey.putIfAbsent(s.key, () => []).add(x);
    titles.putIfAbsent(s.key, () => s.title);
  }
  final out = <({String? key, String title, List<T> members})>[];
  final seen = <String>{};
  for (final x in list) {
    final s = seriesOf(nameOf(x));
    final g = s == null ? null : byKey[s.key];
    if (g == null || g.length < 2) {
      out.add((key: null, title: nameOf(x), members: [x]));
    } else if (seen.add(s!.key)) {
      g.sort((a, b) => _natural(nameOf(a), nameOf(b)));
      out.add((key: s.key, title: titles[s.key]!, members: g));
    }
  }
  return out;
}

int _natural(String a, String b) {
  final re = RegExp(r'\d+|\D+');
  final x = re.allMatches(a.toLowerCase()).map((m) => m[0]!).toList(), y = re.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < x.length && i < y.length; i++) {
    final nx = int.tryParse(x[i]), ny = int.tryParse(y[i]);
    final c = nx != null && ny != null ? nx.compareTo(ny) : x[i].compareTo(y[i]);
    if (c != 0) return c;
  }
  return x.length.compareTo(y.length);
}
