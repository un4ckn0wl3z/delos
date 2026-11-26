import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Full screen for the whole desktop app (F11 / the button in the top bar), shared with the players:
/// a player only leaves full screen on close if it was the one that entered it.
class AppFullscreen extends ValueNotifier<bool> {
  AppFullscreen._() : super(false);
  static final instance = AppFullscreen._();

  static bool get supported => !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  Future<void> set(bool on, {bool remember = true}) async {
    if (!supported || on == value) return;
    value = on;
    await (on ? defaultEnterNativeFullscreen() : defaultExitNativeFullscreen());
    if (remember) (await SharedPreferences.getInstance()).setBool('appFullscreen', on);
  }

  Future<void> toggle() => set(!value);

  /// Opens in full screen if the app was closed in full screen.
  Future<void> restore() async {
    if (!supported) return;
    if ((await SharedPreferences.getInstance()).getBool('appFullscreen') ?? false) await set(true, remember: false);
  }
}

/// Top-bar button: ⛶ full screen / exit full screen (desktop only).
class FullscreenButton extends StatelessWidget {
  const FullscreenButton({super.key});
  @override
  Widget build(BuildContext context) {
    if (!AppFullscreen.supported) return const SizedBox.shrink();
    return ValueListenableBuilder<bool>(
      valueListenable: AppFullscreen.instance,
      builder: (_, on, __) => IconButton(
        tooltip: on ? 'Exit full screen (F11)' : 'Full screen (F11)',
        icon: Icon(on ? Icons.fullscreen_exit : Icons.fullscreen),
        onPressed: AppFullscreen.instance.toggle,
      ),
    );
  }
}
