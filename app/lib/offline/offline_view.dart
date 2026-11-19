import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../api.dart';
import '../settings.dart';
import '../util.dart';
import '../widgets.dart';
import 'local_player.dart';
import 'store.dart';

const _typeNames = {'movies': 'Movies', 'tv': 'TV series', 'videos': 'Other videos'};

/// The offline library: ☁️ files downloaded from a server, and 📁 the user's
/// own folders on this device — two clearly separate sections.
class OfflineView extends StatefulWidget {
  const OfflineView({super.key, this.api, required this.settings});
  final Api? api;
  final Settings settings;
  @override
  State<OfflineView> createState() => _OfflineViewState();
}

class _OfflineViewState extends State<OfflineView> {
  OfflineStore get store => OfflineStore.instance;
  String folderFilter = '';

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(children: [
        const TabBar(tabs: [
          Tab(icon: Icon(Icons.cloud_download_outlined), text: 'Downloaded from server'),
          Tab(icon: Icon(Icons.folder_outlined), text: 'My folders'),
        ]),
        Expanded(
          child: ListenableBuilder(
            listenable: store,
            builder: (context, _) => TabBarView(children: [_downloaded(context), _folders(context)]),
          ),
        ),
      ]),
    );
  }

  // ---------------------------------------------------------------- downloaded
  Widget _downloaded(BuildContext context) {
    final all = store.downloads;
    final active = all.where((i) => i.status != 'done').toList();
    final done = all.where((i) => i.status == 'done').toList();
    return ListView(padding: const EdgeInsets.only(bottom: 32), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(
          done.isEmpty && active.isEmpty
              ? (widget.api == null
                  ? 'Movies you save from a StreamMKV server appear here. Sign in to a server to download.'
                  : 'Long-press a movie or episode → "Download to this device" to watch it without internet.')
              : '${done.length} saved · ${fmtSize(store.downloadedBytes)} on this device${active.isNotEmpty ? ' · ${active.length} in progress' : ''}',
          style: const TextStyle(color: Color(0xFF8B95A5)),
        ),
      ),
      for (final it in active) _progressTile(it),
      if (done.isNotEmpty) _grid(context, done),
    ]);
  }

  Widget _progressTile(OfflineItem it) {
    final failed = it.status == 'failed';
    return ListTile(
      leading: ClipRRect(borderRadius: BorderRadius.circular(4), child: SizedBox(width: 40, height: 60, child: NetImage(it.poster, placeholder: '☁️'))),
      title: Text(it.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 4),
        LinearProgressIndicator(value: it.status == 'queued' ? null : it.progress, minHeight: 3, color: failed ? Colors.redAccent : null),
        const SizedBox(height: 3),
        Text(
          failed
              ? 'Failed: ${it.error}'
              : '${{'queued': 'Waiting', 'downloading': 'Downloading', 'paused': 'Paused'}[it.status] ?? it.status} · ${(it.progress * 100).toStringAsFixed(0)}%${it.size > 0 ? ' of ${fmtSize(it.size)}' : ''}',
          style: TextStyle(fontSize: 12, color: failed ? Colors.redAccent : const Color(0xFF9AA3B2)),
        ),
      ]),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (it.status == 'downloading')
          IconButton(tooltip: 'Pause', icon: const Icon(Icons.pause), onPressed: () => store.pause(it))
        else if (it.status == 'paused' || failed)
          IconButton(tooltip: failed ? 'Retry' : 'Resume', icon: Icon(failed ? Icons.refresh : Icons.play_arrow), onPressed: () => store.resume(it)),
        IconButton(tooltip: 'Cancel', icon: const Icon(Icons.close), onPressed: () => store.remove(it)),
      ]),
    );
  }

  // ---------------------------------------------------------------- my folders
  Widget _folders(BuildContext context) {
    final folders = store.folders.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (folderFilter.isNotEmpty && !store.folders.containsKey(folderFilter)) folderFilter = '';
    final items = store.folderItems(folderFilter.isEmpty ? null : folderFilter);
    return ListView(padding: const EdgeInsets.only(bottom: 32), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
        child: Row(children: [
          Expanded(
            child: Text(
              folders.isEmpty ? 'Add a folder of your own videos on this device.' : '${items.length} videos in ${folders.length} folder${folders.length > 1 ? 's' : ''}',
              style: const TextStyle(color: Color(0xFF8B95A5)),
            ),
          ),
          FilledButton.tonalIcon(onPressed: () => _addFolder(context), icon: const Icon(Icons.create_new_folder_outlined), label: const Text('Add folder')),
        ]),
      ),
      if (folders.isNotEmpty && !store.canScrape)
        const Card(
          margin: EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('No posters yet'),
            subtitle: Text('Sign in to a server, or add your own TMDB key in Offline settings (⚙), to fetch posters and details for your folders.'),
          ),
        ),
      for (final f in folders) _folderTile(context, f),
      if (folders.length > 1)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Wrap(spacing: 8, children: [
            ChoiceChip(label: const Text('All'), selected: folderFilter.isEmpty, onSelected: (_) => setState(() => folderFilter = '')),
            for (final f in folders) ChoiceChip(label: Text(f.name), selected: folderFilter == f.id, onSelected: (_) => setState(() => folderFilter = f.id)),
          ]),
        ),
      if (items.isNotEmpty) _grid(context, items),
    ]);
  }

  Widget _folderTile(BuildContext context, LocalFolder f) {
    final n = store.folderItems(f.id).length;
    final busy = store.scanning.contains(f.id);
    return ListTile(
      leading: const Icon(Icons.folder),
      title: Text(f.name),
      subtitle: Text('${_typeNames[f.type] ?? f.type} · $n videos${busy ? ' · scanning…' : ''}\n${f.path}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
      isThreeLine: true,
      trailing: busy
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'scan') store.scanFolder(f.id);
                if (v == 'refresh') store.scanFolder(f.id, refresh: true);
                if (v == 'remove') store.removeFolder(f);
                if (v.startsWith('type:')) store.setFolderType(f, v.substring(5));
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'scan', child: Text('Scan for new files')),
                const PopupMenuItem(value: 'refresh', child: Text('Rescan & refresh metadata')),
                for (final t in _typeNames.entries.where((e) => e.key != f.type)) PopupMenuItem(value: 'type:${t.key}', child: Text('Treat as ${t.value}')),
                const PopupMenuItem(value: 'remove', child: Text('Remove from app (files stay)')),
              ],
            ),
    );
  }

  Future<void> _addFolder(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    String? path;
    if (Platform.isIOS) {
      // iOS: the app's own folder, visible in the Files app (On My iPhone → StreamMKV)
      final docs = await getApplicationDocumentsDirectory();
      final d = Directory('${docs.path}/My Videos');
      await d.create(recursive: true);
      path = d.path;
      messenger.showSnackBar(const SnackBar(
        duration: Duration(seconds: 8),
        content: Text('Put videos in Files → On My iPhone → StreamMKV → My Videos, then rescan.'),
      ));
    } else {
      if (Platform.isAndroid) {
        final st = await [Permission.videos, Permission.storage].request();
        if (!(st[Permission.videos]?.isGranted ?? false) && !(st[Permission.storage]?.isGranted ?? false)) {
          messenger.showSnackBar(const SnackBar(content: Text('Allow access to videos so the app can read your folder')));
          if (st.values.any((s) => s.isPermanentlyDenied)) openAppSettings();
          return;
        }
      }
      path = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Choose a folder of videos');
    }
    if (path == null || path.isEmpty || !context.mounted) return;
    final type = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('What is in this folder?'),
        children: [
          for (final t in _typeNames.entries)
            SimpleDialogOption(onPressed: () => Navigator.pop(ctx, t.key), child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(t.value))),
        ],
      ),
    );
    if (type == null) return;
    await store.addFolder(path, type);
  }

  // ---------------------------------------------------------------- grid
  Widget _grid(BuildContext context, List<OfflineItem> items) {
    // episodes of a show become one card
    final cards = <Widget>[];
    final shows = <String, List<OfflineItem>>{};
    final singles = <OfflineItem>[];
    for (final it in items) {
      if (it.kind == 'episode' && it.show.isNotEmpty) {
        shows.putIfAbsent('${it.source}|${it.folderId}|${it.show.toLowerCase()}', () => []).add(it);
      } else {
        singles.add(it);
      }
    }
    for (final eps in shows.values) {
      eps.sort((a, b) => a.season != b.season ? a.season.compareTo(b.season) : a.episode.compareTo(b.episode));
      final first = eps.first;
      cards.add(PosterCard(
        title: first.show,
        subtitle: '${eps.length} episode${eps.length > 1 ? 's' : ''}',
        image: first.poster,
        badge: first.isServer ? '📥' : '📁',
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => _ShowScreen(eps: eps, api: widget.api, settings: widget.settings))),
      ));
    }
    singles.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    for (final it in singles) {
      cards.add(PosterCard(
        title: it.label,
        subtitle: [if (it.year > 0) '${it.year}', fmtSize(it.size)].join(' · '),
        image: it.poster,
        progress: it.fraction,
        badge: it.isServer ? '📥' : '📁',
        onTap: () => playLocal(context, it, api: widget.api, settings: widget.settings),
        onLongPress: () => localItemMenu(context, it, api: widget.api, settings: widget.settings),
      ));
    }
    return CardGrid(shrink: true, children: cards);
  }
}

Future<void> playLocal(BuildContext context, OfflineItem it, {Api? api, Settings? settings, bool startOver = false}) =>
    Navigator.push(context, MaterialPageRoute(builder: (_) => LocalPlayerScreen(item: it, api: api, settings: settings, startOver: startOver)));

Future<void> localItemMenu(BuildContext context, OfflineItem it, {Api? api, Settings? settings}) async {
  final store = OfflineStore.instance;
  final a = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
          child: Text(it.label, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(ctx).textTheme.titleMedium),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(it.isServer ? '☁️ Downloaded from ${it.libName.isNotEmpty ? it.libName : 'the server'}' : '📁 ${it.file}',
              maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Color(0xFF8B95A5))),
        ),
        if (it.ready || !it.isServer)
          ListTile(leading: const Icon(Icons.play_arrow), title: Text(it.pos > 0 ? 'Resume from ${fmtDur(it.pos)}' : 'Play'), onTap: () => Navigator.pop(ctx, 'play')),
        if (it.pos > 0) ListTile(leading: const Icon(Icons.replay), title: const Text('Start over'), onTap: () => Navigator.pop(ctx, 'restart')),
        if (!it.isServer && it.kind != 'video')
          ListTile(leading: const Icon(Icons.refresh), title: const Text('Refresh metadata'), onTap: () => Navigator.pop(ctx, 'meta')),
        ListTile(
          leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
          title: Text(it.isServer ? 'Remove from this device' : 'Delete the file…'),
          subtitle: Text(it.isServer ? 'Frees ${fmtSize(it.size)} — it stays on the server' : 'Deletes it from your folder (${fmtSize(it.size)})'),
          onTap: () => Navigator.pop(ctx, 'delete'),
        ),
      ]),
    ),
  );
  if (a == null || !context.mounted) return;
  switch (a) {
    case 'play':
      await playLocal(context, it, api: api, settings: settings);
    case 'restart':
      await playLocal(context, it, api: api, settings: settings, startOver: true);
    case 'meta':
      await store.refreshMeta(it);
    case 'delete':
      if (!it.isServer) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Delete the file?'),
            content: Text('${it.file}\nwill be deleted from this device. This cannot be undone.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.redAccent), onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
            ],
          ),
        );
        if (ok != true) return;
      }
      await store.remove(it);
  }
}

class _ShowScreen extends StatelessWidget {
  const _ShowScreen({required this.eps, this.api, required this.settings});
  final List<OfflineItem> eps;
  final Api? api;
  final Settings settings;
  @override
  Widget build(BuildContext context) {
    final first = eps.first;
    return Scaffold(
      appBar: AppBar(title: Text(first.show)),
      body: ListenableBuilder(
        listenable: OfflineStore.instance,
        builder: (context, _) {
          final live = eps.where((e) => OfflineStore.instance.items.containsKey(e.id)).toList();
          return ListView(children: [
            if (first.overview.isNotEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(first.overview, style: const TextStyle(height: 1.5))),
            for (final e in live)
              InkWell(
                onTap: () => playLocal(context, e, api: api, settings: settings),
                onLongPress: () => localItemMenu(context, e, api: api, settings: settings),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        width: 140,
                        height: 79,
                        child: Stack(fit: StackFit.expand, children: [NetImage(e.still.isNotEmpty ? e.still : e.backdrop, placeholder: 'E${e.episode}'), ProgressStrip(e.fraction)]),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('S${e.season}E${e.episode}${e.episodeTitle.isNotEmpty ? ' · ${e.episodeTitle}' : ''}', style: const TextStyle(fontWeight: FontWeight.w500)),
                        Text('${e.isServer ? '📥 downloaded' : '📁 my folder'} · ${fmtSize(e.size)}', style: const TextStyle(fontSize: 12, color: Color(0xFF7D8696))),
                      ]),
                    ),
                  ]),
                ),
              ),
          ]);
        },
      ),
    );
  }
}

/// Offline settings: own TMDB key (for folders when not signed in), Wi-Fi only.
Future<void> offlineSettings(BuildContext context, Settings s) async {
  final key = TextEditingController(text: s.tmdbKey);
  final lang = TextEditingController(text: s.tmdbLang);
  var wifi = s.wifiOnly;
  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: const Text('Offline settings'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: wifi,
              onChanged: (v) => set(() => wifi = v),
              title: const Text('Download on Wi-Fi only'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: key,
              decoration: const InputDecoration(
                labelText: 'TMDB API key (optional)',
                helperText: 'For posters of your own folders when you are not signed in to a server.',
                helperMaxLines: 3,
              ),
            ),
            TextField(controller: lang, decoration: const InputDecoration(labelText: 'Metadata language (e.g. th-TH)')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              s.tmdbKey = key.text;
              s.tmdbLang = lang.text.isEmpty ? 'en-US' : lang.text;
              s.wifiOnly = wifi;
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  key.dispose();
  lang.dispose();
}
