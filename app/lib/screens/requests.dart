import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../widgets.dart';
import 'home_screen.dart';
import 'movies.dart';
import 'shows.dart';

const _status = {
  'pending': ('⏳', 'Waiting', Color(0xFFFFD77A), Color(0xFF3A3218)),
  'approved': ('👍', 'Approved', Color(0xFF9CC2FF), Color(0xFF1B2A45)),
  'available': ('✅', 'Available', Color(0xFF7FE0A5), Color(0xFF163222)),
  'declined': ('✕', 'Declined', Color(0xFFFF9A9A), Color(0xFF3A1C1C)),
};

Widget statusPill(String st) {
  final s = _status[st] ?? _status['pending']!;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(color: s.$4, borderRadius: BorderRadius.circular(20)),
    child: Text('${s.$1} ${s.$2}', style: TextStyle(color: s.$3, fontSize: 11.5, fontWeight: FontWeight.w600)),
  );
}

/// Open a requested title that is in a library now.
Future<void> openRequested(BuildContext context, AppCtx app, Map x) async {
  final messenger = ScaffoldMessenger.of(context);
  final libs = await app.repo.libraries();
  final info = libs.where((l) => l.id == '${x['lib']}').firstOrNull;
  if (info == null) {
    messenger.showSnackBar(const SnackBar(content: Text("You don't have access to that library")));
    return;
  }
  final d = await app.repo.lib(info, force: true);
  if (!context.mounted) return;
  if (x['kind'] == 'tv') {
    Navigator.push(context, MaterialPageRoute(builder: (_) => ShowScreen(app: app, data: d, show: '${x['where']}')));
  } else {
    final it = d.items.where((i) => i.path == '${x['where']}').firstOrNull;
    final key = it == null ? '${x['tmdbId']}' : (it.movieId != 0 ? '${it.movieId}' : it.path);
    Navigator.push(context, MaterialPageRoute(builder: (_) => MovieScreen(app: app, data: d, groupKey: key)));
  }
}

/// Ask for films / series that aren't here yet, vote, follow what happens.
class RequestsScreen extends StatefulWidget {
  const RequestsScreen({super.key, required this.app});
  final AppCtx app;
  @override
  State<RequestsScreen> createState() => _RequestsScreenState();
}

class _RequestsScreenState extends State<RequestsScreen> {
  Api get api => widget.app.api;
  Map? data;
  String? error;
  String kind = 'movie';
  final _q = TextEditingController();
  List<Map>? results;
  bool searching = false;
  Timer? _debounce;
  int _seq = 0;
  StreamSubscription? _events;

  @override
  void initState() {
    super.initState();
    _load();
    _events = widget.app.social?.requestEvents.stream.listen((_) => _load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _events?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await api.requests();
      if (mounted) setState(() => data = d);
      // looked at it: the "new" marks are read (they stay on screen until next time)
      if ((d['requests'] as List? ?? const []).any((x) => x['new'] == true)) await api.requestsSeen();
      widget.app.refreshRequestBadge();
    } on ApiException catch (e) {
      if (mounted) setState(() => error = e.message);
    }
  }

  Future<void> _search() async {
    final q = _q.text.trim(), seq = ++_seq;
    if (q.isEmpty) {
      setState(() => results = null);
      return;
    }
    setState(() => searching = true);
    try {
      final r = await api.requestSearch(q, kind);
      if (mounted && seq == _seq) setState(() => results = r);
    } on ApiException catch (e) {
      if (mounted) _snack(e.message);
    } finally {
      if (mounted && seq == _seq) setState(() => searching = false);
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _act(Future<void> Function() f, [String? done]) async {
    try {
      await f();
      if (done != null) _snack(done);
      await _load();
      if (results != null) await _search();
    } on ApiException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _setStatus(Map x, String st) async {
    var note = '${x['note'] ?? ''}';
    if (st == 'declined') {
      final c = TextEditingController(text: note);
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Decline “${x['title']}”?'),
          content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(labelText: 'Why? (shown to the people who asked — optional)')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Decline')),
          ],
        ),
      );
      if (ok != true) return;
      note = c.text.trim();
    }
    await _act(() => api.requestStatus('${x['id']}', st, note));
  }

  Future<void> _delete(Map x, bool manage) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(manage ? 'Delete the request for “${x['title']}”?' : 'Withdraw your request for “${x['title']}”?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(manage ? 'Delete' : 'Withdraw')),
        ],
      ),
    );
    if (ok == true) await _act(() => api.requestDelete('${x['id']}'));
  }

  Widget _poster(String? url, {double w = 56}) => ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(width: w, height: w * 1.5, child: NetImage(url ?? '', placeholder: '🎬')),
      );

  Widget _hit(Map x) {
    final rq = x['request'] as Map?;
    Widget action;
    if (x['have'] == true) {
      action = OutlinedButton(onPressed: () => openRequested(context, widget.app, {...x, 'tmdbId': x['id']}), child: const Text('✓ Here — open'));
    } else if (rq != null && rq['status'] == 'declined') {
      action = statusPill('declined');
    } else if (rq != null) {
      action = rq['voted'] == true
          ? Row(mainAxisSize: MainAxisSize.min, children: [statusPill('${rq['status']}'), Text('  👍 ${rq['voteCount']}', style: const TextStyle(fontSize: 12))])
          : OutlinedButton(
              onPressed: () => _act(() => api.requestVote('${rq['id']}', true), 'Added your vote for “${x['title']}”'),
              child: Text('👍 Me too · ${rq['voteCount']}'));
    } else {
      action = FilledButton(
          onPressed: () => _act(() => api.requestCreate(kind, (x['id'] as num).toInt()), 'Asked for “${x['title']}” — you\'ll hear when it\'s here'),
          child: const Text('＋ Request'));
    }
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: _poster(x['poster'] as String?, w: 40),
      title: Text('${x['title']}${x['year'] != null ? ' (${x['year']})' : ''}', maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: '${x['overview'] ?? ''}'.isEmpty
          ? null
          : Text('${x['overview']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Color(0xFF8B95A5))),
      trailing: action,
    );
  }

  Widget _row(Map x, bool manage) {
    final st = '${x['status']}';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      color: const Color(0xFF12161D),
      shape: x['new'] == true
          ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xFF3B6FD6), width: 1.5))
          : null,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _poster(x['poster'] as String?),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${x['title']}${x['year'] != null ? ' (${x['year']})' : ''}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              const SizedBox(height: 4),
              Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                if (x['new'] == true)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: const Color(0xFF3B6FD6), borderRadius: BorderRadius.circular(6)),
                    child: const Text('NEW', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white)),
                  ),
                statusPill(st),
                Text('${x['kind'] == 'tv' ? 'Series' : 'Film'} · ${x['mine'] == true ? 'you asked' : '${x['by']} asked'}',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF8B95A5))),
              ]),
              if ('${x['note'] ?? ''}'.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text('💬 ${x['note']}', style: const TextStyle(fontSize: 13))),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                if (st == 'available' && x['canOpen'] == true)
                  FilledButton.tonal(onPressed: () => openRequested(context, widget.app, x), child: const Text('▶ Open')),
                if (st != 'available')
                  OutlinedButton(
                    onPressed: x['mine'] == true ? null : () => _act(() => api.requestVote('${x['id']}', x['voted'] != true)),
                    style: x['voted'] == true ? OutlinedButton.styleFrom(backgroundColor: const Color(0xFF1B2A45)) : null,
                    child: Text('👍 ${x['voteCount']}'),
                  ),
                if (x['mine'] == true && st == 'pending' && !manage) TextButton(onPressed: () => _delete(x, false), child: const Text('Withdraw')),
                if (manage)
                  PopupMenuButton<String>(
                    tooltip: 'Change',
                    icon: const Icon(Icons.more_horiz),
                    onSelected: (v) => v == 'delete' ? _delete(x, true) : _setStatus(x, v),
                    itemBuilder: (_) => [
                      for (final e in _status.entries)
                        if (e.key != st) PopupMenuItem(value: e.key, child: Text('${e.value.$1} ${e.value.$2}')),
                      const PopupMenuDivider(),
                      const PopupMenuItem(value: 'delete', child: Text('🗑 Delete')),
                    ],
                  ),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    final manage = d?['manage'] == true;
    final list = List<Map>.from(d?['requests'] as List? ?? const []);
    final open = list.where((x) => x['status'] == 'pending' || x['status'] == 'approved').toList();
    final here = list.where((x) => x['status'] == 'available').take(30).toList();
    final no = list.where((x) => x['status'] == 'declined').toList();
    return Scaffold(
      appBar: AppBar(title: const Text('🙋 Requests')),
      body: error != null
          ? Center(child: Text(error!))
          : d == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
                    if (d['tmdb'] == true) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                        child: SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(value: 'movie', label: Text('Films'), icon: Icon(Icons.movie_outlined)),
                            ButtonSegment(value: 'tv', label: Text('Series'), icon: Icon(Icons.tv)),
                          ],
                          selected: {kind},
                          onSelectionChanged: (s) {
                            setState(() => kind = s.first);
                            _search();
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                        child: TextField(
                          controller: _q,
                          textInputAction: TextInputAction.search,
                          decoration: InputDecoration(
                            hintText: 'Find a film or a series to ask for…',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: searching ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))) : null,
                            border: const OutlineInputBorder(),
                            isDense: true,
                          ),
                          onChanged: (_) {
                            _debounce?.cancel();
                            _debounce = Timer(const Duration(milliseconds: 400), _search);
                          },
                          onSubmitted: (_) => _search(),
                        ),
                      ),
                      if (results != null && results!.isEmpty && !searching)
                        const Padding(
                            padding: EdgeInsets.all(16),
                            child: Text('Nothing found. Try the original title, or add the year (e.g. “Dune 2021”).', style: TextStyle(color: Color(0xFF8B95A5)))),
                      for (final x in results ?? const <Map>[]) _hit(x),
                    ] else
                      const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('Searching needs a TMDB API key — an admin can add one in the dashboard.', style: TextStyle(color: Color(0xFF8B95A5)))),
                    SectionTitle('Open · ${open.length}'),
                    if (open.isEmpty)
                      const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('Nothing asked for yet — search above.', style: TextStyle(color: Color(0xFF8B95A5)))),
                    for (final x in open) _row(x, manage),
                    if (here.isNotEmpty) ...[SectionTitle('Here now · ${here.length}'), for (final x in here) _row(x, manage)],
                    if (no.isNotEmpty)
                      ExpansionTile(title: Text('Declined · ${no.length}'), children: [for (final x in no) _row(x, manage)]),
                  ]),
                ),
    );
  }
}
