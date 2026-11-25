import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../offline/store.dart';
import '../settings.dart';
import 'dlna_server.dart';

/// Runs the DLNA server on this computer (Windows) with the files saved for offline use:
/// downloads from the server and your own folders. TVs on the same network see "Delos (name)".
class DlnaHost extends ChangeNotifier {
  DlnaHost._();
  static final instance = DlnaHost._();

  static bool get supported => !kIsWeb && Platform.isWindows;

  Settings? _settings;
  DlnaServer? server;
  String? error;
  bool busy = false;
  Timer? _tick;

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
    if (supported && s.dlnaOn) await start();
  }

  List<OfflineItem> get items {
    final out = <OfflineItem>[];
    try {
      for (final it in OfflineStore.instance.items.values) {
        if (it.ready || (!it.isServer && it.file.isNotEmpty)) out.add(it);
      }
    } catch (_) {}
    return out;
  }

  List<DlnaEntry> _entries() => [
        for (final it in items)
          DlnaEntry(
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
          ),
      ];

  void _storeChanged() => server?.touch();

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
      final srv = DlnaServer(name: name, uuid: uuid, entries: _entries, log: debugPrint);
      await srv.start();
      server = srv;
      try {
        OfflineStore.instance.addListener(_storeChanged);
      } catch (_) {}
      _tick = Timer.periodic(const Duration(seconds: 5), (_) => notifyListeners()); // "watching now" list
    } catch (e) {
      error = '$e';
    }
    busy = false;
    notifyListeners();
  }

  Future<void> stop() async {
    _tick?.cancel();
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
}
