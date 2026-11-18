import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../api.dart';
import '../models.dart';
import '../util.dart';

/// Two playback modes:
///  * direct    — mpv plays the original MKV over HTTP Range. All codecs, all embedded
///                audio/subtitle tracks (ASS, PGS…), native seeking. Needs bandwidth.
///  * transcode — server sends H.264/AAC fMP4 starting at [_offset]. Seeking re-opens the
///                stream; text subs are fetched as WebVTT, image subs are burned in.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.api, required this.file, this.nextLabel, this.onPlayNext, this.onProgress});
  final Api api;
  final MediaFile file;
  /// Next episode (TV): offered when this one ends.
  final String? nextLabel;
  final VoidCallback? onPlayNext;
  /// Called with the saved position so lists can update without reloading.
  final void Function(double pos)? onProgress;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player = Player(
    configuration: PlayerConfiguration(title: widget.file.name, bufferSize: 64 * 1024 * 1024),
  );
  late final VideoController _video = VideoController(_player);
  final _subs = <StreamSubscription>[];

  Api get api => widget.api;
  String get path => widget.file.path;

  ProbeInfo? _info;
  String? _error;

  bool _transcode = false;
  int _maxh = 720;
  double _offset = 0; // transcode: movie time at stream t=0
  int _audio = 0;
  int? _sub;
  double _subDelay = 0;
  bool _tracksApplied = false;
  final _vttCache = <int, String>{};

  bool _controls = true;
  Timer? _hideTimer, _saveTimer, _seekTimer, _flashTimer;
  double? _drag; // slider value while dragging
  double? _pendingSeek; // transcode: target while waiting to re-open
  String? _flash; // "−10s" / "+10s" indicator
  bool _flashLeft = false;
  double _tapX = 0;
  BoxFit _fit = BoxFit.contain;
  final bool _desktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  bool _fullscreen = false;
  final _focus = FocusNode();

  double get _duration {
    final d = _info?.duration ?? 0;
    return d > 0 ? d : _player.state.duration.inMilliseconds / 1000;
  }

  double get _position => _pendingSeek ?? (_offset + _player.state.position.inMilliseconds / 1000);

  // ------------------------------------------------------------------ lifecycle

  @override
  void initState() {
    super.initState();
    if (!_desktop) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    }
    _subs.addAll([
      _player.stream.position.listen((_) {
        if (mounted && _drag == null) setState(() {});
      }),
      _player.stream.playing.listen((playing) {
        if (!mounted) return;
        setState(() {});
        if (playing) {
          _scheduleHide();
        } else {
          _showControls(autoHide: false);
          _saveProgress();
        }
      }),
      _player.stream.buffering.listen((_) {
        if (mounted) setState(() {});
      }),
      _player.stream.tracks.listen(_onTracks),
      _player.stream.completed.listen((done) {
        if (!done || _info == null) return;
        if (_position > _duration - 120) {
          api.saveProgress(path, done: true);
          widget.onProgress?.call(0);
        }
        if (widget.nextLabel != null && widget.onPlayNext != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            duration: const Duration(seconds: 20),
            content: Text('Up next: ${widget.nextLabel}'),
            action: SnackBarAction(label: 'Play next', onPressed: () {
              final go = widget.onPlayNext!;
              Navigator.of(context).pop();
              go();
            }),
          ));
        }
      }),
      _player.stream.error.listen((e) {
        if (!mounted || e.isEmpty) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Playback error: $e')));
      }),
    ]);
    _init();
  }

  @override
  void dispose() {
    _saveProgress();
    for (final s in _subs) {
      s.cancel();
    }
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    _seekTimer?.cancel();
    _flashTimer?.cancel();
    _player.dispose();
    _focus.dispose();
    if (_desktop) {
      if (_fullscreen) defaultExitNativeFullscreen();
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations([]);
    }
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final s = api.settings;
      final results = await Future.wait([api.probe(path), api.progress(path)]);
      final info = results[0] as ProbeInfo;
      final prog = results[1] as Map<String, dynamic>;
      final pick = pickTracks(info, prog, s.audioLang, s.subLang);
      _info = info;
      _audio = pick.audio;
      _sub = pick.sub;
      _transcode = s.quality == 'transcode';
      _maxh = s.maxh;
      var start = (prog['pos'] as num?)?.toDouble() ?? 0;
      if (start < 30 || start > info.duration - 120) start = 0;

      await api.ensureSession(); // media URLs carry the token
      if (!mounted) return;
      setState(() {});
      await _open(start);
      _saveTimer = Timer.periodic(const Duration(seconds: 10), (_) => _saveProgress());
      if (start > 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Resumed at ${fmtTime(start)}'),
          action: SnackBarAction(label: 'Start over', onPressed: () => _seekTo(0)),
          duration: const Duration(seconds: 5),
        ));
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  // ------------------------------------------------------------------ mpv helpers

  Future<void> _mpv(String prop, String value) async {
    try {
      await (_player.platform as dynamic).setProperty(prop, value);
    } catch (_) {}
  }

  Future<void> _open(double start, {bool? play}) async {
    final autoplay = play ?? true;
    _seekTimer?.cancel();
    _tracksApplied = false;
    final info = _info!;
    if (!_transcode) {
      _offset = 0;
      _pendingSeek = null;
      await _player.open(
        Media(api.rawUrl(path), start: Duration(milliseconds: (start * 1000).round())),
        play: autoplay,
      );
    } else {
      final burn = _sub != null && !info.subs[_sub!].text ? _sub : null;
      _offset = start;
      _pendingSeek = null;
      await _player.open(
        Media(api.streamUrl(path, audio: _audio, start: start, maxh: _maxh, burn: burn)),
        play: autoplay,
      );
    }
    if (mounted) setState(() {});
  }

  /// Called whenever mpv reports tracks; apply our selection once per opened file.
  void _onTracks(Tracks t) {
    if (_tracksApplied || _info == null) return;
    if (t.video.where((v) => v.id != 'auto' && v.id != 'no').isEmpty) return; // not loaded yet
    _tracksApplied = true;
    _transcode ? _applyTranscodeSubs() : _applyDirectTracks();
  }

  Future<void> _applyDirectTracks() async {
    final t = _player.state.tracks;
    final a = t.audio.where((x) => x.id == '${_audio + 1}');
    if (a.isNotEmpty) await _player.setAudioTrack(a.first);
    await _applyDirectSub();
  }

  Future<void> _applyDirectSub() async {
    final info = _info!;
    if (_sub == null) {
      await _player.setSubtitleTrack(SubtitleTrack.no());
    } else {
      final s = _player.state.tracks.subtitle.where((x) => x.id == '${_sub! + 1}');
      if (s.isNotEmpty) await _player.setSubtitleTrack(s.first);
    }
    // Text subs are drawn by Flutter (any font incl. Thai); image subs (PGS/VobSub) by mpv.
    final image = _sub != null && !info.subs[_sub!].text;
    await _mpv('sub-visibility', image ? 'yes' : 'no');
    await _mpv('sub-delay', _subDelay.toStringAsFixed(3));
  }

  Future<void> _applyTranscodeSubs() async {
    final info = _info!;
    await _mpv('sub-visibility', 'no');
    if (_sub == null || !info.subs[_sub!].text) {
      await _player.setSubtitleTrack(SubtitleTrack.no());
      return;
    }
    final idx = _sub!;
    var vtt = _vttCache[idx];
    if (vtt == null) {
      _toast('Loading subtitles…');
      try {
        vtt = await api.subtitle(path, idx);
        _vttCache[idx] = vtt;
      } catch (e) {
        _toast('Subtitle error: $e');
        return;
      }
    }
    if (!mounted || _sub != idx || !_transcode) return;
    final s = info.subs[idx];
    await _player.setSubtitleTrack(SubtitleTrack.data(vtt, title: s.label, language: s.language));
    // stream t=0 is movie time _offset, cues are in movie time
    await _mpv('sub-delay', (_subDelay - _offset).toStringAsFixed(3));
  }

  // ------------------------------------------------------------------ actions

  void _togglePlay() {
    _player.playOrPause();
    _showControls();
  }

  void _seekTo(double t) {
    final d = _duration;
    t = t.clamp(0.0, math.max(0.0, d - 1)).toDouble();
    if (!_transcode) {
      _player.seek(Duration(milliseconds: (t * 1000).round()));
      return;
    }
    setState(() => _pendingSeek = t);
    _seekTimer?.cancel();
    _seekTimer = Timer(const Duration(milliseconds: 450), () => _open(t));
  }

  void _seekBy(double d) => _seekTo(_position + d);

  Future<void> _toggleFullscreen() async {
    if (!_desktop) return;
    _fullscreen = !_fullscreen;
    await (_fullscreen ? defaultEnterNativeFullscreen() : defaultExitNativeFullscreen());
    if (mounted) setState(() {});
  }

  void _cycleAudio() {
    final n = _info?.audio.length ?? 0;
    if (n < 2) return;
    _setAudio((_audio + 1) % n);
    _toast('Audio: ${_info!.audio[(_audio) % n].label}');
  }

  void _cycleSub() {
    final n = _info?.subs.length ?? 0;
    if (n == 0) return;
    final next = _sub == null ? 0 : (_sub! + 1 < n ? _sub! + 1 : null);
    _setSub(next);
    _toast(next == null ? 'Subtitles off' : 'Subtitles: ${_info!.subs[next].label}');
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    void vol(double d) {
      final v = (_player.state.volume + d).clamp(0.0, 100.0).toDouble();
      _player.setVolume(v);
      _toast('Volume ${v.round()}%');
    }

    final handlers = <LogicalKeyboardKey, VoidCallback>{
      LogicalKeyboardKey.space: _togglePlay,
      LogicalKeyboardKey.keyK: _togglePlay,
      LogicalKeyboardKey.mediaPlayPause: _togglePlay,
      LogicalKeyboardKey.arrowLeft: () => _seekBy(-10),
      LogicalKeyboardKey.arrowRight: () => _seekBy(10),
      LogicalKeyboardKey.keyJ: () => _seekBy(-30),
      LogicalKeyboardKey.keyL: () => _seekBy(30),
      LogicalKeyboardKey.arrowUp: () => vol(5),
      LogicalKeyboardKey.arrowDown: () => vol(-5),
      LogicalKeyboardKey.keyM: () => vol(_player.state.volume > 0 ? -100 : 100),
      LogicalKeyboardKey.keyF: _toggleFullscreen,
      LogicalKeyboardKey.keyA: _cycleAudio,
      LogicalKeyboardKey.keyC: _cycleSub,
      LogicalKeyboardKey.keyZ: () => _setSubDelay(_subDelay - .1).then((_) => _toast('Subtitle delay ${_subDelay.toStringAsFixed(1)}s')),
      LogicalKeyboardKey.keyX: () => _setSubDelay(_subDelay + .1).then((_) => _toast('Subtitle delay ${_subDelay.toStringAsFixed(1)}s')),
      LogicalKeyboardKey.escape: () => _fullscreen ? _toggleFullscreen() : Navigator.maybePop(context),
    };
    final h = handlers[k];
    if (h == null) return KeyEventResult.ignored;
    h();
    _showControls();
    return KeyEventResult.handled;
  }

  Future<void> _setAudio(int i) async {
    _audio = i;
    _saveTracks();
    if (_transcode) {
      await _open(_position, play: _player.state.playing);
    } else {
      final a = _player.state.tracks.audio.where((x) => x.id == '${i + 1}');
      if (a.isNotEmpty) await _player.setAudioTrack(a.first);
    }
    setState(() {});
  }

  Future<void> _setSub(int? i) async {
    final info = _info!;
    final wasImage = _sub != null && !info.subs[_sub!].text;
    _sub = i;
    _saveTracks();
    if (_transcode) {
      final isImage = i != null && !info.subs[i].text;
      if (wasImage || isImage) {
        await _open(_position, play: _player.state.playing); // burn-in changes the video
      } else {
        await _applyTranscodeSubs();
      }
    } else {
      await _applyDirectSub();
    }
    setState(() {});
  }

  Future<void> _setSubDelay(double d) async {
    _subDelay = double.parse(d.toStringAsFixed(1));
    await _mpv('sub-delay', (_subDelay - (_transcode ? _offset : 0)).toStringAsFixed(3));
    setState(() {});
  }

  Future<void> _setQuality(bool transcode, int maxh) async {
    if (transcode == _transcode && (!transcode || maxh == _maxh)) return;
    final pos = _position;
    _transcode = transcode;
    _maxh = maxh;
    await _open(pos, play: true);
  }

  void _saveTracks() => api.saveProgress(path, audio: _audio, sub: _sub ?? -1);

  void _saveProgress() {
    if (_info == null) return;
    final p = _position;
    if (p < 30) return;
    api.saveProgress(path, pos: p, duration: _duration, audio: _audio, sub: _sub ?? -1);
    widget.onProgress?.call(p > _duration - 120 ? 0 : p);
  }

  // ------------------------------------------------------------------ controls visibility

  void _showControls({bool autoHide = true}) {
    if (!_controls) setState(() => _controls = true);
    if (autoHide) {
      _scheduleHide();
    } else {
      _hideTimer?.cancel();
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _player.state.playing && _drag == null) setState(() => _controls = false);
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  void _onDoubleTap(double width) {
    final third = width / 3;
    if (_tapX < third) {
      _seekBy(-10);
      _showFlash('−10s', true);
    } else if (_tapX > width - third) {
      _seekBy(10);
      _showFlash('+10s', false);
    } else if (_desktop) {
      _toggleFullscreen();
    } else {
      _togglePlay();
    }
  }

  void _showFlash(String text, bool left) {
    _flashTimer?.cancel();
    setState(() {
      _flash = text;
      _flashLeft = left;
    });
    _flashTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _flash = null);
    });
  }

  // ------------------------------------------------------------------ sheets

  Future<void> _sheet(Widget Function(StateSetter setSheet) builder) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        constraints: BoxConstraints(maxWidth: 560, maxHeight: MediaQuery.of(context).size.height * .9),
        builder: (_) => StatefulBuilder(builder: (ctx, setSheet) => SafeArea(child: builder(setSheet))),
      ).whenComplete(() => _focus.requestFocus());

  void _audioSheet() {
    final info = _info!;
    _sheet((_) => ListView(shrinkWrap: true, children: [
          const _SheetTitle('Audio'),
          if (info.audio.isEmpty) const ListTile(title: Text('No audio tracks')),
          for (final a in info.audio)
            ListTile(
              leading: Icon(a.index == _audio ? Icons.radio_button_checked : Icons.radio_button_off),
              title: Text('${a.index + 1}. ${a.label}${a.isDefault ? '  ★' : ''}'),
              subtitle: Text(a.detail),
              onTap: () {
                Navigator.pop(context);
                _setAudio(a.index);
              },
            ),
        ]));
  }

  void _subSheet() {
    final info = _info!;
    _sheet((_) => ListView(shrinkWrap: true, children: [
          const _SheetTitle('Subtitles'),
          ListTile(
            leading: Icon(_sub == null ? Icons.radio_button_checked : Icons.radio_button_off),
            title: const Text('Off'),
            onTap: () {
              Navigator.pop(context);
              _setSub(null);
            },
          ),
          for (final s in info.subs)
            ListTile(
              leading: Icon(s.index == _sub ? Icons.radio_button_checked : Icons.radio_button_off),
              title: Text('${s.index + 1}. ${s.label}${s.isDefault ? '  ★' : ''}'),
              subtitle: Text(s.detail + (!s.text && _transcode ? ' (burned in on server)' : '')),
              onTap: () {
                Navigator.pop(context);
                _setSub(s.index);
              },
            ),
        ]));
  }

  void _tuneSheet() {
    _sheet((setSheet) => ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 12), children: [
          const _SheetTitle('Quality'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              ChoiceChip(
                label: const Text('Direct (original)'),
                selected: !_transcode,
                onSelected: (_) {
                  Navigator.pop(context);
                  _setQuality(false, _maxh);
                },
              ),
              for (final h in const [1080, 720, 480])
                ChoiceChip(
                  label: Text('Transcode ${h}p'),
                  selected: _transcode && _maxh == h,
                  onSelected: (_) {
                    Navigator.pop(context);
                    _setQuality(true, h);
                  },
                ),
            ]),
          ),
          const _SheetTitle('Subtitle delay'),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton.filledTonal(
                onPressed: () async {
                  await _setSubDelay(_subDelay - .1);
                  setSheet(() {});
                },
                icon: const Icon(Icons.remove)),
            SizedBox(
              width: 90,
              child: Text('${_subDelay > 0 ? '+' : ''}${_subDelay.toStringAsFixed(1)}s',
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 18)),
            ),
            IconButton.filledTonal(
                onPressed: () async {
                  await _setSubDelay(_subDelay + .1);
                  setSheet(() {});
                },
                icon: const Icon(Icons.add)),
            const SizedBox(width: 8),
            TextButton(
                onPressed: () async {
                  await _setSubDelay(0);
                  setSheet(() {});
                },
                child: const Text('Reset')),
          ]),
          const _SheetTitle('Subtitle size'),
          Slider(
            value: api.settings.subScale,
            min: .6,
            max: 2,
            divisions: 14,
            label: '${(api.settings.subScale * 100).round()}%',
            onChanged: (v) {
              api.settings.subScale = v;
              setSheet(() {});
              setState(() {});
            },
          ),
          const _SheetTitle('Volume'),
          Slider(
            value: _player.state.volume.clamp(0, 100).toDouble(),
            max: 100,
            divisions: 20,
            label: '${_player.state.volume.round()}%',
            onChanged: (v) {
              _player.setVolume(v);
              setSheet(() {});
            },
          ),
          const _SheetTitle('Video'),
          SwitchListTile(
            title: const Text('Fill screen (crop)'),
            value: _fit == BoxFit.cover,
            onChanged: (v) {
              setState(() => _fit = v ? BoxFit.cover : BoxFit.contain);
              setSheet(() {});
            },
          ),
        ]));
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _error != null
          ? _ErrorView(message: _error!, onBack: () => Navigator.pop(context))
          : _info == null
              ? const Center(child: CircularProgressIndicator())
              : Focus(
                  focusNode: _focus,
                  autofocus: true,
                  onKeyEvent: _onKey,
                  child: MouseRegion(
                    cursor: _controls || !_player.state.playing ? SystemMouseCursors.basic : SystemMouseCursors.none,
                    onHover: (_) => _showControls(),
                    child: LayoutBuilder(builder: (context, box) => _stack(box)),
                  ),
                ),
    );
  }

  Widget _stack(BoxConstraints box) {
    final scale = api.settings.subScale;
    final dur = _duration;
    final double pos = (_drag ?? _position).clamp(0.0, dur > 0 ? dur : 0.0).toDouble();
    final playing = _player.state.playing;
    final buffering = _player.state.buffering || _pendingSeek != null;

    return Stack(fit: StackFit.expand, children: [
      Video(
        controller: _video,
        controls: NoVideoControls,
        fit: _fit,
        subtitleViewConfiguration: SubtitleViewConfiguration(
          textScaler: const TextScaler.linear(1),
          style: TextStyle(
            fontSize: 22 * scale,
            height: 1.3,
            color: Colors.white,
            fontWeight: FontWeight.w500,
            backgroundColor: const Color(0x66000000),
            shadows: const [Shadow(blurRadius: 3, color: Colors.black), Shadow(blurRadius: 6, color: Colors.black)],
          ),
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
        ),
      ),
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _controls ? setState(() => _controls = false) : _showControls(),
        onDoubleTapDown: (d) => _tapX = d.localPosition.dx,
        onDoubleTap: () => _onDoubleTap(box.maxWidth),
      ),
      if (buffering) const Center(child: CircularProgressIndicator(color: Colors.white)),
      if (_flash != null)
        Align(
          alignment: _flashLeft ? const Alignment(-.6, 0) : const Alignment(.6, 0),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(24)),
            child: Text(_flash!, style: const TextStyle(fontSize: 18, color: Colors.white)),
          ),
        ),
      IgnorePointer(
        ignoring: !_controls,
        child: AnimatedOpacity(
          opacity: _controls ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: Stack(fit: StackFit.expand, children: [
            // top bar
            Align(
              alignment: Alignment.topCenter,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black87, Colors.transparent]),
                ),
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                child: SafeArea(
                  bottom: false,
                  child: Row(children: [
                    IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.pop(context)),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(widget.file.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 15)),
                        Text(_transcode ? 'Transcode ≤${_maxh}p' : 'Direct',
                            style: const TextStyle(color: Colors.white60, fontSize: 12)),
                      ]),
                    ),
                    IconButton(
                        tooltip: 'Audio',
                        icon: const Icon(Icons.audiotrack, color: Colors.white),
                        onPressed: _audioSheet),
                    IconButton(
                        tooltip: 'Subtitles',
                        icon: Icon(_sub == null ? Icons.closed_caption_disabled_outlined : Icons.closed_caption,
                            color: Colors.white),
                        onPressed: _subSheet),
                    IconButton(
                        tooltip: 'Settings',
                        icon: const Icon(Icons.tune, color: Colors.white),
                        onPressed: _tuneSheet),
                    if (_desktop)
                      IconButton(
                          tooltip: 'Fullscreen (F)',
                          icon: Icon(_fullscreen ? Icons.fullscreen_exit : Icons.fullscreen, color: Colors.white),
                          onPressed: _toggleFullscreen),
                  ]),
                ),
              ),
            ),
            // center buttons
            Center(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  iconSize: 40,
                  icon: const Icon(Icons.replay_10, color: Colors.white),
                  onPressed: () {
                    _seekBy(-10);
                    _showControls();
                  },
                ),
                const SizedBox(width: 28),
                if (!buffering)
                  IconButton(
                    iconSize: 64,
                    icon: Icon(playing ? Icons.pause_circle_filled : Icons.play_circle_filled, color: Colors.white),
                    onPressed: _togglePlay,
                  )
                else
                  const SizedBox(width: 80),
                const SizedBox(width: 28),
                IconButton(
                  iconSize: 40,
                  icon: const Icon(Icons.forward_10, color: Colors.white),
                  onPressed: () {
                    _seekBy(10);
                    _showControls();
                  },
                ),
              ]),
            ),
            // bottom bar
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black87, Colors.transparent]),
                ),
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                child: SafeArea(
                  top: false,
                  child: Row(children: [
                    Text(fmtTime(pos), style: const TextStyle(color: Colors.white, fontFeatures: [FontFeature.tabularFigures()])),
                    Expanded(
                      child: Slider(
                        value: pos,
                        max: dur > 0 ? dur : 1,
                        onChangeStart: (v) {
                          _hideTimer?.cancel();
                          setState(() => _drag = v);
                        },
                        onChanged: (v) => setState(() => _drag = v),
                        onChangeEnd: (v) {
                          setState(() => _drag = null);
                          _seekTo(v);
                          _scheduleHide();
                        },
                      ),
                    ),
                    Text(fmtTime(dur), style: const TextStyle(color: Colors.white70)),
                  ]),
                ),
              ),
            ),
          ]),
        ),
      ),
    ]);
  }
}

class _SheetTitle extends StatelessWidget {
  const _SheetTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onBack});
  final String message;
  final VoidCallback onBack;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, color: Colors.white54, size: 48),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
            const SizedBox(height: 16),
            FilledButton(onPressed: onBack, child: const Text('Back')),
          ]),
        ),
      );
}
