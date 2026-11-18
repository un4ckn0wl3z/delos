import 'package:flutter/material.dart';

import '../api.dart';
import '../audio.dart';
import '../library.dart';
import '../update.dart';
import '../util.dart';
import '../widgets.dart';
import 'login_screen.dart';
import 'movies.dart';
import 'music.dart';
import 'player_screen.dart';
import 'settings_screen.dart';
import 'shows.dart';

/// Shared state handed to every view.
class AppCtx {
  AppCtx(this.api) : repo = LibraryRepo(api), audio = AudioController(api);
  final Api api;
  final LibraryRepo repo;
  final AudioController audio;
}

/// Plays a video item; for episodes, offers the next one when it ends.
Future<void> openVideo(BuildContext context, AppCtx app, LibData d, Item it) async {
  app.audio.pause();
  FocusManager.instance.primaryFocus?.unfocus(); // a search field's keyboard would squeeze the player
  Item? next;
  if (d.info.type == 'tv') {
    final eps = d.items.where((e) => e.show == it.show).toList()..sort(episodeOrder);
    final i = eps.indexWhere((e) => e.path == it.path);
    if (i >= 0 && i + 1 < eps.length) next = eps[i + 1];
  }
  final file = it.toMediaFile(d.labelOf(it));
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => PlayerScreen(
      api: app.api,
      file: file,
      nextLabel: next == null ? null : 'S${next.season}E${next.episode}${next.episodeTitle.isNotEmpty ? ' · ${next.episodeTitle}' : ''}',
      onProgress: (pos) => app.repo.setPos(it.path, pos),
      onPlayNext: next == null ? null : () => openVideo(context, app, d, next!),
    ),
  ));
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.api});
  final Api api;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final AppCtx app = AppCtx(widget.api);
  List<LibraryInfo> libs = [];
  int sel = 0; // 0 = home
  String? error;
  bool loading = true;
  int reload = 0;
  static bool _updateChecked = false;

  @override
  void initState() {
    super.initState();
    _load();
    if (!_updateChecked) {
      _updateChecked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => checkForUpdate(context, widget.api.settings));
    }
  }

  @override
  void dispose() {
    app.audio.dispose();
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    setState(() => loading = libs.isEmpty);
    try {
      libs = await app.repo.libraries(force: force);
      if (sel > libs.length) sel = 0;
      error = null;
    } on ApiException catch (e) {
      error = e.message;
      if (e.unauthorized) error = '${e.message} — sign in again';
    }
    if (mounted) {
      setState(() {
        loading = false;
        reload++;
      });
    }
  }

  void _signOut() async {
    await app.audio.stop();
    await widget.api.settings.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => LoginScreen(settings: widget.api.settings)), (_) => false);
  }

  IconData _icon(String type) => switch (type) {
        'movies' => Icons.movie_outlined,
        'tv' => Icons.live_tv_outlined,
        'music' => Icons.library_music_outlined,
        _ => Icons.folder_outlined,
      };

  Widget _nav(bool drawer) => ListView(padding: EdgeInsets.zero, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 12),
          child: Row(children: [
            const Icon(Icons.movie_filter_rounded, color: Color(0xFF4A9EFF)),
            const SizedBox(width: 10),
            Text('StreamMKV', style: Theme.of(context).textTheme.titleLarge),
          ]),
        ),
        ListTile(
          leading: const Icon(Icons.home_outlined),
          title: const Text('Home'),
          selected: sel == 0,
          onTap: () => _select(0, drawer),
        ),
        for (var i = 0; i < libs.length; i++)
          ListTile(
            leading: Icon(_icon(libs[i].type)),
            title: Text(libs[i].name),
            trailing: libs[i].count > 0 ? Text('${libs[i].count}', style: const TextStyle(fontSize: 12, color: Color(0xFF7D8696))) : null,
            selected: sel == i + 1,
            onTap: () => _select(i + 1, drawer),
          ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.settings_outlined),
          title: const Text('Settings'),
          onTap: () async {
            if (drawer) Navigator.pop(context);
            final out = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => SettingsScreen(api: widget.api)));
            if (out == true) _signOut();
          },
        ),
      ]);

  void _select(int i, bool drawer) {
    if (drawer) Navigator.pop(context);
    setState(() => sel = i);
  }

  Widget _body() {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Wrap(spacing: 12, children: [
              FilledButton(onPressed: () => _load(force: true), child: const Text('Retry')),
              OutlinedButton(onPressed: _signOut, child: const Text('Sign in again')),
            ]),
          ]),
        ),
      );
    }
    if (sel == 0) return HomeView(key: ValueKey('home$reload'), app: app, libs: libs, open: (i) => setState(() => sel = i + 1));
    final lib = libs[sel - 1];
    final key = ValueKey('${lib.id}$reload');
    return switch (lib.type) {
      'movies' => MoviesView(key: key, app: app, lib: lib),
      'tv' => ShowsView(key: key, app: app, lib: lib),
      'music' => MusicView(key: key, app: app, lib: lib),
      _ => VideosView(key: key, app: app, lib: lib),
    };
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 900;
    final title = sel == 0 || sel > libs.length ? 'Home' : libs[sel - 1].name;
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        automaticallyImplyLeading: !wide,
        actions: [
          IconButton(tooltip: 'Reload', icon: const Icon(Icons.refresh), onPressed: () {
            app.repo.invalidate();
            _load(force: true);
          }),
        ],
      ),
      drawer: wide ? null : Drawer(child: SafeArea(child: _nav(true))),
      body: Column(children: [
        Expanded(
          child: wide
              ? Row(children: [
                  SizedBox(width: 240, child: Material(color: const Color(0xFF11141A), child: _nav(false))),
                  const VerticalDivider(width: 1),
                  Expanded(child: _body()),
                ])
              : _body(),
        ),
        MiniPlayer(audio: app.audio),
      ]),
    );
  }
}

// ---------------------------------------------------------------- home

class HomeView extends StatefulWidget {
  const HomeView({super.key, required this.app, required this.libs, required this.open});
  final AppCtx app;
  final List<LibraryInfo> libs;
  final void Function(int) open;
  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  List<LibData> data = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final out = <LibData>[];
    for (final l in widget.libs) {
      try {
        out.add(await widget.app.repo.lib(l));
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        data = out;
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    final app = widget.app;
    final cont = <(LibData, Item)>[];
    for (final d in data) {
      if (d.info.type == 'music') continue;
      for (final it in d.items) {
        if (it.pos > 0) cont.add((d, it));
      }
    }
    cont.sort((a, b) => b.$2.watched.compareTo(a.$2.watched));
    final sections = <Widget>[];
    if (cont.isNotEmpty) {
      sections.add(const SectionTitle('Continue watching'));
      sections.add(HRow(itemWidth: 240, aspect: 16 / 9, children: [
        for (final (d, it) in cont.take(20))
          PosterCard(
            title: d.movieOf(it)?.title ?? d.showOf(it)?.title ?? it.name,
            subtitle: d.info.type == 'tv' ? 'S${it.season}E${it.episode} · ${fmtDur(it.pos)}' : fmtDur(it.pos),
            image: it.still.isNotEmpty ? it.still : (d.movieOf(it)?.backdrop ?? d.showOf(it)?.backdrop ?? ''),
            aspect: 16 / 9,
            progress: it.progress,
            onTap: () async {
              await openVideo(context, app, d, it);
              if (mounted) setState(() {});
            },
          ),
      ]));
    }
    for (var li = 0; li < data.length; li++) {
      final d = data[li];
      final items = [...d.items]..sort((a, b) => b.added.compareTo(a.added));
      final cards = <Widget>[];
      final seen = <String>{};
      var aspect = 2 / 3;
      final albums = d.info.type == 'music' ? {for (final a in albumsOf(d.items)) a.key: a} : <String, Album>{};
      for (final it in items) {
        if (cards.length >= 16) break;
        final type = d.info.type;
        if (type == 'movies') {
          if (!seen.add('${it.movieId != 0 ? it.movieId : it.path}')) continue;
          final m = d.movieOf(it);
          cards.add(PosterCard(
            title: m?.title ?? it.title,
            subtitle: '${m?.year ?? it.year}',
            image: m?.poster ?? '',
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MovieScreen(app: app, data: d, groupKey: it.movieId != 0 ? '${it.movieId}' : it.path))),
          ));
        } else if (type == 'tv') {
          if (!seen.add(it.show)) continue;
          final s = d.showOf(it);
          cards.add(PosterCard(
            title: s?.title ?? it.title,
            subtitle: 'New episodes',
            image: s?.poster ?? '',
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ShowScreen(app: app, data: d, show: it.show))),
          ));
        } else if (type == 'music') {
          if (!seen.add(it.albumKey)) continue;
          aspect = 1;
          final album = albums[it.albumKey]!;
          cards.add(PosterCard(
            title: album.title,
            subtitle: album.artist,
            image: app.api.coverUrl(album.cover),
            headers: app.api.authHeaders,
            aspect: 1,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AlbumScreen(app: app, data: d, album: album))),
          ));
        } else {
          aspect = 16 / 9;
          cards.add(PosterCard(title: it.name, subtitle: it.dir, aspect: 16 / 9, onTap: () => openVideo(context, app, d, it)));
        }
      }
      if (cards.isEmpty) continue;
      sections.add(SectionTitle('Recently added · ${d.info.name}', onMore: () => widget.open(widget.libs.indexWhere((l) => l.id == d.info.id))));
      sections.add(HRow(itemWidth: aspect > 1 ? 220 : 130, aspect: aspect, children: cards));
    }
    if (sections.isEmpty) {
      return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('No libraries yet — an admin can add them in the dashboard.')));
    }
    return RefreshIndicator(
      onRefresh: () async {
        app.repo.invalidate();
        await _load();
      },
      child: ListView(padding: const EdgeInsets.only(bottom: 24), children: sections),
    );
  }
}

// ---------------------------------------------------------------- plain folders

class VideosView extends StatefulWidget {
  const VideosView({super.key, required this.app, required this.lib});
  final AppCtx app;
  final LibraryInfo lib;
  @override
  State<VideosView> createState() => _VideosViewState();
}

class _VideosViewState extends State<VideosView> {
  LibData? d;
  String q = '';

  @override
  void initState() {
    super.initState();
    widget.app.repo.lib(widget.lib).then((v) {
      if (mounted) setState(() => d = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (d == null) return const Center(child: CircularProgressIndicator());
    final words = q.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final files = d!.items.where((f) => words.every((w) => f.path.toLowerCase().contains(w))).toList()
      ..sort((a, b) => '${a.dir}/${a.name}'.toLowerCase().compareTo('${b.dir}/${b.name}'.toLowerCase()));
    final rows = <Widget>[SearchField(onChanged: (v) => setState(() => q = v))];
    String? last;
    for (final f in files) {
      if (f.dir != last) {
        last = f.dir;
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text((f.dir.isEmpty ? '/' : f.dir).toUpperCase(), style: const TextStyle(fontSize: 11, letterSpacing: .6, color: Color(0xFF7D8696))),
        ));
      }
      rows.add(ListTile(
        leading: Icon(f.pos > 0 ? Icons.play_circle_fill : Icons.movie_outlined, color: f.pos > 0 ? Theme.of(context).colorScheme.primary : null),
        title: Text(f.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(f.pos > 0 ? '${fmtSize(f.size)} · ${fmtDur(f.pos)} / ${fmtDur(f.duration)}' : fmtSize(f.size)),
          if (f.pos > 0) Padding(padding: const EdgeInsets.only(top: 6), child: LinearProgressIndicator(value: f.progress, minHeight: 3)),
        ]),
        onTap: () async {
          await openVideo(context, widget.app, d!, f);
          if (mounted) setState(() {});
        },
      ));
    }
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: rows);
  }
}

class SearchField extends StatelessWidget {
  const SearchField({super.key, required this.onChanged, this.trailing = const []});
  final ValueChanged<String> onChanged;
  final List<Widget> trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(children: [
          Expanded(
            child: TextField(
              onChanged: onChanged,
              decoration: const InputDecoration(
                hintText: 'Search…',
                prefixIcon: Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          ...trailing,
        ]),
      );
}
