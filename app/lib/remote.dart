import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'audio.dart';
import 'library.dart';
import 'party.dart';
import 'social.dart';

/// Remote control, both ways:
///  * this app is a device your other devices can drive (open, play / pause, seek, volume…);
///  * it lists your other devices (apps, web pages on a PC or TV) and drives them.
/// Commands and state go through the server ([Social] carries the events), so no LAN needed.
class RemoteController extends ChangeNotifier {
  RemoteController(this.api, this.audio, this.social, this.party, this.repo) {
    _sub = social.remoteEvents.stream.listen(_onEvent);
    _init();
  }

  final Api api;
  final AudioController audio;
  final Social social;
  final PartyController party;
  final LibraryRepo repo;
  StreamSubscription? _sub;
  Timer? _hello, _watch;
  bool _disposed = false;

  String id = '';
  String name = '';
  List<Map> devices = [];
  bool loading = false;
  String? error;

  /// The device the remote screen drives (remembered).
  String? selected;
  Map? get target => devices.where((d) => d['id'] == selected).firstOrNull;

  Future<void> _init() async {
    final p = await SharedPreferences.getInstance();
    id = p.getString('remoteId') ?? '';
    if (id.isEmpty) {
      final r = math.Random.secure();
      id = 'a${List.generate(10, (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[r.nextInt(36)]).join()}';
      await p.setString('remoteId', id);
    }
    name = p.getString('remoteName') ?? _defaultName();
    selected = p.getString('remoteTarget');
    if (_disposed) return;
    hello(withState: true);
    _hello = Timer.periodic(const Duration(seconds: 30), (_) => hello(withState: true));
    _watch = Timer.periodic(const Duration(milliseconds: 1500), (_) => _checkState());
  }

  static String _defaultName() {
    if (kIsWeb) return 'Browser';
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iPhone / iPad';
    var h = '';
    try {
      h = Platform.localHostname;
    } catch (_) {}
    final os = Platform.isWindows ? 'Windows' : Platform.isMacOS ? 'Mac' : 'Linux';
    return h.isEmpty ? os : '$h ($os)';
  }

  Future<void> rename(String n) async {
    n = n.trim();
    if (n.isEmpty) return;
    name = n;
    (await SharedPreferences.getInstance()).setString('remoteName', n);
    hello(withState: true);
    notifyListeners();
  }

  // ------------------------------------------------------------------ this device

  /// What this device is playing, for remotes.
  Map<String, dynamic> state() {
    final v = party.video;
    if (v != null) {
      final a = NowWatching.activity;
      return {
        'kind': 'video',
        'path': v.path,
        'title': '${a?['title'] ?? v.name}',
        'sub': '${a?['sub'] ?? ''}',
        'pos': v.position.round(),
        'dur': v.duration.round(),
        'playing': v.playing,
        'volume': v.volume.round(),
      };
    }
    final t = audio.current;
    if (t != null) {
      return {
        'kind': 'music',
        'path': t.path,
        'title': t.title.isNotEmpty ? t.title : t.name,
        'sub': [t.j['artist'], t.j['album']].where((x) => x != null && '$x'.isNotEmpty).join(' — '),
        'pos': audio.position.inSeconds,
        'dur': audio.duration.inSeconds,
        'playing': audio.playing,
        'volume': audio.player.state.volume.round(),
        'queue': audio.queue.length > 1,
      };
    }
    return {'idle': true};
  }

  String _lastKey = '';
  double _lastPos = 0;
  DateTime _lastAt = DateTime.now();

  // sends state when something changes: another file, play / pause, volume, or a jump
  void _checkState() {
    final s = state();
    final key = '${s['path']}|${s['playing']}|${s['volume']}|${s['idle']}';
    final pos = ((s['pos'] as num?) ?? 0).toDouble();
    final expect = _lastPos + (s['playing'] == true ? DateTime.now().difference(_lastAt).inMilliseconds / 1000 : 0);
    if (key != _lastKey || (pos - expect).abs() > 4) {
      _lastKey = key;
      _send(s);
    }
    _lastPos = pos;
    _lastAt = DateTime.now();
  }

  void _send(Map<String, dynamic> s) {
    if (id.isEmpty) return;
    api.remoteHello({'id': id, 'name': name, 'platform': kIsWeb ? 'web' : Platform.operatingSystem, 'kind': 'app', 'state': s}).catchError((_) {});
  }

  void hello({bool withState = false}) {
    if (id.isEmpty) return;
    final body = <String, dynamic>{'id': id, 'name': name, 'platform': kIsWeb ? 'web' : Platform.operatingSystem, 'kind': 'app'};
    if (withState) body['state'] = state();
    api.remoteHello(body).catchError((_) {});
  }

  /// "📱 Pixel: playing here" etc. for the UI.
  final notices = StreamController<String>.broadcast();

  Future<void> _run(Map c) async {
    final cmd = '${c['cmd']}';
    final v = party.video;
    switch (cmd) {
      case 'open':
        final path = '${c['path'] ?? ''}';
        final pos = (c['pos'] as num?)?.toDouble() ?? -1;
        final it = await _find(path);
        if (it == null) {
          if (!_disposed) notices.add("Remote: can't find that file here");
          return;
        }
        final libs = await repo.libraries();
        final isMusic = libs.where((l) => l.id == path.split('/').first).firstOrNull?.type == 'music';
        if (isMusic) {
          v?.close();
          await audio.partyOpen(it, pos < 0 ? 0 : pos, true);
        } else {
          if (v != null) {
            v.close();
            await Future<void>.delayed(const Duration(milliseconds: 400));
          }
          audio.pause();
          await party.openVideo?.call(path, pos < 0 ? (it.pos > 0 ? it.pos : 0) : pos, true);
        }
        if (!_disposed) notices.add('📱 ${c['from'] ?? 'Remote'}: playing here');
      case 'toggle':
        if (v != null) {
          await v.partyPlay(!v.playing);
        } else {
          audio.toggle();
        }
      case 'play':
        if (v != null) {
          await v.partyPlay(true);
        } else if (!audio.playing) {
          audio.toggle();
        }
      case 'pause':
        if (v != null) {
          await v.partyPlay(false);
        } else {
          audio.pause();
        }
      case 'seek':
      case 'seekBy':
        final now = v != null ? v.position : audio.position.inMilliseconds / 1000;
        final t = cmd == 'seek' ? ((c['pos'] as num?)?.toDouble() ?? 0) : now + ((c['by'] as num?)?.toDouble() ?? 0);
        final to = t < 0 ? 0.0 : t;
        if (v != null) {
          await v.partySeek(to);
        } else {
          audio.seek(Duration(milliseconds: (to * 1000).round()));
        }
      case 'stop':
        if (v != null) {
          v.close();
        } else {
          await audio.stop();
        }
      case 'next':
        if (v == null) audio.next();
      case 'previous':
        if (v == null) audio.previous();
      case 'volume':
        final vol = ((c['volume'] as num?)?.toDouble() ?? 100).clamp(0, 100).toDouble();
        if (v != null) {
          v.setVolume(vol);
        } else {
          audio.player.setVolume(vol);
        }
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _lastKey = ''; // report right away
    _checkState();
  }

  Future<Item?> _find(String path) async {
    try {
      final libs = await repo.libraries();
      final info = libs.where((l) => l.id == path.split('/').first).firstOrNull;
      if (info == null) return null;
      final d = await repo.lib(info);
      return d.items.where((i) => i.path == path).firstOrNull;
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------------ other devices

  Future<void> refresh() async {
    if (id.isEmpty) await _init();
    loading = true;
    notifyListeners();
    try {
      devices = await api.remoteDevices(id);
      for (final d in devices) {
        d['_at'] = DateTime.fromMillisecondsSinceEpoch((((d['seen'] as num?) ?? 0) * 1000).round());
      }
      error = null;
      if (selected == null || target == null) {
        if (devices.isNotEmpty && target == null) selected = devices.first['id'] as String?;
      }
    } catch (e) {
      error = '$e';
    }
    loading = false;
    if (!_disposed) notifyListeners();
  }

  Future<void> select(String device) async {
    selected = device;
    (await SharedPreferences.getInstance()).setString('remoteTarget', device);
    notifyListeners();
  }

  /// Sends [cmd] to [device] (default: the selected one). Throws the server's message.
  Future<void> send(String cmd, {String? device, Map<String, dynamic> args = const {}}) async {
    final to = device ?? selected;
    if (to == null) throw 'Pick a device first';
    await api.remoteCmd(to, {'cmd': cmd, 'from': name, ...args});
  }

  /// Where the target's playback is now (extrapolated between updates).
  double positionOf(Map d) {
    final s = d['state'] as Map?;
    if (s == null) return 0;
    var p = ((s['pos'] as num?) ?? 0).toDouble();
    final at = d['_at'] as DateTime?;
    if (s['playing'] == true && at != null) p += DateTime.now().difference(at).inMilliseconds / 1000;
    final dur = ((s['dur'] as num?) ?? 0).toDouble();
    return dur > 0 ? math.min(p, dur) : p;
  }

  void _onEvent((String, Map) e) {
    final (ev, v) = e;
    switch (ev) {
      case 'connected':
        hello(withState: true);
        if (hasListeners) refresh();
      case 'remote-cmd':
        if (v['to'] == id) {
          _run(v).catchError((Object x) {
            if (!_disposed) notices.add('Remote: $x');
          });
        }
      case 'remote-devices':
        if (hasListeners) refresh();
      case 'remote-state':
        final d = devices.where((x) => x['id'] == v['id']).firstOrNull;
        if (d != null) {
          d['state'] = v['state'];
          d['_at'] = DateTime.now();
          notifyListeners();
        } else if (v['id'] != id && hasListeners) {
          refresh();
        }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _hello?.cancel();
    _watch?.cancel();
    if (id.isNotEmpty) api.remoteBye(id).catchError((_) {});
    super.dispose();
  }
}
