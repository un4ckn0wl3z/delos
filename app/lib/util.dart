import 'models.dart';

String fmtTime(double secs) {
  if (secs.isNaN || secs < 0) secs = 0;
  final t = secs.floor();
  final h = t ~/ 3600, m = (t % 3600) ~/ 60, s = t % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

String fmtSize(int b) {
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i >= 3 ? 2 : 0)} ${u[i]}';
}

/// Index of [lang] in the comma-separated preference list, or -1.
int langRank(String lang, String prefs) {
  lang = lang.toLowerCase();
  if (lang.isEmpty) return -1;
  final list = prefs.toLowerCase().split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  for (var i = 0; i < list.length; i++) {
    if (lang.startsWith(list[i]) || list[i].startsWith(lang)) return i;
  }
  return -1;
}

/// Same rules as the userscript: saved choice → preferred language → default flag.
({int audio, int? sub}) pickTracks(ProbeInfo info, Map<String, dynamic> saved, String audioLang, String subLang) {
  var audio = 0;
  final sa = saved['audio'];
  if (sa is num && sa >= 0 && sa < info.audio.length) {
    audio = sa.toInt();
  } else if (info.audio.isNotEmpty) {
    final ranked = [
      for (final a in info.audio)
        if (langRank(a.language, audioLang) >= 0) a
    ]..sort((x, y) => langRank(x.language, audioLang).compareTo(langRank(y.language, audioLang)));
    if (ranked.isNotEmpty) {
      audio = ranked.first.index;
    } else {
      final d = info.audio.indexWhere((a) => a.isDefault);
      audio = d >= 0 ? d : 0;
    }
  }

  int? sub;
  final ss = saved['sub'];
  if (ss is num) {
    sub = ss >= 0 && ss < info.subs.length ? ss.toInt() : null;
  } else if (info.subs.isNotEmpty) {
    final ranked = [
      for (final s in info.subs)
        if (langRank(s.language, subLang) >= 0) s
    ]..sort((x, y) {
        final r = langRank(x.language, subLang).compareTo(langRank(y.language, subLang));
        if (r != 0) return r;
        if (x.text != y.text) return x.text ? -1 : 1; // prefer text subs
        if (x.forced != y.forced) return x.forced ? 1 : -1; // prefer full subs
        return 0;
      });
    if (ranked.isNotEmpty) sub = ranked.first.index;
  }
  return (audio: audio, sub: sub);
}
