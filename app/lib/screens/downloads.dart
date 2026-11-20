import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../series.dart';
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
      if (_jobs.any((j) => j['state'] == 'queued' || j['state'] == 'downloading' || j['seeding'] == true || j['tstate'] == 'checking' || j['tstate'] == 'paused')) {
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

  /// Runs an add; if the server says it's a duplicate, asks and retries with force.
  Future<void> _withDupCheck(Future<void> Function(bool force) add) async {
    try {
      await add(false);
    } on ApiException catch (e) {
      if (e.status != 409) rethrow;
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Already have it?'),
          content: Text(e.message),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Download anyway')),
          ],
        ),
      );
      if (ok != true) throw const _Skipped();
      await add(true);
    }
  }

  Future<void> _add() async {
    final src = _src.text.trim();
    if (src.isEmpty || lib == null) return;
    FocusScope.of(context).unfocus();
    // a YouTube video that's part of a playlist: this video, or the whole playlist?
    var playlist = false;
    final u = Uri.tryParse(src);
    if (u != null && RegExp(r'(^|\.)(youtube\.com|youtu\.be)$').hasMatch(u.host) && (u.queryParameters['list'] ?? '').isNotEmpty && (u.queryParameters['v'] ?? '').isNotEmpty) {
      final pick = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('YouTube playlist'),
          content: const Text('This video is part of a playlist. Download just this video, or every video in the playlist?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('This video')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Whole playlist')),
          ],
        ),
      );
      if (pick == null) return;
      playlist = pick;
    }
    setState(() => busy = true);
    try {
      await _withDupCheck((force) => widget.app.api.addDownload(src, lib!, _sub.text.trim(), force: force, playlist: playlist));
      _src.clear();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Download added')));
      await _load();
    } on _Skipped {
      // user chose not to download a duplicate
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Pick .torrent files (one or several) from the device and upload them into the chosen library.
  Future<void> _pickTorrent() async {
    if (lib == null) return;
    final messenger = ScaffoldMessenger.of(context);
    FilePickerResult? r;
    try {
      // custom extensions aren't reliable for .torrent on Android, so pick any file and check
      r = await FilePicker.platform.pickFiles(type: FileType.any, withData: true, allowMultiple: true);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not open files: $e')));
      return;
    }
    final files = r?.files ?? const <PlatformFile>[];
    if (files.isEmpty) return;
    var added = 0;
    final failed = <String>[];
    setState(() => busy = true);
    try {
      for (final f in files) {
        final bytes = f.bytes;
        if (bytes == null || bytes.isEmpty || !f.name.toLowerCase().endsWith('.torrent') && bytes.first != 0x64 /* 'd' */) {
          failed.add('${f.name}: not a .torrent file');
          continue;
        }
        if (bytes.length > 10 * 1024 * 1024) {
          failed.add('${f.name}: too big for a .torrent (max 10 MB)');
          continue;
        }
        try {
          await _withDupCheck((force) => widget.app.api.addTorrentFile(f.name, bytes, lib!, _sub.text.trim(), force: force));
          added++;
        } on _Skipped {
          // not downloading this duplicate
        } on ApiException catch (e) {
          failed.add(files.length > 1 ? '${f.name}: ${e.message}' : e.message);
        }
      }
      if (failed.isNotEmpty) {
        messenger.showSnackBar(SnackBar(
            duration: const Duration(seconds: 8),
            content: Text('${added > 0 ? '$added added · ' : ''}${failed.length} failed — ${failed.take(3).join(' · ')}${failed.length > 3 ? ' …' : ''}')));
      } else if (added > 0) {
        messenger.showSnackBar(SnackBar(content: Text(added > 1 ? '$added torrents added' : 'Added ${files.first.name}')));
      }
      if (added > 0) await _load();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  // ---- episodes / seasons of the same series sit together under one fold-out
  final _open = <String>{};
  static const _bulk = {'pause': ['downloading', 'seeding'], 'resume': ['paused'], 'stop': ['seeding'], 'start': ['stopped', 'finished']};
  static const _bulkLabel = {'pause': 'Pause all', 'resume': 'Resume all', 'stop': 'Stop seeding all', 'start': 'Start all'};
  static const _bulkIcon = {'pause': Icons.pause, 'resume': Icons.play_arrow, 'stop': Icons.stop, 'start': Icons.play_arrow};

  bool _isTor(Map j) => j['kind'] == 'torrent' && '${j['hash'] ?? ''}'.isNotEmpty && '${j['tstate'] ?? ''}'.isNotEmpty && j['tstate'] != 'removed';

  Future<void> _bulkAction(List<Map> js, String a) async {
    final me = widget.app;
    final targets = js.where((j) => (me.admin || j['user'] == me.api.settings.username) && _isTor(j) && _bulk[a]!.contains(j['tstate'])).toList();
    final messenger = ScaffoldMessenger.of(context);
    var bad = 0;
    for (final j in targets) {
      try {
        await me.api.torrentAction('${j['id']}', a);
      } catch (_) {
        bad++;
      }
    }
    messenger.showSnackBar(SnackBar(content: Text(bad > 0 ? '${targets.length - bad} done, $bad failed' : '${targets.length} torrents: ${_bulkLabel[a]!.toLowerCase().replaceAll(' all', '')}')));
    _load();
  }

  Widget _group(String key, String title, List<Map> js, Map<String, String> names, AppCtx me) {
    num sum(String f) => js.fold<num>(0, (a, j) => a + (j[f] as num? ?? 0));
    final size = js.fold<num>(0, (a, j) => a + ((j['size'] as num? ?? 0) > 0 ? j['size'] as num : 0));
    final got = js.fold<num>(0, (a, j) {
      final sz = (j['size'] as num? ?? 0), dn = (j['done'] as num? ?? 0);
      return a + (sz > 0 ? (dn < sz ? dn : sz) : 0);
    });
    final counts = <String, int>{};
    for (final j in js) {
      final ts = '${j['tstate'] ?? ''}';
      final l = j['kind'] == 'torrent' && ts.isNotEmpty
          ? _tName[ts] ?? ts
          : {'queued': 'Queued', 'downloading': 'Downloading', 'done': 'Done', 'failed': 'Failed', 'canceled': 'Canceled'}['${j['state']}'] ?? '${j['state']}';
      counts[l] = (counts[l] ?? 0) + 1;
    }
    final mineTors = js.where((j) => (me.admin || j['user'] == me.api.settings.username) && _isTor(j)).toList();
    final actions = _bulk.keys.where((a) => mineTors.any((j) => _bulk[a]!.contains(j['tstate']))).toList();
    final failed = js.any((j) => j['state'] == 'failed'), allDone = js.every((j) => j['state'] == 'done');
    final rate = sum('rate'), up = sum('up');
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: PageStorageKey('dlg:$key'),
        initiallyExpanded: _open.contains(key),
        onExpansionChanged: (v) => v ? _open.add(key) : _open.remove(key),
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: const EdgeInsets.fromLTRB(14, 4, 8, 4),
        childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
        leading: const Icon(Icons.live_tv_outlined, color: Color(0xFF8B95A5)),
        title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            [
              '${js.length} downloads',
              if (size > 0) '${fmtSize(got.round())} / ${fmtSize(size.round())}',
              for (final e in counts.entries) '${e.value} ${e.key.toLowerCase()}',
              if (rate > 0) '↓ ${fmtSize(rate.round())}/s',
              if (up > 0) '↑ ${fmtSize(up.round())}/s',
            ].join(' · '),
            style: const TextStyle(fontSize: 12, color: Color(0xFF9AA3B2)),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: LinearProgressIndicator(
                value: size > 0 ? (got / size).clamp(0.0, 1.0).toDouble() : 0.0,
                minHeight: 4,
                color: failed ? Colors.redAccent : allDone ? const Color(0xFF3ECF8E) : Theme.of(context).colorScheme.primary),
          ),
          if (actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(spacing: 6, runSpacing: 4, children: [
                for (final a in actions)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 10)),
                    icon: Icon(_bulkIcon[a], size: 16),
                    label: Text(_bulkLabel[a]!, style: const TextStyle(fontSize: 12.5)),
                    onPressed: () => _bulkAction(js, a),
                  ),
              ]),
            ),
        ]),
        children: [for (final j in js) _job(j, names, me)],
      ),
    );
  }

  Future<void> _remove(Map j) async {
    final running = j['state'] == 'queued' || j['state'] == 'downloading';
    final torrent = j['kind'] == 'torrent';
    final files = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(running ? 'Cancel download?' : (torrent ? 'Remove torrent?' : 'Remove download?')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${j['name'] ?? ''}'.isNotEmpty ? '${j['name']}' : '${j['source']}', maxLines: 3, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.inventory_2_outlined),
            title: Text(torrent ? 'Remove the torrent only' : 'Remove from the list'),
            subtitle: Text(running ? 'Keep what was downloaded so far' : 'Keep the files${torrent ? ' — it stops seeding' : ''}'),
            onTap: () => Navigator.pop(ctx, false),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.delete_forever_outlined, color: Colors.redAccent),
            title: const Text('Remove and delete the files', style: TextStyle(color: Colors.redAccent)),
            subtitle: const Text("Can't be undone"),
            onTap: () => Navigator.pop(ctx, true),
          ),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
      ),
    );
    if (files == null) return;
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
        for (final g in groupBySeries<Map>(_jobs, (j) => '${j['name'] ?? ''}'))
          g.key == null ? _job(g.members.first, names, me) : _group(g.key!, g.title, g.members, names, me),
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

  static const _tName = {
    'checking': 'Checking',
    'downloading': 'Downloading',
    'seeding': 'Seeding',
    'paused': 'Paused',
    'stopped': 'Stopped',
    'finished': 'Finished (not seeding)',
    'removed': 'Removed from rtorrent',
  };

  static String _limit(num r, num h) {
    final p = [if (r > 0) 'ratio $r', if (h > 0) '$h h'];
    return p.isEmpty ? 'no limit' : p.join(' or ');
  }

  String _seedText(Map j) {
    final r = j['seedRatio'] as num? ?? 0, h = j['seedHours'] as num? ?? 0;
    if (r == -1 && h == -1) return 'seeds without limit';
    if (r != 0 || h != 0) return 'seed limit: ${_limit(r < 0 ? 0 : r, h < 0 ? 0 : h)}';
    return 'seed limit: server default';
  }

  Future<void> _torrent(Map j, String a) async {
    final api = widget.app.api, id = '${j['id']}';
    final messenger = ScaffoldMessenger.of(context);
    try {
      switch (a) {
        case 'remove':
          return _remove(j);
        case 'limit':
          return _seedLimit(j);
        case 'detail':
          final d = await api.torrentDetail(id);
          if (!mounted) return;
          await showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Trackers & files'),
              content: SizedBox(
                width: 480,
                child: ListView(shrinkWrap: true, children: [
                  for (final t in (d['trackers'] as List? ?? const []))
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.cell_tower, size: 20),
                      title: Text('${t['url']}', maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${t['seeds']} seeds · ${t['leechers']} leechers${(t['failed'] as num? ?? 0) > 0 ? ' · ${t['failed']} failed' : ''}'),
                    ),
                  const Divider(),
                  for (final f in (d['files'] as List? ?? const []))
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.insert_drive_file_outlined, size: 20),
                      title: Text('${f['path']}', maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${fmtSize((f['size'] as num? ?? 0).toInt())} · ${((f['progress'] as num? ?? 0) * 100).toStringAsFixed(0)}%'),
                    ),
                ]),
              ),
              actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
            ),
          );
          return;
        default:
          await api.torrentAction(id, a);
      }
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
    _load();
  }

  Future<void> _seedLimit(Map j) async {
    final r0 = j['seedRatio'] as num? ?? 0, h0 = j['seedHours'] as num? ?? 0;
    var mode = r0 == -1 && h0 == -1 ? 'none' : (r0 != 0 || h0 != 0 ? 'own' : 'def');
    final ratio = TextEditingController(text: r0 > 0 ? '$r0' : '');
    final hours = TextEditingController(text: h0 > 0 ? '$h0' : '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Seeding limit'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'def', label: Text('Default')),
                ButtonSegment(value: 'none', label: Text('No limit')),
                ButtonSegment(value: 'own', label: Text('Custom')),
              ],
              selected: {mode},
              onSelectionChanged: (v) => set(() => mode = v.first),
            ),
            if (mode == 'own') ...[
              const SizedBox(height: 12),
              TextField(controller: ratio, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Stop at ratio', hintText: 'e.g. 2')),
              TextField(controller: hours, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'or after hours seeding', hintText: 'e.g. 48')),
            ],
            const SizedBox(height: 8),
            const Text('When the limit is reached it stops seeding (or is removed, if the server is set that way). Starting it again by hand keeps it seeding.',
                style: TextStyle(fontSize: 12, color: Color(0xFF8B95A5))),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    final rs = ratio.text, hs = hours.text;
    ratio.dispose();
    hours.dispose();
    if (ok != true) return;
    double r = 0, h = 0;
    if (mode == 'none') {
      r = -1;
      h = -1;
    } else if (mode == 'own') {
      r = double.tryParse(rs.trim()) ?? -1;
      h = double.tryParse(hs.trim()) ?? -1;
      if (r <= 0) r = -1;
      if (h <= 0) h = -1;
    }
    try {
      await widget.app.api.torrentSeedLimit('${j['id']}', r, h);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
    _load();
  }

  Widget _job(Map j, Map<String, String> names, AppCtx me) {
    final size = (j['size'] as num? ?? -1).toDouble();
    final done = (j['done'] as num? ?? 0).toDouble();
    final rate = (j['rate'] as num? ?? 0).toDouble();
    final state = '${j['state']}';
    final tstate = '${j['tstate'] ?? ''}';
    final torrent = j['kind'] == 'torrent' && tstate.isNotEmpty;
    final live = torrent && '${j['hash'] ?? ''}'.isNotEmpty && tstate != 'removed';
    final label = torrent
        ? _tName[tstate] ?? tstate
        : {'queued': 'Queued', 'downloading': 'Downloading', 'done': 'Done', 'failed': 'Failed', 'canceled': 'Canceled'}[state] ?? state;
    final up = (j['up'] as num? ?? 0).toInt();
    final color = state == 'failed' ? Colors.redAccent : state == 'done' ? const Color(0xFF3ECF8E) : Theme.of(context).colorScheme.primary;
    final mine = me.admin || j['user'] == me.api.settings.username;
    final name = '${j['name'] ?? ''}'.isNotEmpty ? '${j['name']}' : '${j['source']}';
    final yt = j['kind'] == 'youtube';
    final items = (j['items'] as num? ?? 0).toInt();
    final itemIndex = (j['itemIndex'] as num? ?? 0).toInt();
    final itemsDone = (j['itemsDone'] as num? ?? 0).toInt();
    final frac = size > 0 ? (done / size).clamp(0.0, 1.0) : 0.0;
    final double? progress = yt
        ? (state == 'done'
            ? 1.0
            : items > 0
                ? (((itemIndex > 0 ? itemIndex : 1) - 1 + frac) / items).clamp(0.0, 1.0)
                : (size > 0 ? frac : (state == 'downloading' ? null : 0.0)))
        : (size > 0 ? frac : (state == 'downloading' ? null : 0.0));
    final current = '${j['current'] ?? ''}';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(j['kind'] == 'torrent' ? Icons.hub_outlined : yt ? Icons.smart_display_outlined : Icons.link, size: 18, color: const Color(0xFF8B95A5)),
            const SizedBox(width: 6),
            Expanded(child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
            if (mine && yt && j['playlist'] == true && state == 'done')
              IconButton(tooltip: 'Update — download what was added to the playlist since', icon: const Icon(Icons.sync), onPressed: () async {
                await me.api.retryDownload('${j['id']}');
                _load();
              }),
            if (mine && (j['kind'] == 'http' || yt) && (state == 'failed' || state == 'canceled'))
              IconButton(tooltip: 'Retry', icon: const Icon(Icons.refresh), onPressed: () async {
                await me.api.retryDownload('${j['id']}');
                _load();
              }),
            if (mine && live)
              PopupMenuButton<String>(
                tooltip: 'Torrent',
                onSelected: (a) => _torrent(j, a),
                itemBuilder: (_) => [
                  if (tstate == 'downloading' || tstate == 'seeding') const PopupMenuItem(value: 'pause', child: ListTile(leading: Icon(Icons.pause), title: Text('Pause'))),
                  if (tstate == 'paused') const PopupMenuItem(value: 'resume', child: ListTile(leading: Icon(Icons.play_arrow), title: Text('Resume'))),
                  if (tstate == 'seeding') const PopupMenuItem(value: 'stop', child: ListTile(leading: Icon(Icons.stop), title: Text('Stop seeding'))),
                  if (tstate == 'downloading' || tstate == 'paused') const PopupMenuItem(value: 'stop', child: ListTile(leading: Icon(Icons.stop), title: Text('Stop'))),
                  if (tstate == 'finished') const PopupMenuItem(value: 'start', child: ListTile(leading: Icon(Icons.eco_outlined), title: Text('Seed'))),
                  if (tstate == 'stopped') const PopupMenuItem(value: 'start', child: ListTile(leading: Icon(Icons.play_arrow), title: Text('Start'))),
                  const PopupMenuItem(value: 'recheck', child: ListTile(leading: Icon(Icons.fact_check_outlined), title: Text('Recheck files'))),
                  const PopupMenuItem(value: 'limit', child: ListTile(leading: Icon(Icons.speed), title: Text('Seeding limit…'))),
                  const PopupMenuItem(value: 'detail', child: ListTile(leading: Icon(Icons.info_outline), title: Text('Trackers & files'))),
                  const PopupMenuItem(value: 'remove', child: ListTile(leading: Icon(Icons.delete_outline, color: Colors.redAccent), title: Text('Remove…'))),
                ],
              )
            else if (mine)
              IconButton(tooltip: 'Remove', icon: const Icon(Icons.close), onPressed: () => _remove(j)),
          ]),
          Text('→ ${names['${j['lib']}'] ?? j['lib']}${'${j['subdir'] ?? ''}'.isNotEmpty ? ' / ${j['subdir']}' : ''} · ${j['user']}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF8B95A5))),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 8, 8, 6),
            child: LinearProgressIndicator(value: progress, color: color, minHeight: 4),
          ),
          Text(
            [
              label,
              if (yt && j['playlist'] == true) 'playlist',
              if (yt && items > 1) '${state == 'done' ? itemsDone : (itemIndex > itemsDone ? itemIndex : itemsDone)} / $items',
              if (yt && state == 'downloading' && current.isNotEmpty && current != name) current,
              if (!yt && size > 0) '${fmtSize(done.round())} / ${fmtSize(size.round())}',
              if (rate > 0) '↓ ${fmtSize(rate.round())}/s',
              if (up > 0) '↑ ${fmtSize(up)}/s',
              if ('${j['error'] ?? ''}'.isNotEmpty) '${j['error']}',
            ].join(' · '),
            style: TextStyle(fontSize: 12, color: state == 'failed' ? Colors.redAccent : const Color(0xFF9AA3B2)),
          ),
          if (torrent)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                [
                  'ratio ${(j['ratio'] as num? ?? 0).toStringAsFixed(2)}',
                  '↑ ${fmtSize((j['uploaded'] as num? ?? 0).toInt())} uploaded',
                  if (live) '${j['peers'] ?? 0} peers (${j['seeds'] ?? 0} seeds)',
                  _seedText(j),
                ].join(' · '),
                style: const TextStyle(fontSize: 12, color: Color(0xFF9AA3B2)),
              ),
            ),
          if ('${j['autoStopped'] ?? ''}'.isNotEmpty)
            Text('Auto-stopped: ${j['autoStopped']}', style: const TextStyle(fontSize: 12, color: Color(0xFFF5A623))),
          if ((j['dupes'] as List?)?.isNotEmpty ?? false)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('⚠ Also in the library: ${(j['dupes'] as List).take(2).join(' · ')}${(j['dupes'] as List).length > 2 ? ' +${(j['dupes'] as List).length - 2}' : ''}',
                  style: const TextStyle(fontSize: 12, color: Color(0xFFF5A623))),
            ),
        ]),
      ),
    );
  }
}

/// Thrown when the user declines to download a duplicate.
class _Skipped implements Exception {
  const _Skipped();
}
