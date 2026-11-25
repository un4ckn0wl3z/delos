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

  Widget _head(BuildContext context, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(t, style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600)),
      );

  List<Widget> _audioSection(BuildContext context) {
    final s = h.settings;
    if (s == null) return const [];
    final bad = s.dlnaBadAudio;
    final dl = h.ffmpegProgress;
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return [
      _head(context, 'Audio the TV can\'t play'),
      SwitchListTile(
        secondary: const Icon(Icons.surround_sound_outlined),
        title: const Text('Convert it for the TV'),
        subtitle: const Text('Picture stays as it is; only the sound becomes Dolby Digital (AC3) 5.1. Seeking works by time.'),
        value: s.dlnaFixAudio,
        onChanged: (v) {
          s.dlnaFixAudio = v;
          h.changed();
        },
      ),
      if (s.dlnaFixAudio) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(72, 0, 16, 4),
          child: Wrap(spacing: 8, children: [
            for (final (c, label) in const [('dts', 'DTS'), ('truehd', 'TrueHD / Atmos'), ('eac3', 'E-AC3'), ('flac', 'FLAC'), ('opus', 'Opus')])
              FilterChip(
                label: Text(label),
                selected: bad.contains(c),
                onSelected: (on) {
                  s.dlnaBadAudio = on ? [...bad, c] : bad.where((x) => x != c).toList();
                  h.changed();
                },
              ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
          child: Text('Pick what your TV can\'t play. Newer LG TVs (2023+) play DTS again — untick it if yours does.', style: muted),
        ),
        ListTile(
          leading: const Icon(Icons.build_circle_outlined),
          title: const Text('Converter (ffmpeg) on this PC'),
          subtitle: dl != null
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(dl >= 1 ? 'Unpacking…' : 'Downloading… ${(dl * 100).round()}%'),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(value: dl >= 1 ? null : dl),
                ])
              : Text(h.ffmpegPath != null
                  ? 'Ready${h.convertCount > 0 ? ' — ${h.convertCount} files get converted' : ''}'
                      '${(h.server?.converting ?? 0) > 0 ? ' · converting ${h.server!.converting} now' : ''}'
                  : h.ffmpegError != null
                      ? "Download failed: ${h.ffmpegError}"
                      : 'Not installed — needed to check and convert files on this PC (≈ 150 MB download)'),
          trailing: h.ffmpegPath == null && dl == null ? FilledButton.tonal(onPressed: h.ffmpegDownload, child: const Text('Download')) : null,
        ),
      ],
    ];
  }

  List<Widget> _onlineSection(BuildContext context) {
    final s = h.settings;
    if (s == null) return const [];
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return [
      _head(context, 'Online library (passthrough)'),
      SwitchListTile(
        secondary: const Icon(Icons.cloud_outlined),
        title: const Text('Share the server\'s libraries too'),
        subtitle: Text(!s.loggedIn
            ? 'Sign in to your server first'
            : !s.dlnaOnline
                ? 'The TV gets an "Online" folder; files stream from the server through this PC'
                : h.onlineError != null
                    ? "Couldn't load: ${h.onlineError}"
                    : h.onlineAt == null
                        ? 'Loading…'
                        : '${h.onlineCount} files · updated ${TimeOfDay.fromDateTime(h.onlineAt!).format(context)}'),
        value: s.dlnaOnline && s.loggedIn,
        onChanged: s.loggedIn ? (v) => h.setOnline(v) : null,
      ),
      if (s.dlnaOnline && s.loggedIn) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(72, 0, 16, 4),
          child: Row(children: [
            Expanded(child: Text('Convert online files on', style: Theme.of(context).textTheme.bodyMedium)),
            TextButton.icon(onPressed: h.refreshOnline, icon: const Icon(Icons.refresh, size: 18), label: const Text('Refresh list')),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(72, 4, 16, 4),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'pc', icon: Icon(Icons.computer), label: Text('This PC')),
              ButtonSegment(value: 'server', icon: Icon(Icons.dns_outlined), label: Text('Server')),
            ],
            selected: {s.dlnaConvertAt},
            onSelectionChanged: (v) {
              s.dlnaConvertAt = v.first;
              h.changed();
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(72, 4, 16, 8),
          child: Text(
              s.dlnaConvertAt == 'pc'
                  ? 'This PC: the server only sends the file; ffmpeg here converts the sound (light work). Needs the converter above.'
                  : 'Server: the seedbox converts the sound and this PC just passes it on. Uses the server\'s CPU and counts as a stream there.',
              style: muted),
        ),
      ],
    ];
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
        ..._audioSection(context),
        ..._onlineSection(context),
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
