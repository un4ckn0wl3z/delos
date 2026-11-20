import 'package:flutter/material.dart';

import '../item_menu.dart';
import '../library.dart';
import '../widgets.dart';
import 'home_screen.dart';
import 'movies.dart' show CastRow;

class ShowsView extends StatefulWidget {
  const ShowsView({super.key, required this.app, required this.lib});
  final AppCtx app;
  final LibraryInfo lib;
  @override
  State<ShowsView> createState() => _ShowsViewState();
}

class _ShowsViewState extends State<ShowsView> {
  LibData? d;
  String q = '', genre = '';

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
    final shows = d!.series;
    final genres = <String>{for (final k in shows.keys) ...?d!.shows[k]?.genres}.toList()..sort();
    final words = q.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final keys = shows.keys.where((k) {
      final m = d!.shows[k];
      if (genre.isNotEmpty && !(m?.genres.contains(genre) ?? false)) return false;
      final hay = '${m?.title ?? k} ${m?.originalTitle ?? ''}'.toLowerCase();
      return words.every(hay.contains);
    }).toList()
      ..sort((a, b) => shows[b]!.map((e) => e.added).reduce((x, y) => x > y ? x : y).compareTo(shows[a]!.map((e) => e.added).reduce((x, y) => x > y ? x : y)));
    return Column(children: [
      SearchField(onChanged: (v) => setState(() => q = v), trailing: [
        const SizedBox(width: 8),
        DropdownButton<String>(
          value: genre,
          underline: const SizedBox(),
          items: [const DropdownMenuItem(value: '', child: Text('All genres')), for (final g in genres) DropdownMenuItem(value: g, child: Text(g))],
          onChanged: (v) => setState(() => genre = v ?? ''),
        ),
      ]),
      Expanded(
        child: keys.isEmpty
            ? const Center(child: Text('No shows'))
            : RefreshIndicator(
                onRefresh: () => _load(force: true),
                child: CardGrid(children: [
                  for (final k in keys)
                    PosterCard(
                      title: d!.shows[k]?.title ?? shows[k]!.first.title,
                      subtitle: '${shows[k]!.length} episodes${(d!.shows[k]?.year ?? 0) > 0 ? ' · ${d!.shows[k]!.year}' : ''}',
                      image: d!.shows[k]?.poster ?? '',
                      badge: _missingBadge(d!, k, shows[k]!),
                      onTap: () async {
                        await Navigator.push(context, MaterialPageRoute(builder: (_) => ShowScreen(app: widget.app, data: d!, show: k)));
                        if (mounted) setState(() {});
                      },
                      onLongPress: () => showItemMenu(context, widget.app, d!,
                          title: d!.shows[k]?.title ?? shows[k]!.first.title, items: shows[k]!, play: nextUp(shows[k]!), showKey: k, onChanged: () => _load(force: true)),
                    ),
                ]),
              ),
      ),
    ]);
  }
}

String _missingBadge(LibData d, String key, List<Item> eps) {
  final n = d.missingCount(key, eps);
  return n > 0 ? '$n missing' : '';
}

/// Series cards for a movie / plain-folder library (its S01E02 files), newest first.
List<Widget> seriesCards(BuildContext context, AppCtx app, LibData d, String q, Future<void> Function() reload, {String genre = ''}) {
  final shows = d.series;
  final words = q.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  int newest(List<Item> l) => l.map((e) => e.added).reduce((x, y) => x > y ? x : y);
  final keys = shows.keys.where((k) {
    final m = d.shows[k];
    if (genre.isNotEmpty && !(m?.genres.contains(genre) ?? false)) return false;
    final hay = '${m?.title ?? k} ${m?.originalTitle ?? ''} ${shows[k]!.map((e) => e.name).join(' ')}'.toLowerCase();
    return words.every(hay.contains);
  }).toList()
    ..sort((a, b) => newest(shows[b]!).compareTo(newest(shows[a]!)));
  return [
    for (final k in keys)
      PosterCard(
        title: d.shows[k]?.title ?? shows[k]!.first.title,
        subtitle: '📺 ${shows[k]!.length} file${shows[k]!.length > 1 ? 's' : ''}${(d.shows[k]?.year ?? 0) > 0 ? ' · ${d.shows[k]!.year}' : ''}',
        image: d.shows[k]?.poster ?? '',
        badge: _missingBadge(d, k, shows[k]!),
        onTap: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => ShowScreen(app: app, data: d, show: k)));
          await reload();
        },
        onLongPress: () => showItemMenu(context, app, d,
            title: d.shows[k]?.title ?? shows[k]!.first.title, items: shows[k]!, play: nextUp(shows[k]!), showKey: k, onChanged: reload),
      ),
  ];
}

Item? nextUp(List<Item> eps) {
  if (eps.isEmpty) return null;
  final sorted = [...eps]..sort(episodeOrder);
  final inProgress = sorted.where((e) => e.pos > 0).toList()..sort((a, b) => b.watched.compareTo(a.watched));
  if (inProgress.isNotEmpty) return inProgress.first;
  var last = -1, lastTs = 0;
  for (var i = 0; i < sorted.length; i++) {
    if (sorted[i].watched > lastTs) {
      lastTs = sorted[i].watched;
      last = i;
    }
  }
  if (last >= 0 && last + 1 < sorted.length) return sorted[last + 1];
  return sorted.first;
}

class ShowScreen extends StatefulWidget {
  const ShowScreen({super.key, required this.app, required this.data, required this.show});
  final AppCtx app;
  final LibData data;
  final String show;
  @override
  State<ShowScreen> createState() => _ShowScreenState();
}

class _ShowScreenState extends State<ShowScreen> {
  int? season;

  Future<void> _reload() async {
    final fresh = await widget.app.repo.lib(widget.data.info);
    if (!mounted) return;
    if (identical(fresh, widget.data)) {
      setState(() {});
    } else {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ShowScreen(app: widget.app, data: fresh, show: widget.show)));
    }
  }

  Future<void> _play(Item it) async {
    await openVideo(context, widget.app, widget.data, it);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final eps = widget.data.items.where((e) => e.show == widget.show).toList()..sort(episodeOrder);
    final m = widget.data.shows[widget.show];
    final seasons = eps.map((e) => e.season).toSet().toList()..sort();
    final next = nextUp(eps);
    season ??= next?.season ?? (seasons.isNotEmpty ? seasons.first : 0);
    final missingTotal = widget.data.missingCount(widget.show, eps);
    // files and missing episodes of this season, in episode order
    final rows = <(int, Item?, MissingEp?)>[
      for (final e in eps.where((e) => e.season == season)) (e.episode, e, null),
      for (final m in widget.data.missing(widget.show, eps, season!)) (m.episode, null, m),
    ]..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : (a.$2 != null ? -1 : 1));
    final title = m?.title ?? (eps.isNotEmpty ? eps.first.title : widget.show);
    return Scaffold(
      body: CustomScrollView(slivers: [
        SliverAppBar(
          expandedHeight: (m?.backdrop ?? '').isNotEmpty ? 220 : 0,
          pinned: true,
          title: Text(title),
          actions: [
            IconButton(
              icon: const Icon(Icons.more_vert),
              onPressed: () => showItemMenu(context, widget.app, widget.data, title: title, items: eps, play: next, showKey: widget.show, onChanged: _reload),
            ),
          ],
          flexibleSpace: (m?.backdrop ?? '').isNotEmpty
              ? FlexibleSpaceBar(
                  background: Stack(fit: StackFit.expand, children: [
                    NetImage(m!.backdrop),
                    const DecoratedBox(
                      decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black26, Color(0xFF0D0F13)])),
                    ),
                  ]),
                )
              : null,
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text([
                if ((m?.year ?? 0) > 0) '${m!.year}',
                if ((m?.rating ?? 0) > 0) '★ ${m!.rating.toStringAsFixed(1)}',
                '${eps.length} file${eps.length == 1 ? '' : 's'}',
              ].join(' · '), style: const TextStyle(color: Color(0xFF9AA3B2))),
              if (missingTotal > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('$missingTotal episode${missingTotal == 1 ? '' : 's'} missing', style: const TextStyle(color: Color(0xFFF5A623))),
                ),
              const SizedBox(height: 8),
              Chips(m?.genres ?? const []),
              if ((m?.overview ?? '').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Text(m!.overview, style: const TextStyle(height: 1.5))),
              if (next != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: FilledButton.icon(
                    icon: const Icon(Icons.play_arrow),
                    label: Text('${next.pos > 0 ? 'Resume' : 'Play'} S${next.season}E${next.episode}${next.episodeTitle.isNotEmpty ? ' · ${next.episodeTitle}' : ''}',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    onPressed: () => _play(next),
                  ),
                ),
            ]),
          ),
        ),
        SliverToBoxAdapter(child: CastRow(m?.cast ?? const [])),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Wrap(spacing: 8, children: [
              for (final s in seasons) ChoiceChip(label: Text(s == 0 ? 'Other' : 'Season $s'), selected: s == season, onSelected: (_) => setState(() => season = s)),
            ]),
          ),
        ),
        SliverList.list(children: [
          for (final (_, e0, m) in rows)
            if (m != null) _MissingRow(m) else ...[for (final e in [e0!])
            InkWell(
              onTap: () => _play(e),
              onLongPress: () => showItemMenu(context, widget.app, widget.data,
                  title: 'S${e.season}E${e.episode}${e.episodeTitle.isNotEmpty ? ' · ${e.episodeTitle}' : ''}', items: [e], play: e, showKey: widget.show, onChanged: _reload),
              onSecondaryTap: () => showItemMenu(context, widget.app, widget.data,
                  title: 'S${e.season}E${e.episode}${e.episodeTitle.isNotEmpty ? ' · ${e.episodeTitle}' : ''}', items: [e], play: e, showKey: widget.show, onChanged: _reload),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 150,
                      height: 84,
                      child: Stack(fit: StackFit.expand, children: [NetImage(e.still, placeholder: 'E${e.episode}'), ProgressStrip(e.progress)]),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${e.episode > 0 ? '${e.epLabel} · ' : ''}${e.episodeTitle.isNotEmpty ? e.episodeTitle : e.name}', maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w500)),
                      if (e.duration > 0) Text(fmtDur(e.duration), style: const TextStyle(fontSize: 12, color: Color(0xFF7D8696))),
                      if (e.episodeOverview.isNotEmpty)
                        Text(e.episodeOverview, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: Color(0xFF9AA3B2))),
                    ]),
                  ),
                ]),
              ),
            )],
          const SizedBox(height: 40),
        ]),
      ]),
    );
  }
}

/// A greyed placeholder for an episode the server doesn't have (yet).
class _MissingRow extends StatelessWidget {
  const _MissingRow(this.m);
  final MissingEp m;
  @override
  Widget build(BuildContext context) => Opacity(
        opacity: m.future ? .4 : .55,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 150,
              height: 84,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF2A313C)),
                color: const Color(0xFF161A21),
              ),
              child: Icon(m.future ? Icons.event_outlined : Icons.add, color: const Color(0xFF5D6675)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('E${m.episode}${m.title.isNotEmpty ? ' · ${m.title}' : ''}', maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w500)),
                Text(m.future ? 'Airs ${m.aired}' : 'Missing${m.aired.isNotEmpty ? ' · aired ${m.aired}' : ''}',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF7D8696))),
              ]),
            ),
          ]),
        ),
      );
}
