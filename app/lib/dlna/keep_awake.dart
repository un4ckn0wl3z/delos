import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Keeps the computer from going to sleep while a TV is watching (sleep would cut the stream).
///  * Windows: SetThreadExecutionState. On Modern Standby machines (handhelds like the ROG Ally,
///    most laptops) turning the screen off is itself sleep, so the screen is kept on there too.
///  * macOS: caffeinate · Linux: systemd-inhibit
class KeepAwake {
  KeepAwake._();
  static final instance = KeepAwake._();

  bool _on = false;
  bool get on => _on;
  Process? _helper;
  bool? _modernStandby;

  /// Whether this PC sleeps when the screen goes off (Windows "S0 Low Power Idle").
  Future<bool> modernStandby() async {
    if (_modernStandby != null) return _modernStandby!;
    var v = false;
    if (Platform.isWindows) {
      try {
        final r = await Process.run('powercfg', ['/a']);
        final out = '${r.stdout}';
        // the first block lists the states available; S0 there = Modern Standby
        final avail = out.split(RegExp(r'\r?\n\r?\n')).first;
        v = avail.contains('S0');
      } catch (_) {}
    }
    return _modernStandby = v;
  }

  static int Function(int)? _setState;
  static int Function(int) get _ses => _setState ??= DynamicLibrary.open('kernel32.dll')
      .lookupFunction<Uint32 Function(Uint32), int Function(int)>('SetThreadExecutionState');

  static const _esContinuous = 0x80000000, _esSystem = 0x00000001, _esDisplay = 0x00000002;

  Future<void> set(bool on) async {
    if (on == _on || kIsWeb) return;
    _on = on;
    try {
      if (Platform.isWindows) {
        // the main isolate's thread lives as long as the app, so ES_CONTINUOUS holds until cleared
        _ses(on ? (_esContinuous | _esSystem | ((await modernStandby()) ? _esDisplay : 0)) : _esContinuous);
      } else if (Platform.isMacOS) {
        if (on) {
          _helper = await Process.start('/usr/bin/caffeinate', ['-i', '-s', '-w', '$pid']);
        } else {
          _helper?.kill();
          _helper = null;
        }
      } else if (Platform.isLinux) {
        if (on) {
          _helper = await Process.start('systemd-inhibit',
              ['--what=idle:sleep', '--who=Delos', '--why=A TV is playing from this computer', '--mode=block', 'sleep', 'infinity']);
        } else {
          _helper?.kill();
          _helper = null;
        }
      }
    } catch (e) {
      debugPrint('keep awake: $e');
    }
  }
}
