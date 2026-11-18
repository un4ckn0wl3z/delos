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

  String coverUrl(String key) => key.isEmpty ? '' : _u('cover/$key').toString();

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

  Future<void> addDownload(String source, String lib, String subdir) =>
      _req('POST', 'downloads', body: {'source': source, 'lib': lib, 'subdir': subdir});

  Future<void> retryDownload(String id) => _req('POST', 'downloads/${Uri.encodeComponent(id)}/retry', body: const {});

  Future<void> deleteDownload(String id, {bool files = false}) =>
      _req('DELETE', 'downloads/${Uri.encodeComponent(id)}', q: files ? {'files': '1'} : null);

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
