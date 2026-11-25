import 'package:flutter/material.dart';

import 'dlna_host.dart';

/// Settings → "Share to TV (DLNA)".
class DlnaScreen extends StatefulWidget {
  const DlnaScreen({super.key});
  @override
  State<DlnaScreen> createState() => _DlnaScreenState();
}

class _DlnaScreenState extends State<DlnaScreen> {
  final h = DlnaHost.instance;

  @override
  void initState() {
    super.initState();
    h.addListener(_changed);
  }

  @override
  void dispose() {
    h.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _rename() async {
    final c = TextEditingController(text: h.name);
    final n = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name on the TV'),
        content: TextField(controller: c, autofocus: true, decoration: InputDecoration(hintText: h.defaultName), onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
        ],
      ),
    );
    if (n != null) await h.rename(n);
  }

  @override
  Widget build(BuildContext context) {
    final srv = h.server;
    final items = h.items;
    final counts = <String, int>{};
    for (final it in items) {
      counts[it.kind] = (counts[it.kind] ?? 0) + 1;
    }
    final now = DateTime.now();
    final active = srv == null
        ? <String>[]
        : (srv.clients.entries.where((e) => now.difference(e.value).inSeconds < 60).map((e) => e.key).toList()..sort());
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(title: const Text('Share to TV (DLNA)')),
      body: ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
        SwitchListTile(
          secondary: const Icon(Icons.connected_tv),
          title: const Text('DLNA server'),
          subtitle: Text(h.busy
              ? 'Starting…'
              : h.running
                  ? 'On — your TV sees "${h.name}"'
                  : 'Off'),
          value: h.running,
          onChanged: h.busy ? null : (v) => h.setOn(v),
        ),
        if (h.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text("Couldn't start: ${h.error}", style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ListTile(
          leading: const Icon(Icons.badge_outlined),
          title: const Text('Name on the TV'),
          subtitle: Text(h.name),
          trailing: const Icon(Icons.edit_outlined),
          onTap: _rename,
        ),
        ListTile(
          leading: const Icon(Icons.video_library_outlined),
          title: const Text('Shared'),
          subtitle: Text(items.isEmpty
              ? 'Nothing yet — download something for offline, or add one of your folders in Offline.'
              : [
                  if ((counts['movie'] ?? 0) > 0) '${counts['movie']} movies',
                  if ((counts['episode'] ?? 0) > 0) '${counts['episode']} episodes',
                  if ((counts['video'] ?? 0) > 0) '${counts['video']} videos',
                  if ((counts['music'] ?? 0) > 0) '${counts['music']} songs',
                ].join(' · ')),
        ),
        if (srv != null) ...[
          ListTile(
            leading: const Icon(Icons.lan_outlined),
            title: const Text('Address'),
            subtitle: SelectableText(srv.addresses.isEmpty
                ? 'No network found — connect this PC to your Wi-Fi or LAN'
                : srv.addresses.map((a) => 'http://${a.address}:${srv.boundPort}/desc.xml').join('\n')),
          ),
          ListTile(
            leading: const Icon(Icons.tv),
            title: const Text('TVs using it now'),
            subtitle: Text(active.isEmpty ? 'None in the last minute' : active.join(', ')),
          ),
        ],
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Text(
            'On the TV (same Wi-Fi / LAN as this PC): LG → Media Player or "Photo & Video"; Samsung → Source / Connected devices; '
            'Android TV → VLC or Kodi → UPnP. Open "${h.name}": Recently added, Movies, TV shows, Videos, Music.\n\n'
            'Files play as they are (no converting), so the TV must support the format. Subtitles next to the video (.srt) are '
            'offered to the TV too.\n\n'
            'Windows asks once whether Delos may use the network: allow "Private networks". The server runs while Delos is open.',
            style: muted,
          ),
        ),
      ]),
    );
  }
}
