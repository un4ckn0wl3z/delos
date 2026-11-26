import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../api.dart';
import '../library.dart';
import '../offline/store.dart';
import '../settings.dart';
import 'dlna_server.dart';
import 'keep_awake.dart';

/// Runs the DLNA server on this PC (Windows): the files saved for offline use, and optionally the
/// server's libraries passed through this PC ("Online"). Audio a TV can't play (DTS, TrueHD) is
/// converted to AC3 on the fly — here with ffmpeg, or on the server for online files.
class DlnaHost extends ChangeNotifier {
  DlnaHost._();
  static final instance = DlnaHost._();

  static bool get supported => !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

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
    await _loadCopies();
    await ffmpegFind();
    if (s.dlnaOn) await start();
  }

  // ------------------------------------------------------------------ ffmpeg

  String? ffmpegPath, ffprobePath;
  double? ffmpegProgress; // 0..1 while downloading
  String? ffmpegError;

  static String get _exe => Platform.isWindows ? '.exe' : '';
  static String get _sep => Platform.pathSeparator;
  static bool get _arm => const {Abi.windowsArm64, Abi.linuxArm64, Abi.macosArm64}.contains(Abi.current());

  /// What to download for this computer: (url, kind) — kind zip | tar | two zips (macOS: ffmpeg + ffprobe).
  static List<String> get ffmpegUrls {
    const btbn = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest';
    if (Platform.isWindows) return ['$btbn/ffmpeg-master-latest-win${_arm ? 'arm64' : '64'}-gpl.zip'];
    if (Platform.isLinux) return ['$btbn/ffmpeg-master-latest-linux${_arm ? 'arm64' : '64'}-gpl.tar.xz'];
    const mr = 'https://ffmpeg.martin-riedl.de/redirect/latest/macos';
    final a = _arm ? 'arm64' : 'amd64';
    return ['$mr/$a/release/ffmpeg.zip', '$mr/$a/release/ffprobe.zip'];
  }

  Future<Directory> _dir(String sub) async {
    final d = Directory('${(await getApplicationSupportDirectory()).path}$_sep$sub');
    await d.create(recursive: true);
    return d;
  }

  /// ffmpeg downloaded by the app, or one already installed (Windows / Linux; the Mac app is sandboxed).
  Future<void> ffmpegFind() async {
    try {
      final d = await _dir('ffmpeg');
      final f = File('${d.path}${_sep}ffmpeg$_exe'), p = File('${d.path}${_sep}ffprobe$_exe');
      if (f.existsSync() && p.existsSync()) {
        ffmpegPath = f.path;
        ffprobePath = p.path;
        return;
      }
      if (Platform.isMacOS) return;
      final w = await Process.run(Platform.isWindows ? 'where' : 'which', ['ffmpeg'], runInShell: Platform.isWindows);
      final first = '${w.stdout}'.split(RegExp(r'[\r\n]+')).firstWhere((l) => l.trim().isNotEmpty, orElse: () => '').trim();
      if (w.exitCode == 0 && first.isNotEmpty) {
        final probe = first.replaceAll(RegExp(r'ffmpeg(\.exe)?$', caseSensitive: false), 'ffprobe$_exe');
        if (File(probe).existsSync()) {
          ffmpegPath = first;
          ffprobePath = probe;
        }
      }
    } catch (_) {}
  }

  /// Downloads ffmpeg + ffprobe into the app's folder (≈ 80–160 MB download).
  Future<void> ffmpegDownload() async {
    if (ffmpegProgress != null) return;
    ffmpegProgress = 0;
    ffmpegError = null;
    notifyListeners();
    final d = await _dir('ffmpeg');
    final tmp = Directory('${d.path}${_sep}tmp');
    final client = HttpClient();
    final files = <File>[];
    try {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
      await tmp.create();
      final urls = ffmpegUrls;
      for (var i = 0; i < urls.length; i++) {
        final url = urls[i];
        final f = File('${tmp.path}${_sep}dl$i${url.endsWith('.tar.xz') ? '.tar.xz' : '.zip'}');
        files.add(f);
        final rs = await (await client.getUrl(Uri.parse(url))).close();
        if (rs.statusCode != 200) throw 'download failed (HTTP ${rs.statusCode})';
        final total = rs.contentLength;
        var got = 0;
        final sink = f.openWrite();
        var last = DateTime.now();
        await for (final chunk in rs) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0 && DateTime.now().difference(last).inMilliseconds > 300) {
            ffmpegProgress = (i + got / total) / urls.length;
            last = DateTime.now();
            notifyListeners();
          }
        }
        await sink.close();
      }
      ffmpegProgress = 1;
      notifyListeners();
      for (final f in files) {
        final ProcessResult x;
        if (Platform.isWindows) {
          // Windows' own tar (bsdtar) unpacks zip files
          x = await Process.run('${Platform.environment['SystemRoot'] ?? 'C:\\Windows'}\\System32\\tar.exe', ['-xf', f.path, '-C', tmp.path]);
        } else if (Platform.isMacOS) {
          x = await Process.run('/usr/bin/ditto', ['-x', '-k', f.path, tmp.path]);
        } else {
          x = await Process.run('tar', ['-xf', f.path, '-C', tmp.path]);
        }
        if (x.exitCode != 0) throw 'unpacking failed: ${x.stderr}';
      }
      File? find(String n) {
        for (final e in tmp.listSync(recursive: true)) {
          if (e is File && e.path.split(_sep).last.toLowerCase() == n) return e;
        }
        return null;
      }

      final f = find('ffmpeg$_exe'), p = find('ffprobe$_exe');
      if (f == null || p == null) throw 'ffmpeg not found in the download';
      final fp = '${d.path}${_sep}ffmpeg$_exe', pp = '${d.path}${_sep}ffprobe$_exe';
      await f.copy(fp);
      await p.copy(pp);
      if (!Platform.isWindows) {
        await Process.run('chmod', ['755', fp, pp]);
        if (Platform.isMacOS) await Process.run('/usr/bin/xattr', ['-d', 'com.apple.quarantine', fp, pp]);
      }
      final v = await Process.run(fp, ['-version']);
      if (v.exitCode != 0) throw "the downloaded ffmpeg doesn't run here: ${v.stderr}";
      ffmpegPath = fp;
      ffprobePath = pp;
      server?.touch();
      _probeAll();
    } catch (e) {
      ffmpegError = '$e';
    } finally {
      client.close(force: true);
      try {
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

  /// This PC's file as ffprobe / ffmpeg read it: through the server's loopback route (a sandboxed
  /// Mac app's helper can't open the user's folders itself).
  String _loopback(String key, String file) {
    final srv = server;
    if (srv == null) return file;
    final i = file.lastIndexOf('.');
    return 'http://127.0.0.1:${srv.boundPort}/r/${DlnaServer.idOf(key)}${i < 0 ? '' : file.substring(i)}';
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
                final r = t.$3 ? await _probeServer(t.$2) : await _probeLocal(_loopback(t.$1.substring(2), t.$2));
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
      _autoCopies();
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

  List<DlnaEntry> _entries() => _build();

  /// Everything the TV can browse. With [useCopies], files that have a TV copy play from it.
  List<DlnaEntry> _build({bool useCopies = true}) {
    final s = _settings;
    final out = <DlnaEntry>[];
    DlnaEntry withCopy(DlnaEntry e) {
      if (!useCopies || !e.convert) return e;
      final c = _copies[e.key];
      if (c == null || c['sig'] != '${e.size}' || !File('${c['file']}').existsSync()) return e;
      return DlnaEntry(
        key: e.key,
        file: '${c['file']}',
        origin: e.remote ? '' : e.file,
        section: e.section,
        kind: e.kind,
        title: e.title,
        poster: e.poster,
        show: e.show,
        season: e.season,
        episode: e.episode,
        episodeTitle: e.episodeTitle,
        year: e.year,
        duration: e.duration,
        size: (c['size'] as num?)?.toInt() ?? 0,
        genres: e.genres,
        overview: e.overview,
        added: e.added,
        headers: e.headers,
      );
    }

    for (final it in items) {
      final p = _probes['l:${it.id}'];
      final conv = it.kind != 'music' && _bad(p);
      out.add(withCopy(DlnaEntry(
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
      )));
    }
    final api = _api;
    if (s != null && s.dlnaOnline && api != null) {
      final auth = api.authHeaders;
      final atServer = s.dlnaConvertAt == 'server';
      for (final (l, o) in _online) {
        final p = _probes['s:${o.path}'];
        final conv = o.kind != 'music' && _bad(p);
        final idx = (p?['idx'] as num?)?.toInt() ?? 0;
        out.add(withCopy(DlnaEntry(
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
        )));
      }
    }
    return out;
  }

  // ------------------------------------------------------------------ TV copies (convert ahead)

  /// key → {file, sig, size}: converted copies kept in the app's folder.
  final _copies = <String, Map<String, dynamic>>{};
  File? _copiesFile;
  final copyQueue = <String>[];
  String? copyKey, copyError;
  String copyTitle = '';
  double copyProgress = 0;
  Process? _copyProc;
  bool _copyCancel = false;

  Future<void> _loadCopies() async {
    try {
      _copiesFile = File('${(await _dir('dlna')).path}${_sep}copies.json');
      if (_copiesFile!.existsSync()) {
        (jsonDecode(await _copiesFile!.readAsString()) as Map).forEach((k, v) => _copies['$k'] = Map<String, dynamic>.from(v as Map));
      }
    } catch (_) {}
  }

  void _saveCopies() {
    try {
      _copiesFile?.writeAsStringSync(jsonEncode(_copies));
    } catch (_) {}
  }

  static String labelOf(DlnaEntry e) {
    if (e.kind != 'episode') return e.year > 0 ? '${e.title} (${e.year})' : e.title;
    final c = 'S${e.season.toString().padLeft(2, '0')}E${e.episode.toString().padLeft(2, '0')}';
    return '${e.show.isNotEmpty ? '${e.show} · ' : ''}$c${e.episodeTitle.isNotEmpty ? ' · ${e.episodeTitle}' : ''}';
  }

  /// Files whose audio gets converted: (entry, has a TV copy, copy size).
  List<(DlnaEntry, bool, int)> get candidates {
    final out = <(DlnaEntry, bool, int)>[];
    for (final e in _build(useCopies: false)) {
      if (!e.convert) continue;
      final c = _copies[e.key];
      final ok = c != null && c['sig'] == '${e.size}' && File('${c['file']}').existsSync();
      out.add((e, ok, ok ? (c['size'] as num?)?.toInt() ?? 0 : 0));
    }
    out.sort((a, b) => labelOf(a.$1).toLowerCase().compareTo(labelOf(b.$1).toLowerCase()));
    return out;
  }

  int get copiesSize {
    var n = 0;
    for (final c in _copies.values) {
      n += (c['size'] as num?)?.toInt() ?? 0;
    }
    return n;
  }

  /// Queue [keys] for converting ahead (skips ones that have a copy or are queued).
  void makeCopies(Iterable<String> keys) {
    final have = {for (final c in candidates) if (c.$2) c.$1.key};
    for (final k in keys) {
      if (!have.contains(k) && !copyQueue.contains(k) && copyKey != k) copyQueue.add(k);
    }
    notifyListeners();
    _runCopies();
  }

  void cancelCopies() {
    copyQueue.clear();
    _copyCancel = true;
    _copyProc?.kill();
    notifyListeners();
  }

  Future<void> deleteCopy(String key) async {
    final c = _copies.remove(key);
    if (c != null) {
      try {
        await File('${c['file']}').delete();
      } catch (_) {}
    }
    _saveCopies();
    server?.touch();
    notifyListeners();
  }

  Future<void> deleteAllCopies() async {
    cancelCopies();
    for (final k in _copies.keys.toList()) {
      await deleteCopy(k);
    }
  }

  Future<void> _runCopies() async {
    if (copyKey != null) return;
    copyError = null;
    while (copyQueue.isNotEmpty) {
      final srv = server, ff = ffmpegPath;
      if (srv == null || !srv.running || ff == null) {
        copyError = ff == null ? 'Install the converter first' : 'Turn the DLNA server on first';
        copyQueue.clear();
        break;
      }
      final key = copyQueue.removeAt(0);
      final e = _build(useCopies: false).where((x) => x.key == key).firstOrNull;
      if (e == null) continue;
      _copyCancel = false;
      copyKey = key;
      copyTitle = labelOf(e);
      copyProgress = 0;
      notifyListeners();
      final d = await _dir('dlna${_sep}tv');
      final out = '${d.path}$_sep${DlnaServer.idOf(key)}.mkv';
      final part = File('$out.part');
      final err = StringBuffer();
      try {
        final p = await Process.start(ff, [
          '-hide_banner', '-loglevel', 'error', '-nostdin', '-y',
          '-reconnect', '1', '-reconnect_on_network_error', '1',
          '-i', srv.inputOf(e),
          ...DlnaServer.convertArgs(e, subs: DlnaServer.isMkv(e)),
          '-progress', 'pipe:1', '-nostats',
          '-f', 'matroska', part.path,
        ]);
        _copyProc = p;
        p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
          if (l.startsWith('out_time_us=') && e.duration > 0) {
            final us = int.tryParse(l.substring(12)) ?? 0;
            copyProgress = (us / 1e6 / e.duration).clamp(0, 1).toDouble();
            notifyListeners();
          }
        });
        p.stderr.transform(utf8.decoder).listen((x) {
          if (err.length < 4000) err.write(x);
        });
        final code = await p.exitCode;
        if (code == 0 && !_copyCancel) {
          await part.rename(out);
          _copies[key] = {'file': out, 'sig': '${e.size}', 'size': File(out).lengthSync()};
          _saveCopies();
          srv.touch();
        } else {
          if (!_copyCancel) copyError = '$copyTitle: ${err.toString().trim().split('\n').last}';
          try {
            if (part.existsSync()) await part.delete();
          } catch (_) {}
        }
      } catch (x) {
        copyError = '$x';
      }
      _copyProc = null;
    }
    copyKey = null;
    notifyListeners();
  }

  /// Settings → "Convert new files ahead automatically": this PC's files only.
  void _autoCopies() {
    if (!(_settings?.dlnaAutoCopy ?? false) || ffmpegPath == null) return;
    makeCopies([for (final c in candidates) if (!c.$2 && c.$1.section.isEmpty) c.$1.key]);
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
      _tick = Timer.periodic(const Duration(seconds: 5), (_) {
        // no sleep while a TV watches (or paused within the last few minutes), or while converting
        final busy = (_settings?.dlnaKeepAwake ?? true) && (srv.watching || copyKey != null);
        KeepAwake.instance.set(busy);
        notifyListeners(); // "watching now" list
      });
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
    KeepAwake.instance.set(false);
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
