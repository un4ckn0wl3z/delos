import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';

/// The emoji list comes from the server (/emoji.json, the same one the web app uses).
class EmojiData {
  static Map? _data;
  static Future<Map>? _loading;
  static final List<String> recent = [];

  static Future<Map> load(Api api) {
    final d = _data;
    if (d != null) return Future.value(d);
    return _loading ??= api.emojiData().then((v) {
      _data = v;
      return v;
    }).whenComplete(() => _loading = null);
  }

  static void remember(String e) {
    recent.remove(e);
    recent.insert(0, e);
    if (recent.length > 24) recent.removeLast();
  }
}

/// Full picker (search + categories) in a bottom sheet → the chosen emoji.
Future<String?> pickEmoji(BuildContext context, Api api) async {
  final e = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _EmojiSheet(api: api),
  );
  if (e != null) EmojiData.remember(e);
  return e;
}

/// Quick reactions (recent + a few common ones), with "more" opening the full picker.
Future<String?> pickReaction(BuildContext context, Api api, {String? copyText}) async {
  final quick = <String>{...EmojiData.recent, '👍', '❤️', '😂', '😮', '😢', '🙏'}.take(6).toList();
  final r = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          for (final e in quick)
            InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: () => Navigator.pop(ctx, e),
              child: Padding(padding: const EdgeInsets.all(8), child: Text(e, style: const TextStyle(fontSize: 28))),
            ),
          IconButton(tooltip: 'More', icon: const Icon(Icons.add_reaction_outlined), onPressed: () => Navigator.pop(ctx, '+')),
        ]),
      ),
      if (copyText != null)
        ListTile(
          leading: const Icon(Icons.copy),
          title: const Text('Copy text'),
          onTap: () {
            Clipboard.setData(ClipboardData(text: copyText));
            Navigator.pop(ctx);
          },
        ),
      ]),
    ),
  );
  if (r == '+') {
    if (!context.mounted) return null;
    return pickEmoji(context, api);
  }
  if (r != null) EmojiData.remember(r);
  return r;
}

class _EmojiSheet extends StatefulWidget {
  const _EmojiSheet({required this.api});
  final Api api;
  @override
  State<_EmojiSheet> createState() => _EmojiSheetState();
}

class _EmojiSheetState extends State<_EmojiSheet> {
  Map? data;
  String? error;
  String q = '';
  int group = 0;

  @override
  void initState() {
    super.initState();
    EmojiData.load(widget.api).then((d) {
      if (mounted) setState(() => data = d);
    }, onError: (Object e) {
      if (mounted) setState(() => error = "Couldn't load emoji");
    });
  }

  List<Map> get groups => [
        if (EmojiData.recent.isNotEmpty)
          {
            'name': 'Recent',
            'icon': '🕘',
            'items': [
              for (final e in EmojiData.recent) [e, '']
            ],
          },
        ...List<Map>.from(data?['groups'] as List? ?? const []),
      ];

  @override
  Widget build(BuildContext context) {
    final gs = groups;
    final gi = group < gs.length ? group : 0;
    final List<String> items = [];
    if (q.isNotEmpty) {
      for (final g in List<Map>.from(data?['groups'] as List? ?? const [])) {
        for (final it in g['items'] as List) {
          final row = it as List;
          if ('${row[1]}'.contains(q)) items.add('${row[0]}');
        }
      }
    } else if (gs.isNotEmpty) {
      for (final it in gs[gi]['items'] as List) {
        items.add('${(it as List)[0]}');
      }
    }
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * .55,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: TextField(
              decoration: const InputDecoration(hintText: 'Search emoji', isDense: true, prefixIcon: Icon(Icons.search), border: OutlineInputBorder()),
              onChanged: (v) => setState(() => q = v.trim().toLowerCase()),
            ),
          ),
          if (q.isEmpty && gs.isNotEmpty)
            SizedBox(
              height: 42,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
                for (var i = 0; i < gs.length; i++)
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => setState(() => group = i),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                      decoration: BoxDecoration(color: i == gi ? const Color(0xFF253043) : null, borderRadius: BorderRadius.circular(8)),
                      child: Text('${gs[i]['icon']}', style: const TextStyle(fontSize: 20)),
                    ),
                  ),
              ]),
            ),
          Expanded(
            child: data == null
                ? Center(child: error != null ? Text(error!) : const CircularProgressIndicator())
                : items.isEmpty
                    ? const Center(child: Text('No emoji found', style: TextStyle(color: Color(0xFF8B95A5))))
                    : GridView.builder(
                        padding: const EdgeInsets.all(8),
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 48),
                        itemCount: items.length,
                        itemBuilder: (_, i) => InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => Navigator.pop(context, items[i]),
                          child: Center(child: Text(items[i], style: const TextStyle(fontSize: 26))),
                        ),
                      ),
          ),
        ]),
      ),
    );
  }
}
