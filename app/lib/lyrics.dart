import 'dart:io';

import 'package:flutter/material.dart';

import 'audio.dart';
import 'library.dart';

/// One timed line of an LRC file.
class LrcLine {
  LrcLine(this.time, this.text);
  final double time;
  final String text;
}

/// Parse LRC text (several stamps per line, [offset:] in ms).
List<LrcLine> parseLrc(String text) {
  var offset = 0.0;
  final out = <LrcLine>[];
  final stamp = RegExp(r'^\[(\d+):(\d+(?:[.:]\d+)?)\]');
  final off = RegExp(r'^\[offset:\s*([+-]?\d+)\]', caseSensitive: false);
  for (final raw in text.replaceAll('\r', '').split('\n')) {
    final om = off.firstMatch(raw);
    if (om != null) {
      offset = int.parse(om.group(1)!) / 1000;
      continue;
    }
    var rest = raw;
    final times = <double>[];
    RegExpMatch? m;
    while ((m = stamp.firstMatch(rest)) != null) {
      times.add(int.parse(m!.group(1)!) * 60 + double.parse(m.group(2)!.replaceAll(':', '.')));
      rest = rest.substring(m.group(0)!.length);
    }
    for (final t in times) {
      out.add(LrcLine((t - offset).clamp(0, double.infinity).toDouble(), rest.trim()));
    }
  }
  out.sort((a, b) => a.time.compareTo(b.time));
  return out;
}

class Lyrics {
  Lyrics(this.synced, this.plain, this.source);
  final List<LrcLine> synced;
  final String plain;
  final String source;
  bool get empty => synced.isEmpty && plain.trim().isEmpty;
}

final _cache = <String, Lyrics>{};

/// Lyrics for [t]: the server looks in the .lrc next to the song, its tags and LRCLIB.
/// Songs from this device's own library only use a .lrc next to the file.
Future<Lyrics> loadLyrics(AudioController audio, Item t, {bool refresh = false}) async {
  if (!refresh && _cache[t.path] != null) return _cache[t.path]!;
  Lyrics l = Lyrics(const [], '', '');
  if (t.path.startsWith('file:')) {
    final f = t.path.substring(5);
    final dot = f.lastIndexOf('.');
    final lrc = File('${dot > 0 ? f.substring(0, dot) : f}.lrc');
    if (await lrc.exists()) {
      final txt = await lrc.readAsString();
      final lines = parseLrc(txt);
      l = Lyrics(lines, lines.isEmpty ? txt : '', 'file');
    }
  } else {
    try {
      final d = await audio.api.lyrics(t.path, refresh: refresh);
      final synced = (d['synced'] as String?) ?? '';
      l = Lyrics(synced.isEmpty ? const [] : parseLrc(synced), (d['plain'] as String?) ?? '', (d['source'] as String?) ?? '');
    } catch (_) {
      // offline: no lyrics
    }
  }
  _cache[t.path] = l;
  return l;
}

/// Full-screen lyrics that follow the song; tap a line to jump there.
class LyricsView extends StatefulWidget {
  const LyricsView({super.key, required this.audio});
  final AudioController audio;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  String? _path;
  Lyrics? _lyr;
  bool _loading = false;
  int _idx = -1;
  final _scroll = ScrollController();
  final _keys = <int, GlobalKey>{};
  DateTime _userScroll = DateTime.fromMillisecondsSinceEpoch(0);

  AudioController get audio => widget.audio;

  @override
  void initState() {
    super.initState();
    audio.addListener(_onAudio);
    _onAudio();
  }

  @override
  void dispose() {
    audio.removeListener(_onAudio);
    _scroll.dispose();
    super.dispose();
  }

  void _onAudio() {
    final t = audio.current;
    if (t == null) return;
    if (t.path != _path) {
      _load(t);
      return;
    }
    _follow();
  }

  Future<void> _load(Item t, {bool refresh = false}) async {
    _path = t.path;
    setState(() {
      _lyr = null;
      _loading = true;
      _idx = -1;
      _keys.clear();
    });
    final l = await loadLyrics(audio, t, refresh: refresh);
    if (!mounted || _path != t.path) return;
    setState(() {
      _lyr = l;
      _loading = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _follow(jump: true));
  }

  void _follow({bool jump = false}) {
    final l = _lyr;
    if (l == null || l.synced.isEmpty) return;
    final t = audio.position.inMilliseconds / 1000 + .25;
    var i = -1;
    for (var k = 0; k < l.synced.length && l.synced[k].time <= t; k++) {
      i = k;
    }
    if (i == _idx && !jump) return;
    setState(() => _idx = i);
    if (DateTime.now().difference(_userScroll).inSeconds < 4) return;
    final ctx = _keys[i]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, alignment: .4, duration: jump ? Duration.zero : const Duration(milliseconds: 350), curve: Curves.easeOut);
    } else if (_scroll.hasClients && i >= 0) {
      // not built yet (far away): get close first, the next tick lines it up
      final to = (i * 50.0).clamp(0, _scroll.position.maxScrollExtent).toDouble();
      _scroll.jumpTo(to);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final c = _keys[i]?.currentContext;
        if (c != null && mounted) Scrollable.ensureVisible(c, alignment: .4);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = audio.current;
    final l = _lyr;
    Widget body;
    if (_loading || l == null) {
      body = const Center(child: Text('Looking for lyrics…', style: TextStyle(color: Colors.white54)));
    } else if (l.empty) {
      body = Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('No lyrics found for this song.', style: TextStyle(color: Colors.white54)),
          if (t != null && !t.path.startsWith('file:')) TextButton(onPressed: () => _load(t, refresh: true), child: const Text('Search again')),
        ]),
      );
    } else if (l.synced.isNotEmpty) {
      body = NotificationListener<UserScrollNotification>(
        onNotification: (_) {
          _userScroll = DateTime.now();
          return false;
        },
        child: ShaderMask(
          shaderCallback: (r) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
            stops: [0, .15, .8, 1],
          ).createShader(r),
          blendMode: BlendMode.dstIn,
          child: ListView.builder(
            controller: _scroll,
            padding: EdgeInsets.symmetric(horizontal: 24, vertical: MediaQuery.of(context).size.height * .3),
            itemCount: l.synced.length,
            itemBuilder: (context, i) {
              final line = l.synced[i];
              final on = i == _idx;
              return InkWell(
                key: _keys.putIfAbsent(i, () => GlobalKey()),
                borderRadius: BorderRadius.circular(8),
                onTap: () => audio.seek(Duration(milliseconds: (line.time * 1000).round() + 50)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 250),
                    style: TextStyle(
                      fontSize: line.text.isEmpty ? 16 : 24,
                      height: 1.3,
                      fontWeight: FontWeight.w700,
                      color: on ? Colors.white : Colors.white30,
                    ),
                    child: Text(line.text.isEmpty ? '♪' : line.text),
                  ),
                ),
              );
            },
          ),
        ),
      );
    } else {
      body = SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Text(l.plain, style: const TextStyle(fontSize: 17, height: 1.7, color: Color(0xFFD6DBE3))),
      );
    }
    final src = l == null || l.empty
        ? ''
        : '${l.source == 'lrclib' ? 'Lyrics from LRCLIB' : l.source == 'file' ? 'Lyrics from a .lrc file' : 'Lyrics from the file'}${l.synced.isNotEmpty ? ' · synced' : ''}';
    return Scaffold(
      backgroundColor: const Color(0xFF0E1116),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: t == null
            ? const Text('Lyrics')
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.title.isNotEmpty ? t.title : t.name, style: const TextStyle(fontSize: 16)),
                Text(t.artist, style: const TextStyle(fontSize: 12, color: Color(0xFF8B95A5))),
              ]),
        actions: [
          IconButton(icon: Icon(audio.playing ? Icons.pause : Icons.play_arrow), onPressed: audio.toggle),
          IconButton(icon: const Icon(Icons.skip_next), onPressed: audio.next),
        ],
      ),
      body: Column(children: [
        Expanded(child: body),
        if (src.isNotEmpty) Padding(padding: const EdgeInsets.all(8), child: Text(src, style: const TextStyle(fontSize: 11, color: Color(0xFF6F7988)))),
      ]),
    );
  }
}
