import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../api.dart';
import '../library.dart';
import '../settings.dart';
import 'meta.dart';
import 'parse.dart';

/// Something playable on this device: a file downloaded from a server, or a
/// file in one of the user's own folders. The two are kept apart by [source].
class OfflineItem {
  OfflineItem({required this.id, required this.source});
  final String id;
  /// 'server' (downloaded from a StreamMKV server) or 'folder' (user's own folder)
  final String source;
  String file = ''; // absolute path once available
  String name = '';
  int size = 0;
  String kind = 'video'; // movie | episode | video | music
  // music
  String artist = '', album = '', albumArtist = '';
  int track = 0, disc = 0;
  String title = '', show = '', episodeTitle = '', overview = '';
  int year = 0, season = 0, episode = 0;
  List<String> genres = [];
  double rating = 0;
  String poster = '', backdrop = '', still = ''; // cached local files
  bool scraped = false;
  // downloads from a server
  String server = '', serverPath = '', libName = '';
  String status = 'done'; // queued | downloading | paused | done | failed
  double progress = 0;
  String taskId = '', error = '';
  // user's folder
  String folderId = '';
  // local watch state
  double pos = 0, duration = 0;
  int watched = 0, added = 0;

  bool get isServer => source == 'server';
  bool get ready => status == 'done' && file.isNotEmpty;
  String get label => kind == 'episode' && show.isNotEmpty
      ? '$show · S${season}E$episode${episodeTitle.isNotEmpty ? ' · $episodeTitle' : ''}'
      : (title.isNotEmpty ? title : name);
  double get fraction => duration > 0 ? (pos / duration).clamp(0.0, 1.0) : 0;

  Map<String, dynamic> toJson() => {
        'id': id, 'source': source, 'file': file, 'name': name, 'size': size, 'kind': kind,
        'title': title, 'show': show, 'episodeTitle': episodeTitle, 'overview': overview,
        'year': year, 'season': season, 'episode': episode, 'genres': genres, 'rating': rating,
        'poster': poster, 'backdrop': backdrop, 'still': still, 'scraped': scraped,
        'server': server, 'serverPath': serverPath, 'libName': libName, 'status': status,
        'progress': progress, 'taskId': taskId, 'error': error, 'folderId': folderId,
        'pos': pos, 'duration': duration, 'watched': watched, 'added': added,
        'artist': artist, 'album': album, 'albumArtist': albumArtist, 'track': track, 'disc': disc,
      };

  bool get isMusic => kind == 'music';

  /// A song saved on this device, as something the music player can queue.
  Item toTrack() => Item({
        'path': 'file:$file', 'name': name, 'title': title, 'artist': artist, 'album': album,
        'albumArtist': albumArtist, 'track': track, 'disc': disc, 'year': year, 'duration': duration,
        'cover': poster, 'size': size, 'genres': genres,
      });

  static OfflineItem fromJson(Map j) {
    String s(String k) => '${j[k] ?? ''}';
    int i(String k) => (j[k] as num? ?? 0).toInt();
    double d(String k) => (j[k] as num? ?? 0).toDouble();
    return OfflineItem(id: s('id'), source: s('source'))
      ..file = s('file')
      ..name = s('name')
      ..size = i('size')
      ..kind = s('kind').isEmpty ? 'video' : s('kind')
      ..title = s('title')
      ..show = s('show')
      ..episodeTitle = s('episodeTitle')
      ..overview = s('overview')
      ..year = i('year')
      ..season = i('season')
      ..episode = i('episode')
      ..genres = List<String>.from(j['genres'] as List? ?? const [])
      ..rating = d('rating')
      ..poster = s('poster')
      ..backdrop = s('backdrop')
      ..still = s('still')
      ..scraped = j['scraped'] == true
      ..server = s('server')
      ..serverPath = s('serverPath')
      ..libName = s('libName')
      ..status = s('status').isEmpty ? 'done' : s('status')
      ..progress = d('progress')
      ..taskId = s('taskId')
      ..error = s('error')
      ..folderId = s('folderId')
      ..pos = d('pos')
      ..duration = d('duration')
      ..watched = i('watched')
      ..added = i('added')
      ..artist = s('artist')
      ..album = s('album')
      ..albumArtist = s('albumArtist')
      ..track = i('track')
      ..disc = i('disc');
  }
}

/// A folder of the user's own videos on this device.
class LocalFolder {
  LocalFolder({required this.id, required this.path, required this.name, required this.type});
  final String id, path;
  String name, type; // movies | tv | videos
  int scanned = 0;
  Map<String, dynamic> toJson() => {'id': id, 'path': path, 'name': name, 'type': type, 'scanned': scanned};
  static LocalFolder fromJson(Map j) =>
      LocalFolder(id: '${j['id']}', path: '${j['path']}', name: '${j['name']}', type: '${j['type'] ?? 'movies'}')..scanned = (j['scanned'] as num? ?? 0).toInt();
}

String _hash(String s) {
  // FNV-1a 64 — stable short ids without an extra dependency
  var h = 0xcbf29ce484222325;
  for (final c in utf8.encode(s)) {
    h ^= c;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return (h & 0x7FFFFFFFFFFFFFFF).toRadixString(16).padLeft(16, '0');
}

String _safeName(String n) {
  final s = n.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
  return s.length > 150 ? s.substring(s.length - 150) : s;
}

class OfflineStore extends ChangeNotifier {
  OfflineStore._(this.dir);
  static OfflineStore? _instance;
  static OfflineStore get instance => _instance!;

  final String dir;
  final items = <String, OfflineItem>{};
  final folders = <String, LocalFolder>{};
  final scanning = <String>{};
  Settings? settings;
  Api? api; // set while signed in (downloads, metadata through the server)
  Timer? _saveTimer;

  static Future<OfflineStore> init(Settings settings) async {
    if (_instance != null) return _instance!..settings = settings;
    String dir;
    try {
      dir = (await getApplicationSupportDirectory()).path;
    } catch (e) {
      // never stop the app from starting over this
      debugPrint('offline store dir: $e');
      dir = '${Directory.systemTemp.path}/streammkv';
    }
    final s = OfflineStore._(dir)..settings = settings;
    _instance = s;
    await s._load();
    // never hold up app start for the background downloader
    unawaited(s._startDownloader().timeout(const Duration(seconds: 20)).catchError((Object e) {
      debugPrint('downloader: $e');
    }));
    return s;
  }

  File get _db => File('$dir/offline.json');
  Directory get _posters => Directory('$dir/posters');

  Future<void> _load() async {
    try {
      final j = jsonDecode(await _db.readAsString()) as Map;
      for (final x in (j['items'] as List? ?? const [])) {
        final it = OfflineItem.fromJson(x as Map);
        items[it.id] = it;
      }
      for (final x in (j['folders'] as List? ?? const [])) {
        final f = LocalFolder.fromJson(x as Map);
        folders[f.id] = f;
      }
    } catch (_) {}
  }

  void _save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () async {
      final j = jsonEncode({'items': [for (final i in items.values) i.toJson()], 'folders': [for (final f in folders.values) f.toJson()]});
      final tmp = File('${_db.path}.tmp');
      await tmp.writeAsString(j);
      await tmp.rename(_db.path);
    });
  }

  void changed() {
    _save();
    notifyListeners();
  }

  // ---------------------------------------------------------------- lists

  List<OfflineItem> get downloads => items.values.where((i) => i.isServer).toList()..sort((a, b) => b.added.compareTo(a.added));
  List<OfflineItem> get music => downloads.where((i) => i.isMusic).toList();
  List<OfflineItem> folderItems([String? folderId]) =>
      items.values.where((i) => !i.isServer && (folderId == null || i.folderId == folderId)).toList();
  int get downloadedBytes => downloads.where((i) => i.ready).fold(0, (s, i) => s + i.size);

  static String serverId(String server, String path) => 'srv:$server|$path';

  /// The downloaded copy of a server file (only when it's complete and still on disk).
  OfflineItem? downloaded(String server, String path) {
    final it = items[serverId(server, path)];
    if (it == null || !it.ready) return null;
    if (!File(it.file).existsSync()) {
      it.status = 'failed';
      it.error = 'file missing';
      return null;
    }
    return it;
  }

  OfflineItem? byServer(String server, String path) => items[serverId(server, path)];

  // ---------------------------------------------------------------- downloads from the server

  Future<void> _startDownloader() async {
    final fd = FileDownloader();
    fd.configureNotification(
      running: const TaskNotification('Downloading', '{displayName}'),
      complete: const TaskNotification('Saved to this device', '{displayName}'),
      error: const TaskNotification('Download failed', '{displayName}'),
      paused: const TaskNotification('Download paused', '{displayName}'),
      progressBar: true,
    );
    // songs (a whole album / playlist at once): one combined notification instead of one per song
    fd.configureNotificationForGroup(
      'music',
      running: const TaskNotification('Saving music', '{numFinished} of {numTotal} songs'),
      complete: const TaskNotification('Music saved', '{numTotal} songs on this device'),
      error: const TaskNotification('Some songs could not be saved', '{numFailed} failed'),
      progressBar: true,
      groupNotificationId: 'music',
    );
    fd.updates.listen(_onUpdate);
    // an album or playlist queues many files: fetch a few at a time
    try {
      await fd.configure(globalConfig: [(Config.holdingQueue, (3, null, null))]);
    } catch (e) {
      debugPrint('downloader config: $e');
    }
    await fd.start();
  }

  OfflineItem? _byTask(String taskId) {
    for (final i in items.values) {
      if (i.taskId == taskId) return i;
    }
    return null;
  }

  Future<void> _onUpdate(TaskUpdate u) async {
    final it = _byTask(u.task.taskId);
    if (it == null) return;
    if (u is TaskProgressUpdate) {
      if (u.progress >= 0 && u.progress <= 1) it.progress = u.progress;
      if (u.expectedFileSize > 0) it.size = u.expectedFileSize;
      notifyListeners();
      return;
    }
    if (u is TaskStatusUpdate) {
      switch (u.status) {
        case TaskStatus.enqueued:
        case TaskStatus.waitingToRetry:
          it.status = 'queued';
        case TaskStatus.running:
          it.status = 'downloading';
        case TaskStatus.paused:
          it.status = 'paused';
        case TaskStatus.complete:
          it.file = await u.task.filePath();
          it.status = 'done';
          it.progress = 1;
          try {
            it.size = await File(it.file).length();
          } catch (_) {}
        case TaskStatus.canceled:
          it.status = 'failed';
          it.error = 'canceled';
        case TaskStatus.failed:
        case TaskStatus.notFound:
          it.status = 'failed';
          it.error = u.exception?.description ?? 'failed';
      }
      changed();
    }
  }

  /// Queue a server file for this device. [info]: title/kind/poster… for the offline library.
  Future<void> download(Api api, String path, Map<String, dynamic> info) async {
    final server = api.settings.server;
    final id = serverId(server, path);
    final old = items[id];
    if (old != null && old.status != 'failed') return;
    final name = path.split('/').last;
    final taskId = _hash(id);
    final custom = settings?.offlineDir ?? '';
    if (custom.isNotEmpty) {
      try {
        await Directory(custom).create(recursive: true);
      } catch (_) {}
    }
    final task = DownloadTask(
      taskId: taskId,
      url: api.downloadUrl(path),
      headers: api.authHeaders,
      filename: '${taskId.substring(0, 8)}_${_safeName(name)}',
      directory: custom.isNotEmpty ? custom : 'offline',
      baseDirectory: custom.isNotEmpty ? BaseDirectory.root : BaseDirectory.applicationSupport,
      updates: Updates.statusAndProgress,
      allowPause: true,
      retries: 3,
      requiresWiFi: settings?.wifiOnly ?? false,
      displayName: '${info['title'] ?? name}',
      group: info['kind'] == 'music' ? 'music' : FileDownloader.defaultGroup,
    );
    final it = OfflineItem(id: id, source: 'server')
      ..name = name
      ..server = server
      ..serverPath = path
      ..taskId = taskId
      ..status = 'queued'
      ..added = DateTime.now().millisecondsSinceEpoch ~/ 1000
      ..size = (info['size'] as num? ?? 0).toInt()
      ..kind = '${info['kind'] ?? 'video'}'
      ..title = '${info['title'] ?? ''}'
      ..year = (info['year'] as num? ?? 0).toInt()
      ..show = '${info['show'] ?? ''}'
      ..season = (info['season'] as num? ?? 0).toInt()
      ..episode = (info['episode'] as num? ?? 0).toInt()
      ..episodeTitle = '${info['episodeTitle'] ?? ''}'
      ..overview = '${info['overview'] ?? ''}'
      ..genres = List<String>.from(info['genres'] as List? ?? const [])
      ..rating = (info['rating'] as num? ?? 0).toDouble()
      ..libName = '${info['libName'] ?? ''}'
      ..pos = (info['pos'] as num? ?? 0).toDouble()
      ..duration = (info['duration'] as num? ?? 0).toDouble()
      ..artist = '${info['artist'] ?? ''}'
      ..album = '${info['album'] ?? ''}'
      ..albumArtist = '${info['albumArtist'] ?? ''}'
      ..track = (info['track'] as num? ?? 0).toInt()
      ..disc = (info['disc'] as num? ?? 0).toInt()
      ..scraped = true;
    items[id] = it;
    changed();
    final ok = await FileDownloader().enqueue(task);
    if (!ok) {
      it.status = 'failed';
      it.error = "couldn't start the download";
      changed();
    }
    // artwork for when we're offline
    final headers = api.authHeaders;
    it.poster = await _cacheImage('${info['poster'] ?? ''}', headers);
    it.backdrop = await _cacheImage('${info['backdrop'] ?? ''}', headers);
    it.still = await _cacheImage('${info['still'] ?? ''}', headers);
    changed();
  }

  /// Save songs (an album, a playlist…) to this device.
  Future<int> downloadMusic(Api api, List<Item> tracks, {String libName = ''}) async {
    var n = 0;
    for (final t in tracks) {
      final old = byServer(api.settings.server, t.path);
      if (old != null && old.status != 'failed') continue;
      n++;
      await download(api, t.path, {
        'kind': 'music', 'title': t.title.isNotEmpty ? t.title : t.name, 'artist': t.artist, 'album': t.album,
        'albumArtist': t.albumArtist, 'track': t.track, 'disc': t.disc, 'year': t.year, 'duration': t.duration,
        'size': t.size, 'genres': t.genres, 'poster': t.cover.isEmpty ? '' : api.coverUrl(t.cover), 'libName': libName,
      });
    }
    return n;
  }

  Future<void> pause(OfflineItem it) async {
    final t = await FileDownloader().taskForId(it.taskId);
    if (t is DownloadTask) await FileDownloader().pause(t);
  }

  Future<void> resume(OfflineItem it) async {
    final t = await FileDownloader().taskForId(it.taskId);
    if (t is DownloadTask) {
      await FileDownloader().resume(t);
    } else if (api != null && it.status != 'done') {
      // the task is gone (e.g. failed): start again
      items.remove(it.id);
      await download(api!, it.serverPath, {...it.toJson(), 'poster': '', 'backdrop': ''});
    }
  }

  /// Remove from this device. Downloads: the file goes too. Folder items: only
  /// when [deleteFile] (it's the user's own file).
  Future<void> remove(OfflineItem it, {bool deleteFile = true}) async {
    if (it.isServer && it.status != 'done') {
      try {
        await FileDownloader().cancelTaskWithId(it.taskId);
      } catch (_) {}
    }
    if (deleteFile && it.file.isNotEmpty) {
      try {
        await File(it.file).delete();
      } catch (_) {}
    }
    if (it.isServer) {
      for (final p in [it.poster, it.backdrop, it.still]) {
        if (p.isNotEmpty && !items.values.any((o) => o != it && (o.poster == p || o.backdrop == p || o.still == p))) {
          try {
            await File(p).delete();
          } catch (_) {}
        }
      }
    }
    items.remove(it.id);
    changed();
  }

  /// The folder new downloads go to (for showing in settings).
  Future<String> currentDownloadDir() async {
    final custom = settings?.offlineDir ?? '';
    if (custom.isNotEmpty) return custom;
    return '$dir${Platform.pathSeparator}offline';
  }

  /// Where downloads can go: (label, path) — '' is inside the app.
  static Future<List<(String, String)>> downloadDirChoices() async {
    final out = <(String, String)>[('Inside the app (private)', '')];
    try {
      if (Platform.isAndroid) {
        final dirs = await getExternalStorageDirectories() ?? const <Directory>[];
        for (final (i, d) in dirs.indexed) {
          out.add((i == 0 ? 'Device storage (visible over USB / file manager)' : 'SD card', '${d.path}/StreamMKV'));
        }
      } else if (Platform.isIOS) {
        final d = await getApplicationDocumentsDirectory();
        out.add(('Files app (On My iPhone → Delos → Downloads)', '${d.path}/Downloads'));
      }
    } catch (_) {}
    return out;
  }

  // ---------------------------------------------------------------- artwork

  Future<String> _cacheImage(String url, [Map<String, String>? headers]) async {
    if (url.isEmpty || !url.startsWith('http')) return '';
    final f = File('${_posters.path}/${_hash(url)}.img');
    if (await f.exists()) return f.path;
    try {
      await _posters.create(recursive: true);
      final r = await http.get(Uri.parse(url), headers: url.contains('image.tmdb.org') ? null : headers).timeout(const Duration(seconds: 30));
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) return '';
      await f.writeAsBytes(r.bodyBytes);
      return f.path;
    } catch (_) {
      return '';
    }
  }

  // ---------------------------------------------------------------- user's folders

  Future<LocalFolder> addFolder(String path, String type) async {
    final id = _hash(path);
    final name = path.split(Platform.pathSeparator).where((e) => e.isNotEmpty).lastOrNull ?? path;
    final f = folders[id] ?? LocalFolder(id: id, path: path, name: name, type: type);
    f.type = type;
    folders[id] = f;
    changed();
    unawaited(scanFolder(id));
    return f;
  }

  Future<void> setFolderType(LocalFolder f, String type) async {
    if (f.type == type) return;
    f.type = type;
    for (final it in folderItems(f.id)) {
      items.remove(it.id); // re-parse with the new type
    }
    changed();
    await scanFolder(f.id);
  }

  void removeFolder(LocalFolder f) {
    items.removeWhere((_, i) => i.folderId == f.id);
    folders.remove(f.id);
    changed();
  }

  MetaSource _meta() => MetaSource(api: api, tmdbKey: settings?.tmdbKey ?? '', lang: settings?.tmdbLang ?? 'en-US');

  bool get canScrape => _meta().available;

  /// Find the folder's videos, keep what's known, then fetch missing metadata.
  Future<void> scanFolder(String id, {bool refresh = false}) async {
    final f = folders[id];
    if (f == null || scanning.contains(id)) return;
    scanning.add(id);
    notifyListeners();
    try {
      final root = Directory(f.path);
      final seen = <String>{};
      if (await root.exists()) {
        await for (final e in root.list(recursive: true, followLinks: false).handleError((_) {})) {
          if (e is! File || !isVideoFile(e.path)) continue;
          final rel = e.path.substring(f.path.length).replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), '');
          final parts = rel.split('/');
          if (parts.any((p) => p.startsWith('.'))) continue;
          final iid = 'dir:${f.id}|$rel';
          seen.add(iid);
          var it = items[iid];
          if (it == null || refresh) {
            final keep = it;
            it = OfflineItem(id: iid, source: 'folder')
              ..folderId = f.id
              ..file = e.path
              ..name = parts.last
              ..added = DateTime.now().millisecondsSinceEpoch ~/ 1000;
            if (keep != null) {
              it
                ..pos = keep.pos
                ..duration = keep.duration
                ..watched = keep.watched
                ..added = keep.added;
            }
            try {
              it.size = await e.length();
            } catch (_) {}
            final dirs = parts.sublist(0, parts.length - 1);
            if (f.type == 'tv') {
              final ep = parseEpisode(parts.last, dirs);
              if (ep != null) {
                it
                  ..kind = 'episode'
                  ..show = ep.show
                  ..year = ep.year
                  ..season = ep.season
                  ..episode = ep.episode
                  ..title = ep.show;
              } else {
                it.title = cleanName(parts.last);
              }
            } else if (f.type == 'movies') {
              final m = parseMovie(parts.last, dirs.isEmpty ? '' : dirs.last);
              it
                ..kind = 'movie'
                ..title = m.title
                ..year = m.year;
            } else {
              it.title = cleanName(parts.last);
            }
            items[iid] = it;
          }
        }
      }
      items.removeWhere((k, i) => i.folderId == f.id && !seen.contains(k));
      f.scanned = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      changed();
      await _scrapeFolder(f);
    } finally {
      scanning.remove(id);
      changed();
    }
  }

  Future<void> _scrapeFolder(LocalFolder f) async {
    final meta = _meta();
    if (!meta.available || f.type == 'videos') return;
    for (final it in folderItems(f.id).where((i) => !i.scraped).toList()) {
      try {
        LocalMeta? m;
        if (it.kind == 'movie') {
          m = await meta.movie(it.title, it.year);
        } else if (it.kind == 'episode') {
          m = await meta.episode(it.show, it.year, it.season, it.episode);
        }
        it.scraped = true;
        if (m != null) await _applyMeta(it, m);
        changed();
        await Future.delayed(const Duration(milliseconds: 250));
      } catch (e) {
        debugPrint('scrape ${it.name}: $e');
        if ('$e'.contains('key rejected')) return;
      }
    }
  }

  Future<void> _applyMeta(OfflineItem it, LocalMeta m) async {
    if (m.title.isNotEmpty) {
      if (it.kind == 'episode') {
        it.show = m.title;
      } else {
        it.title = m.title;
      }
    }
    if (m.year > 0) it.year = m.year;
    it
      ..overview = m.overview
      ..genres = m.genres
      ..rating = m.rating
      ..episodeTitle = m.episodeTitle.isNotEmpty ? m.episodeTitle : it.episodeTitle;
    it.poster = await _cacheImage(m.poster);
    it.backdrop = await _cacheImage(m.backdrop);
    if (m.still.isNotEmpty) it.still = await _cacheImage(m.still);
  }

  /// Fetch metadata again for one item (e.g. after fixing the file name).
  Future<void> refreshMeta(OfflineItem it) async {
    final f = folders[it.folderId];
    if (f == null) return;
    it.scraped = false;
    await _scrapeFolder(f);
  }

  // ---------------------------------------------------------------- watch state

  void setPos(OfflineItem it, double pos, double duration) {
    it.pos = duration > 0 && pos > duration - 120 ? 0 : pos;
    if (duration > 0) it.duration = duration;
    it.watched = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    changed();
  }
}
