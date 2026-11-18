import 'dart:async';

import 'package:file_picker/file_picker.dart';
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
  Map? d, my;
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
      final m = await widget.app.api.myLibraries().catchError((_) => <String, dynamic>{});
      if (!mounted) return;
      setState(() {
        d = r;
        my = m;
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

  /// Pick a .torrent file from the device and upload it into the chosen library.
  Future<void> _pickTorrent() async {
    if (lib == null) return;
    FilePickerResult? r;
    try {
      // custom extensions aren't reliable for .torrent on Android, so pick any file and check
      r = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open files: $e')));
      return;
    }
    final f = r?.files.firstOrNull;
    if (f == null) return;
    final bytes = f.bytes;
    if (bytes == null || bytes.isEmpty || !f.name.toLowerCase().endsWith('.torrent') && bytes.first != 0x64 /* 'd' */) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Choose a .torrent file')));
      return;
    }
    if (bytes.length > 10 * 1024 * 1024) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That file is too big for a .torrent (max 10 MB)')));
      return;
    }
    setState(() => busy = true);
    try {
      await widget.app.api.addTorrentFile(f.name, bytes, lib!, _sub.text.trim());
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Added ${f.name}')));
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
              items: [
                for (final l in _libs)
                  DropdownMenuItem(
                    value: '${l['id']}',
                    child: Text('${l['name']}${'${l['owner'] ?? ''}'.isEmpty ? '' : l['owner'] == me.api.settings.username ? ' · mine' : ' · ${l['owner']}'}', overflow: TextOverflow.ellipsis),
                  ),
              ],
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
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: busy ? null : _add,
              icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.download),
              label: const Text('Download'),
            ),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(
            onPressed: busy ? null : _pickTorrent,
            icon: const Icon(Icons.attach_file),
            label: const Text('.torrent file'),
          ),
        ]),
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
        const Divider(height: 28),
        ..._myLibraries(),
      ]),
    );
  }

  // ---------------------------------------------------------------- my libraries
  List<Widget> _myLibraries() {
    final m = my;
    if (m == null || m['libraries'] == null) return const [];
    final libs = List<Map>.from(m['libraries'] as List);
    final u = Map.from(m['usage'] as Map? ?? const {});
    final maxItems = (m['maxItems'] as num? ?? 0).toInt(), maxBytes = (m['maxBytes'] as num? ?? 0).toInt();
    final api = widget.app.api;
    Future<void> run(Future<void> Function() f, String ok) async {
      try {
        await f();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok)));
        widget.app.repo.invalidate();
        await _load();
      } on ApiException catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }

    return [
      Row(children: [
        Text('My libraries', style: Theme.of(context).textTheme.titleMedium),
        const Spacer(),
        TextButton.icon(icon: const Icon(Icons.add), label: const Text('New'), onPressed: () => _createLibrary(run)),
      ]),
      Text(
        '${u['items'] ?? 0}${maxItems > 0 ? ' / $maxItems' : ''} items · ${fmtSize((u['bytes'] as num? ?? 0).toInt())}${maxBytes > 0 ? ' / ${fmtSize(maxBytes)}' : ''}',
        style: const TextStyle(fontSize: 12, color: Color(0xFF8B95A5)),
      ),
      if (maxBytes > 0 || maxItems > 0)
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 4),
          child: LinearProgressIndicator(
            minHeight: 4,
            value: [
              if (maxItems > 0) (u['items'] as num? ?? 0) / maxItems,
              if (maxBytes > 0) (u['bytes'] as num? ?? 0) / maxBytes,
            ].reduce((a, b) => a > b ? a : b).toDouble().clamp(0.0, 1.0),
          ),
        ),
      if (libs.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('Create a library to download into your own space. Private ones are only visible to you; shared ones are visible to everyone, labelled with your name.',
              style: TextStyle(color: Color(0xFF9AA3B2))),
        ),
      for (final l in libs)
        Card(
          margin: const EdgeInsets.only(top: 8),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${l['name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text('${{'movies': 'Movies', 'tv': 'TV series', 'music': 'Music'}[l['type']] ?? 'Videos'} · ${l['count']} items · ${fmtSize((l['size'] as num? ?? 0).toInt())}',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF8B95A5))),
                ]),
              ),
              const Text('Shared', style: TextStyle(fontSize: 12)),
              Switch(
                value: l['shared'] == true,
                onChanged: (v) => run(() => api.shareMyLibrary('${l['id']}', v), v ? 'Shared with everyone' : 'Now private'),
              ),
              IconButton(
                tooltip: 'Delete library',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  var files = false;
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => StatefulBuilder(
                      builder: (ctx, set) => AlertDialog(
                        title: Text('Delete “${l['name']}”?'),
                        content: CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: files,
                          onChanged: (v) => set(() => files = v ?? false),
                          title: Text('Also delete its ${l['count']} files (${fmtSize((l['size'] as num? ?? 0).toInt())}) from the server'),
                        ),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
                        ],
                      ),
                    ),
                  );
                  if (ok == true) run(() => api.deleteMyLibrary('${l['id']}', files: files), 'Library deleted');
                },
              ),
            ]),
          ),
        ),
    ];
  }

  Future<void> _createLibrary(Future<void> Function(Future<void> Function(), String) run) async {
    final name = TextEditingController();
    var type = 'movies';
    var shared = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('New library'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: type,
              decoration: const InputDecoration(labelText: 'Type'),
              items: const [
                DropdownMenuItem(value: 'movies', child: Text('Movies')),
                DropdownMenuItem(value: 'tv', child: Text('TV series')),
                DropdownMenuItem(value: 'music', child: Text('Music')),
                DropdownMenuItem(value: 'videos', child: Text('Other videos')),
              ],
              onChanged: (v) => set(() => type = v ?? 'movies'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: shared,
              onChanged: (v) => set(() => shared = v),
              title: const Text('Share with everyone'),
              subtitle: const Text('Others see it, labelled with your name'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create')),
          ],
        ),
      ),
    );
    final n = name.text.trim();
    name.dispose();
    if (ok == true && n.isNotEmpty) {
      lib = null; // pick the new library once the list reloads
      await run(() => widget.app.api.createMyLibrary(n, type, shared), 'Library created');
    }
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
