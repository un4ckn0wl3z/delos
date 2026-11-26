import 'dart:io';

import 'package:flutter/material.dart';

import 'dlna_host.dart';
import 'keep_awake.dart';

String _size(int b) => b >= 1 << 30 ? '${(b / (1 << 30)).toStringAsFixed(1)} GB' : '${(b / (1 << 20)).toStringAsFixed(0)} MB';

/// Every file whose audio gets converted, with its TV copy (make / delete one).
class TvCopiesScreen extends StatefulWidget {
  const TvCopiesScreen({super.key});
  @override
  State<TvCopiesScreen> createState() => _TvCopiesScreenState();
}

class _TvCopiesScreenState extends State<TvCopiesScreen> {
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

  @override
  Widget build(BuildContext context) {
    final cands = h.candidates;
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant);
    final canMake = h.ffmpegPath != null && h.running;
    return Scaffold(
      appBar: AppBar(title: const Text('TV copies')),
      body: cands.isEmpty
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('No file needs converting.', style: muted)))
          : ListView.builder(
              itemCount: cands.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Text(
                        canMake
                            ? 'Online files are fetched from the server and converted into a copy on this PC (uses its disk).'
                            : h.ffmpegPath == null
                                ? 'Install the converter (previous page) to make copies.'
                                : 'Turn the DLNA server on to make copies.',
                        style: muted),
                  );
                }
                final (e, has, size) = cands[i - 1];
                final busy = h.copyKey == e.key;
                final queued = h.copyQueue.contains(e.key);
                return ListTile(
                  leading: Icon(e.section.isEmpty ? Icons.computer : Icons.cloud_outlined),
                  title: Text(DlnaHost.labelOf(e), maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(busy
                      ? 'Converting… ${(h.copyProgress * 100).round()}%'
                      : queued
                          ? 'Queued'
                          : has
                              ? 'TV copy ready · ${_size(size)}'
                              : '${e.section.isEmpty ? 'This PC' : 'Online · ${e.section}'} · converted while you watch'),
                  trailing: busy
                      ? SizedBox(width: 24, height: 24, child: CircularProgressIndicator(value: h.copyProgress > 0 ? h.copyProgress : null, strokeWidth: 3))
                      : has
                          ? IconButton(tooltip: 'Delete the copy', icon: const Icon(Icons.delete_outline), onPressed: () => h.deleteCopy(e.key))
                          : queued
                              ? null
                              : TextButton(onPressed: canMake ? () => h.makeCopies([e.key]) : null, child: const Text('Convert')),
                );
              },
            ),
    );
  }
}

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

  List<Widget> _copySection(BuildContext context) {
    final s = h.settings;
    if (s == null || !s.dlnaFixAudio) return const [];
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant);
    final cands = h.candidates;
    final have = cands.where((c) => c.$2).length;
    final localTodo = cands.where((c) => !c.$2 && c.$1.section.isEmpty).length;
    return [
      _head(context, 'Convert ahead (TV copies)'),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Text('A converted copy plays like a normal file: seeking works on every TV, and nothing is converted while you watch. '
            'Copies are kept in the app\'s folder (your files stay as they are).', style: muted),
      ),
      SwitchListTile(
        secondary: const Icon(Icons.auto_mode),
        title: const Text('Convert new files ahead automatically'),
        subtitle: const Text("This PC's files (downloads and your folders)"),
        value: s.dlnaAutoCopy,
        onChanged: (v) {
          s.dlnaAutoCopy = v;
          if (v) h.makeCopies([for (final c in cands) if (!c.$2 && c.$1.section.isEmpty) c.$1.key]);
          setState(() {});
        },
      ),
      if (h.copyKey != null)
        ListTile(
          leading: const Icon(Icons.sync),
          title: Text('Converting: ${h.copyTitle}', maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SizedBox(height: 6),
            LinearProgressIndicator(value: h.copyProgress > 0 ? h.copyProgress : null),
            const SizedBox(height: 4),
            Text('${(h.copyProgress * 100).round()}%${h.copyQueue.isNotEmpty ? ' · ${h.copyQueue.length} more queued' : ''}'),
          ]),
          trailing: TextButton(onPressed: h.cancelCopies, child: const Text('Cancel')),
        ),
      if (h.copyError != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
          child: Text(h.copyError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      ListTile(
        leading: const Icon(Icons.video_settings_outlined),
        title: const Text('Files that need converting'),
        subtitle: Text(cands.isEmpty
            ? (h.ffmpegPath == null && h.onlineCount == 0 ? 'Install the converter to check this PC\'s files' : 'None')
            : '${cands.length} · $have with a TV copy${h.copiesSize > 0 ? ' (${_size(h.copiesSize)})' : ''}'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TvCopiesScreen())),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.tonalIcon(
            icon: const Icon(Icons.playlist_add_check),
            label: Text('Convert all on this PC${localTodo > 0 ? ' ($localTodo)' : ''}'),
            onPressed: localTodo == 0 || h.ffmpegPath == null || !h.running
                ? null
                : () => h.makeCopies([for (final c in cands) if (!c.$2 && c.$1.section.isEmpty) c.$1.key]),
          ),
          if (h.copiesSize > 0)
            OutlinedButton.icon(
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete all copies'),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Delete all TV copies?'),
                    content: Text('Frees ${_size(h.copiesSize)}. Your original files stay; those files get converted while you watch again.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
                    ],
                  ),
                );
                if (ok == true) await h.deleteAllCopies();
              },
            ),
        ]),
      ),
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
        if (h.settings != null)
          SwitchListTile(
            secondary: const Icon(Icons.bedtime_off_outlined),
            title: const Text("Don't sleep while a TV is watching"),
            subtitle: Text(KeepAwake.instance.on
                ? 'Keeping this computer awake now'
                : 'Also while converting. On handhelds / Modern Standby PCs (screen off = sleep) the screen stays on — dim it if you like.'),
            value: h.settings!.dlnaKeepAwake,
            onChanged: (v) {
              h.settings!.dlnaKeepAwake = v;
              if (!v) KeepAwake.instance.set(false);
              setState(() {});
            },
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
        ..._copySection(context),
        ..._onlineSection(context),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Text(
            'On the TV (same Wi-Fi / LAN as this PC): LG → Media Player or "Photo & Video"; Samsung → Source / Connected devices; '
            'Android TV → VLC or Kodi → UPnP. Open "${h.name}": Recently added, Movies, TV shows, Videos, Music.\n\n'
            'Files play as they are (no converting), so the TV must support the format. Subtitles next to the video (.srt) are '
            'offered to the TV too.\n\n'
            '${Platform.isWindows ? 'Windows asks once whether Delos may use the network: allow "Private networks". ' : Platform.isLinux ? 'If a firewall is on, allow UDP 1900 and TCP ${h.server?.boundPort ?? 58200}. ' : ''}'
            'The server runs while Delos is open.',
            style: muted,
          ),
        ),
      ]),
    );
  }
}
