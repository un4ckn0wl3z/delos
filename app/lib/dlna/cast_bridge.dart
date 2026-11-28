part of 'dlna_host.dart';

/// Play on… for TVs: while the DLNA server runs on this computer, the TVs on its network
/// (DLNA renderers) show up as devices of the signed-in account — on the phone's "Play on…"
/// list and on its Remote screen. A phone's command reaches this app through the server's
/// remote events; this app tells the TV to play the file from its own DLNA server (the same
/// stream the TV gets by browsing: passthrough, or AC3 when the audio needs it) and drives it
/// with AVTransport. The TV's state goes back to the phone with each hello.
class CastBridge extends ChangeNotifier {
  CastBridge._(this.host);
  final DlnaHost host;
  final ctl = DlnaCast(log: debugPrint);

  /// Entries sent to a TV (added to what the DLNA server serves): key → entry.
  final entries = <String, DlnaEntry>{};
  final _now = <String, _Cast>{}; // device id → what we told that TV to play
  final _sent = <String, (String, DateTime, double)>{}; // device id → (state key, when, pos) last sent
  final _dead = <String, int>{}; // device id → failed state reads in a row
  Timer? _search, _poll;
  int _tick = 0;
  String? error;

  bool get on => host._settings?.dlnaCast ?? true;
  /// "DESKTOP-3L6R773" out of the DLNA name "Delos (DESKTOP-3L6R773)".
  String get _pc => RegExp(r'^Delos \((.*)\)$').firstMatch(host.name)?.group(1) ?? host.name;

  String deviceId(DlnaRenderer r) => 'tv-${DlnaServer.idOf('${host._settings?.dlnaUuid ?? ''}|${r.id}')}';
  DlnaRenderer? _byDevice(String id) => ctl.list.where((r) => deviceId(r) == id).firstOrNull;

  /// The TVs found (for the DLNA page).
  List<DlnaRenderer> get tvs => ctl.list;

  /// A remote command for one of the TVs this computer drives.
  bool owns(String device) => host.running && on && _byDevice(device) != null;

  void start() {
    if (!on) return;
    _search?.cancel();
    _poll?.cancel();
    _search = Timer.periodic(const Duration(seconds: 60), (_) => search());
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _pollAll());
    search();
  }

  Future<void> stop() async {
    _search?.cancel();
    _poll?.cancel();
    _search = _poll = null;
    final api = host._account;
    if (api != null) {
      for (final r in ctl.list) {
        api.remoteBye(deviceId(r)).catchError((_) {});
      }
    }
    _now.clear();
    _sent.clear();
    if (entries.isNotEmpty) {
      entries.clear();
      host.server?.touch();
    }
  }

  Future<void> setOn(bool v) async {
    host._settings?.dlnaCast = v;
    v && host.running ? start() : await stop();
    notifyListeners();
  }

  Future<void> search() async {
    if (!host.running || !on) return;
    try {
      await ctl.search();
      error = null;
    } catch (e) {
      error = '$e';
    }
    for (final r in ctl.list) {
      _sent.remove(deviceId(r)); // say hello again
    }
    _pollAll(all: true);
    notifyListeners();
  }

  // ------------------------------------------------------------------ state for the phones

  Future<void> _pollAll({bool all = false}) async {
    if (!host.running || !on) return;
    _tick++;
    for (final r in ctl.list) {
      final id = deviceId(r);
      // a TV we're playing on: every 2 s; the others every 10 s (enough to keep them listed)
      if (all || _now.containsKey(id) || _tick % 5 == 0) unawaited(_report(r));
    }
  }

  Future<void> _report(DlnaRenderer r, {bool force = false}) async {
    final api = host._account;
    if (api == null) return;
    final id = deviceId(r);
    TvState st;
    try {
      st = await ctl.state(r);
      _dead.remove(id);
    } catch (_) {
      // switched off or gone: stop saying hello (the phones drop it after a minute)
      _dead[id] = (_dead[id] ?? 0) + 1;
      return;
    }
    final c = _now[id];
    Map<String, dynamic> s;
    if (c != null &&
        (st.uri.isEmpty || st.uri == c.uri || st.state == 'TRANSITIONING') &&
        st.state != 'NO_MEDIA_PRESENT' &&
        !(st.state == 'STOPPED' && !c.starting)) {
      final dur = st.duration > 1 ? st.duration : c.duration;
      s = {
        'kind': c.kind == 'music' ? 'music' : 'video',
        'path': c.path,
        'title': c.title,
        'sub': c.sub,
        'pos': st.pos.round(),
        'dur': dur.round(),
        'playing': st.playing,
        'volume': st.volume < 0 ? 100 : st.volume,
        'via': _pc,
        if (c.audios.length > 1) 'audios': c.audios,
        if (c.audios.length > 1) 'audioSel': c.audio,
        if (c.next != null) 'next': c.next!.$2,
      };
      if (st.playing) c.starting = false;
      if (st.pos > 0) c.lastPos = st.pos;
      // watch progress, like the apps keep it
      if (c.kind != 'music' && st.pos > 0 && DateTime.now().difference(c.saved).inSeconds >= 30) {
        c.saved = DateTime.now();
        api.saveProgress(c.path, pos: st.pos, duration: dur > 0 ? dur : null).catchError((_) {});
      }
    } else {
      if (c != null && !c.starting && st.state == 'STOPPED') {
        _finished(c);
        _now.remove(id);
      }
      s = {'idle': true, 'via': _pc, if (st.volume >= 0) 'volume': st.volume};
    }
    final key = '${s['path']}|${s['playing']}|${s['volume']}|${s['idle']}|${s['audioSel']}';
    final pos = ((s['pos'] as num?) ?? 0).toDouble();
    final last = _sent[id];
    final expect = last == null ? 0 : last.$3 + (s['playing'] == true ? DateTime.now().difference(last.$2).inMilliseconds / 1000 : 0);
    if (!force && last != null && last.$1 == key && (pos - expect).abs() <= 4 && DateTime.now().difference(last.$2).inSeconds < 25) return;
    _sent[id] = (key, DateTime.now(), pos);
    api.remoteHello({'id': id, 'name': r.name, 'platform': 'tv', 'kind': 'dlna', 'state': s}).catchError((_) {});
  }

  void _finished(_Cast c) {
    final api = host._account;
    if (api == null || c.kind == 'music') return;
    // the TV stopped by itself near the end: watched
    if (c.duration > 0 && c.lastPos > c.duration - 90) api.saveProgress(c.path, pos: c.duration, duration: c.duration, done: true).catchError((_) {});
  }

  // ------------------------------------------------------------------ commands from the phones

  /// Runs a remote command ({cmd, to, path?, pos?, by?, volume?, index?, from?}) on the TV it's for.
  Future<void> handle(Map c) async {
    final id = '${c['to']}';
    final r = _byDevice(id);
    if (r == null) return;
    final cur = _now[id];
    try {
      switch ('${c['cmd']}') {
        case 'open':
          await _open(r, '${c['path'] ?? ''}', (c['pos'] as num?)?.toDouble() ?? -1);
        case 'toggle':
          if ((await ctl.state(r)).playing) {
            await ctl.pause(r);
          } else {
            await ctl.resume(r);
          }
        case 'play':
          await ctl.resume(r);
        case 'pause':
          await ctl.pause(r);
        case 'stop':
          await ctl.stop(r);
          if (cur != null) {
            final st = await ctl.state(r).catchError((_) => TvState('', cur.lastPos, 0, '', -1));
            host._account?.saveProgress(cur.path, pos: st.pos > 0 ? st.pos : cur.lastPos, duration: cur.duration > 0 ? cur.duration : null).catchError((_) {});
          }
          _now.remove(id);
        case 'seek':
        case 'seekBy':
          final now = (await ctl.state(r)).pos;
          final t = c['cmd'] == 'seek' ? ((c['pos'] as num?)?.toDouble() ?? 0) : now + ((c['by'] as num?)?.toDouble() ?? 0);
          await ctl.seek(r, t < 0 ? 0 : t);
        case 'volume':
          await ctl.setVolume(r, ((c['volume'] as num?) ?? 50).round());
        case 'audio':
          // a TV can't switch tracks itself: start again from here with the other track (converted)
          if (cur != null) await _open(r, cur.path, (await ctl.state(r)).pos, audio: ((c['index'] as num?) ?? 0).toInt());
        case 'nextEp':
          if (cur?.next != null) await _open(r, cur!.next!.$1, 0);
      }
    } catch (e) {
      debugPrint('cast ${c['cmd']} on ${r.name}: $e');
      error = '${r.name}: $e';
      notifyListeners();
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await _report(r, force: true);
  }

  Future<void> _open(DlnaRenderer r, String path, double pos, {int? audio}) async {
    final api = host._account, srv = host.server;
    if (api == null || srv == null || !srv.running) throw StateError('The DLNA server is off');
    final found = await host._findItem(path);
    if (found == null) throw StateError("Can't find that file on the server");
    final (lib, o) = found;
    // the audio tracks: the TV plays the default one; another one (or one it can't play) goes out converted
    final tracks = o.kind == 'music' ? const <AudioInfo>[] : await api.probe(path).then((p) => p.audio).catchError((_) => const <AudioInfo>[]);
    var def = tracks.indexWhere((a) => a.isDefault);
    if (def < 0) def = 0;
    final idx = math.max(0, math.min(audio ?? def, tracks.isEmpty ? 0 : tracks.length - 1));
    final picked = tracks.isEmpty ? null : {'codec': tracks[idx].codec.toLowerCase(), 'ch': tracks[idx].channels, 'idx': idx};
    final conv = o.kind != 'music' && (idx != def || host._bad(picked));
    final ch = tracks.isEmpty ? 2 : (tracks[idx].channels > 0 ? tracks[idx].channels : 2);
    final atServer = host._settings?.dlnaConvertAt == 'server' || host.ffmpegPath == null;
    final key = 'cast:$path#$idx';
    final e = DlnaEntry(
      key: key,
      file: '',
      url: api.rawUrl(path),
      section: lib.name,
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
      headers: o.poster.contains('/api/') ? api.authHeaders : const {},
      convert: conv,
      audioIndex: idx,
      audioChannels: ch,
      serverConvert: conv && atServer ? (start) => api.tvStreamUrl(path, audio: idx, start: start) : null,
    );
    // keep only what some TV still plays
    final id = deviceId(r);
    final old = _now[id]?.key;
    entries[key] = e;
    if (old != null && old != key && !_now.entries.any((x) => x.key != id && x.value.key == old)) entries.remove(old);
    srv.touch();
    final title = DlnaHost.labelOf(e);
    final m = srv.mediaFor(e, r.ip, title);
    final next = o.kind == 'episode' ? await host._nextEpisode(lib, o) : null;
    final sub = o.kind == 'music'
        ? [o.artist, o.album].where((x) => x.isNotEmpty).join(' — ')
        : o.kind == 'episode'
            ? ''
            : (o.year > 0 ? '${o.year}' : '');
    final double start = pos >= 0 ? pos : (((await api.progress(path))['pos'] as num?)?.toDouble() ?? 0.0);
    _now[id] = _Cast(key, path, m.uri, o.kind == 'episode' ? title : o.title, sub, o.kind, o.duration,
        [for (final t in tracks) t.label], idx, next)
      ..lastPos = start;
    await ctl.play(r, m.uri, m.meta);
    debugPrint('cast: "$title" on ${r.name}${conv ? ' (AC3)' : ''}');
    if (start > 5) {
      // seek once the TV is actually playing (most refuse earlier)
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        try {
          if ((await ctl.state(r)).state == 'PLAYING') {
            await ctl.seek(r, start);
            break;
          }
        } catch (_) {}
      }
    }
  }
}

class _Cast {
  _Cast(this.key, this.path, this.uri, this.title, this.sub, this.kind, this.duration, this.audios, this.audio, this.next);
  final String key, path, uri, title, sub, kind;
  final double duration;
  final List<String> audios;
  final int audio;

  /// The next episode: (path, label).
  final (String, String)? next;
  bool starting = true; // until the TV first says PLAYING
  double lastPos = 0;
  DateTime saved = DateTime.now();
}
