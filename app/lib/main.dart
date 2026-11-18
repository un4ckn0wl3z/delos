import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'api.dart';
import 'screens/files_screen.dart';
import 'screens/login_screen.dart';
import 'settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final settings = await Settings.load();
  runApp(StreamMkvApp(settings: settings));
}

class StreamMkvApp extends StatelessWidget {
  const StreamMkvApp({super.key, required this.settings});
  final Settings settings;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF4A9EFF), brightness: Brightness.dark);
    return MaterialApp(
      title: 'StreamMKV',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0D0F13),
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF11141A)),
      ),
      home: settings.loggedIn ? FilesScreen(api: Api(settings)) : LoginScreen(settings: settings),
    );
  }
}
