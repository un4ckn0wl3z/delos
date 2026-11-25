import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../library.dart';
import '../remote.dart';
import '../widgets.dart';
import 'home_screen.dart';

IconData _deviceIcon(Map d) {
  final p = '${d['platform']} ${d['name']}'.toLowerCase();
  if (p.contains('tv') || p.contains('webos') || p.contains('tizen')) return Icons.tv;
  if (p.contains('android') || p.contains('ios') || p.contains('iphone')) return Icons.smartphone;
  if (d['kind'] == 'web') return Icons.language;
  return Icons.computer;
}

String _deviceSub(Map d) {
  final s = d['state'] as Map?;
  final kind = d['kind'] == 'web' ? 'Web' : 'App';
  if (s == null || s['idle'] == true || s['title'] == null) return '$kind · idle';
  return '$kind · ${s['playing'] == true ? '▶' : '⏸'} ${s['title']}';
}

/// Remote: pick one of your devices, then drive what it plays.
class RemoteScreen extends StatefulWidget {
  const RemoteScreen({super.key, required this.app});
  final AppCtx app;
  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> {
  RemoteController get rc => widget.app.remote!;
  Timer? _tick;
  double? _drag; // seek slider while dragging
  double? _vol;

  @override
  void initState() {
    super.initState();
    rc.addListener(_changed);
    rc.refresh();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _drag == null) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    rc.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _send(String cmd, [Map<String, dynamic> args = const {}]) async {
    if (cmd == 'nextEp' || cmd == 'home') HapticFeedback.selectionClick();
    try {
      await rc.send(cmd, args: args);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'.replaceFirst('Exception: ', ''))));
      rc.refresh();
    }
  }

  Future<void> _rename() async {
    final c = TextEditingController(text: rc.name);
    final n = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name of this device'),
        content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(hintText: 'e.g. Living room PC'), onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
        ],
      ),
    );
    if (n != null) await rc.rename(n);
  }

  @override
  Widget build(BuildContext context) {
    final t = rc.target;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Remote'),
        actions: [
          IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: rc.refresh),
          IconButton(tooltip: 'This device: ${rc.name}', icon: const Icon(Icons.badge_outlined), onPressed: _rename),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: rc.refresh,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
          Text('Your devices', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          if (rc.devices.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                rc.loading
                    ? 'Looking…'
                    : rc.error ?? 'No other device is online.\nOpen Delos (app or web page) on your PC or TV, signed in as you, and it shows up here.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          for (final d in rc.devices)
            Card(
              margin: const EdgeInsets.only(bottom: 6),
              color: d['id'] == rc.selected ? Theme.of(context).colorScheme.primaryContainer : null,
              child: ListTile(
                leading: Icon(_deviceIcon(d)),
                title: Text('${d['name']}'),
                subtitle: Text(_deviceSub(d), maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: d['id'] == rc.selected ? const Icon(Icons.check_circle) : null,
                onTap: () => rc.select('${d['id']}'),
              ),
            ),
          const SizedBox(height: 16),
          if (t != null) _controls(t),
        ]),
      ),
    );
  }

  List<Widget> _videoExtras(Map d, Map s) {
    final audios = (s['audios'] as List?) ?? const [];
    final subs = (s['subs'] as List?) ?? const [];
    final aSel = ((s['audioSel'] as num?) ?? 0).toInt();
    final sSel = ((s['subSel'] as num?) ?? -1).toInt();
    final delay = ((s['subDelay'] as num?) ?? 0).toDouble();
    final next = s['next'] as String?;
    final fs = s['fs'] == true;
    final cs = Theme.of(context).colorScheme;
    void local(String k, Object v) => rc.expect(d, {k: v}); // shows right away; the device confirms

    return [
      const Divider(height: 24),
      Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
        ActionChip(
          avatar: Icon(sSel < 0 ? Icons.closed_caption_disabled_outlined : Icons.closed_caption, size: 18),
          label: Text(sSel < 0 || sSel >= subs.length ? 'Subtitles: off' : 'Subs: ${_short('${subs[sSel]}')}'),
          onPressed: subs.isEmpty
              ? null
              : () async {
                  final i = await _pickTrack(context, 'Subtitles', subs, sSel, off: true);
                  if (i == null) return;
                  local('subSel', i);
                  _send('subs', {'index': i});
                },
        ),
        ActionChip(
          avatar: const Icon(Icons.audiotrack, size: 18),
          label: Text(aSel < audios.length ? 'Audio: ${_short('${audios[aSel]}')}' : 'Audio'),
          onPressed: audios.length < 2
              ? null
              : () async {
                  final i = await _pickTrack(context, 'Audio', audios, aSel);
                  if (i == null) return;
                  local('audioSel', i);
                  _send('audio', {'index': i});
                },
        ),
      ]),
      if (sSel >= 0)
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text('Subtitle delay', style: TextStyle(color: cs.onSurfaceVariant)),
          IconButton(
            tooltip: 'Earlier (−0.1 s)',
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: () {
              local('subDelay', ((delay - .1) * 10).round() / 10);
              _send('subDelay', {'by': -0.1});
            },
          ),
          GestureDetector(
            onDoubleTap: () {
              local('subDelay', 0.0);
              _send('subDelay');
            },
            child: SizedBox(
              width: 56,
              child: Text('${delay > 0 ? '+' : ''}${delay.toStringAsFixed(1)}s',
                  textAlign: TextAlign.center, style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
            ),
          ),
          IconButton(
            tooltip: 'Later (+0.1 s)',
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () {
              local('subDelay', ((delay + .1) * 10).round() / 10);
              _send('subDelay', {'by': 0.1});
            },
          ),
        ]),
      const SizedBox(height: 4),
      Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
        if (next != null)
          FilledButton.tonalIcon(icon: const Icon(Icons.skip_next), label: Text('Next: ${_short(next, 26)}'), onPressed: () => _send('nextEp')),
        OutlinedButton.icon(
          icon: Icon(fs ? Icons.fullscreen_exit : Icons.fullscreen),
          label: Text(fs ? 'Exit full screen' : 'Full screen'),
          onPressed: () {
            local('fs', !fs);
            _send('fullscreen');
          },
        ),
      ]),
    ];
  }

  Widget _controls(Map d) {
    final s = (d['state'] as Map?) ?? const {};
    final idle = s['idle'] == true || s['path'] == null;
    final music = s['kind'] == 'music';
    final playing = s['playing'] == true;
    final dur = ((s['dur'] as num?) ?? 0).toDouble();
    final pos = _drag ?? rc.positionOf(d);
    final vol = _vol ?? ((s['volume'] as num?) ?? 100).toDouble().clamp(0, 100).toDouble();
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(music ? Icons.music_note : Icons.movie_outlined, color: cs.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(idle ? 'Nothing playing on ${d['name']}' : '${s['title']}',
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium),
                if (!idle && '${s['sub'] ?? ''}'.isNotEmpty)
                  Text('${s['sub']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurfaceVariant)),
              ]),
            ),
          ]),
          if (idle)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text('Long-press a movie, episode or song and choose "Play on…" to start something there.',
                  style: TextStyle(color: cs.onSurfaceVariant)),
            ),
          if (!idle) ...[
            const SizedBox(height: 8),
            Slider(
              value: dur > 0 ? pos.clamp(0, dur).toDouble() : 0,
              max: dur > 0 ? dur : 1,
              onChanged: dur > 0 ? (v) => setState(() => _drag = v) : null,
              onChangeEnd: (v) {
                _send('seek', {'pos': v});
                // keep the dragged spot until the device reports back
                final st = d['state'] as Map?;
                if (st != null) {
                  st['pos'] = v;
                  d['_at'] = DateTime.now();
                }
                setState(() => _drag = null);
              },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: Row(children: [
                Text(fmtDur(pos), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
                const Spacer(),
                Text(dur > 0 ? fmtDur(dur) : '', style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
              ]),
            ),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              if (music) IconButton(tooltip: 'Previous', iconSize: 32, icon: const Icon(Icons.skip_previous), onPressed: () => _send('previous')),
              IconButton(tooltip: 'Back 10 s', iconSize: 32, icon: const Icon(Icons.replay_10), onPressed: () => _send('seekBy', {'by': -10})),
              IconButton.filled(
                tooltip: playing ? 'Pause' : 'Play',
                iconSize: 44,
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                onPressed: () {
                  rc.expect(d, {'playing': !playing}); // feels instant; the device confirms
                  _send(playing ? 'pause' : 'play');
                },
              ),
              IconButton(tooltip: 'Forward 30 s', iconSize: 32, icon: const Icon(Icons.forward_30), onPressed: () => _send('seekBy', {'by': 30})),
              if (music) IconButton(tooltip: 'Next', iconSize: 32, icon: const Icon(Icons.skip_next), onPressed: () => _send('next')),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              IconButton(
                tooltip: vol > 0 ? 'Mute' : 'Unmute',
                icon: Icon(vol == 0 ? Icons.volume_off : Icons.volume_up),
                onPressed: () {
                  rc.expect(d, {'volume': vol > 0 ? 0 : 100});
                  _send('volume', {'volume': vol > 0 ? 0 : 100});
                },
              ),
              Expanded(
                child: Slider(
                  value: vol,
                  max: 100,
                  divisions: 20,
                  label: '${vol.round()}%',
                  onChanged: (v) => setState(() => _vol = v),
                  onChangeEnd: (v) {
                    _send('volume', {'volume': v.round()});
                    rc.expect(d, {'volume': v.round()});
                    setState(() => _vol = null);
                  },
                ),
              ),
            ]),
            if (!music) ..._videoExtras(d, s),
            const SizedBox(height: 8),
            Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(icon: const Icon(Icons.stop), label: const Text('Stop'), onPressed: () => _send('stop')),
              OutlinedButton.icon(icon: const Icon(Icons.home_outlined), label: const Text('Home'), onPressed: () => _send('home')),
            ]),
          ],
          if (idle) ...[
            const SizedBox(height: 12),
            Center(child: OutlinedButton.icon(icon: const Icon(Icons.home_outlined), label: const Text('Home'), onPressed: () => _send('home'))),
          ],
        ]),
      ),
    );
  }
}

String _short(String s, [int n = 22]) => s.length > n ? '${s.substring(0, n - 1)}…' : s;

/// Lets the user pick one of [labels]; -1 = "Off" when [off] is set. Returns null when dismissed.
Future<int?> _pickTrack(BuildContext context, String title, List labels, int sel, {bool off = false}) {
  return showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * .7),
        child: ListView(shrinkWrap: true, children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text(title, style: Theme.of(ctx).textTheme.titleMedium)),
          if (off)
            ListTile(
              leading: Icon(sel < 0 ? Icons.radio_button_checked : Icons.radio_button_off),
              title: const Text('Off'),
              onTap: () => Navigator.pop(ctx, -1),
            ),
          for (var i = 0; i < labels.length; i++)
            ListTile(
              leading: Icon(i == sel ? Icons.radio_button_checked : Icons.radio_button_off),
              title: Text('${labels[i]}'),
              onTap: () => Navigator.pop(ctx, i),
            ),
        ]),
      ),
    ),
  );
}

/// "Play on…": pick one of your devices and start [it] there (then open the remote).
Future<void> playOnDevice(BuildContext context, AppCtx app, Item it) async {
  final rc = app.remote;
  if (rc == null) return;
  await rc.refresh();
  if (!context.mounted) return;
  final dev = await showModalBottomSheet<Map>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text('Play on…', style: Theme.of(ctx).textTheme.titleMedium),
        ),
        if (rc.devices.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Text('No other device is online. Open Delos on your PC or TV (app or web page), signed in as you.'),
          ),
        for (final d in rc.devices)
          ListTile(
            leading: Icon(_deviceIcon(d)),
            title: Text('${d['name']}'),
            subtitle: Text(_deviceSub(d), maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => Navigator.pop(ctx, d),
          ),
      ]),
    ),
  );
  if (dev == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await rc.send('open', device: '${dev['id']}', args: {'path': it.path, if (it.pos > 0) 'pos': it.pos});
    await rc.select('${dev['id']}');
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => RemoteScreen(app: app)));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e'.replaceFirst('Exception: ', ''))));
  }
}
