import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'settings.dart';

/// CI hook for the emulator test: when the harness pushes `autotest.json` into this app's
/// external files folder (only adb or the app itself can write there), sign in to the given
/// server and start music, so the media notification / lock-screen controls can be checked.
/// The file is deleted as soon as it's read.
class AutoTest {
  static Map? config;

  static Future<void> load(Settings s) async {
    if (!Platform.isAndroid) return;
    try {
      final dir = await getExternalStorageDirectory();
      if (dir == null) return;
      final f = File('${dir.path}/autotest.json');
      if (!await f.exists()) return;
      final c = jsonDecode(await f.readAsString()) as Map;
      await f.delete();
      s.server = '${c['server']}';
      s.username = '${c['user']}';
      s.password = '${c['pass']}';
      s.token = 'autotest'; // the first request gets 401 and signs in with the password
      config = c;
      debugPrint('AUTOTEST: config loaded for ${c['server']}');
    } catch (e) {
      debugPrint('AUTOTEST: $e');
    }
  }
}
