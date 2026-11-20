import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'audio.dart';

/// What the video player is showing right now (set by PlayerScreen).
class NowWatching {
  static Map<String, dynamic>? activity;
  static void Function()? onChange;
  static void set(Map<String, dynamic>? a) {
    activity = a;
    onChange?.call();
  }
}

/// People online (+ what they're playing) and chats, kept live over SSE.
class Social extends ChangeNotifier {
  Social(this.api, this.audio) {
    audio.addListener(_audioChanged);
    NowWatching.onChange = () => heartbeat(force: true);
  }
  final Api api;
  final AudioController audio;

  List<Map> people = [];
  List<Map> convs = [];
  bool hideActivity = false;
  bool connected = false;

  /// The conversation on screen (its messages arrive via [onMessage]).
  String? openConv;
  void Function(String conv, Map msg)? onMessage;
  void Function(String conv, int seq, Map? reactions)? onReaction;

  /// Largest attachment in MB (0 = attachments are off), from /api/me.
  int chatMaxMB = 0;

  /// Watch-party events (party.dart listens).
  final partyEvents = StreamController<(String, Map)>.broadcast();

  /// A message arrived for a chat that isn't open (for a SnackBar).
  final incoming = StreamController<(String conv, Map msg)>.broadcast();

  /// Announcements from the admins (unread + pinned), and new unread ones to show.
  List<Map> announcements = [];
  final newAnnouncements = StreamController<Map>.broadcast();
  final _annShown = <String>{};
  int get annUnread => announcements.where((a) => a['read'] != true).length;

  Future<void> loadAnnouncements() async {
    try {
      final d = await api.announcements();
      announcements = List<Map>.from(d['items'] as List? ?? const []);
      for (final a in announcements) {
        if (a['read'] != true && _annShown.add('${a['id']}')) newAnnouncements.add(a);
      }
      notifyListeners();
    } catch (_) {}
  }

  void markAnnouncementRead(Map a) {
    a['read'] = true;
    api.announcementRead('${a['id']}').catchError((_) {});
    notifyListeners();
  }

  StreamSubscription<String>? _sub;
  Timer? _hb, _retry;
  String _lastAct = '';
  bool _disposed = false;
  int _backoff = 2;

  int get unread => convs.fold(0, (t, c) => t + ((c['unread'] as num?)?.toInt() ?? 0));
  String get me => api.settings.username;

  Map? person(String name) => people.where((p) => p['name'] == name).firstOrNull;

  /// Profile picture version (0 = none: show the initial).
  int avatarOf(String name) => (person(name)?['avatar'] as num? ?? 0).toInt();
  bool isAdmin(String name) => person(name)?['admin'] == true;

  /// After changing our own picture, before the server's "people" update arrives.
  void setMyAvatar(int v) {
    final p = person(me);
    if (p != null) p['avatar'] = v;
    notifyListeners();
  }

  Future<void> start() async {
    _hb ??= Timer.periodic(const Duration(seconds: 15), (_) => heartbeat());
    heartbeat(force: true);
    try {
      convs = await api.chats();
      api.me().then((m) => chatMaxMB = (m['chatMaxMB'] as num? ?? 0).toInt()).catchError((_) => 0);
      final p = await api.people();
      people = List<Map>.from(p['people'] as List? ?? const []);
      hideActivity = p['hideActivity'] == true;
      notifyListeners();
    } catch (_) {}
    _connect();
  }

  Future<void> _connect() async {
    if (_disposed) return;
    _sub?.cancel();
    try {
      final res = await api.events();
      connected = true;
      loadAnnouncements(); // catch up after (re)connecting
      _backoff = 2;
      notifyListeners();
      var event = '';
      final data = StringBuffer();
      _sub = res.stream.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        if (line.startsWith('event:')) {
          event = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          data.write(line.substring(5).trim());
        } else if (line.isEmpty && data.isNotEmpty) {
          _handle(event, data.toString());
          data.clear();
          event = '';
        }
      }, onDone: _lost, onError: (_) => _lost(), cancelOnError: true);
    } catch (_) {
      _lost();
    }
  }

  void _lost() {
    connected = false;
    if (_disposed) return;
    notifyListeners();
    _retry?.cancel();
    _retry = Timer(Duration(seconds: _backoff), _connect);
    _backoff = (_backoff * 2).clamp(2, 60);
  }

  void _handle(String event, String raw) {
    final v = jsonDecode(raw);
    switch (event) {
      case 'people':
        people = List<Map>.from(v as List);
      case 'announcement':
        loadAnnouncements();
      case 'conversation':
        final c = Map.from(v as Map);
        convs.removeWhere((x) => x['id'] == c['id']);
        if (c['members'] != null) convs.insert(0, c);
        convs.sort((a, b) => _ts(b).compareTo(_ts(a)));
      case 'reaction':
        if ('${v['conv']}' == openConv) onReaction?.call('${v['conv']}', (v['seq'] as num).toInt(), v['reactions'] as Map?);
      case 'message':
        final conv = '${v['conv']}';
        final m = Map.from(v['message'] as Map);
        if (conv == openConv && onMessage != null) {
          onMessage!(conv, m);
          api.chatRead(conv, (m['seq'] as num).toInt()).catchError((_) {});
        } else if (m['from'] != me && m['sys'] != true) {
          incoming.add((conv, m));
        }
      default:
        if (event.startsWith('part') && v is Map) partyEvents.add((event, Map.from(v)));
    }
    notifyListeners();
  }

  /// One line for a chat list / notification.
  static String preview(Map? m) {
    if (m == null) return '';
    final ref = m['ref'] as Map?, att = m['att'] as Map?, text = '${m['text'] ?? ''}';
    if (ref != null) return '📎 ${ref['title']}';
    if (att != null) return '${att['image'] == true ? '🖼 Photo' : '📎 ${att['name']}'}${text.isNotEmpty ? ' · $text' : ''}';
    return text;
  }

  static int _ts(Map c) => ((c['last'] as Map?)?['ts'] as num? ?? c['created'] as num? ?? 0).toInt();

  // ---------------------------------------------------------------- presence

  Map<String, dynamic>? _activity() {
    if (NowWatching.activity != null) return NowWatching.activity;
    final t = audio.current;
    if (t != null && audio.playing && !t.path.startsWith('file:')) {
      return {
        'kind': 'music',
        'path': t.path,
        'title': t.title.isNotEmpty ? t.title : t.name,
        'sub': [t.artist, t.album].where((e) => e.isNotEmpty).join(' — '),
        if (t.cover.isNotEmpty) 'image': 'cover:${t.cover}',
        'pos': audio.position.inSeconds,
        'dur': t.duration.round(),
        'playing': true,
      };
    }
    return null;
  }

  Future<void> heartbeat({bool force = false}) async {
    final a = _activity();
    final key = a == null ? '' : '${a['kind']}|${a['path']}|${a['title']}|${a['playing']}';
    if (!force && key == _lastAct && !_due()) return;
    _lastAct = key;
    _lastBeat = DateTime.now();
    try {
      await api.presence(a);
    } catch (_) {}
  }

  DateTime _lastBeat = DateTime.fromMillisecondsSinceEpoch(0);
  bool _due() => DateTime.now().difference(_lastBeat).inSeconds >= 30;

  bool? _wasPlaying;
  String? _wasPath;
  void _audioChanged() {
    final p = audio.current?.path;
    if (audio.playing != _wasPlaying || p != _wasPath) {
      _wasPlaying = audio.playing;
      _wasPath = p;
      heartbeat(force: true);
    }
  }

  Future<void> setHide(bool v) async {
    await api.setHideActivity(v);
    hideActivity = v;
    notifyListeners();
  }

  void upsert(Map c) {
    convs.removeWhere((x) => x['id'] == c['id']);
    convs.insert(0, c);
    notifyListeners();
  }

  void markRead(String id) {
    for (final c in convs) {
      if (c['id'] == id) c['unread'] = 0;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    audio.removeListener(_audioChanged);
    _sub?.cancel();
    _hb?.cancel();
    _retry?.cancel();
    incoming.close();
    newAnnouncements.close();
    super.dispose();
  }
}
