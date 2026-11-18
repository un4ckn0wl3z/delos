import 'package:flutter/material.dart';

import '../audio.dart';
import '../library.dart';
import '../widgets.dart';
import 'home_screen.dart';

class MusicView extends StatefulWidget {
  const MusicView({super.key, required this.app, required this.lib});
  final AppCtx app;
  final LibraryInfo lib;
  @override
  State<MusicView> createState() => _MusicViewState();
}

class _MusicViewState extends State<MusicView> {
  LibData? d;
  String q = '';

  @override
  void initState() {
    super.initState();
    widget.app.repo.lib(widget.lib).then((v) {
      if (mounted) setState(() => d = v);
    });
  }

  bool _match(List<String> fields) {
    final words = q.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final hay = fields.join(' ').toLowerCase();
    return words.every(hay.contains);
  }

  @override
  Widget build(BuildContext context) {
    if (d == null) return const Center(child: CircularProgressIndicator());
    final app = widget.app;
    final albums = albumsOf(d!.items)..sort((a, b) => b.added.compareTo(a.added));
    final artists = <String, List<Album>>{};
    for (final a in albums) {
      artists.putIfAbsent(a.artist, () => []).add(a);
    }
    final genres = <String, List<Album>>{};
    for (final a in albums) {
      for (final g in (a.genres.isEmpty ? {'Unknown'} : a.genres)) {
        genres.putIfAbsent(g, () => []).add(a);
      }
    }
    final songs = d!.items.where((t) => _match([t.title, t.artist, t.album])).toList()
      ..sort((a, b) => a.artist.toLowerCase().compareTo(b.artist.toLowerCase()) != 0
          ? a.artist.toLowerCase().compareTo(b.artist.toLowerCase())
          : (a.album.compareTo(b.album) != 0 ? a.album.compareTo(b.album) : trackOrder(a, b)));
    final artistNames = artists.keys.where((n) => _match([n])).toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final genreNames = genres.keys.where((n) => _match([n])).toList()..sort();

    return DefaultTabController(
      length: 4,
      child: Column(children: [
        SearchField(onChanged: (v) => setState(() => q = v), trailing: [
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Shuffle all',
            icon: const Icon(Icons.shuffle),
            onPressed: () => app.audio.playQueue(d!.items, 0, shuffled: true),
          ),
        ]),
        const TabBar(isScrollable: true, tabs: [Tab(text: 'Albums'), Tab(text: 'Artists'), Tab(text: 'Genres'), Tab(text: 'Songs')]),
        Expanded(
          child: TabBarView(children: [
            AlbumGrid(app: app, data: d!, albums: albums.where((a) => _match([a.title, a.artist, '${a.year}'])).toList()),
            CardGrid(aspect: 1, minWidth: 150, children: [
              for (final n in artistNames)
                PosterCard(
                  title: n,
                  subtitle: '${artists[n]!.length} albums',
                  image: app.api.coverUrl(artists[n]!.first.cover),
                  headers: app.api.authHeaders,
                  aspect: 1,
                  round: true,
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ArtistScreen(app: app, data: d!, artist: n))),
                ),
            ]),
            ListView(children: [
              for (final g in genreNames)
                ListTile(
                  leading: const Icon(Icons.label_outline),
                  title: Text(g),
                  trailing: Text('${genres[g]!.length}'),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => Scaffold(appBar: AppBar(title: Text(g)), body: AlbumGrid(app: app, data: d!, albums: genres[g]!))),
                  ),
                ),
            ]),
            TrackList(app: app, tracks: songs, showAlbum: true),
          ]),
        ),
      ]),
    );
  }
}

class AlbumGrid extends StatelessWidget {
  const AlbumGrid({super.key, required this.app, required this.data, required this.albums});
  final AppCtx app;
  final LibData data;
  final List<Album> albums;
  @override
  Widget build(BuildContext context) => albums.isEmpty
      ? const Center(child: Text('No albums'))
      : CardGrid(aspect: 1, minWidth: 150, children: [
          for (final a in albums)
            PosterCard(
              title: a.title,
              subtitle: '${a.artist}${a.year > 0 ? ' · ${a.year}' : ''}',
              image: app.api.coverUrl(a.cover),
              headers: app.api.authHeaders,
              aspect: 1,
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AlbumScreen(app: app, data: data, album: a))),
            ),
        ]);
}

class TrackList extends StatelessWidget {
  const TrackList({super.key, required this.app, required this.tracks, this.showAlbum = false, this.shrink = false});
  final AppCtx app;
  final List<Item> tracks;
  final bool showAlbum, shrink;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app.audio,
        builder: (context, _) => ListView.builder(
          shrinkWrap: shrink,
          physics: shrink ? const NeverScrollableScrollPhysics() : null,
          padding: const EdgeInsets.only(bottom: 24),
          itemCount: tracks.length,
          itemBuilder: (_, i) {
            final t = tracks[i];
            final on = app.audio.current?.path == t.path;
            return ListTile(
              dense: true,
              selected: on,
              leading: SizedBox(
                width: 28,
                child: on
                    ? const Icon(Icons.graphic_eq, size: 18)
                    : Text(t.track > 0 ? '${t.track}' : '', textAlign: TextAlign.right, style: const TextStyle(color: Color(0xFF7D8696))),
              ),
              title: Text(t.title.isNotEmpty ? t.title : t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: showAlbum ? Text([t.artist, t.album].where((e) => e.isNotEmpty).join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis) : null,
              trailing: Text(t.duration > 0 ? fmtDur(t.duration) : '', style: const TextStyle(fontSize: 12, color: Color(0xFF7D8696))),
              onTap: () => app.audio.playQueue(tracks, i),
            );
          },
        ),
      );
}

class AlbumScreen extends StatelessWidget {
  const AlbumScreen({super.key, required this.app, required this.data, required this.album});
  final AppCtx app;
  final LibData data;
  final Album album;
  @override
  Widget build(BuildContext context) {
    final total = album.tracks.fold<double>(0, (s, t) => s + t.duration);
    return Scaffold(
      appBar: AppBar(title: Text(album.title)),
      body: Column(children: [
        Expanded(
          child: ListView(children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(width: 140, height: 140, child: NetImage(app.api.coverUrl(album.cover), headers: app.api.authHeaders, placeholder: album.title)),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(album.title, style: Theme.of(context).textTheme.titleLarge),
                    InkWell(
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ArtistScreen(app: app, data: data, artist: album.artist))),
                      child: Text(album.artist, style: TextStyle(color: Theme.of(context).colorScheme.primary)),
                    ),
                    Text('${album.year > 0 ? '${album.year} · ' : ''}${album.tracks.length} songs · ${fmtDur(total)}', style: const TextStyle(color: Color(0xFF8B95A5))),
                    const SizedBox(height: 8),
                    Chips(album.genres.toList()),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, children: [
                      FilledButton.icon(icon: const Icon(Icons.play_arrow), label: const Text('Play'), onPressed: () => app.audio.playQueue(album.tracks, 0)),
                      OutlinedButton.icon(icon: const Icon(Icons.shuffle), label: const Text('Shuffle'), onPressed: () => app.audio.playQueue(album.tracks, 0, shuffled: true)),
                    ]),
                  ]),
                ),
              ]),
            ),
            TrackList(app: app, tracks: album.tracks, shrink: true),
          ]),
        ),
        MiniPlayer(audio: app.audio),
      ]),
    );
  }
}

class ArtistScreen extends StatelessWidget {
  const ArtistScreen({super.key, required this.app, required this.data, required this.artist});
  final AppCtx app;
  final LibData data;
  final String artist;
  @override
  Widget build(BuildContext context) {
    final albums = albumsOf(data.items).where((a) => a.artist == artist).toList()..sort((a, b) => b.year.compareTo(a.year));
    final songs = data.items.where((t) => t.artist == artist || t.albumArtist == artist).toList()
      ..sort((a, b) => a.album.compareTo(b.album) != 0 ? a.album.compareTo(b.album) : trackOrder(a, b));
    return Scaffold(
      appBar: AppBar(title: Text(artist), actions: [
        IconButton(icon: const Icon(Icons.shuffle), onPressed: () => app.audio.playQueue(songs, 0, shuffled: true)),
        IconButton(icon: const Icon(Icons.play_arrow), onPressed: () => app.audio.playQueue(songs, 0)),
      ]),
      body: Column(children: [
        Expanded(
          child: ListView(children: [
            const SectionTitle('Albums'),
            HRow(itemWidth: 140, aspect: 1, children: [
              for (final a in albums)
                PosterCard(
                  title: a.title,
                  subtitle: a.year > 0 ? '${a.year}' : '',
                  image: app.api.coverUrl(a.cover),
                  headers: app.api.authHeaders,
                  aspect: 1,
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AlbumScreen(app: app, data: data, album: a))),
                ),
            ]),
            const SectionTitle('Songs'),
            TrackList(app: app, tracks: songs, showAlbum: true, shrink: true),
          ]),
        ),
        MiniPlayer(audio: app.audio),
      ]),
    );
  }
}
