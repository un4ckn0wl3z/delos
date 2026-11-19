import 'package:flutter/material.dart';

import '../screens/login_screen.dart';
import '../settings.dart';
import 'offline_view.dart';

/// The app without a server: only what's on this device (downloaded files and
/// the user's own folders). No sign-in needed.
class OfflineHome extends StatelessWidget {
  const OfflineHome({super.key, required this.settings});
  final Settings settings;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Row(children: [
            Icon(Icons.offline_pin, color: Color(0xFF1F9D63)),
            SizedBox(width: 10),
            Text('Offline'),
          ]),
          actions: [
            IconButton(tooltip: 'Offline settings', icon: const Icon(Icons.tune), onPressed: () => offlineSettings(context, settings)),
            TextButton.icon(
              icon: const Icon(Icons.login),
              label: const Text('Sign in'),
              onPressed: () {
                settings.offlineMode = false;
                Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => LoginScreen(settings: settings)));
              },
            ),
          ],
        ),
        body: OfflineView(settings: settings),
      );
}
