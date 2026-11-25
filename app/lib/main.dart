import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'api.dart';
import 'autotest.dart';
import 'dlna/dlna_host.dart';
import 'offline/offline_home.dart';
import 'offline/store.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'settings.dart';
import 'widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final settings = await Settings.load();
  await RawNames.init();
  await AutoTest.load(settings);
  try {
    await OfflineStore.init(settings).timeout(const Duration(seconds: 5));
  } catch (e) {
    debugPrint('offline store: $e');
  }
  // DLNA server for TVs (Windows); never hold up app start for it
  DlnaHost.instance.init(settings).catchError((Object e) => debugPrint('dlna: $e'));
  runApp(StreamMkvApp(settings: settings));
}

class StreamMkvApp extends StatelessWidget {
  const StreamMkvApp({super.key, required this.settings});
  final Settings settings;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF4A9EFF), brightness: Brightness.dark);
    return MaterialApp(
      title: 'Delos',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0D0F13),
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF11141A)),
      ),
      home: settings.loggedIn
          ? HomeScreen(api: Api(settings))
          : settings.offlineMode
              ? OfflineHome(settings: settings)
              : LoginScreen(settings: settings),
    );
  }
}
