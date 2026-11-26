import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../dlna/dlna_host.dart';
import '../dlna/dlna_screen.dart';
import '../settings.dart';
import '../social.dart';
import '../update.dart';

/// Pops `true` when the user chose to sign out.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.api, this.social});
  final Api api;
  final Social? social;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Settings get s => widget.api.settings;
  late final _audio = TextEditingController(text: s.audioLang);
  late final _sub = TextEditingController(text: s.subLang);
  String _server = '…';
  int _avatar = 0;
  bool _avBusy = false;

  @override
  void initState() {
    super.initState();
    widget.api.me().then((m) {
      if (mounted) {
        setState(() {
          _server = '${m['version'] ?? 'older than 1.2'}${m['admin'] == true ? ' · you are admin' : ''}';
          _avatar = (m['avatar'] as num? ?? 0).toInt();
        });
      }
    }).catchError((_) {
      if (mounted) setState(() => _server = 'unreachable');
    });
  }

  @override
  void dispose() {
    s.audioLang = _audio.text.trim();
    s.subLang = _sub.text.trim();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final messenger = ScaffoldMessenger.of(context);
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png', 'gif'], withData: true);
    final f = r?.files.firstOrNull;
    if (f == null || f.bytes == null) return;
    if (f.size > 10 * 1024 * 1024) {
      messenger.showSnackBar(const SnackBar(content: Text('Pictures can be up to 10 MB')));
      return;
    }
    setState(() => _avBusy = true);
    try {
      final v = await widget.api.uploadAvatar(f.bytes!, f.name);
      _avatar = v;
      widget.social?.setMyAvatar(v);
      messenger.showSnackBar(const SnackBar(content: Text('Profile picture updated')));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _avBusy = false);
    }
  }

  Future<void> _removeAvatar() async {
    setState(() => _avBusy = true);
    try {
      await widget.api.deleteAvatar();
      _avatar = 0;
      widget.social?.setMyAvatar(0);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _avBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const _Section('Playback'),
          ListTile(
            title: const Text('Default quality'),
            subtitle: Text(s.quality == 'direct'
                ? 'Direct — original file, all audio/subtitle formats, needs fast connection'
                : 'Transcode — server converts to H.264 ≤ ${s.maxh}p, saves data'),
            trailing: DropdownButton<String>(
              value: s.quality,
              onChanged: (v) => setState(() => s.quality = v!),
              items: const [
                DropdownMenuItem(value: 'direct', child: Text('Direct')),
                DropdownMenuItem(value: 'transcode', child: Text('Transcode')),
              ],
            ),
          ),
          ListTile(
            title: const Text('Transcode max height'),
            trailing: DropdownButton<int>(
              value: s.maxh,
              onChanged: (v) => setState(() => s.maxh = v!),
              items: const [1080, 720, 480, 360]
                  .map((h) => DropdownMenuItem(value: h, child: Text('${h}p')))
                  .toList(),
            ),
          ),
          SwitchListTile(
            title: const Text('Stereo audio (downmix 5.1 / 7.1)'),
            subtitle: const Text('Fixes stuttering surround tracks on many phones and tablets. Turn off for an AV receiver.'),
            value: s.stereoDownmix,
            onChanged: (v) => setState(() => s.stereoDownmix = v),
          ),
          ListTile(
            title: const Text('Streaming buffer'),
            subtitle: Text(s.bufferMode == 'auto'
                ? 'Auto — about 2 minutes of the file, kept in memory (more for 4K, less for small files)'
                : '${s.bufferMode} MB read ahead, kept in memory. Bigger rides out a slow connection; uses more RAM.'),
            trailing: DropdownButton<String>(
              value: s.bufferMode,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: 'auto', child: Text('Auto')),
                DropdownMenuItem(value: '64', child: Text('64 MB')),
                DropdownMenuItem(value: '256', child: Text('256 MB')),
                DropdownMenuItem(value: '512', child: Text('512 MB')),
                DropdownMenuItem(value: '1024', child: Text('1 GB')),
              ],
              onChanged: (v) => setState(() => s.bufferMode = v ?? 'auto'),
            ),
          ),
          ListTile(
            title: const Text('Subtitle size'),
            subtitle: Slider(
              value: s.subScale,
              min: 0.6,
              max: 2.0,
              divisions: 14,
              label: '${(s.subScale * 100).round()}%',
              onChanged: (v) => setState(() => s.subScale = v),
            ),
          ),
          const _Section('Preferred languages'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _audio,
              decoration: const InputDecoration(
                  labelText: 'Audio', hintText: 'jpn,eng', border: OutlineInputBorder()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _sub,
              decoration: const InputDecoration(
                  labelText: 'Subtitles', hintText: 'tha,eng', border: OutlineInputBorder()),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text('Comma-separated ISO codes, first match wins. Your choice per movie is remembered '
                'and synced with the browser.', style: TextStyle(fontSize: 12, color: Color(0xFF7D8696))),
          ),
          if (DlnaHost.supported) ...[
            const _Section('TV'),
            ListTile(
              leading: const Icon(Icons.connected_tv),
              title: const Text('Share to TV (DLNA)'),
              subtitle: Text(DlnaHost.instance.running ? 'On — "${DlnaHost.instance.name}"' : 'Off — let a TV play your offline files'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DlnaScreen())).then((_) => setState(() {})),
            ),
          ],
          const _Section('About'),
          ListTile(title: const Text('App version'), subtitle: Text(appVersion)),
          ListTile(title: const Text('Server version'), subtitle: Text(_server)),
          ListTile(
            leading: const Icon(Icons.system_update),
            title: const Text('Check for app updates'),
            onTap: () => checkForUpdate(context, s, manual: true),
          ),
          const _Section('Account'),
          ListTile(
            leading: CircleAvatar(
              radius: 24,
              backgroundColor: const Color(0xFF253043),
              foregroundImage: _avatar > 0 ? NetworkImage(widget.api.avatarUrl(s.username, _avatar), headers: widget.api.authHeaders) : null,
              child: _avBusy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(s.username.isNotEmpty ? s.username[0].toUpperCase() : '?', style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            title: Text(s.username),
            subtitle: const Text('Profile picture — shown in People and Chat'),
            trailing: Wrap(spacing: 4, children: [
              TextButton(onPressed: _avBusy ? null : _pickAvatar, child: const Text('Change')),
              if (_avatar > 0) TextButton(onPressed: _avBusy ? null : _removeAvatar, child: const Text('Remove')),
            ]),
          ),
          ListTile(title: const Text('Server'), subtitle: Text(s.server)),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign out'),
            onTap: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600)),
      );
}
