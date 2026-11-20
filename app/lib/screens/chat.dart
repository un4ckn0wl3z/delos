import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../library.dart';
import '../social.dart';
import '../util.dart';
import '../widgets.dart';
import 'emoji_picker.dart';
import 'home_screen.dart';
import 'party_screen.dart';
import 'ranking.dart';

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
              leading: UserAvatar(social, '${p['name']}', online: p['online'] == true),
              title: nameWithBadge(social, '${p['name']}'),
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

const _avColors = [Color(0xFF3B6FD6), Color(0xFF2F9E74), Color(0xFFB8569A), Color(0xFFC9752C), Color(0xFF7B5CD6), Color(0xFF2E8FA8), Color(0xFFB54A4A), Color(0xFF5F8F2E)];

/// A person's profile picture (or their initial on a colour), with an
/// optional green online dot.
class UserAvatar extends StatelessWidget {
  const UserAvatar(this.social, this.name, {super.key, this.online = false, this.group = false, this.radius = 20});
  final Social social;
  final String name;
  final bool online, group;
  final double radius;
  @override
  Widget build(BuildContext context) {
    final v = social.avatarOf(name);
    var h = 0;
    for (final c in name.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return Stack(clipBehavior: Clip.none, children: [
        CircleAvatar(
          radius: radius,
          backgroundColor: group ? const Color(0xFF253043) : _avColors[h % _avColors.length],
          foregroundImage: !group && v > 0 ? NetworkImage(social.api.avatarUrl(name, v), headers: social.api.authHeaders) : null,
          child: group
              ? Icon(Icons.groups, size: radius)
              : Text(name.isNotEmpty ? name[0].toUpperCase() : '?', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: radius * .85)),
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
}

/// Small "ADMIN" tag next to an admin's name.
class AdminBadge extends StatelessWidget {
  const AdminBadge({super.key});
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(color: const Color(0xFF4A3A1C), borderRadius: BorderRadius.circular(6)),
        child: const Text('ADMIN', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: .5, color: Color(0xFFFFCF7A))),
      );
}

/// A name with the ADMIN tag when that person is an admin.
Widget nameWithBadge(Social s, String name, {TextStyle? style}) => Row(mainAxisSize: MainAxisSize.min, children: [
      Flexible(child: Text(name, style: style, overflow: TextOverflow.ellipsis)),
      if (s.isAdmin(name)) const AdminBadge(),
      BadgeIcons(badgesOf(s, name), max: 3),
    ]);

/// Ranking badges of a person (from the people list).
List<Map> badgesOf(Social s, String name) =>
    List<Map>.from((s.people.where((p) => p['name'] == name).firstOrNull?['badges'] as List?) ?? const []);

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
          if (app.party != null)
            ListTile(
              leading: const Icon(Icons.celebration_outlined, color: Color(0xFFB79CFF)),
              title: const Text('Party'),
              subtitle: const Text('Watch or listen together · chat · schedule'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => app.party!.party != null ? PartyRoomScreen(app: app) : PartyListScreen(app: app))),
            ),
          ListTile(
            leading: const Icon(Icons.emoji_events_outlined, color: Color(0xFFF5C542)),
            title: const Text('Ranking'),
            subtitle: const Text('Who watched and listened the most · badges'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => RankingScreen(app: app))),
          ),
          SectionTitle('Online · ${online.length}'),
          if (online.isEmpty) const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('Nobody else is online', style: TextStyle(color: Color(0xFF8B95A5)))),
          for (final p in online)
            ListTile(
              leading: UserAvatar(s, '${p['name']}', online: true),
              title: nameWithBadge(s, '${p['name']}'),
              subtitle: p['activity'] == null
                  ? null
                  : Text(_actLine(p['activity'] as Map), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
              trailing: (p['activity'] as Map?)?['path'] != null && '${(p['activity'] as Map)['path']}'.isNotEmpty
                  ? Row(mainAxisSize: MainAxisSize.min, children: [
                      if (app.party != null)
                        IconButton(
                            tooltip: 'Ask to ${(p['activity'] as Map)['kind'] == 'music' ? 'listen' : 'watch'} together (party)',
                            icon: const Icon(Icons.celebration_outlined),
                            onPressed: () => askToJoin(context, app, '${p['name']}')),
                      IconButton(tooltip: 'Watch / listen too', icon: const Icon(Icons.play_circle_outline), onPressed: () => openRef(context, app, p['activity'] as Map)),
                    ])
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
                    leading: UserAvatar(s, '${p['name']}'),
                    title: nameWithBadge(s, '${p['name']}'),
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
        : '${last['sys'] == true ? '' : '${last['from']}: '}${Social.preview(last)}';
    return ListTile(
      leading: UserAvatar(app.social!, '${c['title']}', online: online, group: c['kind'] == 'group'),
      title: c['kind'] == 'group'
          ? Text('${c['title']}', style: TextStyle(fontWeight: unread > 0 ? FontWeight.bold : FontWeight.normal))
          : nameWithBadge(app.social!, '${c['title']}', style: TextStyle(fontWeight: unread > 0 ? FontWeight.bold : FontWeight.normal)),
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
                    title: nameWithBadge(s, '${p['name']}'),
                    secondary: UserAvatar(s, '${p['name']}', online: p['online'] == true),
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
  final List<String> _uploads = [];

  Social get s => widget.app.social!;

  @override
  void initState() {
    super.initState();
    s.openConv = widget.convId;
    s.onMessage = (id, m) {
      if (!mounted || id != widget.convId || msgs.any((x) => x['seq'] == m['seq'])) return;
      setState(() => msgs.add(m));
    };
    s.onReaction = (id, seq, re) {
      if (!mounted || id != widget.convId) return;
      final m = msgs.where((x) => x['seq'] == seq).firstOrNull;
      if (m != null) setState(() => m['reactions'] = re);
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
      s.onReaction = null;
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

  void _insertEmoji(String e) {
    final v = _text.value;
    final sel = v.selection;
    final start = sel.isValid ? sel.start : v.text.length;
    final end = sel.isValid ? sel.end : v.text.length;
    _text.value = TextEditingValue(text: v.text.replaceRange(start, end, e), selection: TextSelection.collapsed(offset: start + e.length));
  }

  Future<void> _attach() async {
    final messenger = ScaffoldMessenger.of(context);
    final FilePickerResult? r;
    try {
      r = await FilePicker.platform.pickFiles(allowMultiple: true);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
      return;
    }
    if (r == null) return;
    final max = s.chatMaxMB * 1024 * 1024;
    final caption = r.files.length == 1 ? _text.text.trim() : '';
    if (caption.isNotEmpty) _text.clear();
    for (final f in r.files) {
      final path = f.path;
      if (path == null) continue;
      if (max > 0 && f.size > max) {
        messenger.showSnackBar(SnackBar(content: Text('${f.name} is too big (max ${s.chatMaxMB} MB)')));
        continue;
      }
      setState(() => _uploads.add(f.name));
      try {
        final res = await widget.app.api.chatAttach(widget.convId, path, f.name, text: caption);
        final m = Map.from(res['message'] as Map);
        if (mounted && !msgs.any((x) => x['seq'] == m['seq'])) setState(() => msgs.add(m));
      } on ApiException catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('${f.name}: ${e.message}')));
      } finally {
        if (mounted) setState(() => _uploads.remove(f.name));
      }
    }
  }

  Future<void> _react(Map m) async {
    final text = '${m['text'] ?? ''}';
    final e = await pickReaction(context, widget.app.api, copyText: text.isEmpty ? null : text);
    if (e != null) _toggle(m, e);
  }

  Future<void> _toggle(Map m, String emoji) async {
    try {
      final r = await widget.app.api.chatReact(widget.convId, (m['seq'] as num).toInt(), emoji);
      if (mounted) setState(() => m['reactions'] = r['reactions']);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  void _open(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  Widget _attachment(Map a, bool mine) {
    final api = widget.app.api;
    final id = '${a['id']}';
    if (a['gone'] == true) {
      return _fileCard(Icons.history, '${a['name']}', 'expired', null);
    }
    if (a['image'] == true) {
      final w = (a['w'] as num? ?? 0).toDouble(), h = (a['h'] as num? ?? 0).toDouble();
      final ratio = w > 0 && h > 0 ? (w / h).clamp(0.4, 2.5).toDouble() : 4 / 3;
      return GestureDetector(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => _ImageView(
            url: api.chatFileUrl(widget.convId, id),
            name: '${a['name']}',
            onDownload: () => _open(api.chatFileUrl(widget.convId, id, download: true)),
          ),
        )),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: 230,
            child: AspectRatio(
              aspectRatio: ratio,
              child: NetImage(api.chatFileUrl(widget.convId, id, thumb: a['thumb'] == true), placeholder: '🖼'),
            ),
          ),
        ),
      );
    }
    final mime = '${a['mime'] ?? ''}';
    final icon = mime.startsWith('video/')
        ? Icons.movie_outlined
        : mime.startsWith('audio/')
            ? Icons.audiotrack
            : mime.contains('pdf')
                ? Icons.picture_as_pdf_outlined
                : Icons.insert_drive_file_outlined;
    return _fileCard(icon, '${a['name']}', '${fmtSize((a['size'] as num? ?? 0).toInt())} · tap to download',
        () => _open(api.chatFileUrl(widget.convId, id, download: true)));
  }

  Widget _fileCard(IconData icon, String name, String sub, VoidCallback? onTap) => Card(
        margin: const EdgeInsets.symmetric(vertical: 2),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 22, color: const Color(0xFF9AA3B2)),
              const SizedBox(width: 10),
              Flexible(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
                  Text(sub, style: const TextStyle(fontSize: 11.5, color: Color(0xFF8B95A5))),
                ]),
              ),
            ]),
          ),
        ),
      );

  Widget _reactions(Map m) {
    final re = m['reactions'] as Map?;
    if (re == null || re.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Wrap(spacing: 4, runSpacing: 4, children: [
        for (final e in re.entries)
          Tooltip(
            message: (e.value as List).join(', '),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _toggle(m, '${e.key}'),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: (e.value as List).contains(s.me) ? const Color(0xFF16263D) : const Color(0xFF1A202A),
                  border: Border.all(color: (e.value as List).contains(s.me) ? const Color(0xFF4A9EFF) : const Color(0xFF2A3240)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text((e.value as List).length > 1 ? '${e.key} ${(e.value as List).length}' : '${e.key}', style: const TextStyle(fontSize: 13)),
              ),
            ),
          ),
      ]),
    );
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
        titleSpacing: 0,
        title: Row(children: [
          if (c != null) Padding(padding: const EdgeInsets.only(right: 10), child: UserAvatar(s, '${c['title']}', group: group, radius: 17)),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          group ? Text('${c?['title'] ?? ''}') : nameWithBadge(s, '${c?['title'] ?? ''}'),
          if (group) Text('${(c?['members'] as List?)?.length ?? 0} members', style: const TextStyle(fontSize: 12, color: Color(0xFF9AA3B2))),
          if (!group && (online || activity != null))
            Text(activity != null ? _actLine(activity) : 'online', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Color(0xFF3ECF8E))),
          ])),
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
        for (final u in _uploads)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Row(children: [
              const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Expanded(child: Text('Sending $u…', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Color(0xFF9AA3B2)))),
            ]),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(2, 6, 6, 8),
            child: Row(children: [
              IconButton(
                tooltip: 'Emoji',
                icon: const Icon(Icons.emoji_emotions_outlined),
                onPressed: () async {
                  final e = await pickEmoji(context, widget.app.api);
                  if (e != null) _insertEmoji(e);
                },
              ),
              if (s.chatMaxMB > 0) IconButton(tooltip: 'Attach pictures or files', icon: const Icon(Icons.attach_file), onPressed: _attach),
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
    final att = m['att'] as Map?;
    final time = '${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () => _react(m),
      onSecondaryTap: () => _react(m),
      child: Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * .78),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
            if (!mine && group)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  UserAvatar(s, '${m['from']}', radius: 9),
                  const SizedBox(width: 5),
                  nameWithBadge(s, '${m['from']}', style: const TextStyle(fontSize: 11, color: Color(0xFF8B95A5))),
                ]),
              ),
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
            if (att != null) _attachment(att, mine),
            if ('${m['text'] ?? ''}'.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: mine ? const Color(0xFF2B6FD6) : const Color(0xFF1D2430), borderRadius: BorderRadius.circular(16)),
                child: Text('${m['text']}', style: const TextStyle(color: Colors.white)),
              ),
            _reactions(m),
            Text(time, style: const TextStyle(fontSize: 10, color: Color(0xFF7D8696))),
          ]),
        ),
      ),
    ));
  }
}

/// Full-size picture from a chat, zoomable.
class _ImageView extends StatelessWidget {
  const _ImageView({required this.url, required this.name, required this.onDownload});
  final String url, name;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15)),
          actions: [IconButton(tooltip: 'Download', icon: const Icon(Icons.download), onPressed: onDownload)],
        ),
        body: InteractiveViewer(
          maxScale: 6,
          child: Center(
            child: Image.network(url,
                loadingBuilder: (_, child, p) => p == null ? child : const Center(child: CircularProgressIndicator()),
                errorBuilder: (_, __, ___) => const Text('This picture has expired or could not load', style: TextStyle(color: Colors.white70))),
          ),
        ),
      );
}
