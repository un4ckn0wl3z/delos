import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import 'audio.dart';

/// Bridges [AudioController] to the OS media session: Android's media
/// notification + foreground service (keeps music playing in the background),
/// lock-screen / Bluetooth / headset buttons, iOS Now Playing.
class MusicSession extends BaseAudioHandler with QueueHandler, SeekHandler {
  MusicSession._();
  static MusicSession? _instance;
  static bool _starting = false;
  AudioController? _c;
  String? _lastPath;
  bool? _lastPlaying;
  int _lastIndex = -2;
  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);

  /// Why the media session couldn't start (shown in Settings → About).
  static String? error;

  static bool get supported => Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  /// Starts the service once per app run and points it at [c].
  static Future<void> attach(AudioController c) async {
    if (!supported) return;
    if (_instance == null && !_starting) {
      _starting = true;
      try {
        _instance = await AudioService.init(
          builder: MusicSession._,
          config: const AudioServiceConfig(
            androidNotificationChannelId: 'dev.un4ckn0wl3z.streammkv.music',
            androidNotificationChannelName: 'Music playback',
            androidNotificationOngoing: true,
            androidStopForegroundOnPause: true,
          ),
        );
      } catch (e) {
        // no media session on this device — music still plays in the foreground
        error = '$e';
        debugPrint('media session: $e');
      } finally {
        _starting = false;
      }
    }
    final s = _instance;
    if (s == null || identical(s._c, c)) return;
    s._c?.removeListener(s._sync);
    s._c = c;
    c.addListener(s._sync);
    s._sync();
  }

  void _sync() {
    final c = _c;
    if (c == null) return;
    final t = c.current;
    if (t == null) {
      if (_lastPath != null) {
        _lastPath = null;
        playbackState.add(PlaybackState(processingState: AudioProcessingState.idle, playing: false));
      }
      return;
    }
    if (t.path != _lastPath) {
      _lastPath = t.path;
      mediaItem.add(MediaItem(
        id: t.path,
        title: t.title.isNotEmpty ? t.title : t.name,
        artist: t.artist.isNotEmpty ? t.artist : null,
        album: t.album.isNotEmpty ? t.album : null,
        duration: t.duration > 0 ? Duration(milliseconds: (t.duration * 1000).round()) : null,
        artUri: t.cover.isNotEmpty ? Uri.parse(c.api.coverUrl(t.cover)) : null,
        artHeaders: c.api.authHeaders,
      ));
      queue.add([
        for (final q in c.queue) MediaItem(id: q.path, title: q.title.isNotEmpty ? q.title : q.name, artist: q.artist, album: q.album),
      ]);
    }
    if (c.duration > Duration.zero && mediaItem.value?.duration != c.duration && mediaItem.value?.id == t.path) {
      mediaItem.add(mediaItem.value!.copyWith(duration: c.duration));
    }
    // state changes right away; position only every few seconds (the OS interpolates)
    final now = DateTime.now();
    if (c.playing == _lastPlaying && c.index == _lastIndex && now.difference(_lastPush).inSeconds < 5) return;
    _lastPlaying = c.playing;
    _lastIndex = c.index;
    _lastPush = now;
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        c.playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      systemActions: const {MediaAction.seek, MediaAction.skipToQueueItem},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: AudioProcessingState.ready,
      playing: c.playing,
      updatePosition: c.position,
      speed: 1.0,
      queueIndex: c.index,
    ));
  }

  @override
  Future<void> play() async => _c?.player.play();
  @override
  Future<void> pause() async => _c?.pause();
  @override
  Future<void> stop() async {
    await _c?.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async => _c?.seek(position);
  @override
  Future<void> skipToNext() async => _c?.next();
  @override
  Future<void> skipToPrevious() async => _c?.previous();
  @override
  Future<void> skipToQueueItem(int index) async => _c?.jump(index);
}
