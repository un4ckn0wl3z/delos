// A small DLNA / UPnP media server (pure dart:io, no Flutter) so a TV on the same
// network can browse and play the files saved on this computer.
//
//  * SSDP on 239.255.255.250:1900 — answers M-SEARCH, announces itself (NOTIFY alive / byebye)
//  * HTTP — device + service descriptions, ContentDirectory (Browse) and ConnectionManager
//    SOAP actions, the media files with byte ranges, posters and .srt subtitles
//
// The library comes from [DlnaServer.entries], read fresh on every Browse.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// One playable file.
class DlnaEntry {
  DlnaEntry({
    required this.key,
    required this.file,
    required this.kind,
    required this.title,
    this.poster = '',
    this.show = '',
    this.season = 0,
    this.episode = 0,
    this.episodeTitle = '',
    this.artist = '',
    this.album = '',
    this.track = 0,
    this.year = 0,
    this.duration = 0,
    this.size = 0,
    this.genres = const [],
    this.overview = '',
    this.added = 0,
  });

  /// Stable unique key (e.g. the offline store id).
  final String key;
  final String file; // absolute path
  final String kind; // movie | episode | video | music
  final String title, poster, show, episodeTitle, artist, album, overview;
  final int season, episode, track, year, size, added;
  final double duration; // seconds, 0 = unknown
  final List<String> genres;
}

String _fnv(String s) {
  var h = 0xcbf29ce484222325;
  for (final c in utf8.encode(s)) {
    h ^= c;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return (h & 0x7FFFFFFFFFFFFFFF).toRadixString(36);
}

String _x(Object? s) => const HtmlEscape(HtmlEscapeMode.element).convert('${s ?? ''}').replaceAll('"', '&quot;');

String _dur(double secs) {
  final t = secs.round();
  return '${t ~/ 3600}:${(t ~/ 60 % 60).toString().padLeft(2, '0')}:${(t % 60).toString().padLeft(2, '0')}.000';
}

const _mimes = {
  'mkv': 'video/x-matroska', 'mp4': 'video/mp4', 'm4v': 'video/mp4', 'mov': 'video/quicktime', 'avi': 'video/x-msvideo',
  'webm': 'video/webm', 'ts': 'video/mp2t', 'm2ts': 'video/mp2t', 'mts': 'video/mp2t', 'mpg': 'video/mpeg', 'mpeg': 'video/mpeg',
  'wmv': 'video/x-ms-wmv', 'flv': 'video/x-flv', '3gp': 'video/3gpp',
  'mp3': 'audio/mpeg', 'flac': 'audio/flac', 'm4a': 'audio/mp4', 'aac': 'audio/aac', 'ogg': 'audio/ogg', 'opus': 'audio/ogg',
  'wav': 'audio/wav', 'wma': 'audio/x-ms-wma', 'alac': 'audio/mp4',
  'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'webp': 'image/webp', 'srt': 'text/srt',
};

String _ext(String p) {
  final i = p.lastIndexOf('.');
  return i < 0 ? '' : p.substring(i + 1).toLowerCase();
}

String mimeOf(String path) => _mimes[_ext(path)] ?? 'application/octet-stream';

String _dlnaFeatures(String mime) {
  var pn = '';
  if (mime == 'audio/mpeg') pn = 'DLNA.ORG_PN=MP3;';
  if (mime == 'image/jpeg') pn = 'DLNA.ORG_PN=JPEG_TN;';
  final flags = mime.startsWith('image/') ? '00f00000000000000000000000000000' : '01700000000000000000000000000000';
  return '${pn}DLNA.ORG_OP=${mime.startsWith('image/') ? '00' : '01'};DLNA.ORG_CI=0;DLNA.ORG_FLAGS=$flags';
}

/// A folder or a file in the tree the TV browses.
class _Node {
  _Node(this.id, this.parent, this.title, {this.entry, this.cls = 'object.container.storageFolder', this.art = ''});
  final String id, parent, title, cls, art;
  final DlnaEntry? entry;
  final children = <_Node>[];
  bool get isItem => entry != null;
}

class DlnaServer {
  DlnaServer({required this.name, required this.uuid, required this.entries, this.port = 58200, this.log});

  String name;
  final String uuid; // without "uuid:"
  final List<DlnaEntry> Function() entries;
  final int port;
  final void Function(String)? log;

  HttpServer? _http;
  RawDatagramSocket? _ssdp;
  final _senders = <RawDatagramSocket>[];
  Timer? _notify;
  int boundPort = 0;
  List<InternetAddress> addresses = [];
  int updateId = 1;
  bool get running => _http != null;

  /// Who browsed or played lately (for the settings page): address → time.
  final clients = <String, DateTime>{};
  final _rnd = math.Random();

  static final _mcast = InternetAddress('239.255.255.250');

  void _log(String s) => log?.call(s);

  /// Call when the library changed so TVs re-read folders.
  void touch() => updateId++;

  Future<void> start() async {
    if (running) return;
    // fixed port first so the TV's cached address stays valid; any free port as a fallback
    HttpServer? h;
    for (final p in [port, port + 1, port + 2, 0]) {
      try {
        h = await HttpServer.bind(InternetAddress.anyIPv4, p, shared: false);
        break;
      } catch (_) {}
    }
    if (h == null) throw 'no free port for the DLNA server';
    _http = h;
    boundPort = h.port;
    h.autoCompress = false;
    h.listen((r) => _handle(r).catchError((Object e) {
          _log('http: $e');
          try {
            r.response.statusCode = 500;
            r.response.close();
          } catch (_) {}
        }));
    addresses = await _lanAddresses();
    await _startSsdp();
    _log('DLNA: http on $boundPort, ${addresses.map((a) => a.address).join(', ')}');
  }

  Future<void> stop() async {
    _notify?.cancel();
    _notify = null;
    try {
      _announce('ssdp:byebye');
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 150));
    for (final s in _senders) {
      s.close();
    }
    _senders.clear();
    _ssdp?.close();
    _ssdp = null;
    await _http?.close(force: true);
    _http = null;
  }

  // ------------------------------------------------------------------ network

  static Future<List<InternetAddress>> _lanAddresses() async {
    final out = <InternetAddress>[];
    try {
      for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false)) {
        final n = ni.name.toLowerCase();
        if (n.contains('vethernet') || n.contains('virtualbox') || n.contains('vmware') || n.startsWith('docker') || n.startsWith('br-')) continue;
        for (final a in ni.addresses) {
          if (a.isLinkLocal) continue;
          out.add(a);
        }
      }
    } catch (_) {}
    // real LANs first (192.168 / 10 / 172.16-31), then whatever is left
    int rank(InternetAddress a) {
      final b = a.rawAddress;
      if (b[0] == 192 && b[1] == 168) return 0;
      if (b[0] == 10) return 1;
      if (b[0] == 172 && b[1] >= 16 && b[1] < 32) return 2;
      return 3;
    }

    out.sort((a, b) => rank(a).compareTo(rank(b)));
    return out;
  }

  /// The address of ours the [peer] can reach (same /24, then same /16, then the first).
  InternetAddress? _addrFor(InternetAddress peer) {
    if (addresses.isEmpty) return null;
    final p = peer.rawAddress;
    for (final n in [3, 2]) {
      for (final a in addresses) {
        final b = a.rawAddress;
        var same = true;
        for (var i = 0; i < n; i++) {
          if (b[i] != p[i]) same = false;
        }
        if (same) return a;
      }
    }
    if (peer.isLoopback) return InternetAddress.loopbackIPv4;
    return addresses.first;
  }

  String _location(InternetAddress a) => 'http://${a.address}:$boundPort/desc.xml';

  String get _server => '${Platform.operatingSystem}/${Platform.operatingSystemVersion.split(' ').first} UPnP/1.0 Delos/1.0';

  static const _types = [
    'upnp:rootdevice',
    'urn:schemas-upnp-org:device:MediaServer:1',
    'urn:schemas-upnp-org:service:ContentDirectory:1',
    'urn:schemas-upnp-org:service:ConnectionManager:1',
  ];

  Future<void> _startSsdp() async {
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 1900, reuseAddress: true);
      s.multicastLoopback = true;
      var joined = false;
      try {
        for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
          try {
            s.joinMulticast(_mcast, ni);
            joined = true;
          } catch (_) {}
        }
      } catch (_) {}
      if (!joined) {
        try {
          s.joinMulticast(_mcast);
        } catch (e) {
          _log('ssdp join: $e');
        }
      }
      s.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final d = s.receive();
        if (d != null) _onSsdp(s, d);
      });
      _ssdp = s;
    } catch (e) {
      _log('ssdp bind 1900: $e');
    }
    // one sender per LAN address so NOTIFY goes out of every network card
    for (final a in addresses) {
      try {
        final s = await RawDatagramSocket.bind(a, 0);
        s.multicastHops = 4;
        s.listen((ev) {
          if (ev != RawSocketEvent.read) return;
          final d = s.receive();
          if (d != null) _onSsdp(s, d);
        });
        _senders.add(s);
      } catch (e) {
        _log('ssdp sender ${a.address}: $e');
      }
    }
    _announce('ssdp:alive');
    // repeat a few times at start (UDP gets lost), then every 30 s
    var n = 0;
    _notify = Timer.periodic(const Duration(seconds: 3), (t) {
      n++;
      if (n <= 3 || n % 10 == 0) _announce('ssdp:alive');
    });
  }

  void _announce(String nts) {
    for (var i = 0; i < _senders.length && i < addresses.length; i++) {
      final s = _senders[i], a = addresses[i];
      final all = ['uuid:$uuid', ..._types];
      for (final nt in all) {
        final usn = nt.startsWith('uuid:') ? nt : 'uuid:$uuid::$nt';
        final msg = StringBuffer('NOTIFY * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n');
        if (nts == 'ssdp:alive') {
          msg.write('CACHE-CONTROL: max-age=1800\r\nLOCATION: ${_location(a)}\r\nSERVER: $_server\r\n');
        }
        msg.write('NT: $nt\r\nNTS: $nts\r\nUSN: $usn\r\n\r\n');
        try {
          s.send(utf8.encode(msg.toString()), _mcast, 1900);
        } catch (_) {}
      }
    }
  }

  void _onSsdp(RawDatagramSocket s, Datagram d) {
    final text = latin1.decode(d.data, allowInvalid: true);
    if (!text.startsWith('M-SEARCH')) return;
    final headers = <String, String>{};
    for (final l in text.split('\r\n').skip(1)) {
      final i = l.indexOf(':');
      if (i > 0) headers[l.substring(0, i).trim().toUpperCase()] = l.substring(i + 1).trim();
    }
    final st = headers['ST'] ?? '';
    final List<String> answer;
    if (st == 'ssdp:all') {
      answer = ['uuid:$uuid', ..._types];
    } else if (st == 'uuid:$uuid' || _types.contains(st)) {
      answer = [st];
    } else {
      return;
    }
    final me = _addrFor(d.address);
    if (me == null) return;
    final mx = int.tryParse(headers['MX'] ?? '') ?? 1;
    // reply after a random 0..MX (capped) delay, as the spec asks
    Timer(Duration(milliseconds: _rnd.nextInt(math.max(1, math.min(mx, 3)) * 300 + 1)), () {
      for (final t in answer) {
        final usn = t.startsWith('uuid:') ? t : 'uuid:$uuid::$t';
        final msg = 'HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nDATE: ${HttpDate.format(DateTime.now())}\r\nEXT:\r\n'
            'LOCATION: ${_location(me)}\r\nSERVER: $_server\r\nST: $t\r\nUSN: $usn\r\nContent-Length: 0\r\n\r\n';
        try {
          s.send(utf8.encode(msg), d.address, d.port);
        } catch (_) {}
      }
    });
  }

  // ------------------------------------------------------------------ the tree

  Map<String, _Node> _tree() {
    final all = <String, _Node>{};
    _Node add(_Node n) {
      all[n.id] = n;
      all[n.parent]?.children.add(n);
      return n;
    }

    add(_Node('0', '-1', name));
    final list = [for (final e in entries()) if (e.file.isNotEmpty && File(e.file).existsSync()) e];
    String art(DlnaEntry e) => e.poster.isNotEmpty && File(e.poster).existsSync() ? 'a/${_fnv(e.key)}' : '';
    _Node item(String parent, DlnaEntry e, String title) {
      final cls = e.kind == 'music'
          ? 'object.item.audioItem.musicTrack'
          : e.kind == 'movie'
              ? 'object.item.videoItem.movie'
              : 'object.item.videoItem';
      return add(_Node('$parent/i${_fnv(e.key)}', parent, title, entry: e, cls: cls, art: art(e)));
    }

    final movies = list.where((e) => e.kind == 'movie').toList()..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    final eps = list.where((e) => e.kind == 'episode').toList();
    final vids = list.where((e) => e.kind == 'video').toList()..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    final songs = list.where((e) => e.kind == 'music').toList();
    final recent = [...list.where((e) => e.kind != 'music')]..sort((a, b) => b.added.compareTo(a.added));

    if (recent.isNotEmpty) {
      add(_Node('r', '0', 'Recently added'));
      for (final e in recent.take(40)) {
        item('r', e, e.kind == 'episode' ? _epTitle(e, withShow: true) : _movieTitle(e));
      }
    }
    if (movies.isNotEmpty) {
      add(_Node('m', '0', 'Movies'));
      for (final e in movies) {
        item('m', e, _movieTitle(e));
      }
    }
    if (eps.isNotEmpty) {
      add(_Node('t', '0', 'TV shows'));
      final shows = <String, List<DlnaEntry>>{};
      for (final e in eps) {
        shows.putIfAbsent(e.show.isEmpty ? 'Unknown show' : e.show, () => []).add(e);
      }
      for (final sh in shows.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()))) {
        final es = shows[sh]!;
        final sid = 't/${_fnv(sh)}';
        final poster = es.firstWhere((e) => art(e).isNotEmpty, orElse: () => es.first);
        add(_Node(sid, 't', sh, cls: 'object.container.storageFolder', art: art(poster)));
        final seasons = es.map((e) => e.season).toSet().toList()..sort();
        // one season → episodes straight under the show
        final flat = seasons.length == 1;
        for (final se in seasons) {
          final pid = flat ? sid : '$sid/s$se';
          if (!flat) add(_Node(pid, sid, se == 0 ? 'Specials' : 'Season $se', art: art(poster)));
          final list = es.where((e) => e.season == se).toList()..sort((a, b) => a.episode.compareTo(b.episode));
          for (final e in list) {
            item(pid, e, _epTitle(e));
          }
        }
      }
    }
    if (vids.isNotEmpty) {
      add(_Node('v', '0', 'Videos'));
      for (final e in vids) {
        item('v', e, e.title);
      }
    }
    if (songs.isNotEmpty) {
      add(_Node('a', '0', 'Music'));
      add(_Node('a/al', 'a', 'Albums'));
      add(_Node('a/ar', 'a', 'Artists'));
      add(_Node('a/all', 'a', 'All songs'));
      final albums = <String, List<DlnaEntry>>{};
      final artists = <String, List<DlnaEntry>>{};
      for (final e in songs) {
        albums.putIfAbsent(e.album.isEmpty ? 'Unknown album' : e.album, () => []).add(e);
        artists.putIfAbsent(e.artist.isEmpty ? 'Unknown artist' : e.artist, () => []).add(e);
      }
      int byTrack(DlnaEntry a, DlnaEntry b) => a.track != b.track ? a.track.compareTo(b.track) : a.title.compareTo(b.title);
      for (final al in albums.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()))) {
        final es = albums[al]!..sort(byTrack);
        final id = 'a/al/${_fnv(al)}';
        add(_Node(id, 'a/al', al, cls: 'object.container.album.musicAlbum', art: art(es.first)));
        for (final e in es) {
          item(id, e, e.title);
        }
      }
      for (final ar in artists.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()))) {
        final es = artists[ar]!..sort((a, b) => a.album != b.album ? a.album.compareTo(b.album) : byTrack(a, b));
        final id = 'a/ar/${_fnv(ar)}';
        add(_Node(id, 'a/ar', ar, cls: 'object.container.person.musicArtist', art: art(es.first)));
        for (final e in es) {
          item(id, e, e.title);
        }
      }
      for (final e in [...songs]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()))) {
        item('a/all', e, e.title);
      }
    }
    return all;
  }

  static String _movieTitle(DlnaEntry e) => e.year > 0 && e.kind == 'movie' ? '${e.title} (${e.year})' : e.title;
  static String _epTitle(DlnaEntry e, {bool withShow = false}) {
    final code = 'S${e.season.toString().padLeft(2, '0')}E${e.episode.toString().padLeft(2, '0')}';
    final t = e.episodeTitle.isNotEmpty ? '$code · ${e.episodeTitle}' : code;
    return withShow && e.show.isNotEmpty ? '${e.show} · $t' : t;
  }

  /// Files by their short id (for /m/, /a/, /s/).
  Map<String, DlnaEntry> _byId() => {for (final e in entries()) _fnv(e.key): e};

  static String? _srtOf(String file) {
    final i = file.lastIndexOf('.');
    final base = i < 0 ? file : file.substring(0, i);
    for (final s in ['$base.srt', '$base.en.srt', '$base.th.srt', '$base.eng.srt', '$base.tha.srt']) {
      if (File(s).existsSync()) return s;
    }
    return null;
  }

  String _didl(Iterable<_Node> nodes, String base) {
    final b = StringBuffer('<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/" '
        'xmlns:sec="http://www.sec.co.kr/">');
    for (final n in nodes) {
      final artUri = n.art.isEmpty ? '' : '<upnp:albumArtURI dlna:profileID="JPEG_TN">$base/${n.art}</upnp:albumArtURI>';
      if (!n.isItem) {
        b.write('<container id="${_x(n.id)}" parentID="${_x(n.parent)}" restricted="1" searchable="0" childCount="${n.children.length}">'
            '<dc:title>${_x(n.title)}</dc:title><upnp:class>${n.cls}</upnp:class>$artUri</container>');
        continue;
      }
      final e = n.entry!;
      final id = _fnv(e.key);
      final ext = _ext(e.file);
      final mime = mimeOf(e.file);
      final size = e.size > 0 ? e.size : (File(e.file).statSync().size);
      final dur = e.duration > 0 ? ' duration="${_dur(e.duration)}"' : '';
      final srt = e.kind == 'music' ? null : _srtOf(e.file);
      b.write('<item id="${_x(n.id)}" parentID="${_x(n.parent)}" restricted="1"><dc:title>${_x(n.title)}</dc:title>'
          '<upnp:class>${n.cls}</upnp:class>');
      if (e.year > 0) b.write('<dc:date>${e.year}-01-01</dc:date>');
      if (e.overview.isNotEmpty) b.write('<dc:description>${_x(e.overview)}</dc:description>');
      for (final g in e.genres) {
        b.write('<upnp:genre>${_x(g)}</upnp:genre>');
      }
      if (e.kind == 'music') {
        if (e.artist.isNotEmpty) b.write('<upnp:artist>${_x(e.artist)}</upnp:artist><dc:creator>${_x(e.artist)}</dc:creator>');
        if (e.album.isNotEmpty) b.write('<upnp:album>${_x(e.album)}</upnp:album>');
        if (e.track > 0) b.write('<upnp:originalTrackNumber>${e.track}</upnp:originalTrackNumber>');
      }
      if (e.kind == 'episode') {
        if (e.show.isNotEmpty) b.write('<upnp:seriesTitle>${_x(e.show)}</upnp:seriesTitle>');
        b.write('<upnp:episodeSeason>${e.season}</upnp:episodeSeason><upnp:episodeNumber>${e.episode}</upnp:episodeNumber>');
      }
      b.write(artUri);
      if (srt != null) b.write('<sec:CaptionInfoEx sec:type="srt">$base/s/$id.srt</sec:CaptionInfoEx>');
      b.write('<res protocolInfo="http-get:*:$mime:${_dlnaFeatures(mime)}" size="$size"$dur>$base/m/$id.$ext</res>');
      if (srt != null) b.write('<res protocolInfo="http-get:*:text/srt:*">$base/s/$id.srt</res>');
      if (n.art.isNotEmpty) b.write('<res protocolInfo="http-get:*:image/jpeg:${_dlnaFeatures('image/jpeg')}">$base/${n.art}</res>');
      b.write('</item>');
    }
    b.write('</DIDL-Lite>');
    return b.toString();
  }

  // ------------------------------------------------------------------ HTTP

  Future<void> _handle(HttpRequest r) async {
    final res = r.response;
    res.headers.set('Server', _server);
    final path = r.uri.path;
    final peer = r.connectionInfo?.remoteAddress;
    if (peer != null) clients[peer.address] = DateTime.now();
    final host = r.headers.host != null ? '${r.headers.host}:${r.headers.port ?? boundPort}' : '${_addrFor(peer ?? InternetAddress.loopbackIPv4)?.address}:$boundPort';
    final base = 'http://$host';

    if (path == '/desc.xml') return _xml(res, _deviceXml(base));
    if (path == '/cd.xml') return _xml(res, _cdScpd);
    if (path == '/cm.xml') return _xml(res, _cmScpd);
    if (path == '/icon.png' && iconPng != null) {
      res.headers.contentType = ContentType('image', 'png');
      res.add(iconPng!);
      return res.close();
    }
    if (r.method == 'POST' && (path == '/ctl/cd' || path == '/ctl/cm')) {
      final body = await utf8.decoder.bind(r).join();
      final action = (r.headers.value('soapaction') ?? '').replaceAll('"', '');
      final name = action.contains('#') ? action.split('#').last : '';
      return _soap(res, path == '/ctl/cd' ? 'ContentDirectory' : 'ConnectionManager', name, body, base);
    }
    if (r.method == 'SUBSCRIBE' || r.method == 'UNSUBSCRIBE') {
      // no events to send; just say yes so picky TVs carry on
      res.headers.set('SID', 'uuid:${_fnv('$uuid$path${DateTime.now().microsecondsSinceEpoch}')}');
      res.headers.set('TIMEOUT', 'Second-1800');
      return res.close();
    }
    final m = RegExp(r'^/(m|a|s)/([0-9a-z]+)').firstMatch(path);
    if (m != null) {
      final e = _byId()[m.group(2)];
      if (e == null) {
        res.statusCode = 404;
        return res.close();
      }
      final kind = m.group(1);
      final f = kind == 'm' ? e.file : kind == 'a' ? e.poster : _srtOf(e.file);
      if (f == null || f.isEmpty || !File(f).existsSync()) {
        res.statusCode = 404;
        return res.close();
      }
      if (kind == 'm') {
        final srt = e.kind == 'music' ? null : _srtOf(e.file);
        if (srt != null) res.headers.set('CaptionInfo.sec', '$base/s/${m.group(2)}.srt');
      }
      return _file(r, File(f), kind == 's' ? 'text/srt' : kind == 'a' ? mimeOf(f) : mimeOf(e.file));
    }
    res.statusCode = 404;
    await res.close();
  }

  /// PNG shown on the TV next to the server name (optional).
  List<int>? iconPng;

  Future<void> _xml(HttpResponse res, String xml) {
    res.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
    final b = utf8.encode(xml);
    res.contentLength = b.length;
    res.add(b);
    return res.close();
  }

  Future<void> _file(HttpRequest r, File f, String mime) async {
    final res = r.response;
    final len = await f.length();
    res.headers.set('Accept-Ranges', 'bytes');
    res.headers.set('Content-Type', mime);
    res.headers.set('transferMode.dlna.org', mime.startsWith('image/') ? 'Interactive' : 'Streaming');
    res.headers.set('contentFeatures.dlna.org', _dlnaFeatures(mime));
    var start = 0, end = len - 1;
    final range = r.headers.value('range');
    if (range != null) {
      final m = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
      if (m != null) {
        final a = m.group(1)!, b = m.group(2)!;
        if (a.isEmpty && b.isNotEmpty) {
          start = math.max(0, len - int.parse(b));
        } else {
          start = int.tryParse(a) ?? 0;
          if (b.isNotEmpty) end = math.min(len - 1, int.parse(b));
        }
        if (start >= len || start > end) {
          res.statusCode = 416;
          res.headers.set('Content-Range', 'bytes */$len');
          return res.close();
        }
        res.statusCode = 206;
        res.headers.set('Content-Range', 'bytes $start-$end/$len');
      }
    }
    res.contentLength = end - start + 1;
    if (r.method == 'HEAD') return res.close();
    try {
      await res.addStream(f.openRead(start, end + 1));
    } catch (_) {
      // the TV closed the connection (seeking, stop) — normal
    }
    try {
      await res.close();
    } catch (_) {}
  }

  Future<void> _soap(HttpResponse res, String service, String action, String body, String base) async {
    String arg(String n) {
      final m = RegExp('<(?:[a-zA-Z0-9]+:)?$n(?:\\s[^>]*)?>([\\s\\S]*?)</(?:[a-zA-Z0-9]+:)?$n>').firstMatch(body);
      return m == null ? '' : const HtmlUnescape().convert(m.group(1)!.trim());
    }

    final out = <String, Object>{};
    switch ('$service#$action') {
      case 'ContentDirectory#Browse':
        final tree = _tree();
        final id = arg('ObjectID').isEmpty ? '0' : arg('ObjectID');
        final node = tree[id];
        if (node == null) return _fault(res, 701, 'No such object');
        final flag = arg('BrowseFlag');
        final startIdx = int.tryParse(arg('StartingIndex')) ?? 0;
        var count = int.tryParse(arg('RequestedCount')) ?? 0;
        if (flag == 'BrowseMetadata') {
          out['Result'] = _didl([node], base);
          out['NumberReturned'] = 1;
          out['TotalMatches'] = 1;
        } else {
          final kids = node.children;
          if (count <= 0) count = kids.length;
          final page = kids.skip(startIdx).take(count).toList();
          out['Result'] = _didl(page, base);
          out['NumberReturned'] = page.length;
          out['TotalMatches'] = kids.length;
        }
        out['UpdateID'] = updateId;
      case 'ContentDirectory#GetSystemUpdateID':
        out['Id'] = updateId;
      case 'ContentDirectory#GetSearchCapabilities':
        out['SearchCaps'] = '';
      case 'ContentDirectory#GetSortCapabilities':
        out['SortCaps'] = '';
      case 'ContentDirectory#X_GetFeatureList':
        out['FeatureList'] = '<?xml version="1.0" encoding="UTF-8"?><Features xmlns="urn:schemas-upnp-org:av:avs" '
            'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><Feature name="samsung.com_BASICVIEW" version="1">'
            '<container id="0" type="object.item.videoItem"/><container id="a" type="object.item.audioItem"/></Feature></Features>';
      case 'ContentDirectory#X_SetBookmark':
        break;
      case 'ConnectionManager#GetProtocolInfo':
        out['Source'] = {for (final m in _mimes.values) 'http-get:*:$m:*'}.join(',');
        out['Sink'] = '';
      case 'ConnectionManager#GetCurrentConnectionIDs':
        out['ConnectionIDs'] = '0';
      case 'ConnectionManager#GetCurrentConnectionInfo':
        out.addAll({'RcsID': -1, 'AVTransportID': -1, 'ProtocolInfo': '', 'PeerConnectionManager': '', 'PeerConnectionID': -1, 'Direction': 'Output', 'Status': 'OK'});
      default:
        return _fault(res, 401, 'Invalid Action');
    }
    final b = StringBuffer('<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:${action}Response xmlns:u="urn:schemas-upnp-org:service:$service:1">');
    out.forEach((k, v) => b.write('<$k>${_x(v)}</$k>'));
    b.write('</u:${action}Response></s:Body></s:Envelope>');
    res.headers.set('EXT', '');
    return _xml(res, b.toString());
  }

  Future<void> _fault(HttpResponse res, int code, String desc) {
    res.statusCode = 500;
    return _xml(
        res,
        '<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><s:Fault><faultcode>s:Client</faultcode>'
        '<faultstring>UPnPError</faultstring><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>$code</errorCode>'
        '<errorDescription>$desc</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>');
  }

  String _deviceXml(String base) => '<?xml version="1.0" encoding="utf-8"?>'
      '<root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:dlna="urn:schemas-dlna-org:device-1-0" xmlns:sec="http://www.sec.co.kr/dlna">'
      '<specVersion><major>1</major><minor>0</minor></specVersion><URLBase>$base/</URLBase><device>'
      '<deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>'
      '<dlna:X_DLNADOC>DMS-1.50</dlna:X_DLNADOC><sec:ProductCap>smi,DCM10,getMediaInfo.sec,getCaptionInfo.sec</sec:ProductCap>'
      '<friendlyName>${_x(name)}</friendlyName><manufacturer>Delos</manufacturer><manufacturerURL>https://github.com/un4ckn0wl3z/delos</manufacturerURL>'
      '<modelDescription>Delos media server</modelDescription><modelName>Delos</modelName><modelNumber>1</modelNumber>'
      '<serialNumber>${uuid.substring(0, 8)}</serialNumber><UDN>uuid:$uuid</UDN>'
      '${iconPng != null ? '<iconList><icon><mimetype>image/png</mimetype><width>120</width><height>120</height><depth>24</depth><url>/icon.png</url></icon></iconList>' : ''}'
      '<serviceList>'
      '<service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType><serviceId>urn:upnp-org:serviceId:ContentDirectory</serviceId>'
      '<SCPDURL>/cd.xml</SCPDURL><controlURL>/ctl/cd</controlURL><eventSubURL>/evt/cd</eventSubURL></service>'
      '<service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>'
      '<SCPDURL>/cm.xml</SCPDURL><controlURL>/ctl/cm</controlURL><eventSubURL>/evt/cm</eventSubURL></service>'
      '</serviceList><presentationURL>$base/</presentationURL></device></root>';

  static String _scpd(String actions, String vars) => '<?xml version="1.0" encoding="utf-8"?><scpd xmlns="urn:schemas-upnp-org:service-1-0">'
      '<specVersion><major>1</major><minor>0</minor></specVersion><actionList>$actions</actionList><serviceStateTable>$vars</serviceStateTable></scpd>';
  static String _act(String name, List<(String, String, String)> args) => '<action><name>$name</name><argumentList>'
      '${args.map((a) => '<argument><name>${a.$1}</name><direction>${a.$2}</direction><relatedStateVariable>${a.$3}</relatedStateVariable></argument>').join()}'
      '</argumentList></action>';
  static String _var(String name, String type, {bool events = false, List<String>? allowed}) =>
      '<stateVariable sendEvents="${events ? 'yes' : 'no'}"><name>$name</name><dataType>$type</dataType>'
      '${allowed == null ? '' : '<allowedValueList>${allowed.map((v) => '<allowedValue>$v</allowedValue>').join()}</allowedValueList>'}</stateVariable>';

  static final _cdScpd = _scpd(
    [
      _act('Browse', [
        ('ObjectID', 'in', 'A_ARG_TYPE_ObjectID'), ('BrowseFlag', 'in', 'A_ARG_TYPE_BrowseFlag'), ('Filter', 'in', 'A_ARG_TYPE_Filter'),
        ('StartingIndex', 'in', 'A_ARG_TYPE_Index'), ('RequestedCount', 'in', 'A_ARG_TYPE_Count'), ('SortCriteria', 'in', 'A_ARG_TYPE_SortCriteria'),
        ('Result', 'out', 'A_ARG_TYPE_Result'), ('NumberReturned', 'out', 'A_ARG_TYPE_Count'), ('TotalMatches', 'out', 'A_ARG_TYPE_Count'),
        ('UpdateID', 'out', 'A_ARG_TYPE_UpdateID'),
      ]),
      _act('GetSearchCapabilities', [('SearchCaps', 'out', 'SearchCapabilities')]),
      _act('GetSortCapabilities', [('SortCaps', 'out', 'SortCapabilities')]),
      _act('GetSystemUpdateID', [('Id', 'out', 'SystemUpdateID')]),
    ].join(),
    [
      _var('A_ARG_TYPE_ObjectID', 'string'), _var('A_ARG_TYPE_BrowseFlag', 'string', allowed: ['BrowseMetadata', 'BrowseDirectChildren']),
      _var('A_ARG_TYPE_Filter', 'string'), _var('A_ARG_TYPE_Index', 'ui4'), _var('A_ARG_TYPE_Count', 'ui4'),
      _var('A_ARG_TYPE_SortCriteria', 'string'), _var('A_ARG_TYPE_Result', 'string'), _var('A_ARG_TYPE_UpdateID', 'ui4'),
      _var('SearchCapabilities', 'string'), _var('SortCapabilities', 'string'), _var('SystemUpdateID', 'ui4', events: true),
    ].join(),
  );

  static final _cmScpd = _scpd(
    [
      _act('GetProtocolInfo', [('Source', 'out', 'SourceProtocolInfo'), ('Sink', 'out', 'SinkProtocolInfo')]),
      _act('GetCurrentConnectionIDs', [('ConnectionIDs', 'out', 'CurrentConnectionIDs')]),
      _act('GetCurrentConnectionInfo', [
        ('ConnectionID', 'in', 'A_ARG_TYPE_ConnectionID'), ('RcsID', 'out', 'A_ARG_TYPE_RcsID'), ('AVTransportID', 'out', 'A_ARG_TYPE_AVTransportID'),
        ('ProtocolInfo', 'out', 'A_ARG_TYPE_ProtocolInfo'), ('PeerConnectionManager', 'out', 'A_ARG_TYPE_ConnectionManager'),
        ('PeerConnectionID', 'out', 'A_ARG_TYPE_ConnectionID'), ('Direction', 'out', 'A_ARG_TYPE_Direction'), ('Status', 'out', 'A_ARG_TYPE_ConnectionStatus'),
      ]),
    ].join(),
    [
      _var('SourceProtocolInfo', 'string', events: true), _var('SinkProtocolInfo', 'string', events: true),
      _var('CurrentConnectionIDs', 'string', events: true), _var('A_ARG_TYPE_ConnectionID', 'i4'), _var('A_ARG_TYPE_RcsID', 'i4'),
      _var('A_ARG_TYPE_AVTransportID', 'i4'), _var('A_ARG_TYPE_ProtocolInfo', 'string'), _var('A_ARG_TYPE_ConnectionManager', 'string'),
      _var('A_ARG_TYPE_Direction', 'string', allowed: ['Input', 'Output']),
      _var('A_ARG_TYPE_ConnectionStatus', 'string', allowed: ['OK', 'ContentFormatMismatch', 'InsufficientBandwidth', 'UnreliableChannel', 'Unknown']),
    ].join(),
  );
}

/// Minimal XML entity decoder for SOAP arguments.
class HtmlUnescape {
  const HtmlUnescape();
  String convert(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAllMapped(RegExp(r'&#(x?)([0-9a-fA-F]+);'), (m) => String.fromCharCode(int.parse(m.group(2)!, radix: m.group(1)!.isEmpty ? 10 : 16)))
      .replaceAll('&amp;', '&');
}
