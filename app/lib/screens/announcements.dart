import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../social.dart';

const _icons = {'info': 'ℹ️', 'warning': '⚠️', 'important': '🔴'};
const _colors = {'info': Color(0xFF3B6FD6), 'warning': Color(0xFFD9A43B), 'important': Color(0xFFE5484D)};

String _when(Map a) => DateTime.fromMillisecondsSinceEpoch(((a['created'] as num?) ?? 0).toInt() * 1000).toLocal().toString().substring(0, 16);

/// Text with clickable http(s) links.
class LinkText extends StatefulWidget {
  const LinkText(this.text, {super.key, this.style});
  final String text;
  final TextStyle? style;
  @override
  State<LinkText> createState() => _LinkTextState();
}

class _LinkTextState extends State<LinkText> {
  final _taps = <TapGestureRecognizer>[];
  static final _re = RegExp(r'https?://[^\s<]+[^\s<.,;:!?)\]' "'" r'"]');

  @override
  void dispose() {
    for (final t in _taps) {
      t.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
    final spans = <InlineSpan>[];
    var i = 0;
    for (final m in _re.allMatches(widget.text)) {
      if (m.start > i) spans.add(TextSpan(text: widget.text.substring(i, m.start)));
      final url = m.group(0)!;
      final tap = TapGestureRecognizer()..onTap = () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      _taps.add(tap);
      spans.add(TextSpan(text: url, style: const TextStyle(color: Color(0xFF7CC4FF), decoration: TextDecoration.underline), recognizer: tap));
      i = m.end;
    }
    if (i < widget.text.length) spans.add(TextSpan(text: widget.text.substring(i)));
    return Text.rich(TextSpan(style: widget.style ?? DefaultTextStyle.of(context).style, children: spans));
  }
}

/// An "important" announcement pops up as a dialog; OK marks it read.
Future<void> showAnnouncementDialog(BuildContext context, Social s, Map a) async {
  await showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('${_icons[a['level']] ?? 'ℹ️'} ${a['title'] ?? 'Announcement'}'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if ('${a['body'] ?? ''}'.isNotEmpty) LinkText('${a['body']}', style: const TextStyle(height: 1.5, fontSize: 15)),
          const SizedBox(height: 12),
          Text('From ${a['author']} · ${_when(a)}', style: const TextStyle(fontSize: 12, color: Color(0xFF8B95A5))),
        ]),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
    ),
  );
  s.markAnnouncementRead(a);
}

/// 📣 — everything active, newest first.
class AnnouncementsScreen extends StatefulWidget {
  const AnnouncementsScreen({super.key, required this.social});
  final Social social;
  @override
  State<AnnouncementsScreen> createState() => _AnnouncementsScreenState();
}

class _AnnouncementsScreenState extends State<AnnouncementsScreen> {
  List<Map>? items;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.social.api.announcements(all: true);
      if (mounted) setState(() => items = List<Map>.from(d['items'] as List? ?? const []));
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = items;
    final unread = list?.where((a) => a['read'] != true).length ?? 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Announcements'), actions: [
        if (unread > 0)
          TextButton(
            onPressed: () async {
              await widget.social.api.announcementsReadAll().catchError((_) {});
              await widget.social.loadAnnouncements();
              _load();
            },
            child: const Text('Mark all read'),
          ),
      ]),
      body: list == null
          ? Center(child: error != null ? Text(error!) : const CircularProgressIndicator())
          : list.isEmpty
              ? const Center(child: Text('Nothing right now', style: TextStyle(color: Color(0xFF8B95A5))))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.all(12), children: [
                    for (final a in list)
                      Card(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(color: _colors[a['level']] ?? _colors['info']!, width: 1),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: a['read'] == true
                              ? null
                              : () {
                                  widget.social.markAnnouncementRead(a);
                                  setState(() => a['read'] = true);
                                },
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Row(children: [
                                Expanded(
                                  child: Text('${_icons[a['level']] ?? 'ℹ️'} ${a['title'] ?? ''}${a['pinned'] == true ? ' 📌' : ''}',
                                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                                ),
                                if (a['read'] != true)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                    decoration: BoxDecoration(color: const Color(0xFFE5484D), borderRadius: BorderRadius.circular(8)),
                                    child: const Text('new', style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold)),
                                  ),
                              ]),
                              if ('${a['body'] ?? ''}'.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                LinkText('${a['body']}', style: const TextStyle(height: 1.45)),
                              ],
                              const SizedBox(height: 8),
                              Text('${a['author']} · ${_when(a)}', style: const TextStyle(fontSize: 12, color: Color(0xFF8B95A5))),
                            ]),
                          ),
                        ),
                      ),
                  ]),
                ),
    );
  }
}
