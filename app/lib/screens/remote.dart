import 'dart:async';

import 'package:flutter/material.dart';

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
                  (d['state'] as Map)['playing'] = !playing; // feels instant; the device confirms
                  (d['state'] as Map)['pos'] = rc.positionOf(d);
                  d['_at'] = DateTime.now();
                  setState(() {});
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
                onPressed: () => _send('volume', {'volume': vol > 0 ? 0 : 100}),
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
                    (d['state'] as Map)['volume'] = v.round();
                    setState(() => _vol = null);
                  },
                ),
              ),
            ]),
            Wrap(alignment: WrapAlignment.center, spacing: 8, children: [
              if (d['kind'] == 'web' && !music)
                OutlinedButton.icon(icon: const Icon(Icons.fullscreen), label: const Text('Full screen'), onPressed: () => _send('fullscreen')),
              OutlinedButton.icon(icon: const Icon(Icons.stop), label: const Text('Stop'), onPressed: () => _send('stop')),
            ]),
          ],
        ]),
      ),
    );
  }
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
