import 'api.dart';
import 'models.dart';

double _d(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
int _i(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
String _s(dynamic v) => v == null ? '' : '$v';
List<String> _l(dynamic v) => v is List ? v.map((e) => '$e').toList() : const [];

class LibraryInfo {
  LibraryInfo(this.id, this.name, this.type, this.count, {this.owner = '', this.shared = false});
  final String id, name, type;
  final int count;
  /// Personal library of this user ('' = an admin library).
  final String owner;
  final bool shared;
  factory LibraryInfo.fromJson(Map j) =>
      LibraryInfo(_s(j['id']), _s(j['name']), _s(j['type']), _i(j['count']), owner: _s(j['owner']), shared: j['shared'] == true);
}

class Person {
  Person(this.name, this.role, this.photo);
  final String name, role, photo;
  factory Person.fromJson(Map j) => Person(_s(j['name']), _s(j['role']), _s(j['photo']));
}

/// Movie or show metadata (same shape for both).
class Meta {
  Meta(this.j);
  final Map j;
  String get title => _s(j['title']);
  String get originalTitle => _s(j['originalTitle']);
  int get year => _i(j['year']);
  String get overview => _s(j['overview']);
  List<String> get genres => _l(j['genres']);
  String get poster => _s(j['poster']);
  String get backdrop => _s(j['backdrop']);
  double get rating => _d(j['rating']);
  int get runtime => _i(j['runtime']);
  String get director => _s(j['director']);
  int get tmdbId => _i(j['tmdbId'] ?? j['id']);
  List<Person> get cast => (j['cast'] as List? ?? const []).map((e) => Person.fromJson(e as Map)).toList();
}

class Item {
  Item(this.j);
  final Map j;
  String get path => _s(j['path']);
  String get name => _s(j['name']);
  String get dir => _s(j['dir']);
  int get size => _i(j['size']);
  int get added => _i(j['added']);
  double get duration => _d(j['duration']);
  double get pos => _d(j['pos']);
  set pos(double v) => j['pos'] = v;
  int get watched => _i(j['watched']);
  set watched(int v) => j['watched'] = v;
  String get title => _s(j['title']);
  int get year => _i(j['year']);
  int get movieId => _i(j['movieId']);
  String get show => _s(j['show']);
  int get season => _i(j['season']);
  int get episode => _i(j['episode']);
  String get episodeTitle => _s(j['episodeTitle']);
  String get episodeOverview => _s(j['episodeOverview']);
  String get still => _s(j['still']);
  String get artist => _s(j['artist']);
  String get albumArtist => _s(j['albumArtist']).isNotEmpty ? _s(j['albumArtist']) : artist;
  String get album => _s(j['album']);
  List<String> get genres => _l(j['genres']);
  int get track => _i(j['track']);
  int get disc => _i(j['disc']);
  String get cover => _s(j['cover']);
  double get progress => duration > 0 ? (pos / duration).clamp(0.0, 1.0).toDouble() : 0.0;
  String get albumKey => '$albumArtist\u0001${album.isNotEmpty ? album : dir}';

  MediaFile toMediaFile(String label) =>
      MediaFile(path: path, name: label, dir: dir, size: size, pos: pos, duration: duration);
}

class LibData {
  LibData(this.info, this.items, this.movies, this.shows);
  final LibraryInfo info;
  final List<Item> items;
  final Map<int, Meta> movies;
  final Map<String, Meta> shows;

  factory LibData.fromJson(LibraryInfo info, Map j) {
    final movies = <int, Meta>{};
    (j['movies'] as Map? ?? const {}).forEach((k, v) => movies[int.tryParse('$k') ?? 0] = Meta(v as Map));
    final shows = <String, Meta>{};
    (j['shows'] as Map? ?? const {}).forEach((k, v) => shows['$k'] = Meta(v as Map));
    return LibData(info, (j['items'] as List? ?? const []).map((e) => Item(e as Map)).toList(), movies, shows);
  }

  Meta? movieOf(Item it) => it.movieId != 0 ? movies[it.movieId] : null;
  Meta? showOf(Item it) => shows[it.show];

  String labelOf(Item it) {
    final m = movieOf(it);
    if (m != null) return m.title;
    final s = info.type == 'tv' ? showOf(it) : null;
    if (s != null) {
      final se = 'S${it.season.toString().padLeft(2, '0')}E${it.episode.toString().padLeft(2, '0')}';
      return '${s.title} · $se${it.episodeTitle.isNotEmpty ? ' · ${it.episodeTitle}' : ''}';
    }
    return it.title.isNotEmpty ? it.title : it.name;
  }
}

int episodeOrder(Item a, Item b) {
  final s = a.season.compareTo(b.season);
  if (s != 0) return s;
  final e = a.episode.compareTo(b.episode);
  return e != 0 ? e : a.name.compareTo(b.name);
}

int trackOrder(Item a, Item b) {
  final d = a.disc.compareTo(b.disc);
  if (d != 0) return d;
  final t = a.track.compareTo(b.track);
  return t != 0 ? t : a.name.compareTo(b.name);
}

class Album {
  Album(this.key, this.title, this.artist);
  final String key, title, artist;
  String cover = '';
  int year = 0, added = 0;
  final genres = <String>{};
  final tracks = <Item>[];
}

List<Album> albumsOf(Iterable<Item> items) {
  final m = <String, Album>{};
  for (final it in items) {
    final a = m.putIfAbsent(it.albumKey, () => Album(it.albumKey, it.album.isNotEmpty ? it.album : (it.dir.isNotEmpty ? it.dir.split('/').last : '(no album)'),
        it.albumArtist.isNotEmpty ? it.albumArtist : 'Unknown artist'));
    a.tracks.add(it);
    if (a.cover.isEmpty) a.cover = it.cover;
    if (a.year == 0) a.year = it.year;
    if (it.added > a.added) a.added = it.added;
    a.genres.addAll(it.genres);
  }
  for (final a in m.values) {
    a.tracks.sort(trackOrder);
  }
  return m.values.toList();
}

/// Caches library listings for the session.
class LibraryRepo {
  LibraryRepo(this.api);
  final Api api;
  List<LibraryInfo>? libs;
  bool legacy = false; // server < 1.4
  final _data = <String, LibData>{};

  Future<List<LibraryInfo>> libraries({bool force = false}) async {
    if (libs != null && !force) return libs!;
    try {
      libs = await api.libraries();
      legacy = false;
    } on ApiException catch (e) {
      if (e.status != 404) rethrow;
      legacy = true;
      libs = [LibraryInfo('_legacy', 'Files', 'videos', 0)];
    }
    if (force) _data.clear();
    return libs!;
  }

  /// Every music library merged into one (the Music side of the app).
  static final allMusic = LibraryInfo('_all', 'Music', 'music', 0);

  Future<LibData> lib(LibraryInfo info, {bool force = false}) async {
    if (info.id == '_all') {
      final items = <Item>[];
      for (final l in (await libraries()).where((l) => l.type == 'music')) {
        try {
          items.addAll((await lib(l, force: force)).items);
        } catch (_) {}
      }
      return LibData(info, items, {}, {});
    }
    if (!force && _data[info.id] != null) return _data[info.id]!;
    LibData d;
    if (info.id == '_legacy') {
      final files = await api.list();
      d = LibData(info, files.map((f) => Item({'path': f.path, 'name': f.name, 'dir': f.dir, 'size': f.size, 'pos': f.pos, 'duration': f.duration})).toList(), {}, {});
    } else {
      d = LibData.fromJson(info, await api.lib(info.id));
    }
    _data[info.id] = d;
    return d;
  }

  void setPos(String path, double pos) {
    for (final d in _data.values) {
      for (final it in d.items) {
        if (it.path == path) {
          it.pos = pos;
          it.watched = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        }
      }
    }
  }

  void invalidate() => _data.clear();
}
