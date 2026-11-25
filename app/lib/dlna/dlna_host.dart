import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../api.dart';
import '../library.dart';
import '../offline/store.dart';
import '../settings.dart';
import 'dlna_server.dart';

/// Runs the DLNA server on this PC (Windows): the files saved for offline use, and optionally the
/// server's libraries passed through this PC ("Online"). Audio a TV can't play (DTS, TrueHD) is
/// converted to AC3 on the fly — here with ffmpeg, or on the server for online files.
class DlnaHost extends ChangeNotifier {
  DlnaHost._();
  static final instance = DlnaHost._();

  static bool get supported => !kIsWeb && Platform.isWindows;

  Settings? _settings;
  Settings? get settings => _settings;
  DlnaServer? server;
  String? error;
  bool busy = false;
  Timer? _tick, _onlineTimer;

  bool get running => server?.running ?? false;

  String get defaultName {
    var h = '';
    try {
      h = Platform.localHostname;
    } catch (_) {}
    return h.isEmpty ? 'Delos' : 'Delos ($h)';
  }

  String get name {
    final n = _settings?.dlnaName ?? '';
    return n.isEmpty ? defaultName : n;
  }

  /// Called once at app start.
  Future<void> init(Settings s) async {
    _settings = s;
    if (!supported) return;
    await _loadProbes();
    await ffmpegFind();
    if (s.dlnaOn) await start();
  }

  // ------------------------------------------------------------------ ffmpeg

  String? ffmpegPath, ffprobePath;
  double? ffmpegProgress; // 0..1 while downloading
  String? ffmpegError;
  static const ffmpegUrl = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip';

  Future<Directory> _dir(String sub) async {
    final d = Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}$sub');
    await d.create(recursive: true);
    return d;
  }

  /// ffmpeg downloaded by the app, or one already on PATH.
  Future<void> ffmpegFind() async {
    try {
      final d = await _dir('ffmpeg');
      final f = File('${d.path}\\ffmpeg.exe'), p = File('${d.path}\\ffprobe.exe');
      if (f.existsSync() && p.existsSync()) {
        ffmpegPath = f.path;
        ffprobePath = p.path;
        return;
      }
      final w = await Process.run('where', ['ffmpeg'], runInShell: true);
      final first = '${w.stdout}'.split(RegExp(r'[\r\n]+')).firstWhere((l) => l.trim().isNotEmpty, orElse: () => '').trim();
      if (w.exitCode == 0 && first.isNotEmpty) {
        final probe = first.replaceAll(RegExp(r'ffmpeg(\.exe)?$', caseSensitive: false), 'ffprobe.exe');
        if (File(probe).existsSync()) {
          ffmpegPath = first;
          ffprobePath = probe;
        }
      }
    } catch (_) {}
  }

  /// Downloads ffmpeg (≈ 150 MB zip, keeps ffmpeg.exe + ffprobe.exe ≈ 250 MB).
  Future<void> ffmpegDownload() async {
    if (ffmpegProgress != null) return;
    ffmpegProgress = 0;
    ffmpegError = null;
    notifyListeners();
    final d = await _dir('ffmpeg');
    final tmp = Directory('${d.path}\\tmp');
    final zip = File('${d.path}\\ffmpeg.zip');
    final client = HttpClient();
    try {
      final rs = await (await client.getUrl(Uri.parse(ffmpegUrl))).close();
      if (rs.statusCode != 200) throw 'download failed (HTTP ${rs.statusCode})';
      final total = rs.contentLength;
      var got = 0;
      final sink = zip.openWrite();
      var last = DateTime.now();
      await for (final chunk in rs) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0 && DateTime.now().difference(last).inMilliseconds > 300) {
          ffmpegProgress = got / total;
          last = DateTime.now();
          notifyListeners();
        }
      }
      await sink.close();
      ffmpegProgress = 1;
      notifyListeners();
      if (tmp.existsSync()) await tmp.delete(recursive: true);
      await tmp.create();
      // Windows' own tar (bsdtar) unpacks zip files
      final x = await Process.run('${Platform.environment['SystemRoot'] ?? 'C:\\Windows'}\\System32\\tar.exe', ['-xf', zip.path, '-C', tmp.path]);
      if (x.exitCode != 0) throw 'unzip failed: ${x.stderr}';
      File? find(String n) {
        for (final e in tmp.listSync(recursive: true)) {
          if (e is File && e.path.toLowerCase().endsWith('\\$n')) return e;
        }
        return null;
      }

      final f = find('ffmpeg.exe'), p = find('ffprobe.exe');
      if (f == null || p == null) throw 'ffmpeg.exe not found in the download';
      await f.copy('${d.path}\\ffmpeg.exe');
      await p.copy('${d.path}\\ffprobe.exe');
      ffmpegPath = '${d.path}\\ffmpeg.exe';
      ffprobePath = '${d.path}\\ffprobe.exe';
      server?.touch();
      _probeAll();
    } catch (e) {
      ffmpegError = '$e';
    } finally {
      client.close(force: true);
      try {
        if (zip.existsSync()) await zip.delete();
        if (tmp.existsSync()) await tmp.delete(recursive: true);
      } catch (_) {}
      ffmpegProgress = null;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------ audio check

  /// key → {sig, codec, ch, idx}: the audio track a TV would play, per file (cached on disk).
  final _probes = <String, Map<String, dynamic>>{};
  File? _probeFile;
  bool _probing = false;

  Future<void> _loadProbes() async {
    try {
      _probeFile = File('${(await _dir('dlna')).path}${Platform.pathSeparator}audio.json');
      if (_probeFile!.existsSync()) {
        final j = jsonDecode(await _probeFile!.readAsString()) as Map;
        j.forEach((k, v) => _probes['$k'] = Map<String, dynamic>.from(v as Map));
      }
    } catch (_) {}
  }

  Timer? _saveTimer;
  void _saveProbes() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () {
      try {
        _probeFile?.writeAsStringSync(jsonEncode(_probes));
      } catch (_) {}
    });
  }

  static Map<String, dynamic> _pick(List<Map> streams) {
    if (streams.isEmpty) return {'codec': '', 'ch': 0, 'idx': 0};
    var i = streams.indexWhere((s) => s['default'] == true);
    if (i < 0) i = 0;
    return {'codec': '${streams[i]['codec'] ?? ''}'.toLowerCase(), 'ch': streams[i]['channels'] ?? 2, 'idx': i};
  }

  Future<Map<String, dynamic>?> _probeLocal(String file) async {
    final p = ffprobePath;
    if (p == null) return null;
    final r = await Process.run(p, ['-v', 'error', '-select_streams', 'a', '-show_entries', 'stream=codec_name,channels:stream_disposition=default', '-of', 'json', file]);
    if (r.exitCode != 0) return null;
    final st = ((jsonDecode('${r.stdout}') as Map)['streams'] as List? ?? const [])
        .map((s) => {'codec': (s as Map)['codec_name'], 'channels': s['channels'], 'default': (s['disposition'] as Map?)?['default'] == 1})
        .toList();
    return _pick(st);
  }

  Future<Map<String, dynamic>?> _probeServer(String path) async {
    final api = _api;
    if (api == null) return null;
    final info = await api.probe(path);
    return _pick([for (final a in info.audio) {'codec': a.codec, 'channels': a.channels, 'default': a.isDefault}]);
  }

  /// Checks the audio of files not checked yet, two at a time, in the background.
  Future<void> _probeAll() async {
    if (_probing || !running) return;
    _probing = true;
    var changed = false;
    try {
      final todo = <(String, String, bool)>[]; // key, sig, online
      for (final it in items) {
        if (it.kind == 'music') continue;
        final sig = '${it.size}';
        if (_probes['l:${it.id}']?['sig'] != sig) todo.add(('l:${it.id}', it.file, false));
      }
      for (final it in _online) {
        if (it.$2.kind == 'music') continue;
        if (_probes['s:${it.$2.path}']?['sig'] != '${it.$2.size}') todo.add(('s:${it.$2.path}', it.$2.path, true));
      }
      for (var i = 0; i < todo.length && running; i += 2) {
        await Future.wait([
          for (final t in todo.skip(i).take(2))
            () async {
              try {
                final r = t.$3 ? await _probeServer(t.$2) : await _probeLocal(t.$2);
                if (r == null) return;
                final size = t.$3 ? _online.firstWhere((o) => o.$2.path == t.$2).$2.size : (items.firstWhere((x) => x.file == t.$2).size);
                _probes[t.$1] = {...r, 'sig': '$size'};
                changed = true;
              } catch (_) {}
            }(),
        ]);
        if (changed && i % 20 == 0) {
          server?.touch();
          _saveProbes();
        }
      }
    } finally {
      _probing = false;
      if (changed) {
        server?.touch();
        _saveProbes();
        notifyListeners();
      }
    }
  }

  /// The audio needs converting for the TV (and conversion is on).
  bool _bad(Map<String, dynamic>? p) {
    final s = _settings;
    if (s == null || !s.dlnaFixAudio || p == null) return false;
    final c = '${p['codec']}';
    return s.dlnaBadAudio.any((b) => c == b || (b == 'truehd' && c == 'mlp') || (b == 'dts' && c == 'dca'));
  }

  /// Files that would be converted now (for the settings page).
  int get convertCount {
    var n = 0;
    for (final it in items) {
      if (it.kind != 'music' && _bad(_probes['l:${it.id}'])) n++;
    }
    if (_settings?.dlnaOnline ?? false) {
      for (final o in _online) {
        if (o.$2.kind != 'music' && _bad(_probes['s:${o.$2.path}'])) n++;
      }
    }
    return n;
  }

  // ------------------------------------------------------------------ online (passthrough)

  Api? _api;
  final _online = <(LibraryInfo, _OnlineItem)>[];
  String? onlineError;
  DateTime? onlineAt;
  int get onlineCount => _online.length;

  Future<void> refreshOnline() async {
    final s = _settings;
    if (s == null || !s.dlnaOnline || !s.loggedIn) {
      _online.clear();
      server?.touch();
      notifyListeners();
      return;
    }
    _api ??= Api(s);
    final repo = LibraryRepo(_api!);
    final out = <(LibraryInfo, _OnlineItem)>[];
    try {
      for (final l in await repo.libraries(force: true)) {
        final d = await repo.lib(l, force: true);
        for (final it in d.items) {
          final kind = l.type == 'music'
              ? 'music'
              : it.episode > 0 && it.show.isNotEmpty
                  ? 'episode'
                  : l.type == 'videos'
                      ? 'video'
                      : 'movie';
          final m = d.movies[it.movieId];
          final sh = d.shows[it.show];
          var poster = kind == 'music' ? (it.cover.isEmpty ? '' : _api!.coverUrl(it.cover)) : (kind == 'episode' ? sh?.poster : m?.poster) ?? '';
          if (poster.isNotEmpty && !poster.startsWith('http')) poster = '';
          out.add((
            l,
            _OnlineItem(
              path: it.path,
              kind: kind,
              title: kind == 'movie' ? (m?.title.isNotEmpty == true ? m!.title : (it.title.isNotEmpty ? it.title : it.name)) : (it.title.isNotEmpty ? it.title : it.name),
              year: m?.year ?? it.year,
              show: sh?.title.isNotEmpty == true ? sh!.title : it.show,
              season: it.season,
              episode: it.episode,
              episodeTitle: it.episodeTitle,
              artist: it.albumArtist,
              album: it.album,
              track: it.track,
              duration: it.duration,
              size: it.size,
              poster: poster,
              overview: m?.overview ?? '',
              genres: m?.genres ?? const [],
              added: it.added,
            )
          ));
        }
      }
      _online
        ..clear()
        ..addAll(out);
      onlineError = null;
      onlineAt = DateTime.now();
    } catch (e) {
      onlineError = '$e';
    }
    server?.touch();
    notifyListeners();
    _probeAll();
  }

  // ------------------------------------------------------------------ entries

  List<OfflineItem> get items {
    final out = <OfflineItem>[];
    try {
      for (final it in OfflineStore.instance.items.values) {
        if (it.ready || (!it.isServer && it.file.isNotEmpty)) out.add(it);
      }
    } catch (_) {}
    return out;
  }

  List<DlnaEntry> _entries() {
    final s = _settings;
    final out = <DlnaEntry>[];
    for (final it in items) {
      final p = _probes['l:${it.id}'];
      final conv = it.kind != 'music' && _bad(p);
      out.add(DlnaEntry(
        key: it.id,
        file: it.file,
        kind: it.kind,
        title: it.title.isNotEmpty ? it.title : it.name,
        poster: it.poster,
        show: it.show,
        season: it.season,
        episode: it.episode,
        episodeTitle: it.episodeTitle,
        artist: it.artist,
        album: it.album,
        track: it.track,
        year: it.year,
        duration: it.duration,
        size: it.size,
        genres: it.genres,
        overview: it.overview,
        added: it.added,
        convert: conv,
        audioIndex: (p?['idx'] as num?)?.toInt() ?? 0,
        audioChannels: (p?['ch'] as num?)?.toInt() ?? 2,
      ));
    }
    final api = _api;
    if (s != null && s.dlnaOnline && api != null) {
      final auth = api.authHeaders;
      final atServer = s.dlnaConvertAt == 'server';
      for (final (l, o) in _online) {
        final p = _probes['s:${o.path}'];
        final conv = o.kind != 'music' && _bad(p);
        final idx = (p?['idx'] as num?)?.toInt() ?? 0;
        out.add(DlnaEntry(
          key: 's:${o.path}',
          file: '',
          url: api.rawUrl(o.path),
          section: l.name,
          kind: o.kind,
          title: o.title,
          poster: o.poster,
          show: o.show,
          season: o.season,
          episode: o.episode,
          episodeTitle: o.episodeTitle,
          artist: o.artist,
          album: o.album,
          track: o.track,
          year: o.year,
          duration: o.duration,
          size: o.size,
          genres: o.genres,
          overview: o.overview,
          added: o.added,
          headers: o.poster.contains('/api/') ? auth : const {},
          convert: conv,
          audioIndex: idx,
          audioChannels: (p?['ch'] as num?)?.toInt() ?? 2,
          serverConvert: conv && atServer ? (start) => api.tvStreamUrl(o.path, audio: idx, start: start) : null,
        ));
      }
    }
    return out;
  }

  void _storeChanged() {
    server?.touch();
    _probeAll();
  }

  Future<void> start() async {
    final s = _settings;
    if (s == null || running || busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      var uuid = s.dlnaUuid;
      if (uuid.isEmpty) {
        final r = math.Random.secure();
        String hex(int n) => List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
        uuid = '${hex(8)}-${hex(4)}-4${hex(3)}-a${hex(3)}-${hex(12)}';
        s.dlnaUuid = uuid;
      }
      final srv = DlnaServer(name: name, uuid: uuid, entries: _entries, log: debugPrint, ffmpeg: () => ffmpegPath);
      await srv.start();
      server = srv;
      try {
        OfflineStore.instance.addListener(_storeChanged);
      } catch (_) {}
      _tick = Timer.periodic(const Duration(seconds: 5), (_) => notifyListeners()); // "watching now" list
      _onlineTimer = Timer.periodic(const Duration(minutes: 15), (_) => refreshOnline());
      refreshOnline();
      _probeAll();
    } catch (e) {
      error = '$e';
    }
    busy = false;
    notifyListeners();
  }

  Future<void> stop() async {
    _tick?.cancel();
    _onlineTimer?.cancel();
    try {
      OfflineStore.instance.removeListener(_storeChanged);
    } catch (_) {}
    await server?.stop();
    server = null;
    notifyListeners();
  }

  Future<void> setOn(bool on) async {
    _settings?.dlnaOn = on;
    on ? await start() : await stop();
  }

  Future<void> rename(String n) async {
    _settings?.dlnaName = n;
    if (running) {
      // TVs read the name from the description; restart so they notice
      await stop();
      await start();
    }
    notifyListeners();
  }

  /// A setting changed: TVs should re-read the folders.
  void changed() {
    server?.touch();
    notifyListeners();
  }

  Future<void> setOnline(bool on) async {
    _settings?.dlnaOnline = on;
    notifyListeners();
    await refreshOnline();
  }
}

class _OnlineItem {
  _OnlineItem({
    required this.path,
    required this.kind,
    required this.title,
    required this.year,
    required this.show,
    required this.season,
    required this.episode,
    required this.episodeTitle,
    required this.artist,
    required this.album,
    required this.track,
    required this.duration,
    required this.size,
    required this.poster,
    required this.overview,
    required this.genres,
    required this.added,
  });
  final String path, kind, title, show, episodeTitle, artist, album, poster, overview;
  final int year, season, episode, track, size, added;
  final double duration;
  final List<String> genres;
}
