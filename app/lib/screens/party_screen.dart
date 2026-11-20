import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api.dart';
import '../party.dart';
import '../widgets.dart';
import 'chat.dart';
import 'home_screen.dart';

const partyReacts = ['😂', '❤️', '👏', '😮', '😢', '🔥', '🎉', '👍'];

String _when(num? unix) {
  if (unix == null || unix == 0) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(unix.toInt() * 1000);
  String two(int n) => n.toString().padLeft(2, '0');
  final today = DateTime.now();
  final day = t.year == today.year && t.month == today.month && t.day == today.day ? 'Today' : '${t.day}/${t.month}/${t.year}';
  return '$day ${two(t.hour)}:${two(t.minute)}';
}

/// Join a party, asking for its password / offering a join request when needed.
Future<void> joinParty(BuildContext context, AppCtx app, String id, {String? password}) async {
  final party = app.party;
  if (party == null) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await party.enter(id, password: password);
  } on ApiException catch (e) {
    if (!context.mounted) return;
    if (e.status == 401) {
      final c = TextEditingController();
      final pw = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(password != null ? 'Wrong password — try again' : '🔑 This party has a password'),
          content: TextField(controller: c, autofocus: true, obscureText: true, decoration: const InputDecoration(labelText: 'Password'), onSubmitted: (v) => Navigator.pop(ctx, v)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Join')),
          ],
        ),
      );
      if (pw != null && pw.isNotEmpty && context.mounted) await joinParty(context, app, id, password: pw);
      return;
    }
    if (e.status == 403 && e.message.contains('private')) {
      final ask = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Private party'),
          content: const Text('Ask the host to let you in?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ask')),
          ],
        ),
      );
      if (ask == true) {
        try {
          await app.api.partyAction(id, 'request', {});
          messenger.showSnackBar(const SnackBar(content: Text('Asked — you get in when the host says yes')));
        } on ApiException catch (x) {
          messenger.showSnackBar(SnackBar(content: Text(x.message)));
        }
      }
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  }
}

/// The party room (chat beside what's playing), or the list when not in a party.
Future<void> openPartyUi(BuildContext context, AppCtx app) async {
  final p = app.party;
  if (p == null) return;
  if (p.party != null) {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PartyRoomScreen(app: app)));
  } else if (p.current() != null) {
    await showNewPartyDialog(context, app);
  } else {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PartyListScreen(app: app)));
  }
}

// ---------------------------------------------------------------- list

class PartyListScreen extends StatefulWidget {
  const PartyListScreen({super.key, required this.app});
  final AppCtx app;
  @override
  State<PartyListScreen> createState() => _PartyListScreenState();
}

class _PartyListScreenState extends State<PartyListScreen> {
  Map? r;
  String? error;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = widget.app.party?.notices.stream.listen((n) {
      if (n.kind == 'list') _load();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final v = await widget.app.api.parties();
      if (mounted) setState(() => r = v);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Widget _card(Map x) {
    final app = widget.app, s = app.social;
    final members = List<Map>.from(x['members'] as List? ?? const []);
    final live = x['live'] == true, member = x['member'] == true, invited = x['invited'] == true;
    final here = app.party?.id == x['id'];
    Widget action;
    if (here) {
      action = const Text('You’re here', style: TextStyle(color: Color(0xFF8B95A5)));
    } else if (member) {
      action = FilledButton(onPressed: () => _go('${x['id']}'), child: const Text('Open'));
    } else if (x['kicked'] == true) {
      action = const Text('Removed', style: TextStyle(color: Color(0xFF8B95A5)));
    } else if (invited || x['visibility'] == 'public') {
      action = FilledButton(onPressed: () => _go('${x['id']}'), child: Text('${x['locked'] == true && !invited ? '🔑 ' : ''}${live ? 'Join' : 'I’m in'}'));
    } else if (x['requested'] == true) {
      action = const Text('Asked…', style: TextStyle(color: Color(0xFF8B95A5)));
    } else {
      action = OutlinedButton(
          onPressed: () async {
            try {
              await app.api.partyAction('${x['id']}', 'request', {});
              _load();
            } on ApiException catch (e) {
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
            }
          },
          child: const Text('Ask to join'));
    }
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (s != null) UserAvatar(s, '${x['host']}', radius: 18) else const Icon(Icons.celebration),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${x['title']}${invited ? '  · invited' : ''}', style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(
                  [
                    '👑 ${x['host']}',
                    x['visibility'] == 'public' ? '🌐 public' : '🔒 private',
                    if (x['locked'] == true) '🔑',
                    '${members.length} in',
                    if (!live) '🗓 ${_when(x['scheduled'] as num?)}',
                  ].join(' · '),
                  style: const TextStyle(fontSize: 12, color: Color(0xFF8B95A5))),
              if ('${x['name'] ?? ''}'.isNotEmpty) Text('${x['kind'] == 'music' ? '🎵' : '🎬'} ${x['name']}${live ? (x['playing'] == true ? ' · ▶' : ' · ⏸') : ''}'),
              if ('${x['note'] ?? ''}'.isNotEmpty) Text('“${x['note']}”', style: const TextStyle(fontSize: 12, color: Color(0xFF8B95A5))),
            ]),
          ),
          const SizedBox(width: 8),
          action,
        ]),
      ),
    );
  }

  Future<void> _go(String id) async {
    await joinParty(context, widget.app, id);
    if (!mounted) return;
    if (widget.app.party?.id == id) {
      await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => PartyRoomScreen(app: widget.app)));
    } else {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = List<Map>.from(r?['parties'] as List? ?? const []);
    final live = list.where((x) => x['live'] == true).toList(), soon = list.where((x) => x['live'] != true).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('🎉 Party')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.celebration),
        label: const Text('New party'),
        onPressed: () async {
          await showNewPartyDialog(context, widget.app);
          _load();
        },
      ),
      body: r == null
          ? Center(child: error != null ? Text(error!) : const CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('Watch or listen together: the host plays, everyone follows, with chat and emoji. '
                      'Friends who are playing something have a 🎉 in Chat — ask to join them.', style: TextStyle(color: Color(0xFF8B95A5))),
                ),
                const SectionTitle('Live now'),
                if (live.isEmpty) const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('No party right now — start one!', style: TextStyle(color: Color(0xFF8B95A5)))),
                for (final x in live) _card(x),
                const SectionTitle('Coming up'),
                if (soon.isEmpty) const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('Nothing scheduled.', style: TextStyle(color: Color(0xFF8B95A5)))),
                for (final x in soon) _card(x),
              ]),
            ),
    );
  }
}

// ---------------------------------------------------------------- new party

Future<void> showNewPartyDialog(BuildContext context, AppCtx app) async {
  final party = app.party;
  if (party == null) return;
  final cur = party.current();
  final title = TextEditingController(), note = TextEditingController(), pw = TextEditingController(), q = TextEditingController();
  Map<String, dynamic>? pick = cur;
  var later = false, public = false;
  var at = DateTime.now().add(const Duration(hours: 1));
  at = DateTime(at.year, at.month, at.day, at.hour);
  final invite = <String>{};
  List<Map<String, dynamic>>? all;
  var hits = <Map<String, dynamic>>[];
  final messenger = ScaffoldMessenger.of(context);
  final people = (app.social?.people ?? const []).map((p) => '${p['name']}').where((n) => n != app.api.settings.username).toList();

  Future<List<Map<String, dynamic>>> load() async {
    final out = <Map<String, dynamic>>[];
    for (final l in await app.repo.libraries()) {
      try {
        final d = await app.repo.lib(l);
        for (final it in d.items) {
          out.add({
            'path': it.path,
            'kind': l.type == 'music' ? 'music' : 'video',
            'name': l.type == 'music' ? [it.title.isNotEmpty ? it.title : it.name, it.artist].where((e) => e.isNotEmpty).join(' · ') : d.labelOf(it),
          });
        }
      } catch (_) {}
    }
    return out;
  }

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: const Text('🎉 New party'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(controller: title, decoration: InputDecoration(labelText: 'Title', hintText: "${app.api.settings.username}'s party")),
              const SizedBox(height: 8),
              Text(pick != null ? '${pick!['kind'] == 'music' ? '🎵' : '🎬'} ${pick!['name']}' : 'Nothing chosen yet',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              TextField(
                controller: q,
                decoration: const InputDecoration(labelText: 'Search what to watch / listen', prefixIcon: Icon(Icons.search)),
                onChanged: (v) async {
                  final s = v.trim().toLowerCase();
                  if (s.length < 2) {
                    set(() => hits = []);
                    return;
                  }
                  all ??= await load();
                  final words = s.split(RegExp(r'\s+'));
                  set(() => hits = all!.where((x) => words.every((w) => '${x['name']} ${x['path']}'.toLowerCase().contains(w))).take(20).toList());
                },
              ),
              for (final h in hits)
                ListTile(
                  dense: true,
                  leading: Text(h['kind'] == 'music' ? '🎵' : '🎬'),
                  title: Text('${h['name']}', maxLines: 2, overflow: TextOverflow.ellipsis),
                  onTap: () => set(() {
                    pick = h;
                    hits = [];
                    q.clear();
                  }),
                ),
              const SizedBox(height: 8),
              SegmentedButton<bool>(
                segments: const [ButtonSegment(value: false, label: Text('Now')), ButtonSegment(value: true, label: Text('Later'))],
                selected: {later},
                onSelectionChanged: (v) => set(() => later = v.first),
              ),
              if (later)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event),
                  title: Text(_when(at.millisecondsSinceEpoch ~/ 1000)),
                  trailing: const Icon(Icons.edit_calendar_outlined),
                  onTap: () async {
                    final d = await showDatePicker(context: ctx, initialDate: at, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)));
                    if (d == null || !ctx.mounted) return;
                    final t = await showTimePicker(context: ctx, initialTime: TimeOfDay.fromDateTime(at));
                    if (t == null) return;
                    set(() => at = DateTime(d.year, d.month, d.day, t.hour, t.minute));
                  },
                ),
              TextField(controller: note, decoration: const InputDecoration(labelText: 'Note (optional)', hintText: 'e.g. bring snacks 🍿')),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: public,
                onChanged: (v) => set(() => public = v),
                title: Text(public ? '🌐 Public' : '🔒 Private'),
                subtitle: Text(public ? 'Everyone sees it in Party' : 'Only people you invite'),
              ),
              TextField(controller: pw, obscureText: true, decoration: const InputDecoration(labelText: 'Password (optional)')),
              if (people.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text('Invite', style: TextStyle(color: Color(0xFF8B95A5))),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  for (final n in people)
                    FilterChip(label: Text(n), selected: invite.contains(n), onSelected: (v) => set(() => v ? invite.add(n) : invite.remove(n))),
                ]),
              ],
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('🎉 Create')),
        ],
      ),
    ),
  );
  final body = <String, dynamic>{
    'title': title.text.trim(),
    'note': note.text.trim(),
    'password': pw.text,
    'visibility': public ? 'public' : 'private',
    'invite': invite.toList(),
  };
  title.dispose();
  note.dispose();
  pw.dispose();
  q.dispose();
  if (ok != true) return;
  if (pick != null) {
    body['path'] = pick!['path'];
    body['kind'] = pick!['kind'];
    body['name'] = pick!['name'];
    if (cur != null && cur['path'] == pick!['path']) {
      body['pos'] = cur['pos'];
      body['playing'] = cur['playing'];
    }
  }
  if (later) {
    if (at.isBefore(DateTime.now().add(const Duration(minutes: 1)))) {
      messenger.showSnackBar(const SnackBar(content: Text('Pick a time in the future')));
      return;
    }
    body['scheduled'] = at.millisecondsSinceEpoch ~/ 1000;
  }
  try {
    await party.create(body);
    messenger.showSnackBar(SnackBar(content: Text(later ? '🗓 Scheduled for ${_when(body['scheduled'] as int)}' : '🎉 Party started')));
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  }
}

// ---------------------------------------------------------------- room

class PartyRoomScreen extends StatelessWidget {
  const PartyRoomScreen({super.key, required this.app});
  final AppCtx app;
  @override
  Widget build(BuildContext context) {
    final p = app.party!;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final d = p.party;
        if (d == null) {
          return Scaffold(appBar: AppBar(title: const Text('🎉 Party')), body: const Center(child: Text('You left the party')));
        }
        return Scaffold(
          appBar: AppBar(title: Text('🎉 ${d['title']}')),
          body: Stack(children: [
            Positioned.fill(child: PartyPanel(app: app, showNow: true)),
            Positioned.fill(child: PartyFloats(party: p)),
          ]),
        );
      },
    );
  }
}

/// Members, requests, chat, emoji, host tools.
class PartyPanel extends StatefulWidget {
  const PartyPanel({super.key, required this.app, this.showNow = false, this.dark = false});
  final AppCtx app;
  final bool showNow, dark;
  @override
  State<PartyPanel> createState() => _PartyPanelState();
}

class _PartyPanelState extends State<PartyPanel> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  PartyController get p => widget.app.party!;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _do(Future<void> Function() f) async {
    try {
      await f();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  void _toEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });

  Future<void> _invite() async {
    final d = p.party!;
    final here = p.members.map((m) => '${m['name']}').toSet();
    final others = (widget.app.social?.people ?? const []).map((x) => '${x['name']}').where((n) => n != p.me && !here.contains(n)).toList();
    if (others.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Everyone is already here')));
      return;
    }
    final pick = <String>{};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text('Invite to ${d['title']}'),
          content: Wrap(spacing: 6, runSpacing: 4, children: [
            for (final n in others) FilterChip(label: Text(n), selected: pick.contains(n), onSelected: (v) => set(() => v ? pick.add(n) : pick.remove(n))),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Invite')),
          ],
        ),
      ),
    );
    if (ok == true && pick.isNotEmpty) await _do(() => p.act('invite', {'users': pick.toList()}));
  }

  Future<void> _settings() async {
    final d = p.party!;
    final title = TextEditingController(text: '${d['title']}'), pw = TextEditingController();
    var public = d['visibility'] == 'public', chatOn = d['chatOn'] == true, noPw = false;
    String? host;
    final others = p.members.map((m) => '${m['name']}').where((n) => n != d['host']).toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('⚙ Party settings'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: title, decoration: const InputDecoration(labelText: 'Title')),
              SwitchListTile(contentPadding: EdgeInsets.zero, value: public, onChanged: (v) => set(() => public = v), title: Text(public ? '🌐 Public' : '🔒 Private')),
              TextField(controller: pw, obscureText: true, decoration: InputDecoration(labelText: d['locked'] == true ? 'New password (leave empty to keep)' : 'Password (optional)')),
              if (d['locked'] == true) CheckboxListTile(contentPadding: EdgeInsets.zero, value: noPw, onChanged: (v) => set(() => noPw = v ?? false), title: const Text('Remove the password')),
              SwitchListTile(contentPadding: EdgeInsets.zero, value: chatOn, onChanged: (v) => set(() => chatOn = v), title: const Text('Chat and emoji'), subtitle: const Text('Off: only you can write')),
              if (others.isNotEmpty)
                DropdownButtonFormField<String?>(
                  value: host,
                  decoration: const InputDecoration(labelText: 'Hand over the party to'),
                  items: [const DropdownMenuItem<String?>(value: null, child: Text('— keep hosting —')), for (final n in others) DropdownMenuItem<String?>(value: n, child: Text(n))],
                  onChanged: (v) => set(() => host = v),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    final body = <String, dynamic>{'title': title.text, 'visibility': public ? 'public' : 'private', 'chatOn': chatOn};
    if (pw.text.isNotEmpty) body['password'] = pw.text;
    if (noPw) body['password'] = '';
    if (host != null) body['host'] = host;
    title.dispose();
    pw.dispose();
    if (ok == true) await _do(() => p.act('settings', body));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: p,
        builder: (context, _) {
          final d = p.party;
          if (d == null) return const Center(child: Text('Not in a party'));
          final host = p.isHost;
          final s = widget.app.social;
          final reqs = host ? List<Map>.from(d['requests'] as List? ?? const []) : const <Map>[];
          final canWrite = p.chatOn || host;
          _toEnd();
          const dim = TextStyle(fontSize: 12, color: Color(0xFF8B95A5));
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (widget.showNow)
              ListTile(
                leading: Icon(d['kind'] == 'music' ? Icons.music_note : Icons.movie_outlined),
                title: Text('${d['name'] ?? ''}'.isNotEmpty ? '${d['name']}' : 'Nothing chosen yet', maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text(d['live'] == true
                    ? '${d['playing'] == true ? '▶ playing' : '⏸ paused'} · ${host ? 'you control playback' : '👑 ${d['host']} controls playback'}'
                    : '🗓 ${_when(d['scheduled'] as num?)}'),
                trailing: host && d['live'] != true
                    ? FilledButton(onPressed: () => _do(() => p.act('start')), child: const Text('Start'))
                    : (!host && d['kind'] == 'video' && p.video == null && '${d['path'] ?? ''}'.isNotEmpty
                        ? FilledButton.icon(
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Watch'),
                            onPressed: () => p.openVideo?.call('${d['path']}', ((d['pos'] as num?) ?? 0).toDouble(), d['playing'] == true))
                        : null),
              ),
            SizedBox(
              height: 52,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), children: [
                for (final m in p.members)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: GestureDetector(
                      onLongPress: host && m['name'] != d['host']
                          ? () async {
                              final yes = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: Text('Remove ${m['name']}?'),
                                  content: const Text('They leave the party and can’t join again unless you invite them.'),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
                                  ],
                                ),
                              );
                              if (yes == true) await _do(() => p.act('kick', {'user': '${m['name']}'}));
                            }
                          : null,
                      child: Tooltip(
                        message: '${m['name']}${m['name'] == d['host'] ? ' — host' : ''}${host && m['name'] != d['host'] ? ' (long-press to remove)' : ''}',
                        child: Stack(clipBehavior: Clip.none, children: [
                          if (s != null) UserAvatar(s, '${m['name']}', online: m['online'] == true, radius: 18) else CircleAvatar(radius: 18, child: Text('${m['name']}'[0])),
                          if (m['name'] == d['host']) const Positioned(top: -10, left: 8, child: Text('👑', style: TextStyle(fontSize: 12))),
                        ]),
                      ),
                    ),
                  ),
                if (host || d['visibility'] == 'public') IconButton(tooltip: 'Invite', onPressed: _invite, icon: const Icon(Icons.person_add_alt_1_outlined)),
              ]),
            ),
            for (final r in reqs)
              ListTile(
                dense: true,
                leading: const Icon(Icons.front_hand_outlined),
                title: Text('${r['name']} wants to join'),
                trailing: Wrap(spacing: 6, children: [
                  FilledButton(onPressed: () => _do(() => p.act('answer', {'user': '${r['name']}', 'accept': true})), child: const Text('Let in')),
                  OutlinedButton(onPressed: () => _do(() => p.act('answer', {'user': '${r['name']}', 'accept': false})), child: const Text('No')),
                ]),
              ),
            const Divider(height: 1),
            Expanded(
              child: p.muted
                  ? const Center(child: Text('🔕 Chat muted for you — the party goes on', style: dim))
                  : ListView(controller: _scroll, padding: const EdgeInsets.fromLTRB(12, 8, 12, 8), children: [
                      for (final m in p.msgs)
                        m['sys'] == true
                            ? Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text('${m['text']}', textAlign: TextAlign.center, style: dim))
                            : Padding(
                                padding: const EdgeInsets.symmetric(vertical: 3),
                                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  if (s != null) UserAvatar(s, '${m['from']}', radius: 11),
                                  const SizedBox(width: 7),
                                  Expanded(
                                    child: Text.rich(TextSpan(children: [
                                      TextSpan(text: '${m['from']}  ', style: TextStyle(fontWeight: FontWeight.w600, color: m['from'] == p.me ? const Color(0xFF8AB4FF) : null)),
                                      TextSpan(text: '${m['text']}'),
                                    ])),
                                  ),
                                ]),
                              ),
                    ]),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                for (final e in partyReacts)
                  InkWell(
                    onTap: canWrite ? () => _do(() => p.react(e)) : null,
                    child: Padding(padding: const EdgeInsets.all(6), child: Text(e, style: TextStyle(fontSize: 20, color: canWrite ? null : Colors.white24))),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 6, 6),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    enabled: canWrite,
                    textInputAction: TextInputAction.send,
                    decoration: InputDecoration(isDense: true, hintText: canWrite ? 'Say something…' : '🤫 The host turned chat off'),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                IconButton(onPressed: canWrite ? _send : null, icon: const Icon(Icons.send)),
              ]),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                child: Wrap(spacing: 6, runSpacing: 4, children: [
                  OutlinedButton.icon(
                    icon: Icon(p.muted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined, size: 18),
                    label: Text(p.muted ? 'Show chat' : 'Mute chat'),
                    onPressed: () => p.setMuted(!p.muted),
                  ),
                  if (host) OutlinedButton.icon(icon: const Icon(Icons.tune, size: 18), label: const Text('Party'), onPressed: _settings),
                  OutlinedButton.icon(icon: const Icon(Icons.logout, size: 18), label: const Text('Leave'), onPressed: () => p.leave()),
                  if (host)
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent),
                      icon: const Icon(Icons.stop_circle_outlined, size: 18),
                      label: const Text('End'),
                      onPressed: () async {
                        final yes = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('End the party for everyone?'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('End')),
                            ],
                          ),
                        );
                        if (yes == true) await p.end();
                      },
                    ),
                ]),
              ),
            ),
          ]);
        },
      );

  Future<void> _send() async {
    final t = _input.text.trim();
    if (t.isEmpty) return;
    _input.clear();
    await _do(() => p.send(t));
  }
}

/// Floating emoji (and, with the panel closed, the latest message) over the player.
class PartyFloats extends StatefulWidget {
  const PartyFloats({super.key, required this.party, this.showMessages = false});
  final PartyController party;
  final bool showMessages;
  @override
  State<PartyFloats> createState() => _PartyFloatsState();
}

class _Float {
  _Float(this.emoji, this.from, this.x);
  final String emoji, from;
  final double x;
}

class _PartyFloatsState extends State<PartyFloats> {
  final _floats = <_Float>[];
  final _rnd = math.Random();
  Map? _msg;
  Timer? _msgTimer;
  final _subs = <StreamSubscription>[];

  @override
  void initState() {
    super.initState();
    _subs.add(widget.party.reactions.stream.listen((r) {
      if (!mounted || widget.party.muted) return;
      final f = _Float(r.$1, r.$2, .08 + _rnd.nextDouble() * .7);
      setState(() => _floats.add(f));
      Future.delayed(const Duration(milliseconds: 3200), () {
        if (mounted) setState(() => _floats.remove(f));
      });
    }));
    if (widget.showMessages) {
      _subs.add(widget.party.messages.stream.listen((m) {
        if (!mounted || widget.party.muted || m['sys'] == true || m['from'] == widget.party.me) return;
        setState(() => _msg = m);
        _msgTimer?.cancel();
        _msgTimer = Timer(const Duration(seconds: 5), () {
          if (mounted) setState(() => _msg = null);
        });
      }));
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _msgTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: LayoutBuilder(
          builder: (context, box) => Stack(children: [
            for (final f in _floats)
              Positioned.fill(
                key: ObjectKey(f),
                child: TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: 1),
                duration: const Duration(milliseconds: 3200),
                curve: Curves.easeOut,
                builder: (context, t, child) => Stack(children: [
                  Positioned(
                    left: f.x * box.maxWidth,
                    bottom: 60 + t * box.maxHeight * .55,
                    child: Opacity(opacity: t < .12 ? t / .12 : (1 - t).clamp(0.0, 1.0).toDouble(), child: child),
                  ),
                ]),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(f.emoji, style: const TextStyle(fontSize: 38)),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                    child: Text(f.from, style: const TextStyle(fontSize: 11, color: Colors.white)),
                  ),
                ]),
              ),
              ),
            if (_msg != null)
              Positioned(
                left: 16,
                bottom: 90,
                right: box.maxWidth * .35,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(color: Colors.black.withValues(alpha: .7), borderRadius: BorderRadius.circular(12)),
                  child: Text('${_msg!['from']}: ${_msg!['text']}', maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white)),
                ),
              ),
          ]),
        ),
      );
}

/// The little "🎉 party" button floating over the app while you're in one.
class PartyPill extends StatelessWidget {
  const PartyPill({super.key, required this.app});
  final AppCtx app;
  @override
  Widget build(BuildContext context) {
    final p = app.party;
    if (p == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final d = p.party;
        if (d == null) return const SizedBox.shrink();
        return FloatingActionButton.extended(
          heroTag: 'party',
          backgroundColor: const Color(0xFF5B3FB8),
          foregroundColor: Colors.white,
          icon: const Icon(Icons.celebration),
          label: Text('${d['title']} · ${p.members.length}', maxLines: 1, overflow: TextOverflow.ellipsis),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PartyRoomScreen(app: app))),
        );
      },
    );
  }
}

/// Shows party notices (invites, requests, reminders…) from anywhere in the app.
StreamSubscription<PartyNotice>? listenPartyNotices(BuildContext Function() ctx, AppCtx app) {
  final p = app.party;
  if (p == null) return null;
  return p.notices.stream.listen((n) async {
    final context = ctx();
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final x = n.party ?? const {};
    final t = '${x['title'] ?? ''}';
    void snack(String text, {String? label, VoidCallback? go, int secs = 6}) => messenger.showSnackBar(SnackBar(
          duration: Duration(seconds: secs),
          content: Text(text),
          action: label == null ? null : SnackBarAction(label: label, onPressed: go!),
        ));
    switch (n.kind) {
      case 'locked':
        snack('🎉 ${n.from} controls playback in this party', secs: 2);
      case 'cant-open':
        snack('Can’t open what the party is playing');
      case 'host':
        snack('👑 You are the host now');
      case 'invite':
        snack('🎉 ${n.from} invited you to $t${x['live'] == true ? '' : ' · 🗓 ${_when(x['scheduled'] as num?)}'}',
            label: x['live'] == true ? 'Join' : 'Open', secs: 20, go: () {
          if (x['live'] == true) {
            joinParty(ctx(), app, '${x['id']}');
          } else {
            Navigator.of(ctx()).push(MaterialPageRoute(builder: (_) => PartyListScreen(app: app)));
          }
        });
      case 'reminder':
        if (p.id != x['id']) snack('⏰ $t is starting', label: 'Join', secs: 30, go: () => joinParty(ctx(), app, '${x['id']}'));
      case 'accepted':
        snack('🎉 ${n.from} let you in');
      case 'declined':
        snack('${n.from} said no this time');
      case 'ask-declined':
        snack('${n.from} wants to watch alone right now');
      case 'kicked':
        snack('🚫 ${n.from} removed you from the party');
      case 'ended':
        if (n.from != p.me) snack('🎉 The party has ended');
      case 'request':
      case 'ask':
        final a = n.activity ?? const {};
        final yes = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(n.kind == 'ask' ? '🎉 ${n.from} wants to ${a['kind'] == 'music' ? 'listen' : 'watch'} with you' : '🙋 ${n.from} wants to join'),
            content: Text(n.kind == 'ask' ? '${a['title'] ?? ''}' : t),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('No')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(n.kind == 'ask' ? 'Let them join' : 'Let in')),
            ],
          ),
        );
        if (yes == null) return;
        try {
          if (n.kind == 'ask') {
            await p.answerAsk(n.from, yes);
          } else {
            await app.api.partyAction('${x['id']}', 'answer', {'user': n.from, 'accept': yes});
          }
        } on ApiException catch (e) {
          messenger.showSnackBar(SnackBar(content: Text(e.message)));
        }
    }
  });
}

/// For a person in the People list: "🎉 ask to join".
Future<void> askToJoin(BuildContext context, AppCtx app, String user) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await app.party?.ask(user);
    if (app.party?.party == null) messenger.showSnackBar(SnackBar(content: Text('🎉 Asked $user — waiting for a yes')));
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  }
}
