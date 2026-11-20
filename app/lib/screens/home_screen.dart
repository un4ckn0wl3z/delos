import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../autotest.dart';
import '../audio.dart';
import '../item_menu.dart';
import '../library.dart';
import '../media_session.dart';
import '../offline/local_player.dart';
import 'announcements.dart';
import '../offline/offline_view.dart';
import '../offline/store.dart';
import '../social.dart';
import '../update.dart';
import '../util.dart';
import '../widgets.dart';
import 'chat.dart';
import 'downloads.dart';
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
  /// May fix metadata matches (admin or editor role).
  bool editor = false;
  bool admin = false;
  /// May add downloads (admin or downloader role).
  bool downloader = false;
  /// May save files to this device (admin or "offline" permission).
  bool offline = false;
  /// Ids of this user's own personal libraries (deletable).
  Set<String> myLibs = {};
  /// Who's online + chats (live).
  Social? social;
}

/// Plays a video item; for episodes, offers the next one when it ends.
Future<void> openVideo(BuildContext context, AppCtx app, LibData d, Item it, {bool startOver = false}) async {
  app.audio.pause();
  FocusManager.instance.primaryFocus?.unfocus(); // a search field's keyboard would squeeze the player
  Item? next;
  if (it.show.isNotEmpty) {
    final eps = d.items.where((e) => e.show == it.show).toList()..sort(episodeOrder);
    final i = eps.indexWhere((e) => e.path == it.path);
    if (i >= 0 && i + 1 < eps.length) next = eps[i + 1];
  }
  // a copy on this device plays from there (works without internet too)
  final local = OfflineStore.instance.downloaded(app.api.settings.server, it.path);
  if (local != null) {
    if (!startOver && it.pos > local.pos) local.pos = it.pos; // further along on another device
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LocalPlayerScreen(item: local, api: app.api, settings: app.api.settings, startOver: startOver),
    ));
    app.repo.setPos(it.path, local.pos);
    return;
  }
  final file = it.toMediaFile(d.labelOf(it));
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => PlayerScreen(
      api: app.api,
      file: file,
      startOver: startOver,
      nextLabel: next == null ? null : 'S${next.season}E${next.episode}${next.episodeTitle.isNotEmpty ? ' · ${next.episodeTitle}' : ''}',
      onProgress: (pos) => app.repo.setPos(it.path, pos),
      onPlayNext: next == null ? null : () => openVideo(context, app, d, next!),
      saveInfo: app.offline ? offlineInfo(d, it) : null,
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
  List<LibraryInfo> get videoLibs => libs.where((l) => l.type != 'music').toList();
  List<LibraryInfo> get musicLibs => libs.where((l) => l.type == 'music').toList();
  /// Music side: '_all' (everything) or one music library's id.
  String musicSel = '_all';
  bool get _musicNav => musicLibs.length > 1 || musicLibs.any((l) => l.owner.isNotEmpty);
  /// 0 = Videos, 1 = Music, 2 = Chat, 3 = Downloads, 4 = Offline — separate sides with their own menus
  static int section = 0;
  int _lastMedia = 0;
  StreamSubscription? _incoming, _announce;
  int sel = 0; // Videos: 0 = home, i + 1 = videoLibs[i]
  String? error;
  bool loading = true;
  int reload = 0;
  static bool _updateChecked = false;

  @override
  void initState() {
    super.initState();
    _load();
    widget.api.me().then((m) {
      app.admin = m['admin'] == true;
      app.editor = m['editor'] == true || app.admin;
      app.downloader = m['downloader'] == true || app.admin;
      app.offline = m['offline'] == true || app.admin;
      app.audio.canSave = app.offline;
      if (!app.downloader && section == 3) section = 0;
      if (mounted) setState(() {});
    }).catchError((_) {});
    OfflineStore.instance.api = widget.api;
    MusicSession.attach(app.audio);
    if (AutoTest.config?['play'] == 'music') {
      Future.delayed(const Duration(seconds: 3), () async {
        try {
          final d = await app.repo.lib(LibraryRepo.allMusic);
          debugPrint('AUTOTEST: ${d.items.length} tracks');
          if (d.items.isNotEmpty) await app.audio.playQueue(d.items, 0);
          debugPrint('AUTOTEST: playing=${app.audio.playing}');
          if (AutoTest.config?['offline'] == true && d.items.length > 1) {
            // save two songs, then play the saved copy from its file
            await OfflineStore.instance.downloadMusic(app.api, d.items.take(2).toList());
            for (var i = 0; i < 150; i++) { // background downloads can take a while to be scheduled
              await Future.delayed(const Duration(seconds: 1));
              final saved = OfflineStore.instance.music.where((x) => x.ready).toList();
              if (saved.length >= 2) {
                debugPrint('AUTOTEST: saved ${saved.length} songs');
                await app.audio.playQueue([saved.first.toTrack()], 0);
                await Future.delayed(const Duration(seconds: 2));
                debugPrint('AUTOTEST: offline playing=${app.audio.playing} file=${app.audio.current?.path.startsWith('file:')}');
                break;
              }
              if (i == 149) debugPrint('AUTOTEST: offline save timed out (${OfflineStore.instance.music.map((x) => x.status).join(',')})');
            }
          }
        } catch (e) {
          debugPrint('AUTOTEST: play failed: $e');
        }
      });
    }
    app.social = Social(widget.api, app.audio)..start();
    _incoming = app.social!.incoming.stream.listen((e) {
      if (!mounted) return;
      final (conv, m) = e;
      final c = app.social!.convs.where((x) => x['id'] == conv).firstOrNull;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('💬 ${m['from']}${c != null && c['kind'] == 'group' ? ' in ${c['title']}' : ''}: ${Social.preview(m)}',
            maxLines: 2, overflow: TextOverflow.ellipsis),
        action: SnackBarAction(label: 'Open', onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(app: app, convId: conv)))),
      ));
    });
    // announcements: important ones pop up, others show as a SnackBar (📣 lists them all)
    _announce = app.social!.newAnnouncements.stream.listen((a) {
      if (!mounted) return;
      if (a['level'] == 'important') {
        showAnnouncementDialog(context, app.social!, a);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          duration: const Duration(seconds: 8),
          content: Text('${a['level'] == 'warning' ? '⚠️' : '📣'} ${a['title'] ?? ''}${'${a['body'] ?? ''}'.isNotEmpty ? ' — ${a['body']}' : ''}',
              maxLines: 3, overflow: TextOverflow.ellipsis),
          action: SnackBarAction(label: 'View', onPressed: _openAnnouncements),
        ));
      }
    });
    if (!_updateChecked) {
      _updateChecked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => checkForUpdate(context, widget.api.settings));
    }
  }

  Future<void> _openAnnouncements() async {
    final s = app.social;
    if (s == null) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AnnouncementsScreen(social: s)));
    s.loadAnnouncements();
  }

  @override
  void dispose() {
    _incoming?.cancel();
    _announce?.cancel();
    app.social?.dispose();
    NowWatching.onChange = null;
    app.audio.dispose();
    if (OfflineStore.instance.api == widget.api) OfflineStore.instance.api = null;
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    setState(() => loading = libs.isEmpty);
    try {
      libs = await app.repo.libraries(force: force);
      app.myLibs = {for (final l in libs) if (l.owner.isNotEmpty && l.owner == widget.api.settings.username) l.id};
      if (sel > videoLibs.length) sel = 0;
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
            Text('Delos', style: Theme.of(context).textTheme.titleLarge),
          ]),
        ),
        if (section == 1) ...[
          ListTile(
            leading: const Icon(Icons.library_music_outlined),
            title: const Text('All music'),
            selected: musicSel == '_all',
            onTap: () => _selectMusic('_all', drawer),
          ),
          ..._libGroups(musicLibs, (l) => musicSel == l.id, (l) => _selectMusic(l.id, drawer)),
        ] else ...[
          ListTile(
            leading: const Icon(Icons.home_outlined),
            title: const Text('Home'),
            selected: sel == 0,
            onTap: () => _select(0, drawer),
          ),
          ..._libGroups(videoLibs, (l) => sel == videoLibs.indexOf(l) + 1, (l) => _select(videoLibs.indexOf(l) + 1, drawer)),
        ],
        const Divider(),
        ListTile(
          leading: const Icon(Icons.settings_outlined),
          title: const Text('Settings'),
          onTap: () async {
            if (drawer) Navigator.pop(context);
            final out = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => SettingsScreen(api: widget.api, social: app.social)));
            if (out == true) _signOut();
          },
        ),
      ]);

  /// The server's libraries, then each person's (mine first) in a fold-out group.
  List<Widget> _libGroups(List<LibraryInfo> list, bool Function(LibraryInfo) selected, void Function(LibraryInfo) open) {
    final me = app.api.settings.username;
    Widget tile(LibraryInfo l, {bool indent = false}) => ListTile(
          contentPadding: EdgeInsets.only(left: indent ? 32 : 16, right: 16),
          leading: Icon(_icon(l.type)),
          title: Text(l.name),
          trailing: l.count > 0 ? Text('${l.count}', style: const TextStyle(fontSize: 12, color: Color(0xFF7D8696))) : null,
          selected: selected(l),
          onTap: () => open(l),
        );
    final owners = {for (final l in list) if (l.owner.isNotEmpty) l.owner}.toList()
      ..sort((a, b) => a == me ? -1 : (b == me ? 1 : a.toLowerCase().compareTo(b.toLowerCase())));
    return [
      if (owners.isNotEmpty)
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('LIBRARIES', style: TextStyle(fontSize: 11, letterSpacing: .8, color: Color(0xFF7D8696))),
        ),
      for (final l in list.where((l) => l.owner.isEmpty)) tile(l),
      for (final o in owners)
        Builder(builder: (context) {
          final mine = list.where((l) => l.owner == o).toList();
          return ExpansionTile(
            key: PageStorageKey('libs-$o'),
            initiallyExpanded: mine.any(selected),
            leading: app.social == null ? const Icon(Icons.person_outline) : UserAvatar(app.social!, o, radius: 13),
            title: Text(o == me ? 'My libraries' : o),
            trailing: Text('${mine.length}', style: const TextStyle(fontSize: 12, color: Color(0xFF7D8696))),
            shape: const Border(),
            collapsedShape: const Border(),
            children: [for (final l in mine) tile(l, indent: true)],
          );
        }),
    ];
  }

  void _selectMusic(String id, bool drawer) {
    if (drawer) Navigator.pop(context);
    setState(() => musicSel = id);
  }

  void _select(int i, bool drawer) {
    if (drawer) Navigator.pop(context);
    setState(() => sel = i);
  }

  Widget _body() {
    // the offline library works even when the server can't be reached
    if (section == 4) return OfflineView(api: widget.api, settings: widget.api.settings, audio: app.audio);
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
              OutlinedButton.icon(onPressed: () => _go(4), icon: const Icon(Icons.offline_pin_outlined), label: const Text('Offline library')),
            ]),
          ]),
        ),
      );
    }
    if (section == 1) {
      return libs.any((l) => l.type == 'music')
          ? MusicView(
              key: ValueKey('music$musicSel$reload'),
              app: app,
              lib: musicLibs.where((l) => l.id == musicSel).firstOrNull ?? LibraryRepo.allMusic)
          : const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('No music library yet — an admin can add one (type Music) in the dashboard.')));
    }
    if (section == 2) return ChatView(app: app);
    if (section == 3) return DownloadsView(key: ValueKey('dl$reload'), app: app, preferMusic: _lastMedia == 1);
    final vl = videoLibs;
    if (sel == 0 || sel > vl.length) return HomeView(key: ValueKey('home$reload'), app: app, libs: vl, open: (i) => setState(() => sel = i + 1));
    final lib = vl[sel - 1];
    final key = ValueKey('${lib.id}$reload');
    return switch (lib.type) {
      'movies' => MoviesView(key: key, app: app, lib: lib),
      'tv' => ShowsView(key: key, app: app, lib: lib),
      'music' => MusicView(key: key, app: app, lib: lib),
      _ => VideosView(key: key, app: app, lib: lib),
    };
  }

  Widget _badged(IconData icon, String label) {
    final n = label == 'Chat' ? app.social?.unread ?? 0 : 0;
    return n > 0 ? Badge(label: Text(n > 99 ? '99+' : '$n'), child: Icon(icon)) : Icon(icon);
  }

  void _go(int i) {
    if (i == section) return;
    setState(() {
      if (section < 2) _lastMedia = section;
      section = i;
    });
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 900;
    final vl = videoLibs;
    final title = switch (section) {
      1 => musicLibs.where((l) => l.id == musicSel).firstOrNull?.name ?? 'Music',
      2 => 'Chat',
      3 => 'Downloads',
      4 => 'Offline',
      _ => sel == 0 || sel > vl.length ? 'Home' : vl[sel - 1].name,
    };
    final dests = <(IconData, IconData, String, int)>[
      (Icons.movie_outlined, Icons.movie, 'Videos', 0),
      (Icons.library_music_outlined, Icons.library_music, 'Music', 1),
      (Icons.offline_pin_outlined, Icons.offline_pin, 'Offline', 4),
      (Icons.chat_bubble_outline, Icons.chat_bubble, 'Chat', 2),
      if (app.downloader) (Icons.download_outlined, Icons.download, 'Downloads', 3),
    ];
    final idx = dests.indexWhere((d) => d.$4 == section).clamp(0, dests.length - 1);
    void goIdx(int i) => _go(dests[i].$4);
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        automaticallyImplyLeading: !wide && (section == 0 || (section == 1 && _musicNav)),
        actions: [
          if (app.social != null)
            ListenableBuilder(
              listenable: app.social!,
              builder: (_, __) {
                final n = app.social!.annUnread;
                return IconButton(
                  tooltip: 'Announcements',
                  icon: Badge(isLabelVisible: n > 0, label: Text('$n'), child: const Icon(Icons.campaign_outlined)),
                  onPressed: _openAnnouncements,
                );
              },
            ),
          // music keeps playing on the Videos side: a shortcut back to it
          if (section != 1)
            ListenableBuilder(
              listenable: app.audio,
              builder: (_, __) => app.audio.active
                  ? IconButton(tooltip: 'Music is playing', icon: const Icon(Icons.graphic_eq), onPressed: () => _go(1))
                  : const SizedBox.shrink(),
            ),
          if (section == 4)
            IconButton(tooltip: 'Offline settings', icon: const Icon(Icons.tune), onPressed: () => offlineSettings(context, widget.api.settings)),
          IconButton(tooltip: 'Reload', icon: const Icon(Icons.refresh), onPressed: () {
            app.repo.invalidate();
            _load(force: true);
          }),
          if (section != 0)
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () async {
                final out = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => SettingsScreen(api: widget.api, social: app.social)));
                if (out == true) _signOut();
              },
            ),
        ],
      ),
      drawer: wide || !(section == 0 || (section == 1 && _musicNav)) ? null : Drawer(child: SafeArea(child: _nav(true))),
      body: Column(children: [
        Expanded(
          child: wide
              ? Row(children: [
                  ListenableBuilder(
                    listenable: app.social!,
                    builder: (_, __) => NavigationRail(
                      selectedIndex: idx,
                      labelType: NavigationRailLabelType.all,
                      onDestinationSelected: goIdx,
                      destinations: [for (final d in dests) NavigationRailDestination(icon: _badged(d.$1, d.$3), selectedIcon: _badged(d.$2, d.$3), label: Text(d.$3))],
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  if (section == 0 || (section == 1 && _musicNav)) ...[
                    SizedBox(width: 240, child: Material(color: const Color(0xFF11141A), child: _nav(false))),
                    const VerticalDivider(width: 1),
                  ],
                  Expanded(child: _body()),
                ])
              : _body(),
        ),
        // the music player lives on the Music side only
        if (section == 1) MiniPlayer(audio: app.audio),
      ]),
      bottomNavigationBar: wide
          ? null
          : ListenableBuilder(
              listenable: app.social!,
              builder: (_, __) => NavigationBar(
                selectedIndex: idx,
                onDestinationSelected: goIdx,
                destinations: [for (final d in dests) NavigationDestination(icon: _badged(d.$1, d.$3), selectedIcon: _badged(d.$2, d.$3), label: d.$3)],
              ),
            ),
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

  void _refresh() {
    if (mounted) _load();
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
            subtitle: it.show.isNotEmpty ? 'S${it.season}E${it.episode} · ${fmtDur(it.pos)}' : fmtDur(it.pos),
            image: it.still.isNotEmpty ? it.still : (d.movieOf(it)?.backdrop ?? d.showOf(it)?.backdrop ?? ''),
            aspect: 16 / 9,
            progress: it.progress,
            onTap: () async {
              await openVideo(context, app, d, it);
              if (mounted) setState(() {});
            },
            onLongPress: () => showItemMenu(context, app, d,
                title: d.labelOf(it), items: [it], play: it, showKey: it.show.isNotEmpty ? it.show : null, onChanged: _refresh),
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
            onLongPress: () => showItemMenu(context, app, d, title: m?.title ?? it.title, items: [it], play: it, onChanged: _refresh),
          ));
        } else if (type == 'tv') {
          if (!seen.add(it.show)) continue;
          final s = d.showOf(it);
          cards.add(PosterCard(
            title: s?.title ?? it.title,
            subtitle: 'New episodes',
            image: s?.poster ?? '',
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ShowScreen(app: app, data: d, show: it.show))),
            onLongPress: () {
              final eps = d.items.where((e) => e.show == it.show).toList();
              showItemMenu(context, app, d, title: s?.title ?? it.title, items: eps, play: nextUp(eps), showKey: it.show, onChanged: _refresh);
            },
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
          cards.add(PosterCard(
            title: it.name,
            subtitle: it.dir,
            aspect: 16 / 9,
            onTap: () => openVideo(context, app, d, it),
            onLongPress: () => showItemMenu(context, app, d, title: it.name, items: [it], play: it, onChanged: _refresh),
          ));
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
    final files = d!.items.where((f) => f.show.isEmpty && words.every((w) => f.path.toLowerCase().contains(w))).toList()
      ..sort((a, b) => '${a.dir}/${a.name}'.toLowerCase().compareTo('${b.dir}/${b.name}'.toLowerCase()));
    final rows = <Widget>[SearchField(onChanged: (v) => setState(() => q = v))];
    // S01E02 files group into series, on top
    final series = seriesCards(context, widget.app, d!, q, () => widget.app.repo.lib(widget.lib, force: true).then((v) {
          if (mounted) setState(() => d = v);
        }));
    if (series.isNotEmpty) {
      rows.add(const SectionTitle('Series'));
      rows.add(CardGrid(shrink: true, children: series));
      if (files.isNotEmpty) rows.add(const SectionTitle('Files'));
    }
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
        onLongPress: () => showItemMenu(context, widget.app, d!, title: f.name, items: [f], play: f, onChanged: () {
          if (mounted) setState(() {});
        }),
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
          const RawNamesButton(),
        ]),
      );
}
