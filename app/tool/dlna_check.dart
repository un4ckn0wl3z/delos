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
  final s = DlnaServer(
    name: 'Delos test & co',
    uuid: '4d696e69-444c-164e-9d41-b827eb000001',
    log: print,
    entries: () => [
      DlnaEntry(key: 'm1', file: movie, kind: 'movie', title: 'Pitch Black', year: 2000, poster: poster, duration: 6540, added: 3, genres: ['Sci-Fi']),
      DlnaEntry(key: 'e1', file: e1, kind: 'episode', title: 'x', show: 'The Show', season: 1, episode: 1, episodeTitle: 'Pilot <1>', added: 2),
      DlnaEntry(key: 'e2', file: e2, kind: 'episode', title: 'x', show: 'The Show', season: 1, episode: 2, added: 1),
      DlnaEntry(key: 'e3', file: e3, kind: 'episode', title: 'x', show: 'The Show', season: 2, episode: 1),
      DlnaEntry(key: 's1', file: song, kind: 'music', title: 'Song', artist: 'Band', album: 'LP', track: 1, duration: 200),
      DlnaEntry(key: 'gone', file: '${dir.path}/missing.mkv', kind: 'movie', title: 'Missing'),
    ],
  );
  await s.start();
  print('READY ${s.boundPort}');
  ProcessSignal.sigterm.watch().listen((_) async {
    await s.stop();
    exit(0);
  });
}
