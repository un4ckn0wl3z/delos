import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../api.dart';
import '../settings.dart';
import '../social.dart';
import '../util.dart';
import '../widgets.dart';
import 'store.dart';

bool _isImageSub(SubtitleTrack t) {
  final c = (t.codec ?? '').toLowerCase();
  return c.contains('pgs') || c.contains('dvd') || c.contains('dvb') || c.contains('vobsub') || c.contains('xsub');
}

/// Plays a file on this device (downloaded from a server, or from the user's own folder),
/// with the same controls as the streaming player. Shows a LOCAL badge; saves the position
/// locally and — for server downloads — to the server too when it's reachable.
class LocalPlayerScreen extends StatefulWidget {
  const LocalPlayerScreen({super.key, required this.item, this.startOver = false, this.api, this.settings});
  final OfflineItem item;
  final bool startOver;
  final Api? api;
  final Settings? settings;
  @override
  State<LocalPlayerScreen> createState() => _LocalPlayerScreenState();
}

class _LocalPlayerScreenState extends State<LocalPlayerScreen> {
  late final Player _player = Player(configuration: PlayerConfiguration(title: widget.item.label));
  late final VideoController _video = VideoController(_player);
  final _subs = <StreamSubscription>[];
  OfflineItem get it => widget.item;

  final bool _desktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  bool _controls = true;
  Timer? _hideTimer, _saveTimer, _flashTimer, _lockTimer;
  bool _locked = false, _lockHint = false;
  double? _drag; // slider value while dragging
  String? _flash; // "−10s" / "+10s"
  bool _flashLeft = false;
  double _tapX = 0;
  BoxFit _fit = BoxFit.contain;
  bool _fullscreen = false;
  double _subDelay = 0;
  final _focus = FocusNode();

  double get _duration => _player.state.duration.inMilliseconds / 1000;
  double get _position => _player.state.position.inMilliseconds / 1000;
  double get _subScale => widget.settings?.subScale ?? 1.0;

  // ------------------------------------------------------------------ lifecycle

  @override
  void initState() {
    super.initState();
    if (!_desktop) {
      FocusManager.instance.primaryFocus?.unfocus();
      SystemChannels.textInput.invokeMethod('TextInput.hide');
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    }
    _subs.addAll([
      _player.stream.position.listen((_) {
        if (mounted && _drag == null) setState(() {});
      }),
      _player.stream.duration.listen((_) {
        if (mounted) setState(() {});
      }),
      _player.stream.playing.listen((playing) {
        if (!mounted) return;
        if (NowWatching.activity != null) {
          NowWatching.activity!['playing'] = playing;
          NowWatching.activity!['pos'] = _position.round();
          NowWatching.onChange?.call();
        }
        setState(() {});
        if (playing) {
          _scheduleHide();
        } else {
          _showControls(autoHide: false);
          _savePos();
        }
      }),
      _player.stream.buffering.listen((_) {
        if (mounted) setState(() {});
      }),
      _player.stream.error.listen((e) {
        if (mounted && e.isNotEmpty) _toast('Playback error: $e');
      }),
    ]);
    _start();
    _saveTimer = Timer.periodic(const Duration(seconds: 10), (_) => _savePos());
  }

  Future<void> _mpv(String k, String v) async {
    final p = _player.platform;
    if (p is NativePlayer) {
      try {
        await p.setProperty(k, v);
      } catch (_) {}
    }
  }

  Future<void> _start() async {
    if (!File(it.file).existsSync()) {
      if (mounted) {
        _toast('The file is no longer on this device');
        Navigator.pop(context);
      }
      return;
    }
    if (Platform.isAndroid) {
      await _mpv('ao', 'audiotrack,opensles');
      await _mpv('audio-buffer', '0.5');
    }
    if (widget.settings?.stereoDownmix ?? true) await _mpv('audio-channels', 'stereo');
    final start = widget.startOver ? 0.0 : it.pos;
    await _player.open(Media(it.file, start: start > 5 ? Duration(milliseconds: (start * 1000).round()) : null));
    if (start > 5 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Resumed at ${fmtTime(start)}'),
        action: SnackBarAction(label: 'Start over', onPressed: () => _player.seek(Duration.zero)),
      ));
    }
    NowWatching.set({
      'kind': 'video',
      if (it.isServer) 'path': it.serverPath,
      'title': it.kind == 'episode' ? it.show : (it.title.isNotEmpty ? it.title : it.name),
      'sub': [if (it.kind == 'episode') 'S${it.season}E${it.episode}', 'offline'].join(' · '),
      'playing': true,
    });
  }

  void _savePos() {
    final pos = _position, dur = _duration;
    if (dur <= 0 || pos < 10) return;
    OfflineStore.instance.setPos(it, pos, dur);
    // keep the server's "continue watching" in step for downloaded files
    if (it.isServer && widget.api != null && widget.api!.settings.server == it.server) {
      widget.api!.saveProgress(it.serverPath, pos: pos > dur - 120 ? 0 : pos, duration: dur, done: pos > dur - 120).catchError((_) {});
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    _flashTimer?.cancel();
    _lockTimer?.cancel();
    _savePos();
    for (final s in _subs) {
      s.cancel();
    }
    if (NowWatching.activity?['title'] != null) NowWatching.set(null);
    _player.dispose();
    _focus.dispose();
    if (_fullscreen) defaultExitNativeFullscreen();
    if (!_desktop) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations([]);
    }
    super.dispose();
  }

  // ------------------------------------------------------------------ playback

  void _togglePlay() {
    _player.playOrPause();
    _showControls();
  }

  void _seekTo(double t) {
    final d = _duration;
    final v = t.clamp(0.0, d > 0 ? d : t).toDouble();
    _player.seek(Duration(milliseconds: (v * 1000).round()));
  }

  void _seekBy(double d) => _seekTo(_position + d);

  Future<void> _toggleFullscreen() async {
    if (!_desktop) return;
    _fullscreen = !_fullscreen;
    await (_fullscreen ? defaultEnterNativeFullscreen() : defaultExitNativeFullscreen());
    if (mounted) setState(() {});
  }

  Future<void> _setSubDelay(double d) async {
    _subDelay = double.parse(d.toStringAsFixed(1));
    await _mpv('sub-delay', _subDelay.toString());
    if (mounted) setState(() {});
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
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
      LogicalKeyboardKey.keyZ: () => _setSubDelay(_subDelay - .1).then((_) => _toast('Subtitle delay ${_subDelay.toStringAsFixed(1)}s')),
      LogicalKeyboardKey.keyX: () => _setSubDelay(_subDelay + .1).then((_) => _toast('Subtitle delay ${_subDelay.toStringAsFixed(1)}s')),
      LogicalKeyboardKey.escape: () => _fullscreen ? _toggleFullscreen() : Navigator.maybePop(context),
    };
    final h = handlers[e.logicalKey];
    if (h == null) return KeyEventResult.ignored;
    h();
    _showControls();
    return KeyEventResult.handled;
  }

  // ------------------------------------------------------------------ controls visibility

  void _showControls({bool autoHide = true}) {
    if (_locked) return;
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

  void _lock() {
    _hideTimer?.cancel();
    setState(() {
      _locked = true;
      _controls = false;
    });
    _toast('Screen locked — tap the screen, then 🔒 to unlock');
  }

  void _unlock() {
    _lockTimer?.cancel();
    setState(() {
      _locked = false;
      _lockHint = false;
    });
    _showControls();
  }

  void _pokeLock() {
    _lockTimer?.cancel();
    setState(() => _lockHint = true);
    _lockTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _lockHint = false);
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

  String _trackName(String? title, String? lang, String id) {
    final s = [title ?? '', lang ?? ''].where((e) => e.isNotEmpty).join(' · ');
    return s.isEmpty ? 'Track $id' : s;
  }

  void _audioSheet() {
    final t = _player.state.tracks.audio.where((x) => x.id != 'auto' && x.id != 'no').toList();
    final cur = _player.state.track.audio.id;
    _sheet((_) => ListView(shrinkWrap: true, children: [
          const _SheetTitle('Audio'),
          if (t.isEmpty) const ListTile(title: Text('No audio tracks')),
          for (final x in t)
            ListTile(
              leading: Icon(x.id == cur ? Icons.radio_button_checked : Icons.radio_button_off),
              title: Text(_trackName(x.title, x.language, x.id)),
              subtitle: Text([x.codec ?? '', if ((x.channelscount ?? 0) > 0) '${x.channelscount} ch'].where((e) => e.isNotEmpty).join(' · ')),
              onTap: () {
                Navigator.pop(context);
                _player.setAudioTrack(x);
              },
            ),
        ]));
  }

  void _subSheet() {
    final t = _player.state.tracks.subtitle.where((x) => x.id != 'auto' && x.id != 'no').toList();
    final cur = _player.state.track.subtitle.id;
    _sheet((_) => ListView(shrinkWrap: true, children: [
          const _SheetTitle('Subtitles'),
          ListTile(
            leading: Icon(cur == 'no' ? Icons.radio_button_checked : Icons.radio_button_off),
            title: const Text('Off'),
            onTap: () {
              Navigator.pop(context);
              _player.setSubtitleTrack(SubtitleTrack.no());
              setState(() {});
            },
          ),
          for (final x in t)
            ListTile(
              leading: Icon(x.id == cur ? Icons.radio_button_checked : Icons.radio_button_off),
              title: Text(_trackName(x.title, x.language, x.id)),
              subtitle: (x.codec ?? '').isEmpty ? null : Text(x.codec!),
              onTap: () async {
                Navigator.pop(context);
                await _player.setSubtitleTrack(x);
                // text subs are drawn by Flutter (any font, Thai included); image subs (PGS) by mpv
                await _mpv('sub-visibility', _isImageSub(x) ? 'yes' : 'no');
                if (mounted) setState(() {});
              },
            ),
        ]));
  }

  void _tuneSheet() {
    _sheet((setSheet) => ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 12), children: [
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
              child: Text('${_subDelay > 0 ? '+' : ''}${_subDelay.toStringAsFixed(1)}s', textAlign: TextAlign.center, style: const TextStyle(fontSize: 18)),
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
          if (widget.settings != null) ...[
            const _SheetTitle('Subtitle size'),
            Slider(
              value: _subScale,
              min: .6,
              max: 2,
              divisions: 14,
              label: '${(_subScale * 100).round()}%',
              onChanged: (v) {
                widget.settings!.subScale = v;
                setSheet(() {});
                setState(() {});
              },
            ),
          ],
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
    return PopScope(
      canPop: !_locked,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _locked) _pokeLock();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: false,
        body: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: MouseRegion(
            cursor: _controls || !_player.state.playing ? SystemMouseCursors.basic : SystemMouseCursors.none,
            onHover: (_) => _showControls(),
            child: MediaQuery.removeViewInsets(
              context: context,
              removeBottom: true,
              child: LayoutBuilder(builder: (context, box) => _stack(box)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _stack(BoxConstraints box) {
    final title = it.kind == 'episode' ? it.label : (it.title.isNotEmpty ? it.title : it.name);
    final dur = _duration;
    final double pos = (_drag ?? _position).clamp(0.0, dur > 0 ? dur : 0.0).toDouble();
    final playing = _player.state.playing;
    final buffering = _player.state.buffering;
    final subOff = _player.state.track.subtitle.id == 'no';

    return Stack(fit: StackFit.expand, children: [
      Video(
        controller: _video,
        controls: NoVideoControls,
        fit: _fit,
        subtitleViewConfiguration: SubtitleViewConfiguration(
          textScaler: const TextScaler.linear(1),
          style: TextStyle(
            fontSize: 22 * _subScale,
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
        onTap: () => _locked ? _pokeLock() : (_controls ? setState(() => _controls = false) : _showControls()),
        onDoubleTapDown: _locked ? null : (d) => _tapX = d.localPosition.dx,
        onDoubleTap: _locked ? null : () => _onDoubleTap(box.maxWidth),
        onLongPress: _locked ? _pokeLock : null,
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
        ignoring: !_controls || _locked,
        child: AnimatedOpacity(
          opacity: _controls && !_locked ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // top bar
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black87, Colors.transparent]),
              ),
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
              child: SafeArea(
                bottom: false,
                child: Row(children: [
                  IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.pop(context)),
                  Expanded(
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 15)),
                      const SizedBox(height: 3),
                      SourceBadge(local: true, text: it.isServer ? 'LOCAL · downloaded' : 'LOCAL · my folder'),
                    ]),
                  ),
                  if (!_desktop) IconButton(tooltip: 'Lock screen', icon: const Icon(Icons.lock_open, color: Colors.white), onPressed: _lock),
                  IconButton(tooltip: 'Audio', icon: const Icon(Icons.audiotrack, color: Colors.white), onPressed: _audioSheet),
                  IconButton(
                      tooltip: 'Subtitles',
                      icon: Icon(subOff ? Icons.closed_caption_disabled_outlined : Icons.closed_caption, color: Colors.white),
                      onPressed: _subSheet),
                  IconButton(tooltip: 'Settings', icon: const Icon(Icons.tune, color: Colors.white), onPressed: _tuneSheet),
                  if (_desktop)
                    IconButton(
                        tooltip: 'Fullscreen (F)',
                        icon: Icon(_fullscreen ? Icons.fullscreen_exit : Icons.fullscreen, color: Colors.white),
                        onPressed: _toggleFullscreen),
                ]),
              ),
            ),
            // center buttons
            Expanded(
              child: Center(
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
            ),
            // bottom bar: time · seek bar · length, side by side (never on top of each other)
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.black87, Colors.transparent]),
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
          ]),
        ),
      ),
      if (_locked)
        Align(
          alignment: const Alignment(-.85, 0),
          child: IgnorePointer(
            ignoring: !_lockHint,
            child: AnimatedOpacity(
              opacity: _lockHint ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: Material(
                color: Colors.black54,
                shape: const CircleBorder(),
                child: IconButton(
                  iconSize: 36,
                  padding: const EdgeInsets.all(14),
                  tooltip: 'Unlock',
                  icon: const Icon(Icons.lock, color: Colors.white),
                  onPressed: _unlock,
                ),
              ),
            ),
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
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );
}
