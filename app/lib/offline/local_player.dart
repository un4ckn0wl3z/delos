import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../api.dart';
import '../settings.dart';
import '../social.dart';
import '../widgets.dart';
import 'store.dart';

bool _isImageSub(SubtitleTrack t) {
  final c = (t.codec ?? '').toLowerCase();
  return c.contains('pgs') || c.contains('dvd') || c.contains('dvb') || c.contains('vobsub') || c.contains('xsub');
}

/// Plays a file on this device (downloaded from a server, or from the user's
/// own folder). Shows a LOCAL badge; saves the position locally and — for
/// server downloads — to the server too when it's reachable.
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
  Timer? _save;
  bool get _mobile => Platform.isAndroid || Platform.isIOS;
  OfflineItem get it => widget.item;

  @override
  void initState() {
    super.initState();
    if (_mobile) SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _subs.add(_player.stream.error.listen((e) {
      if (mounted && e.isNotEmpty) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Playback error: $e')));
    }));
    _start();
    _save = Timer.periodic(const Duration(seconds: 10), (_) => _savePos());
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('The file is no longer on this device')));
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
    NowWatching.set({
      'kind': 'video',
      if (it.isServer) 'path': it.serverPath,
      'title': it.kind == 'episode' ? it.show : (it.title.isNotEmpty ? it.title : it.name),
      'sub': [if (it.kind == 'episode') 'S${it.season}E${it.episode}', 'offline'].join(' · '),
    });
  }

  void _savePos() {
    final pos = _player.state.position.inMilliseconds / 1000;
    final dur = _player.state.duration.inMilliseconds / 1000;
    if (dur <= 0 || pos < 10) return;
    OfflineStore.instance.setPos(it, pos, dur);
    // keep the server's "continue watching" in step for downloaded files
    if (it.isServer && widget.api != null && widget.api!.settings.server == it.server) {
      widget.api!.saveProgress(it.serverPath, pos: pos > dur - 120 ? 0 : pos, duration: dur, done: pos > dur - 120).catchError((_) {});
    }
  }

  @override
  void dispose() {
    _save?.cancel();
    _savePos();
    for (final s in _subs) {
      s.cancel();
    }
    if (NowWatching.activity?['title'] != null) NowWatching.set(null);
    _player.dispose();
    if (_mobile) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  String get _badgeText => it.isServer ? 'LOCAL · downloaded' : 'LOCAL · my folder';

  Future<void> _tracks(bool audio) async {
    final t = _player.state.tracks;
    final cur = _player.state.track;
    String name(String? title, String? lang, String id) {
      final s = [title ?? '', lang ?? ''].where((e) => e.isNotEmpty).join(' · ');
      return s.isEmpty ? 'Track $id' : s;
    }

    // (id, label, detail, select)
    final list = <(String, String, String, Future<void> Function())>[
      if (audio)
        for (final x in t.audio.where((x) => x.id != 'auto' && x.id != 'no'))
          (x.id, name(x.title, x.language, x.id), [x.codec ?? '', if ((x.channelscount ?? 0) > 0) '${x.channelscount} ch'].where((e) => e.isNotEmpty).join(' · '), () => _player.setAudioTrack(x))
      else
        for (final x in t.subtitle.where((x) => x.id != 'auto' && x.id != 'no'))
          (x.id, name(x.title, x.language, x.id), x.codec ?? '', () async {
            await _player.setSubtitleTrack(x);
            // text subs are drawn by Flutter (any font, Thai included); image subs (PGS) by mpv
            await _mpv('sub-visibility', _isImageSub(x) ? 'yes' : 'no');
          }),
    ];
    final curId = audio ? cur.audio.id : cur.subtitle.id;
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text(audio ? 'Audio' : 'Subtitles', style: Theme.of(ctx).textTheme.titleMedium)),
          if (!audio)
            ListTile(
              leading: Icon(cur.subtitle.id == 'no' ? Icons.radio_button_checked : Icons.radio_button_off),
              title: const Text('Off'),
              onTap: () async {
                Navigator.pop(ctx);
                await _player.setSubtitleTrack(SubtitleTrack.no());
              },
            ),
          for (final (id, label, detail, select) in list)
            ListTile(
              leading: Icon(curId == id ? Icons.radio_button_checked : Icons.radio_button_off),
              title: Text(label),
              subtitle: detail.isEmpty ? null : Text(detail),
              onTap: () async {
                Navigator.pop(ctx);
                await select();
              },
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = it.kind == 'episode' ? it.label : (it.title.isNotEmpty ? it.title : it.name);
    final top = <Widget>[
      IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.pop(context)),
      Expanded(
        child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 15)),
      ),
      SourceBadge(local: true, text: _badgeText),
      IconButton(tooltip: 'Audio', icon: const Icon(Icons.audiotrack, color: Colors.white), onPressed: () => _tracks(true)),
      IconButton(tooltip: 'Subtitles', icon: const Icon(Icons.subtitles_outlined, color: Colors.white), onPressed: () => _tracks(false)),
    ];
    final mobile = MaterialVideoControlsThemeData(topButtonBar: top, seekBarMargin: const EdgeInsets.fromLTRB(16, 0, 16, 24));
    final desktop = MaterialDesktopVideoControlsThemeData(topButtonBar: top);
    return Scaffold(
      backgroundColor: Colors.black,
      body: MaterialVideoControlsTheme(
        normal: mobile,
        fullscreen: mobile,
        child: MaterialDesktopVideoControlsTheme(
          normal: desktop,
          fullscreen: desktop,
          child: Video(
            controller: _video,
            controls: AdaptiveVideoControls,
            subtitleViewConfiguration: SubtitleViewConfiguration(
              style: TextStyle(
                fontSize: 40 * (widget.settings?.subScale ?? 1.0),
                color: Colors.white,
                shadows: const [Shadow(blurRadius: 4, color: Colors.black), Shadow(blurRadius: 8, color: Colors.black)],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
