import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// Persistent app settings (SharedPreferences).
class Settings {
  Settings._(this._p);
  final SharedPreferences _p;

  static Future<Settings> load() async => Settings._(await SharedPreferences.getInstance());

  String get server => _p.getString('server') ?? '';
  set server(String v) => _p.setString('server', normalizeServer(v));

  String get username => _p.getString('username') ?? '';
  set username(String v) => _p.setString('username', v);

  String get password => _p.getString('password') ?? '';
  set password(String v) => _p.setString('password', v);

  String? get token => _p.getString('token');
  set token(String? v) => v == null ? _p.remove('token') : _p.setString('token', v);

  /// 'direct' = original file played by mpv, 'transcode' = server-side H.264.
  String get quality => _p.getString('quality') ?? 'direct';
  set quality(String v) => _p.setString('quality', v);

  /// Mix 5.1/7.1 audio down to stereo in the player. Phones and tablets have
  /// stereo speakers anyway, and multichannel output makes some Android
  /// devices stutter. Off by default on desktops (receivers / surround).
  bool get stereoDownmix => _p.getBool('stereoDownmix') ?? (Platform.isAndroid || Platform.isIOS);
  set stereoDownmix(bool v) => _p.setBool('stereoDownmix', v);

  /// Read-ahead buffer for streaming: auto (≈ 2 minutes of the file) or a size in MB.
  String get bufferMode => _p.getString('bufferMode') ?? 'auto';
  set bufferMode(String v) => _p.setString('bufferMode', v);

  // ---------------------------------------------------------------- offline
  /// Use the app without a server (offline library only).
  bool get offlineMode => _p.getBool('offlineMode') ?? false;
  set offlineMode(bool v) => _p.setBool('offlineMode', v);

  /// Own TMDB key for scraping local folders when not signed in to a server.
  String get tmdbKey => _p.getString('tmdbKey') ?? '';
  set tmdbKey(String v) => _p.setString('tmdbKey', v.trim());
  String get tmdbLang => _p.getString('tmdbLang') ?? 'en-US';
  set tmdbLang(String v) => _p.setString('tmdbLang', v.trim());

  /// Where downloads to this device go: '' = inside the app (private), or an absolute folder.
  String get offlineDir => _p.getString('offlineDir') ?? '';
  set offlineDir(String v) => _p.setString('offlineDir', v);

  /// DLNA server for TVs on the home network (Windows).
  bool get dlnaOn => _p.getBool('dlnaOn') ?? false;
  set dlnaOn(bool v) => _p.setBool('dlnaOn', v);
  String get dlnaName => _p.getString('dlnaName') ?? '';
  set dlnaName(String v) => _p.setString('dlnaName', v.trim());
  /// Convert audio the TV can't play (codecs in [dlnaBadAudio]) to AC3.
  bool get dlnaFixAudio => _p.getBool('dlnaFixAudio') ?? true;
  set dlnaFixAudio(bool v) => _p.setBool('dlnaFixAudio', v);
  List<String> get dlnaBadAudio => _p.getStringList('dlnaBadAudio') ?? const ['dts', 'truehd'];
  set dlnaBadAudio(List<String> v) => _p.setStringList('dlnaBadAudio', v);
  /// Also share the server's libraries (passthrough via this PC).
  bool get dlnaOnline => _p.getBool('dlnaOnline') ?? false;
  set dlnaOnline(bool v) => _p.setBool('dlnaOnline', v);
  /// Keep the computer awake while a TV plays from it (DLNA).
  bool get dlnaKeepAwake => _p.getBool('dlnaKeepAwake') ?? true;
  set dlnaKeepAwake(bool v) => _p.setBool('dlnaKeepAwake', v);
  /// Make TV copies (convert ahead) of new files on this PC automatically.
  bool get dlnaAutoCopy => _p.getBool('dlnaAutoCopy') ?? false;
  set dlnaAutoCopy(bool v) => _p.setBool('dlnaAutoCopy', v);
  /// Where online files are converted: pc | server.
  String get dlnaConvertAt => _p.getString('dlnaConvertAt') ?? 'pc';
  set dlnaConvertAt(String v) => _p.setString('dlnaConvertAt', v);
  String get dlnaUuid => _p.getString('dlnaUuid') ?? '';
  set dlnaUuid(String v) => _p.setString('dlnaUuid', v);

  /// Download to this device only on Wi-Fi.
  bool get wifiOnly => _p.getBool('wifiOnly') ?? true;
  set wifiOnly(bool v) => _p.setBool('wifiOnly', v);

  int get maxh => _p.getInt('maxh') ?? 720;
  set maxh(int v) => _p.setInt('maxh', v);

  String get audioLang => _p.getString('audioLang') ?? '';
  set audioLang(String v) => _p.setString('audioLang', v);

  String get subLang => _p.getString('subLang') ?? '';
  set subLang(String v) => _p.setString('subLang', v);

  double get subScale => _p.getDouble('subScale') ?? 1.0;
  set subScale(double v) => _p.setDouble('subScale', v);

  /// Release the user chose to skip in the update dialog.
  String get skipVersion => _p.getString('skipVersion') ?? '';
  set skipVersion(String v) => _p.setString('skipVersion', v);

  bool get loggedIn => server.isNotEmpty && token != null;

  Future<void> logout() async {
    await _p.remove('token');
    await _p.remove('password');
  }

  static String normalizeServer(String v) {
    v = v.trim();
    if (v.isEmpty) return v;
    if (!v.contains('://')) v = 'http://$v';
    final u = Uri.parse(v);
    var path = u.path;
    if (!path.endsWith('/')) path = '$path/';
    return Uri(scheme: u.scheme, host: u.host, port: u.hasPort ? u.port : null, path: path).toString();
  }
}
