import 'package:flutter/material.dart';

import '../library.dart';
import '../offline/store.dart';
import 'home_screen.dart';
import 'playlists.dart';

/// Save songs to this device (needs the "offline" permission).
Future<void> saveMusic(BuildContext context, AppCtx app, List<Item> tracks) async {
  final messenger = ScaffoldMessenger.of(context);
  final n = await OfflineStore.instance.downloadMusic(app.api, tracks);
  messenger.showSnackBar(SnackBar(
    content: Text(n == 0 ? 'Already on this device' : 'Saving $n song${n > 1 ? 's' : ''} — see Offline → Music'),
  ));
}

bool isSaved(AppCtx app, Item t) => OfflineStore.instance.downloaded(app.api.settings.server, t.path) != null;

/// Play next / add to queue, for several songs (album, artist, playlist).
Future<void> queueMenu(BuildContext context, AppCtx app, List<Item> tracks) async {
  if (tracks.isEmpty) return;
  final a = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: const Icon(Icons.queue_play_next), title: const Text('Play next'), onTap: () => Navigator.pop(ctx, 'next')),
        ListTile(leading: const Icon(Icons.queue_music), title: const Text('Add to queue'), onTap: () => Navigator.pop(ctx, 'end')),
      ]),
    ),
  );
  if (a == null || !context.mounted) return;
  await enqueue(context, app, tracks, next: a == 'next');
}

Future<void> enqueue(BuildContext context, AppCtx app, List<Item> tracks, {bool next = false}) async {
  final messenger = ScaffoldMessenger.of(context);
  final playing = app.audio.current != null;
  await app.audio.enqueue(tracks, next: next);
  final what = tracks.length > 1 ? '${tracks.length} songs' : (tracks.first.title.isNotEmpty ? tracks.first.title : tracks.first.name);
  messenger.showSnackBar(SnackBar(content: Text(!playing ? 'Playing $what' : (next ? 'Playing next: $what' : 'Added to queue: $what'))));
}

/// Long-press menu of a song.
Future<void> songMenu(BuildContext context, AppCtx app, Item t) async {
  final store = OfflineStore.instance;
  final saved = store.byServer(app.api.settings.server, t.path);
  final a = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(t.title.isNotEmpty ? t.title : t.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(ctx).textTheme.titleMedium),
        ),
        ListTile(leading: const Icon(Icons.queue_play_next), title: const Text('Play next'), onTap: () => Navigator.pop(ctx, 'next')),
        ListTile(leading: const Icon(Icons.queue_music), title: const Text('Add to queue'), onTap: () => Navigator.pop(ctx, 'queue')),
        ListTile(leading: const Icon(Icons.playlist_add), title: const Text('Add to playlist…'), onTap: () => Navigator.pop(ctx, 'playlist')),
        if (app.offline && saved == null)
          ListTile(leading: const Icon(Icons.download_for_offline_outlined), title: const Text('Save to this device'), onTap: () => Navigator.pop(ctx, 'save')),
        if (saved != null)
          ListTile(
            leading: const Icon(Icons.offline_pin, color: Color(0xFF1F9D63)),
            title: Text(saved.ready ? 'Remove from this device' : 'Cancel saving'),
            subtitle: saved.ready ? const Text('It stays on the server') : null,
            onTap: () => Navigator.pop(ctx, 'unsave'),
          ),
      ]),
    ),
  );
  if (a == null || !context.mounted) return;
  switch (a) {
    case 'next':
      await enqueue(context, app, [t], next: true);
    case 'queue':
      await enqueue(context, app, [t]);
    case 'playlist':
      await addToPlaylist(context, app, [t]);
    case 'save':
      await saveMusic(context, app, [t]);
    case 'unsave':
      if (saved != null) await store.remove(saved);
  }
}
