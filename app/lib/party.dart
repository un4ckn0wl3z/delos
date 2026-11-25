import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'audio.dart';
import 'library.dart';
import 'social.dart';

/// The video player plugs in here while it's open, so a party can follow or drive it.
abstract class PartyVideo {
  String get path;
  String get name;
  bool get playing;
  double get position;
  bool get ready;
  Future<void> partySeek(double t);
  Future<void> partyPlay(bool play);
  void close();
  double get duration;
  double get volume; // 0–100
  void setVolume(double v);
}

/// Something for the UI to show: an invite, a join request, "you were removed", …
class PartyNotice {
  PartyNotice(this.kind, {this.from = '', this.party, this.activity});
  final String kind; // invite request accepted declined ask ask-declined kicked ended reminder locked cant-open
  final String from;
  final Map? party;
  final Map? activity;
}

/// A watch party: one host plays a movie / episode / song, everyone else follows.
/// Live updates come from [Social] (the /api/events stream).
class PartyController extends ChangeNotifier {
  PartyController(this.api, this.audio, this.social, this.repo) {
    _sub = social.partyEvents.stream.listen(_onEvent);
    audio.guard = () => locked('music', audio.current?.path);
    audio.hold = () => party != null && kind == 'music' && !isHost;
    _audioSubs.add(audio.player.stream.playing.listen((_) {
      if (isHost && kind == 'music') hostChanged();
    }));
    audio.addListener(_audioTrack);
    SharedPreferences.getInstance().then((p) {
      muted = p.getBool('partyMute') ?? false;
      final id = p.getString('partyId');
      if (id != null && id.isNotEmpty) resume(id);
    }).catchError((_) {});
  }

  final Api api;
  final AudioController audio;
  final Social social;
  final LibraryRepo repo;
  StreamSubscription? _sub;
  final _audioSubs = <StreamSubscription>[];

  Map? party;
  int skew = 0; // server clock − ours (ms)
  bool muted = false;
  Map? lastState;
  bool applying = false;
  PartyVideo? video;
  /// Opens a video for the party (set by the home screen; navigates to the player).
  Future<void> Function(String path, double pos, bool playing)? openVideo;

  final notices = StreamController<PartyNotice>.broadcast();
  final reactions = StreamController<(String emoji, String from)>.broadcast();
  final messages = StreamController<Map>.broadcast();
  Timer? _hostTimer, _driftTimer;
  String _lastPush = '';
  String? _lastTrack;

  String get me => api.settings.username;
  bool get isHost => party != null && party!['host'] == me;
  String get kind => '${party?['kind'] ?? 'video'}';
  String get id => '${party?['id'] ?? ''}';
  List<Map> get msgs => List<Map>.from(party?['msgs'] as List? ?? const []);
  List<Map> get members => List<Map>.from(party?['members'] as List? ?? const []);
  bool get chatOn => party?['chatOn'] == true;
  int get serverNow => DateTime.now().millisecondsSinceEpoch + skew;

  /// true (and a notice) when a viewer tries to control what the party is playing.
  bool locked(String k, String? path) {
    if (party == null || applying || isHost) return false;
    if (kind != k || path == null || path != party!['path']) return false;
    notices.add(PartyNotice('locked', from: '${party!['host']}'));
    return true;
  }

  void _set(Map? d) {
    final had = party != null;
    if (d != null && d['now'] is num) skew = (d['now'] as num).toInt() - DateTime.now().millisecondsSinceEpoch;
    party = d;
    _hostTimer?.cancel();
    _driftTimer?.cancel();
    if (d != null && isHost) _hostTimer = Timer.periodic(const Duration(seconds: 5), (_) => _push(false));
    if (d != null && !isHost) _driftTimer = Timer.periodic(const Duration(seconds: 4), (_) => _apply(lastState ?? party!));
    SharedPreferences.getInstance().then((p) => d == null ? p.remove('partyId') : p.setString('partyId', '${d['id']}')).catchError((_) => false);
    if (had || d != null) notifyListeners();
  }

  Future<void> resume(String pid) async {
    try {
      final d = Map.from(await api.party(pid));
      if (d['msgs'] == null) return _set(null);
      _set(d);
      if (!isHost) _apply(d);
    } catch (_) {
      _set(null);
    }
  }

  /// Join (or open) a party. Throws [ApiException]: 401 = needs a (correct) password, 403 = private / kicked.
  Future<void> enter(String pid, {String? password}) async {
    var d = Map.from(await api.party(pid));
    if (d['msgs'] == null) d = Map.from(await api.partyAction(pid, 'join', password != null ? {'password': password} : {}));
    _set(d);
    if (isHost) {
      _takeOver();
    } else {
      _apply(d);
    }
  }

  Future<void> leave() async {
    final pid = id;
    _set(null);
    if (pid.isNotEmpty) {
      try {
        await api.partyAction(pid, 'leave', {});
      } catch (_) {}
    }
  }

  Future<void> end() async {
    final pid = id;
    _set(null);
    try {
      await api.partyEnd(pid);
    } catch (_) {}
  }

  /// A host / member action; the server answers with the party as we see it.
  Future<void> act(String action, [Map<String, dynamic>? body]) async {
    final r = await api.partyAction(id, action, body ?? {});
    if (r is Map && r['msgs'] != null) _set(Map.from(r));
  }

  Future<void> send(String text) => api.partyAction(id, 'msg', {'text': text});
  Future<void> react(String emoji) {
    reactions.add((emoji, me));
    return api.partyAction(id, 'react', {'emoji': emoji});
  }

  void setMuted(bool v) {
    muted = v;
    SharedPreferences.getInstance().then((p) => p.setBool('partyMute', v)).catchError((_) => false);
    notifyListeners();
  }

  /// What this device is playing right now (for creating a party from it / answering "can I join?").
  Map<String, dynamic>? current() {
    final v = video;
    if (v != null) return {'kind': 'video', 'path': v.path, 'name': v.name, 'pos': v.position, 'playing': v.playing};
    final t = audio.current;
    if (t != null && !t.path.startsWith('file:')) {
      return {
        'kind': 'music',
        'path': t.path,
        'name': [t.title.isNotEmpty ? t.title : t.name, t.artist].where((e) => e.isNotEmpty).join(' · '),
        'pos': audio.position.inMilliseconds / 1000,
        'playing': audio.playing,
      };
    }
    return null;
  }

  Future<void> create(Map<String, dynamic> body) async {
    final d = Map.from(await api.partyCreate(body));
    if (d['live'] != true) return; // scheduled: nothing to play yet
    _set(d);
    _takeOver();
  }

  Future<void> ask(String user) async {
    final r = await api.partyAsk(user);
    if (r['party'] is Map) {
      _set(Map.from(r['party'] as Map));
      _apply(party!);
    }
  }

  Future<void> answerAsk(String user, bool yes) async {
    final c = current();
    final r = await api.partyAskAnswer(user, yes, (c?['pos'] as num?)?.toDouble() ?? 0, c?['playing'] == true);
    if (yes && r is Map && r['msgs'] != null) {
      _set(Map.from(r));
      hostChanged();
    }
  }

  // ---------------------------------------------------------------- host

  /// The host's player changed (play / pause / seek / new file): tell the party now.
  void hostChanged() => _push(true);

  Future<void> _push(bool force) async {
    if (!isHost) return;
    Map<String, dynamic>? st;
    if (kind == 'music' || video == null) {
      final c = current();
      if (c != null && (c['kind'] == kind || video == null)) st = c;
    } else {
      st = current();
    }
    if (st == null) return;
    final key = '${st['path']}|${st['playing']}';
    if (!force && key == _lastPush && st['playing'] != true) return;
    _lastPush = key;
    try {
      await api.partyAction(id, 'state', st);
      if (party != null && st['path'] != party!['path']) {
        party!['path'] = st['path'];
        party!['kind'] = st['kind'];
        party!['name'] = st['name'];
        notifyListeners();
      }
    } on ApiException catch (e) {
      if (e.status == 404) _set(null);
    } catch (_) {}
  }

  void _audioTrack() {
    final p = audio.current?.path;
    if (p != _lastTrack) {
      _lastTrack = p;
      if (isHost && p != null) hostChanged();
    }
  }

  /// The host opens what the party is about, or keeps what's already playing.
  void _takeOver() {
    if (current() != null) {
      hostChanged();
    } else if ('${party?['path'] ?? ''}'.isNotEmpty) {
      _apply(party!, asHost: true);
    }
  }

  // ---------------------------------------------------------------- viewer

  Future<Item?> _find(String path) async {
    try {
      final libId = path.split('/').first;
      final libs = await repo.libraries();
      final info = libs.where((l) => l.id == libId).firstOrNull;
      if (info == null) return null;
      final d = await repo.lib(info);
      return d.items.where((i) => i.path == path).firstOrNull;
    } catch (_) {
      return null;
    }
  }

  bool _busy = false;
  Future<void> _apply(Map st, {bool asHost = false}) async {
    if (party == null || (isHost && !asHost) || _busy) return;
    lastState = st;
    final path = '${st['path'] ?? ''}';
    if (path.isEmpty) return;
    final playing = st['playing'] == true;
    final at = (st['at'] as num?)?.toInt() ?? serverNow;
    final pos = ((st['pos'] as num?)?.toDouble() ?? 0) + (playing ? math.max(0, serverNow - at) / 1000 : 0);
    _busy = true;
    applying = true;
    try {
      if (st['kind'] == 'music') {
        final cur = audio.current;
        if (cur == null || cur.path != path) {
          final it = await _find(path);
          if (it == null) {
            notices.add(PartyNotice('cant-open'));
            return;
          }
          video?.close();
          await audio.partyOpen(it, pos, playing);
          return;
        }
        final p = audio.position.inMilliseconds / 1000;
        if ((p - pos).abs() > 2.5) await audio.player.seek(Duration(milliseconds: (pos * 1000).round()));
        if (playing != audio.playing) await (playing ? audio.player.play() : audio.player.pause());
      } else {
        final v = video;
        if (v == null || v.path != path) {
          if (audio.playing) audio.pause();
          v?.close();
          await openVideo?.call(path, pos, playing);
          return;
        }
        if (!v.ready) return;
        if ((v.position - pos).abs() > 2.5) await v.partySeek(pos);
        if (playing != v.playing) await v.partyPlay(playing);
      }
    } catch (_) {
      // try again with the next update
    } finally {
      _busy = false;
      Future.delayed(const Duration(milliseconds: 400), () => applying = false);
    }
  }

  // ---------------------------------------------------------------- events

  void _onEvent((String, Map) e) {
    final (event, v) = e;
    switch (event) {
      case 'party':
        final d = v['party'] as Map?;
        if (d == null || party == null || d['id'] != party!['id']) return;
        final wasHost = isHost;
        _set(Map.from(d));
        if (!wasHost && isHost) {
          notices.add(PartyNotice('host'));
          hostChanged();
        }
      case 'party-state':
        if (party == null || v['id'] != party!['id']) return;
        if (v['now'] is num) skew = (v['now'] as num).toInt() - DateTime.now().millisecondsSinceEpoch;
        for (final k in ['path', 'kind', 'name', 'playing', 'pos', 'at']) {
          party![k] = v[k];
        }
        notifyListeners();
        _apply(v);
      case 'party-msg':
        if (party == null || v['id'] != party!['id']) return;
        final m = Map.from(v['msg'] as Map);
        final list = (party!['msgs'] as List?) ?? [];
        if (!list.any((x) => x is Map && x['seq'] == m['seq'])) {
          party!['msgs'] = [...list, m];
          messages.add(m);
          notifyListeners();
        }
      case 'party-react':
        if (party != null && v['id'] == party!['id'] && v['from'] != me) reactions.add(('${v['emoji']}', '${v['from']}'));
      case 'party-notice':
        final kind = '${v['kind']}';
        final p = v['party'] as Map?;
        if ((kind == 'kicked' || kind == 'ended') && party != null && p != null && p['id'] == party!['id']) _set(null);
        if (kind == 'accepted' && p != null) {
          enter('${p['id']}').catchError((_) {});
        }
        notices.add(PartyNotice(kind, from: '${v['from'] ?? ''}', party: p, activity: v['activity'] as Map?));
      case 'parties':
        notices.add(PartyNotice('list'));
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    for (final s in _audioSubs) {
      s.cancel();
    }
    audio.removeListener(_audioTrack);
    _hostTimer?.cancel();
    _driftTimer?.cancel();
    super.dispose();
  }
}
