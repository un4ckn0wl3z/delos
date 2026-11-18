import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'api.dart';
import 'library.dart';
import 'widgets.dart';

enum RepeatMode { off, all, one }

/// Music playback: a queue played by its own mpv instance (plays every format,
/// including wma/ape/alac, straight from /api/raw).
class AudioController extends ChangeNotifier {
  AudioController(this.api) {
    if (Platform.isAndroid) {
      final p = player.platform;
      if (p is NativePlayer) {
        p.setProperty('ao', 'audiotrack,opensles').catchError((_) {});
        p.setProperty('audio-buffer', '0.5').catchError((_) {});
      }
    }
    _subs.addAll([
      player.stream.completed.listen((done) {
        if (done) _onCompleted();
      }),
      player.stream.playing.listen((_) => notifyListeners()),
      player.stream.position.listen((p) {
        position = p;
        _tick();
      }),
      player.stream.duration.listen((d) {
        duration = d;
        notifyListeners();
      }),
    ]);
  }

  final Api api;
  final player = Player(configuration: const PlayerConfiguration(title: 'StreamMKV music'));
  final _subs = <StreamSubscription>[];
  List<Item> queue = [];
  int index = -1;
  RepeatMode repeat = RepeatMode.off;
  Duration position = Duration.zero, duration = Duration.zero;
  DateTime _lastTick = DateTime.fromMillisecondsSinceEpoch(0);

  Item? get current => index >= 0 && index < queue.length ? queue[index] : null;
  bool get playing => player.state.playing;
  bool get active => current != null;

  void _tick() {
    final now = DateTime.now();
    if (now.difference(_lastTick).inMilliseconds > 400) {
      _lastTick = now;
      notifyListeners();
    }
  }

  Future<void> playQueue(List<Item> items, int start, {bool shuffled = false}) async {
    queue = List.of(items);
    if (shuffled) queue.shuffle(math.Random());
    index = shuffled ? 0 : start;
    await _load();
  }

  Future<void> _load() async {
    final t = current;
    if (t == null) return;
    await api.ensureSession();
    await player.open(Media(api.rawUrl(t.path)), play: true);
    notifyListeners();
  }

  void _onCompleted() {
    if (repeat == RepeatMode.one) {
      _load();
    } else if (index + 1 < queue.length) {
      index++;
      _load();
    } else if (repeat == RepeatMode.all && queue.isNotEmpty) {
      index = 0;
      _load();
    }
  }

  void next() {
    if (index + 1 < queue.length) {
      index++;
      _load();
    } else if (repeat == RepeatMode.all && queue.isNotEmpty) {
      index = 0;
      _load();
    }
  }

  void previous() {
    if (position.inSeconds > 4 || index == 0) {
      player.seek(Duration.zero);
    } else {
      index--;
      _load();
    }
  }

  void jump(int i) {
    index = i;
    _load();
  }

  void toggle() => player.playOrPause();
  void pause() => player.pause();
  void seek(Duration d) => player.seek(d);

  void cycleRepeat() {
    repeat = RepeatMode.values[(repeat.index + 1) % RepeatMode.values.length];
    notifyListeners();
  }

  Future<void> stop() async {
    await player.stop();
    queue = [];
    index = -1;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    player.dispose();
    super.dispose();
  }
}

/// Bottom bar shown while music is loaded.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.audio});
  final AudioController audio;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: audio,
        builder: (context, _) {
          final t = audio.current;
          if (t == null) return const SizedBox.shrink();
          final dur = audio.duration.inMilliseconds > 0 ? audio.duration : Duration(milliseconds: (t.duration * 1000).round());
          final p = dur.inMilliseconds > 0 ? audio.position.inMilliseconds / dur.inMilliseconds : 0.0;
          return Material(
            color: const Color(0xFF151A22),
            child: InkWell(
              onTap: () => showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                builder: (_) => NowPlaying(audio: audio),
              ),
              child: SafeArea(
                top: false,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  LinearProgressIndicator(value: p.clamp(0.0, 1.0).toDouble(), minHeight: 2),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                    child: Row(children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(5),
                        child: SizedBox(width: 44, height: 44, child: NetImage(audio.api.coverUrl(t.cover), headers: audio.api.authHeaders, placeholder: '♪')),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(t.title.isNotEmpty ? t.title : t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          Text([t.artist, t.album].where((e) => e.isNotEmpty).join(' · '),
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Color(0xFF8B95A5))),
                        ]),
                      ),
                      IconButton(icon: const Icon(Icons.skip_previous), onPressed: audio.previous),
                      IconButton(icon: Icon(audio.playing ? Icons.pause_circle_filled : Icons.play_circle_filled, size: 36), onPressed: audio.toggle),
                      IconButton(icon: const Icon(Icons.skip_next), onPressed: audio.next),
                    ]),
                  ),
                ]),
              ),
            ),
          );
        },
      );
}

/// Full-screen "now playing" sheet with seek bar and queue.
class NowPlaying extends StatelessWidget {
  const NowPlaying({super.key, required this.audio});
  final AudioController audio;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: audio,
        builder: (context, _) {
          final t = audio.current;
          if (t == null) return const SizedBox(height: 200, child: Center(child: Text('Nothing playing')));
          final dur = audio.duration.inMilliseconds > 0 ? audio.duration : Duration(milliseconds: (t.duration * 1000).round());
          final maxMs = math.max(1, dur.inMilliseconds).toDouble();
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: .92,
            minChildSize: .5,
            maxChildSize: 1,
            builder: (context, scroll) => ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(24, 8, 24, 24), children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: NetImage(audio.api.coverUrl(t.cover), headers: audio.api.authHeaders, placeholder: t.album),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(t.title.isNotEmpty ? t.title : t.name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
              Text([t.artist, t.album].where((e) => e.isNotEmpty).join(' · '), textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF8B95A5))),
              Slider(
                value: audio.position.inMilliseconds.clamp(0, maxMs.toInt()).toDouble(),
                max: maxMs,
                onChanged: (v) => audio.seek(Duration(milliseconds: v.round())),
              ),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text(fmtDur(audio.position.inMilliseconds / 1000), style: const TextStyle(fontSize: 12)),
                Text(fmtDur(dur.inMilliseconds / 1000), style: const TextStyle(fontSize: 12)),
              ]),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                IconButton(
                  icon: Icon(audio.repeat == RepeatMode.one ? Icons.repeat_one : Icons.repeat,
                      color: audio.repeat == RepeatMode.off ? Colors.white38 : Theme.of(context).colorScheme.primary),
                  onPressed: audio.cycleRepeat,
                ),
                IconButton(iconSize: 40, icon: const Icon(Icons.skip_previous), onPressed: audio.previous),
                IconButton(iconSize: 64, icon: Icon(audio.playing ? Icons.pause_circle_filled : Icons.play_circle_filled), onPressed: audio.toggle),
                IconButton(iconSize: 40, icon: const Icon(Icons.skip_next), onPressed: audio.next),
                IconButton(
                  icon: const Icon(Icons.stop_circle_outlined),
                  onPressed: () {
                    audio.stop();
                    Navigator.pop(context);
                  },
                ),
              ]),
              const Divider(height: 28),
              const Text('Queue', style: TextStyle(fontWeight: FontWeight.w600)),
              for (var i = 0; i < audio.queue.length; i++)
                ListTile(
                  dense: true,
                  selected: i == audio.index,
                  leading: Text('${i + 1}', style: const TextStyle(color: Color(0xFF7D8696))),
                  title: Text(audio.queue[i].title.isNotEmpty ? audio.queue[i].title : audio.queue[i].name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(audio.queue[i].artist, maxLines: 1),
                  onTap: () => audio.jump(i),
                ),
            ]),
          );
        },
      );
}
