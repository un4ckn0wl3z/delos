import 'package:flutter/material.dart';

import '../api.dart';
import '../audio.dart';
import '../dlna/dlna_host.dart';
import '../dlna/dlna_screen.dart';
import '../fullscreen.dart';
import '../media_session.dart';
import '../screens/login_screen.dart';
import '../settings.dart';
import 'offline_view.dart';

/// The app without a server: only what's on this device (downloaded files and
/// the user's own folders). No sign-in needed.
class OfflineHome extends StatefulWidget {
  const OfflineHome({super.key, required this.settings});
  final Settings settings;
  @override
  State<OfflineHome> createState() => _OfflineHomeState();
}

class _OfflineHomeState extends State<OfflineHome> {
  // saved songs play from their files; the Api is only there for the player's helpers
  late final audio = AudioController(Api(widget.settings));

  @override
  void initState() {
    super.initState();
    MusicSession.attach(audio); // background playback + lock-screen controls
  }

  @override
  void dispose() {
    audio.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Row(children: [
            Icon(Icons.offline_pin, color: Color(0xFF1F9D63)),
            SizedBox(width: 10),
            Text('Offline'),
          ]),
          actions: [
            const FullscreenButton(),
            if (DlnaHost.supported)
              IconButton(
                  tooltip: 'Share to TV (DLNA)',
                  icon: const Icon(Icons.connected_tv),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DlnaScreen()))),
            IconButton(tooltip: 'Offline settings', icon: const Icon(Icons.tune), onPressed: () => offlineSettings(context, widget.settings)),
            TextButton.icon(
              icon: const Icon(Icons.login),
              label: const Text('Sign in'),
              onPressed: () {
                widget.settings.offlineMode = false;
                Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => LoginScreen(settings: widget.settings)));
              },
            ),
          ],
        ),
        body: Column(children: [
          Expanded(child: OfflineView(settings: widget.settings, audio: audio)),
          MiniPlayer(audio: audio),
        ]),
      );
}
