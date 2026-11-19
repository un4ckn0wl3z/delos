import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'library.dart';
import 'models.dart';
import 'settings.dart';

class ApiException implements Exception {
  ApiException(this.status, this.message);
  final int status;
  final String message;
  bool get unauthorized => status == 401;
  @override
  String toString() => message;
}

/// Client for the StreamMKV server API.
class Api {
  Api(this.settings);
  final Settings settings;
  final _client = http.Client();

  Uri _u(String path, [Map<String, String>? q]) {
    final u = Uri.parse(settings.server).resolve('api/$path');
    return q == null ? u : u.replace(queryParameters: q);
  }

  Future<dynamic> _req(String method, String path,
      {Map<String, String>? q, Object? body, bool retried = false}) async {
    final uri = _u(path, q);
    final token = settings.token;
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
    http.Response r;
    try {
      final f = switch (method) {
        'GET' => _client.get(uri, headers: headers),
        'DELETE' => _client.delete(uri, headers: headers),
        'PUT' => _client.put(uri, headers: headers, body: jsonEncode(body)),
        _ => _client.post(uri, headers: headers, body: jsonEncode(body)),
      };
      r = await f.timeout(const Duration(seconds: 45));
    } on TimeoutException {
      throw ApiException(0, 'Server did not respond (timeout)');
    } on SocketException catch (e) {
      throw ApiException(0, 'Network error: ${e.message}');
    } on http.ClientException catch (e) {
      throw ApiException(0, 'Network error: ${e.message}');
    }
    if (r.statusCode == 401 && !retried && path != 'login') {
      await login();
      return _req(method, path, q: q, body: body, retried: true);
    }
    final text = utf8.decode(r.bodyBytes);
    if (r.statusCode >= 400) {
      String msg = 'HTTP ${r.statusCode}';
      try {
        msg = (jsonDecode(text) as Map)['error']?.toString() ?? msg;
      } catch (_) {}
      throw ApiException(r.statusCode, msg);
    }
    if (text.isEmpty) return null;
    return path == 'subtitle' ? text : jsonDecode(text);
  }

  Future<void> login() async {
    if (settings.username.isEmpty) throw ApiException(401, 'Not signed in');
    final res = await _req('POST', 'login',
        body: {'username': settings.username, 'password': settings.password}, retried: true);
    settings.token = (res as Map)['token'] as String;
  }

  /// Makes sure the token is valid (re-logs in if needed). Call before handing URLs to the player.
  Future<void> ensureSession() => _req('GET', 'me');

  /// {"user","admin","version"} — version is missing on servers older than 1.2.
  Future<Map<String, dynamic>> me() async => Map<String, dynamic>.from(await _req('GET', 'me') as Map);

  Future<List<LibraryInfo>> libraries() async {
    final res = await _req('GET', 'libraries') as Map;
    return (res['libraries'] as List).map((e) => LibraryInfo.fromJson(e as Map)).toList();
  }

  Future<Map> lib(String id) async => await _req('GET', 'lib/${Uri.encodeComponent(id)}') as Map;

  Map<String, String> get authHeaders => {if (settings.token != null) 'Authorization': 'Bearer ${settings.token}'};

  /// Cover art: a server cover key, or a file already on this device (offline music).
  String coverUrl(String key) => key.isEmpty
      ? ''
      : (key.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(key))
          ? key
          : _u('cover/$key').toString();

  Future<List<MediaFile>> list() async {
    final res = await _req('GET', 'list') as Map;
    return (res['files'] as List).map((e) => MediaFile.fromJson(e as Map)).toList();
  }

  Future<ProbeInfo> probe(String path) async =>
      ProbeInfo.fromJson(await _req('GET', 'probe', q: {'path': path}) as Map);

  Future<Map<String, dynamic>> progress(String path) async {
    try {
      return Map<String, dynamic>.from(await _req('GET', 'progress', q: {'path': path}) as Map);
    } catch (_) {
      return {};
    }
  }

  Future<void> saveProgress(String path,
      {double? pos, double? duration, int? audio, int? sub, bool done = false}) async {
    try {
      await _req('POST', 'progress', body: {
        'path': path,
        if (pos != null) 'pos': pos,
        if (duration != null) 'duration': duration,
        if (audio != null) 'audio': audio,
        if (sub != null) 'sub': sub,
        if (done) 'done': true,
      });
    } catch (_) {/* best effort */}
  }

  // ---------------------------------------------------------------- downloads (downloader role)

  /// {"jobs": [...], "torrent": {"ok", "version"|"error"}, "libraries": [{id,name,type}]}
  Future<Map> downloads() async => await _req('GET', 'downloads') as Map;

  Future<List<String>> downloadDirs(String lib) async {
    final r = await _req('GET', 'downloads/dirs', q: {'lib': lib}) as Map;
    return List<String>.from(r['dirs'] as List? ?? const []);
  }

  /// 409 = looks like a duplicate (retry with force), 422 = can't (already in rtorrent).
  Future<void> addDownload(String source, String lib, String subdir, {bool force = false, bool playlist = false}) =>
      _req('POST', 'downloads', body: {'source': source, 'lib': lib, 'subdir': subdir, 'force': force, 'playlist': playlist});

  /// Upload a .torrent file (rtorrent downloads it into the library).
  Future<void> addTorrentFile(String fileName, List<int> bytes, String lib, String subdir, {bool force = false}) async {
    await ensureSession();
    final req = http.MultipartRequest('POST', _u('downloads/torrent'))
      ..headers.addAll(authHeaders)
      ..fields['lib'] = lib
      ..fields['subdir'] = subdir
      ..fields['force'] = force ? '1' : '0'
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: fileName));
    final res = await http.Response.fromStream(await _client.send(req));
    if (res.statusCode != 200) {
      String msg = res.reasonPhrase ?? 'upload failed';
      try {
        msg = (jsonDecode(res.body) as Map)['error'] as String? ?? msg;
      } catch (_) {}
      throw ApiException(res.statusCode, msg);
    }
  }

  Future<void> retryDownload(String id) => _req('POST', 'downloads/${Uri.encodeComponent(id)}/retry', body: const {});

  // ---------------------------------------------------------------- profile picture
  String avatarUrl(String user, int version) => _u('avatar/${Uri.encodeComponent(user)}', {'v': '$version'}).toString();

  /// Upload a picture (JPG / PNG / GIF; the server crops and scales it). Returns the new version.
  Future<int> uploadAvatar(List<int> bytes, String filename) async {
    await ensureSession();
    final req = http.MultipartRequest('POST', _u('me/avatar'))
      ..headers.addAll(authHeaders)
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final res = await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds: 60)));
    Map body = const {};
    try {
      body = jsonDecode(res.body) as Map;
    } catch (_) {}
    if (res.statusCode != 200) throw ApiException(res.statusCode, '${body['error'] ?? 'HTTP ${res.statusCode}'}');
    return (body['avatar'] as num? ?? 0).toInt();
  }

  Future<void> deleteAvatar() => _req('DELETE', 'me/avatar');

  /// Torrent control: start | stop | pause | resume | recheck → the updated job.
  Future<Map> torrentAction(String id, String action) async =>
      await _req('POST', 'downloads/${Uri.encodeComponent(id)}/torrent', body: {'action': action}) as Map;

  /// Seeding limit for one torrent: 0 = server default, -1 = no limit.
  Future<Map> torrentSeedLimit(String id, double ratio, double hours) async =>
      await _req('POST', 'downloads/${Uri.encodeComponent(id)}/seed', body: {'ratio': ratio, 'hours': hours}) as Map;

  /// Trackers and files of a torrent.
  Future<Map> torrentDetail(String id) async => await _req('GET', 'downloads/${Uri.encodeComponent(id)}/detail') as Map;

  Future<void> deleteDownload(String id, {bool files = false}) =>
      _req('DELETE', 'downloads/${Uri.encodeComponent(id)}', q: files ? {'files': '1'} : null);

  // ---------------------------------------------------------------- people & chat

  /// Live events (text/event-stream). Caller listens and cancels.
  Future<http.StreamedResponse> events() async {
    await ensureSession();
    final req = http.Request('GET', _u('events'))..headers.addAll({...authHeaders, 'Accept': 'text/event-stream'});
    final res = await http.Client().send(req);
    if (res.statusCode != 200) throw ApiException(res.statusCode, 'events: ${res.statusCode}');
    return res;
  }

  Future<void> presence(Map? activity) => _req('POST', 'presence', body: {'activity': activity});
  Future<Map> people() async => await _req('GET', 'people') as Map;
  Future<void> setHideActivity(bool hide) => _req('POST', 'me/privacy', body: {'hideActivity': hide});
  Future<List<Map>> chats() async => List<Map>.from((await _req('GET', 'chat') as Map)['conversations'] as List? ?? const []);
  // ---------------------------------------------------------------- announcements
  /// Active announcements for me: unread + pinned (all: also the read ones).
  Future<Map> announcements({bool all = false}) async => await _req('GET', 'announcements', q: all ? {'all': '1'} : null) as Map;
  Future<void> announcementRead(String id) => _req('POST', 'announcements/${Uri.encodeComponent(id)}/read', body: {});
  Future<void> announcementsReadAll() => _req('POST', 'announcements/read-all', body: {});

  Future<Map> chatDM(String user) async => await _req('POST', 'chat/dm', body: {'user': user}) as Map;
  Future<Map> chatGroup(String name, List<String> members) async => await _req('POST', 'chat/groups', body: {'name': name, 'members': members}) as Map;
  Future<Map> chatUpdate(String id, {String? name, List<String> add = const [], List<String> remove = const []}) async =>
      await _req('PUT', 'chat/${Uri.encodeComponent(id)}', body: {if (name != null) 'name': name, 'add': add, 'remove': remove}) as Map;
  Future<void> chatLeave(String id) => _req('POST', 'chat/${Uri.encodeComponent(id)}/leave', body: const {});
  Future<Map> chatMessages(String id, {int before = 0}) async =>
      await _req('GET', 'chat/${Uri.encodeComponent(id)}/messages', q: {if (before > 0) 'before': '$before'}) as Map;
  /// Returns {"message", "warning"?}
  Future<Map> chatSend(String id, String text, {Map? ref}) async =>
      await _req('POST', 'chat/${Uri.encodeComponent(id)}/messages', body: {'text': text, if (ref != null) 'ref': ref}) as Map;
  Future<void> chatRead(String id, int seq) => _req('POST', 'chat/${Uri.encodeComponent(id)}/read', body: {'seq': seq});

  // ---------------------------------------------------------------- music playlists
  Future<List<Map>> playlists() async => List<Map>.from((await _req('GET', 'playlists') as Map)['playlists'] as List? ?? const []);
  Future<Map> playlist(String id) async => await _req('GET', 'playlists/${Uri.encodeComponent(id)}') as Map;
  Future<Map> createPlaylist(String name, List<String> tracks) async =>
      await _req('POST', 'playlists', body: {'name': name, 'tracks': tracks}) as Map;
  Future<Map> updatePlaylist(String id, {String? name, List<String>? tracks}) async => await _req('PUT', 'playlists/${Uri.encodeComponent(id)}',
      body: {if (name != null) 'name': name, if (tracks != null) 'tracks': tracks}) as Map;
  Future<Map> addToPlaylist(String id, List<String> tracks) async =>
      await _req('POST', 'playlists/${Uri.encodeComponent(id)}/add', body: {'tracks': tracks}) as Map;
  Future<void> deletePlaylist(String id) => _req('DELETE', 'playlists/${Uri.encodeComponent(id)}');

  /// Toggle my reaction on a message → {reactions: {emoji: [users]}}.
  Future<Map> chatReact(String id, int seq, String emoji) async =>
      await _req('POST', 'chat/${Uri.encodeComponent(id)}/messages/$seq/react', body: {'emoji': emoji}) as Map;

  /// Send a picture / file (streamed from disk) with an optional caption → {message}.
  Future<Map> chatAttach(String id, String filePath, String filename, {String text = ''}) async {
    await ensureSession();
    final req = http.MultipartRequest('POST', _u('chat/${Uri.encodeComponent(id)}/attachments'))
      ..headers.addAll(authHeaders);
    if (text.isNotEmpty) req.fields['text'] = text;
    req.files.add(await http.MultipartFile.fromPath('file', filePath, filename: filename));
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req).timeout(const Duration(minutes: 30)));
    } on TimeoutException {
      throw ApiException(0, 'Upload timed out');
    } on SocketException catch (e) {
      throw ApiException(0, 'Network error: ${e.message}');
    }
    Map body = const {};
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
    } catch (_) {}
    if (res.statusCode != 200) throw ApiException(res.statusCode, '${body['error'] ?? 'HTTP ${res.statusCode}'}');
    return body;
  }

  /// URL of a chat attachment (token in the query so images and the browser can open it).
  String chatFileUrl(String conv, String att, {bool thumb = false, bool download = false}) =>
      _u('chat/${Uri.encodeComponent(conv)}/files/$att', {
        if (thumb) 'thumb': '1',
        if (download) 'dl': '1',
        'token': settings.token ?? '',
      }).toString();

  /// The emoji list the server ships (same as the web app's picker).
  Future<Map> emojiData() async {
    final r = await _client.get(Uri.parse(settings.server).resolve('emoji.json')).timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) throw ApiException(r.statusCode, 'emoji list unavailable');
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map;
  }

  // ---------------------------------------------------------------- personal libraries

  /// {"libraries": [...], "usage": {items, bytes}, "maxItems", "maxBytes"}
  Future<Map> myLibraries() async => await _req('GET', 'my/libraries') as Map;

  Future<void> createMyLibrary(String name, String type, bool shared) =>
      _req('POST', 'my/libraries', body: {'name': name, 'type': type, 'shared': shared});

  Future<void> shareMyLibrary(String id, bool shared) => _req('PUT', 'my/libraries/${Uri.encodeComponent(id)}', body: {'shared': shared});

  Future<void> deleteMyLibrary(String id, {bool files = false}) =>
      _req('DELETE', 'my/libraries/${Uri.encodeComponent(id)}', q: files ? {'files': '1'} : null);

  /// Delete media files (own personal libraries; admins anywhere).
  Future<void> deleteFiles(List<String> paths) => _req('POST', 'files/delete', body: {'paths': paths});

  /// pos 0 = drop it from "Continue watching" (track choices are kept).
  Future<void> clearProgress(String path) => _req('POST', 'progress', body: {'path': path, 'pos': 0});

  /// TMDB candidates for a movie/TV library (editor role).
  Future<List<Map>> metaSearch(String lib, String q, int year) async {
    final r = await _req('GET', 'meta/search', q: {'lib': lib, 'q': q, if (year > 0) 'year': '$year'}) as Map;
    return List<Map>.from(r['results'] as List? ?? const []);
  }

  /// Pin a TMDB id (0 = detect automatically again) for a movie file or a show.
  Future<void> metaMatch(String lib, {String? path, String? show, required int tmdbId}) =>
      _req('POST', 'meta/match', body: {'lib': lib, if (path != null) 'path': path, if (show != null) 'show': show, 'tmdbId': tmdbId});

  /// URL that saves a file to the device (needs the "offline" permission).
  String downloadUrl(String path) => _u('download', {'path': path}).toString();

  /// Metadata for the app's own local folders, using the server's TMDB key.
  Future<Map> metaLookup(Map<String, dynamic> body) async => await _req('POST', 'meta/lookup', body: body) as Map;

  /// Throws ApiException with the server's reason when a stream limit is hit.
  Future<void> streamCheck(String path, String kind) => _req('GET', 'stream/check', q: {'path': path, 'kind': kind});

  Future<String> subtitle(String path, int index) async =>
      await _req('GET', 'subtitle', q: {'path': path, 'sub': '$index'}) as String;

  String rawUrl(String path) => _u('raw', {'path': path, 'token': settings.token ?? ''}).toString();

  String streamUrl(String path, {required int audio, required double start, required int maxh, int? burn}) =>
      _u('stream', {
        'path': path,
        'audio': '$audio',
        'start': start.toStringAsFixed(3),
        'v': 'transcode',
        'maxh': '$maxh',
        if (burn != null) 'burn': '$burn',
        'token': settings.token ?? '',
      }).toString();
}
