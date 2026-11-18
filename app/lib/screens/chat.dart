import 'package:flutter/material.dart';

import '../api.dart';
import '../library.dart';
import '../social.dart';
import '../widgets.dart';
import 'home_screen.dart';

String _actLine(Map a) {
  final kind = a['kind'] == 'music' ? '♪' : '▶';
  final sub = '${a['sub'] ?? ''}';
  return '$kind ${a['title']}${sub.isNotEmpty ? ' · $sub' : ''}';
}

String _imgUrl(AppCtx app, String img) => img.startsWith('cover:') ? app.api.coverUrl(img.substring(6)) : img;

/// Open a shared movie / episode / song (if this user can see its library).
Future<void> openRef(BuildContext context, AppCtx app, Map ref) async {
  final path = '${ref['path'] ?? ''}';
  final libId = path.split('/').first;
  final messenger = ScaffoldMessenger.of(context);
  final libs = await app.repo.libraries();
  final info = libs.where((l) => l.id == libId).firstOrNull;
  if (info == null) {
    messenger.showSnackBar(const SnackBar(content: Text("You don't have access to that library")));
    return;
  }
  final d = await app.repo.lib(info);
  final it = d.items.where((i) => i.path == path).firstOrNull;
  if (it == null) {
    messenger.showSnackBar(const SnackBar(content: Text('That file is gone')));
    return;
  }
  if (!context.mounted) return;
  if (info.type == 'music' || ref['kind'] == 'music') {
    app.audio.playQueue([it], 0);
    messenger.showSnackBar(SnackBar(content: Text('Playing ${it.title.isNotEmpty ? it.title : it.name}')));
  } else {
    await openVideo(context, app, d, it);
  }
}

/// "Send to a friend": pick a group or a person and share the card.
Future<void> shareSheet(BuildContext context, AppCtx app, Map ref) async {
  final social = app.social;
  if (social == null) return;
  final note = TextEditingController();
  final messenger = ScaffoldMessenger.of(context);
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) {
      final groups = social.convs.where((c) => c['kind'] == 'group').toList();
      final others = social.people.where((p) => p['name'] != social.me).toList();
      Future<void> send({String? conv, String? user}) async {
        try {
          var id = conv;
          if (id == null) {
            final c = await app.api.chatDM(user!);
            social.upsert(c);
            id = '${c['id']}';
          }
          final r = await app.api.chatSend(id, note.text.trim(), ref: ref);
          if (ctx.mounted) Navigator.pop(ctx);
          messenger.showSnackBar(SnackBar(
            duration: Duration(seconds: r['warning'] != null ? 6 : 3),
            content: Text(r['warning'] != null ? 'Sent, but ${r['warning']}' : 'Sent to ${user ?? groups.firstWhere((g) => g['id'] == conv)['title']}'),
          ));
        } on ApiException catch (e) {
          messenger.showSnackBar(SnackBar(content: Text(e.message)));
        }
      }

      return Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: ListView(shrinkWrap: true, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text('Send “${ref['title']}” to…', style: Theme.of(ctx).textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(controller: note, decoration: const InputDecoration(hintText: 'Add a message (optional)', isDense: true, border: OutlineInputBorder())),
          ),
          for (final g in groups)
            ListTile(leading: const CircleAvatar(child: Icon(Icons.groups, size: 20)), title: Text('${g['title']}'), onTap: () => send(conv: '${g['id']}')),
          for (final p in others)
            ListTile(
              leading: _Avatar('${p['name']}', online: p['online'] == true),
              title: Text('${p['name']}'),
              subtitle: p['online'] == true ? const Text('online') : null,
              onTap: () => send(user: '${p['name']}'),
            ),
          const SizedBox(height: 16),
        ]),
      );
    },
  );
  note.dispose();
}

class _Avatar extends StatelessWidget {
  const _Avatar(this.name, {this.online = false, this.group = false});
  final String name;
  final bool online, group;
  @override
  Widget build(BuildContext context) => Stack(clipBehavior: Clip.none, children: [
        CircleAvatar(
          backgroundColor: const Color(0xFF253043),
          child: group ? const Icon(Icons.groups, size: 20) : Text(name.isNotEmpty ? name[0].toUpperCase() : '?', style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
        if (online)
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(color: const Color(0xFF3ECF8E), shape: BoxShape.circle, border: Border.all(color: const Color(0xFF0D0F13), width: 2)),
            ),
          ),
      ]);
}

/// The Chat tab: who's online (and what they're playing) + conversations.
class ChatView extends StatelessWidget {
  const ChatView({super.key, required this.app});
  final AppCtx app;

  Future<void> _openDM(BuildContext context, String user) async {
    try {
      final c = await app.api.chatDM(user);
      app.social!.upsert(c);
      if (context.mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(app: app, convId: '${c['id']}')));
    } on ApiException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = app.social!;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final others = s.people.where((p) => p['name'] != s.me).toList();
        final online = others.where((p) => p['online'] == true).toList();
        final offline = others.where((p) => p['online'] != true).toList();
        return ListView(padding: const EdgeInsets.only(bottom: 32), children: [
          if (!s.connected)
            const ListTile(dense: true, leading: Icon(Icons.cloud_off, size: 18), title: Text('Reconnecting…', style: TextStyle(color: Color(0xFF9AA3B2)))),
          SectionTitle('Online · ${online.length}'),
          if (online.isEmpty) const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('Nobody else is online', style: TextStyle(color: Color(0xFF8B95A5)))),
          for (final p in online)
            ListTile(
              leading: _Avatar('${p['name']}', online: true),
              title: Text('${p['name']}'),
              subtitle: p['activity'] == null
                  ? null
                  : Text(_actLine(p['activity'] as Map), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
              trailing: (p['activity'] as Map?)?['path'] != null && '${(p['activity'] as Map)['path']}'.isNotEmpty
                  ? IconButton(tooltip: 'Watch / listen too', icon: const Icon(Icons.play_circle_outline), onPressed: () => openRef(context, app, p['activity'] as Map))
                  : null,
              onTap: () => _openDM(context, '${p['name']}'),
            ),
          Row(children: [
            const Expanded(child: SectionTitle('Chats')),
            TextButton.icon(icon: const Icon(Icons.group_add_outlined, size: 18), label: const Text('New group'), onPressed: () => groupDialog(context, app)),
            const SizedBox(width: 8),
          ]),
          if (s.convs.isEmpty) const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('No chats yet — tap someone to start one.', style: TextStyle(color: Color(0xFF8B95A5)))),
          for (final c in s.convs) _convTile(context, c),
          if (offline.isNotEmpty)
            ExpansionTile(
              title: Text('Offline · ${offline.length}'),
              children: [
                for (final p in offline)
                  ListTile(
                    leading: _Avatar('${p['name']}'),
                    title: Text('${p['name']}'),
                    subtitle: (p['lastSeen'] as num? ?? 0) > 0 ? Text('last seen ${_ago((p['lastSeen'] as num).toInt())}', style: const TextStyle(fontSize: 12)) : null,
                    onTap: () => _openDM(context, '${p['name']}'),
                  ),
              ],
            ),
          SwitchListTile(
            value: s.hideActivity,
            onChanged: (v) => s.setHide(v),
            title: const Text("Hide what I'm watching"),
            subtitle: const Text('Others still see that you are online'),
          ),
        ]);
      },
    );
  }

  Widget _convTile(BuildContext context, Map c) {
    final last = c['last'] as Map?;
    final unread = (c['unread'] as num? ?? 0).toInt();
    final online = c['kind'] == 'dm' && app.social!.people.any((p) => p['name'] == c['title'] && p['online'] == true);
    final preview = last == null
        ? 'No messages yet'
        : '${last['sys'] == true ? '' : '${last['from']}: '}${last['ref'] != null ? '📎 ${(last['ref'] as Map)['title']}' : last['text']}';
    return ListTile(
      leading: _Avatar('${c['title']}', online: online, group: c['kind'] == 'group'),
      title: Text('${c['title']}', style: TextStyle(fontWeight: unread > 0 ? FontWeight.bold : FontWeight.normal)),
      subtitle: Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: unread > 0 ? Badge(label: Text('$unread')) : null,
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(app: app, convId: '${c['id']}'))),
    );
  }
}

String _ago(int ts) {
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ts * 1000));
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

/// Create a group, or edit one (rename, add / remove people, leave).
Future<void> groupDialog(BuildContext context, AppCtx app, {Map? conv}) async {
  final s = app.social!;
  final name = TextEditingController(text: conv == null ? '' : '${conv['name'] ?? conv['title']}');
  final members = <String>{...List<String>.from(conv?['members'] as List? ?? const [])}..remove(s.me);
  final before = {...members};
  final messenger = ScaffoldMessenger.of(context);
  final nav = Navigator.of(context);
  final res = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: Text(conv == null ? 'New group' : 'Group'),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Group name')),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final p in s.people.where((p) => p['name'] != s.me))
                  CheckboxListTile(
                    dense: true,
                    value: members.contains(p['name']),
                    onChanged: (v) => set(() => v == true ? members.add('${p['name']}') : members.remove('${p['name']}')),
                    title: Text('${p['name']}'),
                    secondary: _Avatar('${p['name']}', online: p['online'] == true),
                  ),
              ]),
            ),
          ]),
        ),
        actions: [
          if (conv != null) TextButton(onPressed: () => Navigator.pop(ctx, 'leave'), child: const Text('Leave group', style: TextStyle(color: Colors.redAccent))),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: Text(conv == null ? 'Create' : 'Save')),
        ],
      ),
    ),
  );
  final n = name.text.trim();
  name.dispose();
  try {
    if (res == 'leave') {
      await app.api.chatLeave('${conv!['id']}');
      s.convs.removeWhere((c) => c['id'] == conv['id']);
      s.markRead('');
      nav.popUntil((r) => r.isFirst);
    } else if (res == 'save') {
      if (conv == null) {
        if (n.isEmpty) {
          messenger.showSnackBar(const SnackBar(content: Text('Name the group')));
          return;
        }
        final c = await app.api.chatGroup(n, members.toList());
        s.upsert(c);
        nav.push(MaterialPageRoute(builder: (_) => ChatScreen(app: app, convId: '${c['id']}')));
      } else {
        await app.api.chatUpdate('${conv['id']}',
            name: n, add: members.difference(before).toList(), remove: before.difference(members).toList());
      }
    }
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.app, required this.convId});
  final AppCtx app;
  final String convId;
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  List<Map> msgs = [];
  Map? conv;
  bool loading = true, more = true;

  Social get s => widget.app.social!;

  @override
  void initState() {
    super.initState();
    s.openConv = widget.convId;
    s.onMessage = (id, m) {
      if (!mounted || id != widget.convId || msgs.any((x) => x['seq'] == m['seq'])) return;
      setState(() => msgs.add(m));
    };
    s.addListener(_convChanged);
    _load();
  }

  void _convChanged() {
    final c = s.convs.where((x) => x['id'] == widget.convId).firstOrNull;
    if (c != null && mounted) setState(() => conv = c);
  }

  @override
  void dispose() {
    s.removeListener(_convChanged);
    if (s.openConv == widget.convId) {
      s.openConv = null;
      s.onMessage = null;
    }
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool older = false}) async {
    try {
      final before = older && msgs.isNotEmpty ? (msgs.first['seq'] as num).toInt() : 0;
      final r = await widget.app.api.chatMessages(widget.convId, before: before);
      final list = List<Map>.from(r['messages'] as List);
      if (!mounted) return;
      setState(() {
        conv = Map.from(r['conversation'] as Map);
        msgs = older ? [...list, ...msgs] : list;
        more = list.length >= 50;
        loading = false;
      });
      if (!older && (conv!['unread'] as num? ?? 0) > 0) {
        widget.app.api.chatRead(widget.convId, (conv!['seq'] as num).toInt()).catchError((_) {});
      }
      s.markRead(widget.convId);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => loading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    _text.clear();
    try {
      final r = await widget.app.api.chatSend(widget.convId, t);
      final m = Map.from(r['message'] as Map);
      if (mounted && !msgs.any((x) => x['seq'] == m['seq'])) setState(() => msgs.add(m));
    } on ApiException catch (e) {
      _text.text = t;
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = conv;
    final group = c?['kind'] == 'group';
    final online = !group && s.people.any((p) => p['name'] == c?['title'] && p['online'] == true);
    final activity = group ? null : (s.people.where((p) => p['name'] == c?['title']).firstOrNull?['activity'] as Map?);
    final items = msgs.reversed.toList();
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${c?['title'] ?? ''}'),
          if (group) Text('${(c?['members'] as List?)?.length ?? 0} members', style: const TextStyle(fontSize: 12, color: Color(0xFF9AA3B2))),
          if (!group && (online || activity != null))
            Text(activity != null ? _actLine(activity) : 'online', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Color(0xFF3ECF8E))),
        ]),
        actions: [
          if (group) IconButton(tooltip: 'Group', icon: const Icon(Icons.group_outlined), onPressed: () => groupDialog(context, widget.app, conv: c)),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  controller: _scroll,
                  reverse: true,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  itemCount: items.length + (more ? 1 : 0),
                  itemBuilder: (_, i) {
                    if (i == items.length) {
                      return Center(child: TextButton(onPressed: () => _load(older: true), child: const Text('Load earlier')));
                    }
                    return _bubble(items[i], group);
                  },
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 6, 8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _text,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(hintText: 'Message…', isDense: true, border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(20)))),
                ),
              ),
              IconButton(icon: const Icon(Icons.send), onPressed: _send),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _bubble(Map m, bool group) {
    final ts = DateTime.fromMillisecondsSinceEpoch(((m['ts'] as num?) ?? 0).toInt() * 1000);
    if (m['sys'] == true) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(child: Text('${m['text']}', style: const TextStyle(fontSize: 12, color: Color(0xFF8B95A5)))),
      );
    }
    final mine = m['from'] == s.me;
    final ref = m['ref'] as Map?;
    final time = '${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * .78),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
            if (!mine && group) Text('${m['from']}', style: const TextStyle(fontSize: 11, color: Color(0xFF8B95A5))),
            if (ref != null)
              Card(
                margin: const EdgeInsets.only(top: 2, bottom: 2),
                child: InkWell(
                  onTap: () => openRef(context, widget.app, ref),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(5),
                        child: SizedBox(
                          width: 46,
                          height: 68,
                          child: NetImage(_imgUrl(widget.app, '${ref['image'] ?? ''}'), headers: widget.app.api.authHeaders, placeholder: ref['kind'] == 'music' ? '♪' : '🎬'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${ref['title']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                          if ('${ref['sub'] ?? ''}'.isNotEmpty) Text('${ref['sub']}', style: const TextStyle(fontSize: 12, color: Color(0xFF9AA3B2))),
                          const SizedBox(height: 6),
                          Text(ref['kind'] == 'music' ? '▶ Play' : '▶ Watch', style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 12.5)),
                        ]),
                      ),
                    ]),
                  ),
                ),
              ),
            if ('${m['text'] ?? ''}'.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: mine ? const Color(0xFF2B6FD6) : const Color(0xFF1D2430), borderRadius: BorderRadius.circular(16)),
                child: SelectableText('${m['text']}', style: const TextStyle(color: Colors.white)),
              ),
            Text(time, style: const TextStyle(fontSize: 10, color: Color(0xFF7D8696))),
          ]),
        ),
      ),
    );
  }
}
