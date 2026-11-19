import 'package:flutter/material.dart';

import '../audio.dart';
import '../util.dart';
import '../widgets.dart';
import 'store.dart';

/// Songs saved on this device, by album. Plays without the server.
class OfflineMusicTab extends StatelessWidget {
  const OfflineMusicTab({super.key, required this.audio});
  final AudioController? audio;

  OfflineStore get store => OfflineStore.instance;

  static List<(String, String, List<OfflineItem>)> albums(List<OfflineItem> songs) {
    final m = <String, List<OfflineItem>>{};
    for (final s in songs) {
      final artist = s.albumArtist.isNotEmpty ? s.albumArtist : (s.artist.isNotEmpty ? s.artist : 'Unknown artist');
      m.putIfAbsent('${artist.toLowerCase()}|${s.album.toLowerCase()}', () => []).add(s);
    }
    final out = [
      for (final v in m.values)
        (
          v.first.album.isNotEmpty ? v.first.album : 'Singles',
          v.first.albumArtist.isNotEmpty ? v.first.albumArtist : (v.first.artist.isNotEmpty ? v.first.artist : 'Unknown artist'),
          v..sort((a, b) => a.disc != b.disc ? a.disc.compareTo(b.disc) : (a.track != b.track ? a.track.compareTo(b.track) : a.label.compareTo(b.label)))
        )
    ]..sort((a, b) => a.$2.toLowerCase() != b.$2.toLowerCase() ? a.$2.toLowerCase().compareTo(b.$2.toLowerCase()) : a.$1.compareTo(b.$1));
    return out;
  }

  void _play(List<OfflineItem> songs, int i, {bool shuffled = false}) {
    final a = audio;
    if (a == null) return;
    a.playQueue([for (final s in songs) s.toTrack()], i, shuffled: shuffled);
  }

  @override
  Widget build(BuildContext context) {
    final all = store.music;
    final done = all.where((i) => i.ready).toList();
    final active = all.where((i) => i.status != 'done').toList();
    final failed = active.where((i) => i.status == 'failed').toList();
    final going = active.length - failed.length;
    final size = done.fold<int>(0, (s, i) => s + i.size);
    final albumList = albums(done);
    return ListView(padding: const EdgeInsets.only(bottom: 32), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(children: [
          Expanded(
            child: Text(
              done.isEmpty && active.isEmpty
                  ? 'Songs you save appear here and play without internet. In Music, long-press a song or use ⬇ on an album, artist or playlist.'
                  : '${done.length} songs · ${fmtSize(size)}',
              style: const TextStyle(color: Color(0xFF8B95A5)),
            ),
          ),
          if (done.isNotEmpty && audio != null) ...[
            IconButton(tooltip: 'Shuffle all', icon: const Icon(Icons.shuffle), onPressed: () => _play(done, 0, shuffled: true)),
            IconButton(tooltip: 'Play all', icon: const Icon(Icons.play_arrow), onPressed: () => _play([for (final a in albumList) ...a.$3], 0)),
          ],
        ]),
      ),
      if (going > 0)
        ListTile(
          leading: const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
          title: Text('Saving $going song${going > 1 ? 's' : ''}…'),
          subtitle: LinearProgressIndicator(
              value: active.where((i) => i.status != 'failed').fold<double>(0, (s, i) => s + i.progress) / going, minHeight: 3),
          trailing: IconButton(
            tooltip: 'Cancel',
            icon: const Icon(Icons.close),
            onPressed: () async {
              for (final i in active.where((i) => i.status != 'failed').toList()) {
                await store.remove(i);
              }
            },
          ),
        ),
      for (final f in failed)
        ListTile(
          dense: true,
          leading: const Icon(Icons.error_outline, color: Colors.redAccent),
          title: Text(f.label, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('Failed: ${f.error}', style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(tooltip: 'Retry', icon: const Icon(Icons.refresh), onPressed: () => store.resume(f)),
            IconButton(tooltip: 'Remove', icon: const Icon(Icons.close), onPressed: () => store.remove(f)),
          ]),
        ),
      for (final (title, artist, songs) in albumList)
        ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(width: 52, height: 52, child: NetImage(songs.firstWhere((s) => s.poster.isNotEmpty, orElse: () => songs.first).poster, placeholder: '♪')),
          ),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('$artist · ${songs.length} song${songs.length > 1 ? 's' : ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: audio == null ? null : IconButton(icon: const Icon(Icons.play_arrow), onPressed: () => _play(songs, 0)),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => _OfflineAlbum(title: title, artist: artist, audio: audio))),
        ),
    ]);
  }
}

class _OfflineAlbum extends StatelessWidget {
  const _OfflineAlbum({required this.title, required this.artist, required this.audio});
  final String title, artist;
  final AudioController? audio;

  Future<void> _removeAll(BuildContext context, List<OfflineItem> songs) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove from this device?'),
        content: Text('${songs.length} songs (${fmtSize(songs.fold<int>(0, (s, i) => s + i.size))}) — they stay on the server.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    for (final s in songs) {
      await OfflineStore.instance.remove(s);
    }
    if (context.mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([OfflineStore.instance, if (audio != null) audio!]),
        builder: (context, _) {
          final songs = OfflineMusicTab.albums(OfflineStore.instance.music.where((i) => i.ready).toList())
                  .where((a) => a.$1 == title && a.$2 == artist)
                  .firstOrNull
                  ?.$3 ??
              const <OfflineItem>[];
          final tracks = [for (final s in songs) s.toTrack()];
          return Scaffold(
            appBar: AppBar(title: Text(title), actions: [
              if (songs.isNotEmpty) IconButton(tooltip: 'Remove from this device', icon: const Icon(Icons.delete_outline), onPressed: () => _removeAll(context, songs)),
            ]),
            body: Column(children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  Expanded(child: Text('$artist · ${songs.length} songs', style: const TextStyle(color: Color(0xFF8B95A5)))),
                  if (audio != null && songs.isNotEmpty) ...[
                    FilledButton.icon(icon: const Icon(Icons.play_arrow), label: const Text('Play'), onPressed: () => audio!.playQueue(tracks, 0)),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(icon: const Icon(Icons.shuffle), label: const Text('Shuffle'), onPressed: () => audio!.playQueue(tracks, 0, shuffled: true)),
                  ],
                ]),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: songs.length,
                  itemBuilder: (_, i) {
                    final s = songs[i];
                    final on = audio?.current?.path == 'file:${s.file}';
                    return ListTile(
                      dense: true,
                      selected: on,
                      leading: SizedBox(
                        width: 28,
                        child: on
                            ? const Icon(Icons.graphic_eq, size: 18)
                            : Text(s.track > 0 ? '${s.track}' : '', textAlign: TextAlign.right, style: const TextStyle(color: Color(0xFF7D8696))),
                      ),
                      title: Text(s.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: s.artist.isNotEmpty && s.artist != artist ? Text(s.artist) : null,
                      trailing: Text(s.duration > 0 ? fmtDur(s.duration) : '', style: const TextStyle(fontSize: 12, color: Color(0xFF7D8696))),
                      onTap: audio == null ? null : () => audio!.playQueue(tracks, i),
                      onLongPress: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Remove from this device?'),
                            content: Text('${s.label} — it stays on the server.'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
                            ],
                          ),
                        );
                        if (ok == true) await OfflineStore.instance.remove(s);
                      },
                    );
                  },
                ),
              ),
              if (audio != null) MiniPlayer(audio: audio!),
            ]),
          );
        },
      );
}
