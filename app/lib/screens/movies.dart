import 'package:flutter/material.dart';

import '../offline/store.dart';
import '../item_menu.dart';
import '../library.dart';
import '../util.dart';
import '../widgets.dart';
import 'home_screen.dart';
import 'shows.dart' show seriesCards;

class MovieGroup {
  MovieGroup(this.key, this.meta);
  final String key;
  final Meta? meta;
  final items = <Item>[];
  String get title => meta?.title ?? (items.first.title.isNotEmpty ? items.first.title : items.first.name);
  int get year => meta?.year ?? items.first.year;
  int get added => items.map((i) => i.added).reduce((a, b) => a > b ? a : b);
  Item get main => items.firstWhere((i) => i.pos > 0, orElse: () => items.first);
}

List<MovieGroup> movieGroups(LibData d) {
  final m = <String, MovieGroup>{};
  for (final it in d.items) {
    if (it.show.isNotEmpty) continue; // an episode: it's in a series card
    final k = it.movieId != 0 ? '${it.movieId}' : it.path;
    m.putIfAbsent(k, () => MovieGroup(k, d.movieOf(it))).items.add(it);
  }
  return m.values.toList();
}

class MoviesView extends StatefulWidget {
  const MoviesView({super.key, required this.app, required this.lib});
  final AppCtx app;
  final LibraryInfo lib;
  @override
  State<MoviesView> createState() => _MoviesViewState();
}

class _MoviesViewState extends State<MoviesView> {
  LibData? d;
  String q = '', genre = '', sort = 'added';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = false}) async {
    final v = await widget.app.repo.lib(widget.lib, force: force);
    if (mounted) setState(() => d = v);
  }

  @override
  Widget build(BuildContext context) {
    if (d == null) return const Center(child: CircularProgressIndicator());
    final groups = movieGroups(d!);
    final genres = <String>{for (final g in groups) ...?g.meta?.genres}.toList()..sort();
    final words = q.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final list = groups.where((g) {
      if (genre.isNotEmpty && !(g.meta?.genres.contains(genre) ?? false)) return false;
      final hay = [g.title, g.meta?.originalTitle ?? '', '${g.year}', g.meta?.director ?? '', ...?g.meta?.cast.map((c) => c.name)].join(' ').toLowerCase();
      return words.every(hay.contains);
    }).toList();
    switch (sort) {
      case 'title':
        list.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      case 'year':
        list.sort((a, b) => b.year.compareTo(a.year));
      case 'rating':
        list.sort((a, b) => (b.meta?.rating ?? 0).compareTo(a.meta?.rating ?? 0));
      default:
        list.sort((a, b) => b.added.compareTo(a.added));
    }
    final series = seriesCards(context, widget.app, d!, q, () => _load(force: true), genre: genre);
    return Column(children: [
      SearchField(onChanged: (v) => setState(() => q = v), trailing: [
        const SizedBox(width: 8),
        DropdownButton<String>(
          value: genre,
          underline: const SizedBox(),
          items: [const DropdownMenuItem(value: '', child: Text('All genres')), for (final g in genres) DropdownMenuItem(value: g, child: Text(g))],
          onChanged: (v) => setState(() => genre = v ?? ''),
        ),
        const SizedBox(width: 8),
        DropdownButton<String>(
          value: sort,
          underline: const SizedBox(),
          items: const [
            DropdownMenuItem(value: 'added', child: Text('Recent')),
            DropdownMenuItem(value: 'title', child: Text('Title')),
            DropdownMenuItem(value: 'year', child: Text('Year')),
            DropdownMenuItem(value: 'rating', child: Text('Rating')),
          ],
          onChanged: (v) => setState(() => sort = v ?? 'added'),
        ),
      ]),
      Expanded(
        child: list.isEmpty && series.isEmpty
            ? const Center(child: Text('No movies'))
            : RefreshIndicator(
                onRefresh: () => _load(force: true),
                child: CardGrid(children: [
                  ...series, // series first (episodes found in this movie library)
                  for (final g in list)
                    PosterCard(
                      title: g.title,
                      subtitle: [if (g.year > 0) '${g.year}', if ((g.meta?.rating ?? 0) > 0) '★ ${g.meta!.rating.toStringAsFixed(1)}'].join(' · '),
                      image: g.meta?.poster ?? '',
                      progress: g.main.progress,
                      raw: rawOf(g.items.map((i) => i.name), RawNames.tmdb(g.meta?.tmdbId ?? 0)),
                      badge: [
                        if (g.items.any((i) => OfflineStore.instance.downloaded(widget.app.api.settings.server, i.path) != null)) '📥',
                        if (g.items.length > 1) '${g.items.length} versions',
                      ].join(' '),
                      onTap: () async {
                        await Navigator.push(context, MaterialPageRoute(builder: (_) => MovieScreen(app: widget.app, data: d!, groupKey: g.key)));
                        if (mounted) setState(() {});
                      },
                      onLongPress: () => showItemMenu(context, widget.app, d!, title: g.title, items: g.items, play: g.main, onChanged: () => _load(force: true)),
                    ),
                ]),
              ),
      ),
    ]);
  }
}

class CastRow extends StatelessWidget {
  const CastRow(this.cast, {super.key});
  final List<Person> cast;
  @override
  Widget build(BuildContext context) => cast.isEmpty
      ? const SizedBox.shrink()
      : SizedBox(
          height: 128,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: cast.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (_, i) => SizedBox(
              width: 84,
              child: Column(children: [
                ClipOval(child: SizedBox(width: 64, height: 64, child: NetImage(cast[i].photo, placeholder: cast[i].name.isNotEmpty ? cast[i].name[0] : '?'))),
                const SizedBox(height: 4),
                Text(cast[i].name, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                Text(cast[i].role, maxLines: 1, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Color(0xFF7D8696))),
              ]),
            ),
          ),
        );
}

class MovieScreen extends StatefulWidget {
  const MovieScreen({super.key, required this.app, required this.data, required this.groupKey});
  final AppCtx app;
  final LibData data;
  final String groupKey;
  @override
  State<MovieScreen> createState() => _MovieScreenState();
}

class _MovieScreenState extends State<MovieScreen> {
  @override
  Widget build(BuildContext context) {
    final g = movieGroups(widget.data).where((x) => x.key == widget.groupKey).firstOrNull;
    if (g == null) return Scaffold(appBar: AppBar(), body: const Center(child: Text('Not found')));
    final m = g.meta;
    return Scaffold(
      body: CustomScrollView(slivers: [
        SliverAppBar(
          expandedHeight: m != null && m.backdrop.isNotEmpty ? 240 : 0,
          pinned: true,
          actions: [
            IconButton(
              icon: const Icon(Icons.more_vert),
              onPressed: () => showItemMenu(context, widget.app, widget.data, title: g.title, items: g.items, play: g.main, onChanged: () async {
                final fresh = await widget.app.repo.lib(widget.data.info, force: true);
                if (!context.mounted) return;
                Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => MovieScreen(app: widget.app, data: fresh, groupKey: g.key)));
              }),
            ),
          ],
          flexibleSpace: m != null && m.backdrop.isNotEmpty
              ? FlexibleSpaceBar(
                  background: Stack(fit: StackFit.expand, children: [
                    NetImage(m.backdrop),
                    const DecoratedBox(
                      decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Color(0xFF0D0F13)])),
                    ),
                  ]),
                )
              : null,
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (m != null && m.poster.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: ClipRRect(borderRadius: BorderRadius.circular(8), child: SizedBox(width: 110, height: 165, child: NetImage(m.poster))),
                ),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(g.title, style: Theme.of(context).textTheme.headlineSmall),
                  if ((m?.originalTitle ?? '').isNotEmpty) Text(m!.originalTitle, style: const TextStyle(color: Color(0xFF8B95A5))),
                  const SizedBox(height: 4),
                  Text([
                    if (g.year > 0) '${g.year}',
                    if ((m?.runtime ?? 0) > 0) '${m!.runtime} min',
                    if ((m?.rating ?? 0) > 0) '★ ${m!.rating.toStringAsFixed(1)}',
                  ].join(' · '), style: const TextStyle(color: Color(0xFF9AA3B2))),
                  const SizedBox(height: 8),
                  Chips(m?.genres ?? const []),
                  if ((m?.director ?? '').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Director: ${m!.director}', style: const TextStyle(color: Color(0xFF8B95A5)))),
                ]),
              ),
            ]),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final it in g.items)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(children: [
                      FilledButton.icon(
                        icon: const Icon(Icons.play_arrow),
                        label: Text(it.pos > 0 ? 'Resume ${fmtDur(it.pos)}' : 'Play'),
                        onPressed: () async {
                          await openVideo(context, widget.app, widget.data, it);
                          if (mounted) setState(() {});
                        },
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text('${it.name}\n${fmtSize(it.size)}', maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Color(0xFF9AA3B2)))),
                    ]),
                  ),
                ),
              if ((m?.overview ?? '').isNotEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(m!.overview, style: const TextStyle(height: 1.5))),
            ]),
          ),
        ),
        SliverToBoxAdapter(child: CastRow(m?.cast ?? const [])),
        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ]),
    );
  }
}
