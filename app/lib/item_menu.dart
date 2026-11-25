import 'package:flutter/material.dart';

import 'api.dart';
import 'library.dart';
import 'offline/store.dart';
import 'screens/chat.dart';
import 'screens/home_screen.dart';
import 'screens/remote.dart';
import 'util.dart';
import 'widgets.dart';

/// Long-press / right-click menu for a movie, a show, an episode or a plain video.
///
/// [items] are all the files the entry stands for (a movie's versions, a show's
/// episodes); [play] is what Play / Start over opens. Identify needs the editor
/// role and a movie or TV library.
Future<void> showItemMenu(
  BuildContext context,
  AppCtx app,
  LibData d, {
  required String title,
  required List<Item> items,
  Item? play,
  String? showKey,
  VoidCallback? onChanged,
}) async {
  final type = d.info.type;
  if (type == 'movies' && items.length == 1 && items.first.movieId != 0) {
    // a single version from Home → cover every version of that movie
    items = d.items.where((i) => i.movieId == items.first.movieId).toList();
  }
  final inProgress = items.where((i) => i.pos > 0).toList();
  // only files in your own personal library (admins: anywhere). Merged views ('_all') check per file.
  bool ownsLib(String id) => app.admin || app.myLibs.contains(id);
  // metadata: editors everywhere, anyone in their own library
  final canEditMeta = app.editor || ownsLib(d.info.id);
  final canIdentify = canEditMeta && (type == 'movies' || (showKey != null && showKey.isNotEmpty && type != 'music'));
  final canGroup = canEditMeta && type != 'music' && d.info.id != '_all' && items.isNotEmpty;
  final deletable = items.where((i) => ownsLib(i.path.split('/').first)).toList();
  // save to this device (needs the "offline" permission)
  final store = OfflineStore.instance;
  final server = app.api.settings.server;
  final candidates = type == 'music' ? <Item>[] : (play != null ? [play] : items);
  final onDevice = candidates.where((i) => store.byServer(server, i.path) != null).toList();
  final toSave = candidates.where((i) => store.byServer(server, i.path) == null).toList();

  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(ctx).textTheme.titleMedium),
        ),
        if (play != null)
          ListTile(
            leading: const Icon(Icons.play_arrow),
            title: Text(play.pos > 0 ? 'Resume from ${fmtDur(play.pos)}' : 'Play'),
            onTap: () => Navigator.pop(ctx, 'play'),
          ),
        if (play != null && app.remote != null)
          ListTile(
            leading: const Icon(Icons.cast),
            title: const Text('Play on…'),
            subtitle: const Text('Your PC or TV — this phone becomes the remote'),
            onTap: () => Navigator.pop(ctx, 'playon'),
          ),
        if (canGroup)
          ListTile(
            leading: const Icon(Icons.live_tv_outlined),
            title: Text(items.every((i) => i.show.isNotEmpty) ? 'Move to another series…' : 'Put in a series…'),
            subtitle: Text(items.length > 1 ? '${items.length} files → episodes of one series' : 'Make it an episode of a series'),
            onTap: () => Navigator.pop(ctx, 'group'),
          ),
        if (play != null && play.pos > 0)
          ListTile(
            leading: const Icon(Icons.replay),
            title: const Text('Start over'),
            onTap: () => Navigator.pop(ctx, 'restart'),
          ),
        if (app.offline && toSave.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.download_for_offline_outlined),
            title: Text(toSave.length > 1 ? 'Download ${toSave.length} files to this device' : 'Download to this device'),
            subtitle: Text('${fmtSize(toSave.fold<int>(0, (s, i) => s + i.size))} · watch without internet'),
            onTap: () => Navigator.pop(ctx, 'save'),
          ),
        if (onDevice.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.offline_pin, color: Color(0xFF1F9D63)),
            title: Text(onDevice.length > 1 ? 'Remove ${onDevice.length} files from this device' : 'Remove from this device'),
            subtitle: const Text('Frees space here — it stays on the server'),
            onTap: () => Navigator.pop(ctx, 'unsave'),
          ),
        if (inProgress.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.playlist_remove),
            title: const Text('Remove from Continue watching'),
            subtitle: inProgress.length > 1 ? Text('${inProgress.length} files') : null,
            onTap: () => Navigator.pop(ctx, 'clear'),
          ),
        if (app.social != null && (play ?? items.firstOrNull) != null)
          ListTile(
            leading: const Icon(Icons.send_outlined),
            title: const Text('Send to a friend…'),
            onTap: () => Navigator.pop(ctx, 'share'),
          ),
        if (deletable.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
            title: Text(deletable.length > 1 ? 'Delete ${deletable.length} files…' : 'Delete from server…'),
            subtitle: Text(fmtSize(deletable.fold<int>(0, (s, i) => s + i.size))),
            onTap: () => Navigator.pop(ctx, 'delete'),
          ),
        if (canIdentify)
          ListTile(
            leading: const Icon(Icons.manage_search),
            title: const Text('Identify…'),
            subtitle: Text(type == 'tv' ? 'Fix the TMDB match for this show' : 'Fix the TMDB match for this movie'),
            onTap: () => Navigator.pop(ctx, 'identify'),
          ),
        const SizedBox(height: 8),
      ]),
    ),
  );
  if (action == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  switch (action) {
    case 'group':
      if (await groupAsSeries(context, app, d, items)) {
        messenger.showSnackBar(const SnackBar(content: Text('Grouped — updating…')));
        app.repo.invalidate();
        await Future<void>.delayed(const Duration(milliseconds: 1600)); // the server re-applies edits
        onChanged?.call();
      }
    case 'play':
      await openVideo(context, app, d, play!);
    case 'playon':
      await playOnDevice(context, app, play!);
    case 'restart':
      await openVideo(context, app, d, play!, startOver: true);
    case 'save':
      for (final it in toSave) {
        await store.download(app.api, it.path, offlineInfo(d, it));
      }
      messenger.showSnackBar(SnackBar(
        content: Text(toSave.length > 1 ? 'Downloading ${toSave.length} files — see Offline' : 'Downloading — see Offline'),
      ));
    case 'unsave':
      for (final it in onDevice) {
        final o = store.byServer(server, it.path);
        if (o != null) await store.remove(o);
      }
      messenger.showSnackBar(const SnackBar(content: Text('Removed from this device')));
    case 'clear':
      for (final it in inProgress) {
        await app.api.clearProgress(it.path);
        app.repo.setPos(it.path, 0);
      }
      messenger.showSnackBar(const SnackBar(content: Text('Removed from Continue watching')));
    case 'share':
      final it = play ?? items.first;
      final m = type == 'tv' ? d.shows[showKey ?? it.show] : d.movieOf(it);
      await shareSheet(context, app, {
        'path': it.path,
        'title': m?.title ?? title,
        'sub': type == 'tv' && it.episode > 0 ? 'S${it.season}E${it.episode}${it.episodeTitle.isNotEmpty ? ' · ${it.episodeTitle}' : ''}' : (m != null && m.year > 0 ? '${m.year}' : ''),
        'image': m?.poster ?? '',
        'kind': 'video',
      });
      return;
    case 'delete':
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Delete from server?'),
          content: Text('${deletable.length > 1 ? '${deletable.length} files' : deletable.first.name} '
              '(${fmtSize(deletable.fold<int>(0, (s, i) => s + i.size))}) will be removed from disk. This cannot be undone.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.redAccent), onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
          ],
        ),
      );
      if (ok != true) return;
      try {
        await app.api.deleteFiles([for (final i in deletable) i.path]);
      } on ApiException catch (e) {
        messenger.showSnackBar(SnackBar(content: Text(e.message)));
        return;
      }
      messenger.showSnackBar(const SnackBar(content: Text('Deleted')));
      await Future.delayed(const Duration(milliseconds: 1500));
      app.repo.invalidate();
    case 'identify':
      final series = showKey != null && showKey.isNotEmpty; // a series, in any video library
      final m = series ? d.shows[showKey] : d.movieOf(items.first);
      final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => IdentifyScreen(
          app: app,
          lib: d.info,
          query: m?.title ?? (items.first.title.isNotEmpty ? items.first.title : items.first.name),
          year: m?.year ?? items.first.year,
          paths: !series && type == 'movies' ? items.map((i) => i.path).toList() : const [],
          show: series ? showKey : null,
        ),
      ));
      if (ok != true) return;
      messenger.showSnackBar(const SnackBar(content: Text('Matched — updating metadata…')));
      // the server re-scrapes in the background; give it a moment, then reload
      await Future.delayed(const Duration(seconds: 3));
      app.repo.invalidate();
  }
  onChanged?.call();
}

class IdentifyScreen extends StatefulWidget {
  const IdentifyScreen({super.key, required this.app, required this.lib, required this.query, required this.year, required this.paths, this.show});
  final AppCtx app;
  final LibraryInfo lib;
  final String query;
  final int year;
  final List<String> paths;
  final String? show;
  @override
  State<IdentifyScreen> createState() => _IdentifyScreenState();
}

class _IdentifyScreenState extends State<IdentifyScreen> {
  late final _q = TextEditingController(text: widget.query);
  late final _y = TextEditingController(text: widget.year > 0 ? '${widget.year}' : '');
  List<Map>? results;
  String? error;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _q.dispose();
    _y.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    FocusScope.of(context).unfocus();
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final r = await widget.app.api.metaSearch(widget.lib.id, _q.text.trim(), int.tryParse(_y.text.trim()) ?? 0, tv: widget.show != null);
      if (mounted) setState(() => results = r);
    } on ApiException catch (e) {
      if (mounted) setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _match(int id) async {
    setState(() => busy = true);
    try {
      if (widget.show != null) {
        await widget.app.api.metaMatch(widget.lib.id, show: widget.show, tmdbId: id);
      } else {
        for (final p in widget.paths) {
          await widget.app.api.metaMatch(widget.lib.id, path: p, tmdbId: id);
        }
      }
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final asId = int.tryParse(_q.text.trim());
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.show != null ? 'Identify show' : 'Identify movie'),
        actions: [
          TextButton(
            onPressed: busy ? null : () => _match(0),
            child: const Text('Re-detect'),
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _q,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Title or TMDB ID', isDense: true, border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 80,
              child: TextField(
                controller: _y,
                keyboardType: TextInputType.number,
                onSubmitted: (_) => _search(),
                decoration: const InputDecoration(labelText: 'Year', isDense: true, border: OutlineInputBorder()),
              ),
            ),
            IconButton(icon: const Icon(Icons.search), onPressed: busy ? null : _search),
          ]),
        ),
        if (busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: ListView(children: [
            if (asId != null && asId > 0)
              ListTile(
                leading: const Icon(Icons.tag),
                title: Text('Use TMDB ID $asId'),
                onTap: busy ? null : () => _match(asId),
              ),
            if (error != null) Padding(padding: const EdgeInsets.all(16), child: Text(error!, style: const TextStyle(color: Colors.redAccent))),
            if (results != null && results!.isEmpty && error == null)
              const Padding(padding: EdgeInsets.all(16), child: Text('No results — try a shorter title or clear the year.')),
            for (final r in results ?? const <Map>[])
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(width: 46, height: 69, child: NetImage('${r['poster'] ?? ''}', placeholder: '${r['title'] ?? '?'}')),
                ),
                title: Text('${r['title']}${(r['year'] ?? 0) != 0 ? ' (${r['year']})' : ''}'),
                subtitle: Text(
                  [if ((r['originalTitle'] ?? '').toString().isNotEmpty) r['originalTitle'], r['overview'] ?? ''].join(' — '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: busy ? null : () => _match(r['id'] as int),
              ),
          ]),
        ),
      ]),
    );
  }
}


/// What the offline library needs to show a server file without the server.
Map<String, dynamic> offlineInfo(LibData d, Item it) {
  final tv = it.show.isNotEmpty && it.episode > 0;
  final m = tv ? d.showOf(it) : d.movieOf(it);
  return {
    'kind': tv ? 'episode' : (d.info.type == 'movies' ? 'movie' : 'video'),
    'title': m?.title.isNotEmpty == true ? m!.title : (it.title.isNotEmpty ? it.title : it.name),
    'year': m?.year ?? it.year,
    'show': tv ? (m?.title.isNotEmpty == true ? m!.title : it.show) : '',
    'season': it.season,
    'episode': it.episode,
    'episodeTitle': it.episodeTitle,
    'overview': tv && it.episodeOverview.isNotEmpty ? it.episodeOverview : (m?.overview ?? ''),
    'genres': m?.genres ?? const <String>[],
    'rating': m?.rating ?? 0,
    'poster': m?.poster ?? '',
    'backdrop': m?.backdrop ?? '',
    'still': it.still,
    'libName': d.info.owner.isNotEmpty ? '${d.info.name} (${d.info.owner})' : d.info.name,
    'size': it.size,
    'pos': it.pos,
    'duration': it.duration,
  };
}

/// "Put in a series…": the files become episodes of one series (new or existing), numbered in name order.
/// Editors anywhere, owners in their own library. Undo per file with "Reset" on the web (✎).
Future<bool> groupAsSeries(BuildContext context, AppCtx app, LibData d, List<Item> items) async {
  final files = [...items]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  final existing = {for (final e in d.series.entries) d.shows[e.key]?.title ?? e.value.first.title}..removeWhere((t) => t.isEmpty);
  final title = TextEditingController(text: files.firstWhere((i) => i.show.isNotEmpty, orElse: () => files.first).show.isNotEmpty
      ? (d.showOf(files.firstWhere((i) => i.show.isNotEmpty))?.title ?? '')
      : '');
  final season = TextEditingController(text: '${files.first.season > 0 ? files.first.season : 1}');
  final start = TextEditingController(text: '${files.first.episode > 0 ? files.first.episode : 1}');
  final messenger = ScaffoldMessenger.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        final s0 = int.tryParse(season.text) ?? 1, e0 = int.tryParse(start.text) ?? 1;
        return AlertDialog(
          title: Text(files.length > 1 ? 'Group ${files.length} files as a series' : 'Put in a series'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(controller: title, autofocus: true, decoration: const InputDecoration(labelText: 'Series')),
              if (existing.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(spacing: 6, runSpacing: 4, children: [
                    for (final t in existing.take(12))
                      ActionChip(label: Text(t, style: const TextStyle(fontSize: 12)), onPressed: () => set(() => title.text = t)),
                  ]),
                ),
              Row(children: [
                Expanded(child: TextField(controller: season, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Season'), onChanged: (_) => set(() {}))),
                const SizedBox(width: 12),
                Expanded(child: TextField(controller: start, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'First episode'), onChanged: (_) => set(() {}))),
              ]),
              const SizedBox(height: 12),
              for (var i = 0; i < files.length && i < 30; i++)
                Text('S${s0}E${e0 + i} ← ${files[i].name}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Color(0xFF9AA3B2))),
              if (files.length > 30) Text('… ${files.length - 30} more', style: const TextStyle(fontSize: 12, color: Color(0xFF9AA3B2))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Group')),
          ],
        );
      },
    ),
  );
  final name = title.text.trim(), s = int.tryParse(season.text.trim()) ?? 1, e = int.tryParse(start.text.trim()) ?? 1;
  title.dispose();
  season.dispose();
  start.dispose();
  if (ok != true || name.isEmpty) return false;
  try {
    for (var i = 0; i < files.length; i++) {
      final it = files[i];
      await app.api.metaEdit(it.path.split('/').first, it.path, {'showTitle': name, 'season': '$s', 'episode': '${e + i}'});
    }
    return true;
  } on ApiException catch (x) {
    messenger.showSnackBar(SnackBar(content: Text(x.message)));
    return false;
  }
}
