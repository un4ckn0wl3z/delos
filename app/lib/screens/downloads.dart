import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../util.dart';
import 'home_screen.dart';

/// Add HTTP / magnet downloads into a library and watch their progress.
class DownloadsView extends StatefulWidget {
  const DownloadsView({super.key, required this.app, this.preferMusic = false});
  final AppCtx app;
  final bool preferMusic;
  @override
  State<DownloadsView> createState() => _DownloadsViewState();
}

class _DownloadsViewState extends State<DownloadsView> {
  final _src = TextEditingController();
  final _sub = TextEditingController();
  Map? d;
  String? error, lib;
  List<String> dirs = [];
  bool busy = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _src.dispose();
    _sub.dispose();
    super.dispose();
  }

  List<Map> get _jobs => List<Map>.from(d?['jobs'] as List? ?? const []);
  List<Map> get _libs => List<Map>.from(d?['libraries'] as List? ?? const []);

  Future<void> _load() async {
    _timer?.cancel();
    try {
      final r = await widget.app.api.downloads();
      if (!mounted) return;
      setState(() {
        d = r;
        error = null;
        if (lib == null && _libs.isNotEmpty) {
          final pref = _libs.where((l) => (l['type'] == 'music') == widget.preferMusic);
          lib = '${(pref.isNotEmpty ? pref.first : _libs.first)['id']}';
          _loadDirs();
        }
      });
      if (_jobs.any((j) => j['state'] == 'queued' || j['state'] == 'downloading' || j['seeding'] == true)) {
        _timer = Timer(const Duration(seconds: 3), _load);
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => error = e.message);
    }
  }

  Future<void> _loadDirs() async {
    if (lib == null) return;
    try {
      final v = await widget.app.api.downloadDirs(lib!);
      if (mounted) setState(() => dirs = v);
    } catch (_) {}
  }

  Future<void> _add() async {
    final src = _src.text.trim();
    if (src.isEmpty || lib == null) return;
    FocusScope.of(context).unfocus();
    setState(() => busy = true);
    try {
      await widget.app.api.addDownload(src, lib!, _sub.text.trim());
      _src.clear();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Download added')));
      await _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _remove(Map j) async {
    final running = j['state'] == 'queued' || j['state'] == 'downloading';
    var files = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(running ? 'Cancel download?' : 'Remove download?'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${j['name'] ?? ''}'.isNotEmpty ? '${j['name']}' : '${j['source']}', maxLines: 3, overflow: TextOverflow.ellipsis),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: files,
              onChanged: (v) => set(() => files = v ?? false),
              title: Text(running ? 'Also delete what was downloaded so far' : 'Also delete the downloaded files'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(running ? 'Cancel download' : 'Remove')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await widget.app.api.deleteDownload('${j['id']}', files: files);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (d == null) {
      return Center(child: error != null ? Padding(padding: const EdgeInsets.all(24), child: Text(error!)) : const CircularProgressIndicator());
    }
    final t = Map.from(d!['torrent'] as Map? ?? const {});
    final names = {for (final l in _libs) '${l['id']}': '${l['name']}'};
    final me = widget.app;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
        TextField(
          controller: _src,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Link or magnet', hintText: 'https://…  or  magnet:?xt=…', border: OutlineInputBorder(), isDense: true),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              value: lib,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Library', border: OutlineInputBorder(), isDense: true),
              items: [for (final l in _libs) DropdownMenuItem(value: '${l['id']}', child: Text('${l['name']}', overflow: TextOverflow.ellipsis))],
              onChanged: (v) {
                setState(() => lib = v);
                _loadDirs();
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Autocomplete<String>(
              optionsBuilder: (v) => dirs.where((x) => x.toLowerCase().contains(v.text.toLowerCase())).take(30),
              onSelected: (v) => _sub.text = v,
              fieldViewBuilder: (ctx, ctl, focus, submit) {
                ctl.addListener(() => _sub.text = ctl.text);
                return TextField(
                  controller: ctl,
                  focusNode: focus,
                  decoration: const InputDecoration(labelText: 'Folder (optional)', border: OutlineInputBorder(), isDense: true),
                );
              },
            ),
          ),
        ]),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: busy ? null : _add,
          icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.download),
          label: const Text('Download'),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            t['ok'] == true ? 'Torrents and magnets go to rtorrent ${t['version'] ?? ''}' : 'Torrents unavailable: ${t['error'] ?? ''} — http(s) links still work',
            style: const TextStyle(fontSize: 12, color: Color(0xFF8B95A5)),
          ),
        ),
        const Divider(height: 28),
        if (_jobs.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Center(child: Text('No downloads yet'))),
        for (final j in _jobs) _job(j, names, me),
      ]),
    );
  }

  Widget _job(Map j, Map<String, String> names, AppCtx me) {
    final size = (j['size'] as num? ?? -1).toDouble();
    final done = (j['done'] as num? ?? 0).toDouble();
    final rate = (j['rate'] as num? ?? 0).toDouble();
    final state = '${j['state']}';
    final label = state == 'done' && j['seeding'] == true
        ? 'Seeding'
        : {'queued': 'Queued', 'downloading': 'Downloading', 'done': 'Done', 'failed': 'Failed', 'canceled': 'Canceled'}[state] ?? state;
    final color = state == 'failed' ? Colors.redAccent : state == 'done' ? const Color(0xFF3ECF8E) : Theme.of(context).colorScheme.primary;
    final mine = me.admin || j['user'] == me.api.settings.username;
    final name = '${j['name'] ?? ''}'.isNotEmpty ? '${j['name']}' : '${j['source']}';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(j['kind'] == 'torrent' ? Icons.hub_outlined : Icons.link, size: 18, color: const Color(0xFF8B95A5)),
            const SizedBox(width: 6),
            Expanded(child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
            if (mine && j['kind'] == 'http' && (state == 'failed' || state == 'canceled'))
              IconButton(tooltip: 'Retry', icon: const Icon(Icons.refresh), onPressed: () async {
                await me.api.retryDownload('${j['id']}');
                _load();
              }),
            if (mine) IconButton(tooltip: 'Remove', icon: const Icon(Icons.close), onPressed: () => _remove(j)),
          ]),
          Text('→ ${names['${j['lib']}'] ?? j['lib']}${'${j['subdir'] ?? ''}'.isNotEmpty ? ' / ${j['subdir']}' : ''} · ${j['user']}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF8B95A5))),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 8, 8, 6),
            child: LinearProgressIndicator(value: size > 0 ? (done / size).clamp(0.0, 1.0) : (state == 'downloading' ? null : 0), color: color, minHeight: 4),
          ),
          Text(
            [
              label,
              if (size > 0) '${fmtSize(done.round())} / ${fmtSize(size.round())}',
              if (rate > 0) '${fmtSize(rate.round())}/s',
              if ('${j['error'] ?? ''}'.isNotEmpty) '${j['error']}',
            ].join(' · '),
            style: TextStyle(fontSize: 12, color: state == 'failed' ? Colors.redAccent : const Color(0xFF9AA3B2)),
          ),
        ]),
      ),
    );
  }
}
