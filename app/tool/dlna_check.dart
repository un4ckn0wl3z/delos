// CI check for lib/dlna/dlna_server.dart (copied next to this file by the workflow;
// plain `dart run`, no Flutter). Serves a few fake files until killed.
import 'dart:io';
import 'dlna_server.dart';

Future<void> main(List<String> args) async {
  final dir = await Directory.systemTemp.createTemp('dlna');
  Future<String> mk(String name, int size) async {
    final f = File('${dir.path}/$name');
    await f.create(recursive: true);
    await f.writeAsBytes(List.generate(size, (i) => i % 251));
    return f.path;
  }

  final movie = await mk('Pitch Black (2000).mkv', 300000);
  await File('${dir.path}/Pitch Black (2000).srt').writeAsString('1\n00:00:01,000 --> 00:00:02,000\nHello\n');
  final poster = await mk('posters/pb.jpg', 2000);
  final e1 = await mk('Show/S01E01.mkv', 1000), e2 = await mk('Show/S01E02.mkv', 1000), e3 = await mk('Show/S02E01.mkv', 1000);
  final song = await mk('Music/01 Song.mp3', 5000);
  // a real clip with DTS audio + a subtitle track, to check converting (needs FFMPEG)
  final ff = Platform.environment['FFMPEG'] ?? '';
  var dts = '';
  if (ff.isNotEmpty) {
    dts = '${dir.path}/DTS Movie.mkv';
    final srt = '${dir.path}/sub.srt';
    await File(srt).writeAsString('1\n00:00:01,000 --> 00:00:05,000\nHi\n');
    final r = await Process.run(ff, [
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=25', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
      '-i', srt, '-t', '20', '-map', '0:v', '-map', '1:a', '-map', '2:s',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '25', '-c:a', 'dca', '-strict', '-2', '-ac', '2', '-c:s', 'srt', dts,
    ]);
    if (r.exitCode != 0) {
      print('making the DTS clip failed: ${r.stderr}');
      dts = '';
    }
  }
  final s = DlnaServer(
    name: 'Delos test & co',
    uuid: '4d696e69-444c-164e-9d41-b827eb000001',
    log: print,
    ffmpeg: () => ff.isEmpty ? null : ff,
    entries: () => [
      DlnaEntry(key: 'm1', file: movie, kind: 'movie', title: 'Pitch Black', year: 2000, poster: poster, duration: 6540, added: 3, genres: ['Sci-Fi']),
      DlnaEntry(key: 'e1', file: e1, kind: 'episode', title: 'x', show: 'The Show', season: 1, episode: 1, episodeTitle: 'Pilot <1>', added: 2),
      DlnaEntry(key: 'e2', file: e2, kind: 'episode', title: 'x', show: 'The Show', season: 1, episode: 2, added: 1),
      DlnaEntry(key: 'e3', file: e3, kind: 'episode', title: 'x', show: 'The Show', season: 2, episode: 1),
      DlnaEntry(key: 's1', file: song, kind: 'music', title: 'Song', artist: 'Band', album: 'LP', track: 1, duration: 200),
      DlnaEntry(key: 'gone', file: '${dir.path}/missing.mkv', kind: 'movie', title: 'Missing'),
      if (dts.isNotEmpty) DlnaEntry(key: 'dts', file: dts, kind: 'movie', title: 'DTS Movie', duration: 20, convert: true, audioChannels: 2),
      // "online": this server's own /m/ URL stands in for the Delos server
      DlnaEntry(
          key: 'on1', file: '', url: 'http://127.0.0.1:58200/m/${DlnaServer.idOf('m1')}.mkv', kind: 'movie', title: 'Pitch Black online',
          size: 300000, section: 'Films', headers: {'X-Test': '1'}),
    ],
  );
  await s.start();
  // a TV copy, made the way the app makes one: through the loopback route, with the shared args
  if (dts.isNotEmpty) {
    final e = s.entries().firstWhere((x) => x.key == 'dts');
    final out = '${dir.path}/copy.mkv';
    final r = await Process.run(ff, [
      '-hide_banner', '-loglevel', 'error', '-nostdin', '-y', '-reconnect', '1', '-reconnect_on_network_error', '1',
      '-i', s.inputOf(e), ...DlnaServer.convertArgs(e, subs: DlnaServer.isMkv(e)), '-progress', 'pipe:1', '-nostats', '-f', 'matroska', out,
    ]);
    final pr = await Process.run(ff.replaceAll(RegExp(r'ffmpeg(\.exe)?$'), Platform.isWindows ? 'ffprobe.exe' : 'ffprobe'),
        ['-v', 'error', '-show_entries', 'stream=codec_name', '-of', 'csv=p=0', out]);
    final codecs = '${pr.stdout}'.split(RegExp(r'\s+')).where((x) => x.isNotEmpty).join(',');
    print(r.exitCode == 0 && '${r.stdout}'.contains('progress=end') && codecs == 'h264,ac3,subrip' ? 'COPY OK $codecs' : 'COPY FAIL ${r.stderr} $codecs');
  }
  print('READY ${s.boundPort}');
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) async {
      await s.stop();
      exit(0);
    });
  }
}
