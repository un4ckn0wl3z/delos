double _d(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
int _i(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
String _s(dynamic v) => v == null ? '' : '$v';

class MediaFile {
  MediaFile({
    required this.path,
    required this.name,
    required this.dir,
    required this.size,
    required this.pos,
    required this.duration,
  });
  final String path, name, dir;
  final int size;
  double pos, duration;

  factory MediaFile.fromJson(Map j) => MediaFile(
        path: _s(j['path']),
        name: _s(j['name']),
        dir: _s(j['dir']),
        size: _i(j['size']),
        pos: _d(j['pos']),
        duration: _d(j['duration']),
      );

  double get progress => duration > 0 ? (pos / duration).clamp(0.0, 1.0).toDouble() : 0.0;
}

class AudioInfo {
  AudioInfo(this.index, this.codec, this.channels, this.layout, this.language, this.title, this.isDefault);
  final int index, channels;
  final String codec, layout, language, title;
  final bool isDefault;
  factory AudioInfo.fromJson(Map j) => AudioInfo(_i(j['index']), _s(j['codec']), _i(j['channels']),
      _s(j['layout']), _s(j['language']), _s(j['title']), j['default'] == true);

  String get label {
    final p = <String>[(language.isEmpty ? 'und' : language).toUpperCase()];
    if (title.isNotEmpty) p.add(title);
    return p.join(' · ');
  }

  String get detail => [codec.toUpperCase(), layout.isNotEmpty ? layout : (channels > 0 ? '${channels}ch' : '')]
      .where((e) => e.isNotEmpty)
      .join(' ');
}

class SubInfo {
  SubInfo(this.index, this.codec, this.language, this.title, this.isDefault, this.forced, this.text);
  final int index;
  final String codec, language, title;
  final bool isDefault, forced, text;
  factory SubInfo.fromJson(Map j) => SubInfo(_i(j['index']), _s(j['codec']), _s(j['language']), _s(j['title']),
      j['default'] == true, j['forced'] == true, j['text'] == true);

  String get label {
    final p = <String>[(language.isEmpty ? 'und' : language).toUpperCase()];
    if (title.isNotEmpty) p.add(title);
    return p.join(' · ');
  }

  String get detail => [codec, if (forced) 'forced', if (!text) 'image'].join(' · ');
}

class VideoInfo {
  VideoInfo(this.codec, this.width, this.height, this.pixFmt);
  final String codec, pixFmt;
  final int width, height;
  factory VideoInfo.fromJson(Map j) => VideoInfo(_s(j['codec']), _i(j['width']), _i(j['height']), _s(j['pixFmt']));
}

class ProbeInfo {
  ProbeInfo(this.duration, this.video, this.audio, this.subs);
  final double duration;
  final VideoInfo? video;
  final List<AudioInfo> audio;
  final List<SubInfo> subs;

  factory ProbeInfo.fromJson(Map j) => ProbeInfo(
        _d(j['duration']),
        j['video'] is Map ? VideoInfo.fromJson(j['video'] as Map) : null,
        ((j['audio'] as List?) ?? const []).map((e) => AudioInfo.fromJson(e as Map)).toList(),
        ((j['subs'] as List?) ?? const []).map((e) => SubInfo.fromJson(e as Map)).toList(),
      );
}
