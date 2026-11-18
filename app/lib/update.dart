import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'settings.dart';

/// Set by CI: flutter build apk --dart-define=APP_VERSION=1.2.0
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');
const _repo = 'un4ckn0wl3z/streammkv';

class AppRelease {
  AppRelease(this.version, this.notes, this.pageUrl, this.apkUrl);
  final String version, notes, pageUrl;
  final String? apkUrl;
}

bool newerThan(String a, String b) {
  List<int> parts(String v) => v
      .replaceFirst(RegExp('^v'), '')
      .split('.')
      .map((p) => int.tryParse(p.split('-').first) ?? 0)
      .toList();
  final x = parts(a), y = parts(b);
  for (var i = 0; i < 3; i++) {
    final p = i < x.length ? x[i] : 0, q = i < y.length ? y[i] : 0;
    if (p != q) return p > q;
  }
  return false;
}

/// APK name for this device's CPU (Dart's Platform.version ends with `on "android_arm64"`).
String _apkName() {
  final v = Platform.version;
  final abi = v.contains('android_arm64')
      ? 'arm64-v8a'
      : v.contains('android_x64')
          ? 'x86_64'
          : v.contains('android_arm')
              ? 'armeabi-v7a'
              : 'arm64-v8a';
  return 'streammkv-android-$abi.apk';
}

Future<AppRelease?> fetchLatestRelease() async {
  try {
    final r = await http.get(Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
        headers: {'Accept': 'application/vnd.github+json'}).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) return null;
    final j = jsonDecode(r.body) as Map;
    final name = _apkName();
    String? apk;
    for (final a in (j['assets'] as List? ?? const [])) {
      if ((a as Map)['name'] == name) apk = a['browser_download_url'] as String?;
    }
    return AppRelease(
      (j['tag_name'] as String? ?? '').replaceFirst(RegExp('^v'), ''),
      j['body'] as String? ?? '',
      j['html_url'] as String? ?? 'https://github.com/$_repo/releases/latest',
      apk,
    );
  } catch (_) {
    return null;
  }
}

/// Shows an update dialog if a newer release exists. [manual] also reports "up to date".
Future<void> checkForUpdate(BuildContext context, Settings settings, {bool manual = false}) async {
  final rel = await fetchLatestRelease();
  if (!context.mounted) return;
  if (rel == null) {
    if (manual) _snack(context, 'Could not reach GitHub');
    return;
  }
  final available = appVersion != 'dev' && newerThan(rel.version, appVersion);
  if (!available) {
    if (manual) _snack(context, appVersion == 'dev' ? 'Development build' : 'You have the latest version ($appVersion)');
    return;
  }
  if (!manual && settings.skipVersion == rel.version) return;
  final notes = rel.notes.length > 600 ? '${rel.notes.substring(0, 600)}…' : rel.notes;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('StreamMKV ${rel.version}'),
      content: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('You have $appVersion.'),
          if (notes.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(notes, style: const TextStyle(fontSize: 13, color: Color(0xFF9AA3B2))),
          ],
          const SizedBox(height: 12),
          const Text('The APK downloads in your browser — open it to install the update.',
              style: TextStyle(fontSize: 12, color: Color(0xFF7D8696))),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () {
            settings.skipVersion = rel.version;
            Navigator.pop(ctx);
          },
          child: const Text('Skip'),
        ),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Later')),
        FilledButton(
          onPressed: () {
            Navigator.pop(ctx);
            launchUrl(Uri.parse(rel.apkUrl ?? rel.pageUrl), mode: LaunchMode.externalApplication);
          },
          child: const Text('Download'),
        ),
      ],
    ),
  );
}

void _snack(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
