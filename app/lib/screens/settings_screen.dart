import 'package:flutter/material.dart';

import '../api.dart';
import '../settings.dart';
import '../update.dart';

/// Pops `true` when the user chose to sign out.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.api});
  final Api api;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Settings get s => widget.api.settings;
  late final _audio = TextEditingController(text: s.audioLang);
  late final _sub = TextEditingController(text: s.subLang);
  String _server = '…';

  @override
  void initState() {
    super.initState();
    widget.api.me().then((m) {
      if (mounted) setState(() => _server = '${m['version'] ?? 'older than 1.2'}${m['admin'] == true ? ' · you are admin' : ''}');
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
          const _Section('About'),
          ListTile(title: const Text('App version'), subtitle: Text(appVersion)),
          ListTile(title: const Text('Server version'), subtitle: Text(_server)),
          ListTile(
            leading: const Icon(Icons.system_update),
            title: const Text('Check for app updates'),
            onTap: () => checkForUpdate(context, s, manual: true),
          ),
          const _Section('Account'),
          ListTile(title: const Text('Server'), subtitle: Text(s.server)),
          ListTile(title: const Text('User'), subtitle: Text(s.username)),
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
