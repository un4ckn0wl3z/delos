import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api.dart';

/// Metadata for local files: through the signed-in server's TMDB key
/// (POST /api/meta/lookup), or straight from TMDB with the user's own key.
class LocalMeta {
  LocalMeta({this.title = '', this.year = 0, this.overview = '', this.genres = const [], this.poster = '', this.backdrop = '', this.rating = 0, this.episodeTitle = '', this.still = ''});
  final String title, overview, poster, backdrop, episodeTitle, still;
  final int year;
  final List<String> genres;
  final double rating;
}

class MetaSource {
  MetaSource({this.api, this.tmdbKey = '', this.lang = 'en-US'});
  final Api? api;
  final String tmdbKey, lang;

  bool get available => tmdbKey.isNotEmpty || api != null;

  Future<LocalMeta?> movie(String title, int year) async {
    if (title.isEmpty) return null;
    if (tmdbKey.isEmpty && api != null) {
      final r = await api!.metaLookup({'type': 'movie', 'title': title, if (year > 0) 'year': year});
      final m = r['movie'] as Map?;
      return m == null ? null : _fromServer(m);
    }
    if (tmdbKey.isEmpty) return null;
    var id = await _search('movie', title, year);
    if (id == 0 && year > 0) id = await _search('movie', title, 0);
    if (id == 0) return null;
    final d = await _get('/3/movie/$id', {});
    return _fromTmdb(d, movie: true);
  }

  Future<LocalMeta?> episode(String show, int year, int season, int ep) async {
    if (show.isEmpty) return null;
    if (tmdbKey.isEmpty && api != null) {
      final r = await api!.metaLookup({'type': 'tv', 'title': show, if (year > 0) 'year': year, 'season': season, 'episode': ep});
      final s = r['show'] as Map?;
      if (s == null) return null;
      final e = r['episode'] as Map?;
      return _fromServer(s, episode: e);
    }
    if (tmdbKey.isEmpty) return null;
    var id = await _search('tv', show, year);
    if (id == 0 && year > 0) id = await _search('tv', show, 0);
    if (id == 0) return null;
    final d = await _get('/3/tv/$id', {});
    Map? e;
    if (season > 0 && ep > 0) {
      try {
        e = await _get('/3/tv/$id/season/$season/episode/$ep', {});
      } catch (_) {}
    }
    final base = _fromTmdb(d, movie: false);
    return LocalMeta(
      title: base.title,
      year: base.year,
      overview: e?['overview'] as String? ?? base.overview,
      genres: base.genres,
      poster: base.poster,
      backdrop: base.backdrop,
      rating: base.rating,
      episodeTitle: e?['name'] as String? ?? '',
      still: _img('w300', e?['still_path'] as String?),
    );
  }

  LocalMeta _fromServer(Map m, {Map? episode}) => LocalMeta(
        title: '${m['title'] ?? ''}',
        year: (m['year'] as num? ?? 0).toInt(),
        overview: '${episode?['overview'] ?? m['overview'] ?? ''}',
        genres: List<String>.from(m['genres'] as List? ?? const []),
        poster: '${m['poster'] ?? ''}',
        backdrop: '${m['backdrop'] ?? ''}',
        rating: (m['rating'] as num? ?? 0).toDouble(),
        episodeTitle: '${episode?['title'] ?? ''}',
        still: '${episode?['still'] ?? ''}',
      );

  LocalMeta _fromTmdb(Map d, {required bool movie}) {
    final date = '${(movie ? d['release_date'] : d['first_air_date']) ?? ''}';
    return LocalMeta(
      title: '${(movie ? d['title'] : d['name']) ?? ''}',
      year: date.length >= 4 ? int.tryParse(date.substring(0, 4)) ?? 0 : 0,
      overview: '${d['overview'] ?? ''}',
      genres: [for (final g in (d['genres'] as List? ?? const [])) '${(g as Map)['name']}'],
      poster: _img('w342', d['poster_path'] as String?),
      backdrop: _img('w1280', d['backdrop_path'] as String?),
      rating: (d['vote_average'] as num? ?? 0).toDouble(),
    );
  }

  static String _img(String size, String? path) => path == null || path.isEmpty ? '' : 'https://image.tmdb.org/t/p/$size$path';

  Future<int> _search(String kind, String q, int year) async {
    final d = await _get('/3/search/$kind', {
      'query': q,
      if (year > 0) (kind == 'movie' ? 'year' : 'first_air_date_year'): '$year',
    });
    final res = d['results'] as List? ?? const [];
    return res.isEmpty ? 0 : ((res.first as Map)['id'] as num).toInt();
  }

  Future<Map> _get(String path, Map<String, String> q) async {
    final bearer = tmdbKey.startsWith('eyJ'); // v4 read token
    final uri = Uri.https('api.themoviedb.org', path, {...q, 'language': lang, if (!bearer) 'api_key': tmdbKey});
    final r = await http.get(uri, headers: {if (bearer) 'Authorization': 'Bearer $tmdbKey', 'Accept': 'application/json'}).timeout(const Duration(seconds: 20));
    if (r.statusCode == 401) throw Exception('TMDB key rejected');
    if (r.statusCode != 200) throw Exception('TMDB ${r.statusCode}');
    return jsonDecode(r.body) as Map;
  }
}
