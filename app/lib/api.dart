import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

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
      final f = method == 'GET'
          ? _client.get(uri, headers: headers)
          : _client.post(uri, headers: headers, body: jsonEncode(body));
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
