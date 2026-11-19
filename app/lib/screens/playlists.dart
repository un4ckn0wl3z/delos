import 'package:flutter/material.dart';

import '../api.dart';
import '../audio.dart';
import '../library.dart';
import '../widgets.dart';
import 'home_screen.dart';

Future<String?> _askName(BuildContext context, {String title = 'New playlist', String initial = ''}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Playlist name'),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Save')),
      ],
    ),
  );
}

/// "Add to playlist" sheet for one or more songs.
Future<void> addToPlaylist(BuildContext context, AppCtx app, List<Item> tracks) async {
  if (tracks.isEmpty) return;
  final messenger = ScaffoldMessenger.of(context);
  List<Map> pls;
  try {
    pls = await app.api.playlists();
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
    return;
  }
  if (!context.mounted) return;
  final pick = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * .6),
        child: ListView(shrinkWrap: true, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(tracks.length > 1 ? 'Add ${tracks.length} songs to…' : 'Add to playlist', style: Theme.of(ctx).textTheme.titleMedium),
          ),
          ListTile(leading: const Icon(Icons.add), title: const Text('New playlist…'), onTap: () => Navigator.pop(ctx, '')),
          for (final p in pls)
            ListTile(
              leading: const Icon(Icons.queue_music),
              title: Text('${p['name']}'),
              trailing: Text('${p['count']}', style: const TextStyle(color: Color(0xFF8B95A5))),
              onTap: () => Navigator.pop(ctx, '${p['id']}'),
            ),
        ]),
      ),
    ),
  );
  if (pick == null || !context.mounted) return;
  final paths = [for (final t in tracks) t.path];
  try {
    if (pick.isEmpty) {
      final sameAlbum = tracks.length > 1 && tracks.every((t) => t.album == tracks.first.album) ? tracks.first.album : '';
      final name = await _askName(context, initial: sameAlbum);
      if (name == null || name.isEmpty) return;
      await app.api.createPlaylist(name, paths);
      messenger.showSnackBar(SnackBar(content: Text('Created “$name”')));
    } else {
      final r = await app.api.addToPlaylist(pick, paths);
      final n = (r['added'] as num? ?? 0).toInt(), name = '${(r['playlist'] as Map)['name']}';
      messenger.showSnackBar(SnackBar(content: Text(n == 0 ? 'Already in “$name”' : 'Added ${n > 1 ? '$n songs ' : ''}to “$name”')));
    }
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  }
}

/// The Playlists tab of the music view.
class PlaylistsTab extends StatefulWidget {
  const PlaylistsTab({super.key, required this.app, required this.data});
  final AppCtx app;
  final LibData data;
  @override
  State<PlaylistsTab> createState() => _PlaylistsTabState();
}

class _PlaylistsTabState extends State<PlaylistsTab> {
  List<Map>? pls;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final v = await widget.app.api.playlists();
      if (mounted) setState(() => pls = v);
    } on ApiException catch (e) {
      if (mounted) setState(() => error = e.message);
    }
  }

  Future<void> _new() async {
    final name = await _askName(context);
    if (name == null || name.isEmpty) return;
    try {
      await widget.app.api.createPlaylist(name, const []);
      _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (pls == null) return Center(child: error != null ? Text(error!) : const CircularProgressIndicator());
    final byPath = {for (final t in widget.data.items) t.path: t};
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        ListTile(leading: const Icon(Icons.add), title: const Text('New playlist'), onTap: _new),
        if (pls!.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No playlists yet. Long-press a song (or use “Add to playlist” on an album or artist) to start one.',
                style: TextStyle(color: Color(0xFF8B95A5))),
          ),
        for (final p in pls!)
          ListTile(
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 48,
                height: 48,
                child: Builder(builder: (_) {
                  final t = [for (final x in (p['first'] as List? ?? const [])) byPath['$x']].whereType<Item>().where((t) => t.cover.isNotEmpty).firstOrNull;
                  return NetImage(t == null ? '' : widget.app.api.coverUrl(t.cover), headers: widget.app.api.authHeaders, placeholder: '♪');
                }),
              ),
            ),
            title: Text('${p['name']}'),
            subtitle: Text('${p['count']} songs'),
            onTap: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => PlaylistScreen(app: widget.app, id: '${p['id']}')));
              _load();
            },
          ),
      ]),
    );
  }
}

class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({super.key, required this.app, required this.id});
  final AppCtx app;
  final String id;
  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  Map? pl;
  Map<String, Item> byPath = {};
  String? error;

  AppCtx get app => widget.app;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([app.api.playlist(widget.id), app.repo.lib(LibraryRepo.allMusic)]);
      if (!mounted) return;
      setState(() {
        pl = r[0] as Map;
        byPath = {for (final t in (r[1] as LibData).items) t.path: t};
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => error = e.message);
    }
  }

  List<String> get paths => List<String>.from(pl?['tracks'] as List? ?? const []);

  Future<void> _save(List<String> tracks) async {
    setState(() => pl!['tracks'] = tracks); // feels instant; the server copy follows
    try {
      final r = await app.api.updatePlaylist(widget.id, tracks: tracks);
      if (mounted) setState(() => pl = r);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      _load();
    }
  }

  Future<void> _rename() async {
    final n = await _askName(context, title: 'Rename playlist', initial: '${pl!['name']}');
    if (n == null || n.isEmpty) return;
    try {
      final r = await app.api.updatePlaylist(widget.id, name: n);
      if (mounted) setState(() => pl = r);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete playlist?'),
        content: Text('“${pl!['name']}” will be deleted. The songs stay in your library.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await app.api.deletePlaylist(widget.id);
      if (mounted) Navigator.pop(context);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (pl == null) {
      return Scaffold(appBar: AppBar(), body: Center(child: error != null ? Text(error!) : const CircularProgressIndicator()));
    }
    final all = paths;
    // entries whose song can't be found (deleted, no access) are kept but not shown
    final rows = [for (var k = 0; k < all.length; k++) if (byPath[all[k]] != null) k];
    final tracks = [for (final k in rows) byPath[all[k]]!];
    final total = tracks.fold<double>(0, (s, t) => s + t.duration);
    final missing = all.length - rows.length;
    return Scaffold(
      appBar: AppBar(title: Text('${pl!['name']}'), actions: [
        PopupMenuButton<String>(
          onSelected: (v) => v == 'rename' ? _rename() : _delete(),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rename', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Rename'))),
            PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete playlist'))),
          ],
        ),
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(children: [
            Expanded(
              child: Text('${tracks.length} songs · ${fmtDur(total)}${missing > 0 ? ' · $missing unavailable' : ''}',
                  style: const TextStyle(color: Color(0xFF8B95A5))),
            ),
            FilledButton.icon(
                icon: const Icon(Icons.play_arrow), label: const Text('Play'), onPressed: tracks.isEmpty ? null : () => app.audio.playQueue(tracks, 0)),
            const SizedBox(width: 8),
            OutlinedButton.icon(
                icon: const Icon(Icons.shuffle),
                label: const Text('Shuffle'),
                onPressed: tracks.isEmpty ? null : () => app.audio.playQueue(tracks, 0, shuffled: true)),
          ]),
        ),
        Expanded(
          child: tracks.isEmpty
              ? const Center(
                  child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Empty — long-press songs to add them here.', style: TextStyle(color: Color(0xFF8B95A5))),
                ))
              : ListenableBuilder(
                  listenable: app.audio,
                  builder: (context, _) => ReorderableListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: tracks.length,
                    onReorder: (from, to) {
                      if (to > from) to--;
                      final vis = [for (final k in rows) all[k]];
                      vis.insert(to, vis.removeAt(from));
                      final gone = [for (var k = 0; k < all.length; k++) if (!rows.contains(k)) all[k]];
                      _save([...vis, ...gone]);
                    },
                    itemBuilder: (_, i) {
                      final t = tracks[i];
                      final on = app.audio.current?.path == t.path;
                      return Dismissible(
                        key: ValueKey('${rows[i]}|${t.path}'),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: Colors.red.shade900,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          child: const Icon(Icons.delete_outline),
                        ),
                        onDismissed: (_) => _save([...all]..removeAt(rows[i])),
                        child: ListTile(
                          dense: true,
                          selected: on,
                          leading: on ? const Icon(Icons.graphic_eq, size: 18) : const Icon(Icons.music_note_outlined, size: 18),
                          title: Text(t.title.isNotEmpty ? t.title : t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text([t.artist, t.album].where((e) => e.isNotEmpty).join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: Text(t.duration > 0 ? fmtDur(t.duration) : '', style: const TextStyle(fontSize: 12, color: Color(0xFF7D8696))),
                          onTap: () => app.audio.playQueue(tracks, i),
                        ),
                      );
                    },
                  ),
                ),
        ),
        MiniPlayer(audio: app.audio),
      ]),
    );
  }
}
