import 'dart:convert';
import 'dart:io';

/// Play on a TV: this computer as a UPnP control point. Finds the TVs (MediaRenderer) on the
/// network with SSDP and tells one what to play through AVTransport (SetAVTransportURI, Play,
/// Pause, Stop, Seek) and RenderingControl (volume). Plain Dart, no Flutter.
class DlnaRenderer {
  DlnaRenderer({required this.id, required this.name, required this.ip, this.maker = '', this.model = '', required this.avt, required this.avtType, this.rc = '', this.rcType = ''});

  /// The TV's UDN ("uuid:…").
  final String id;
  final String name, maker, model;
  final InternetAddress ip;
  final String avt, avtType, rc, rcType;
  DateTime seen = DateTime.now();
}

/// The TV refused (e.g. 701 "transition not available", 714 "illegal MIME type").
class UpnpError implements Exception {
  UpnpError(this.code, this.desc);
  final int code;
  final String desc;
  @override
  String toString() => desc.isEmpty ? 'The TV refused ($code)' : 'The TV refused ($code $desc)';
}

/// What a TV is doing.
class TvState {
  TvState(this.state, this.pos, this.duration, this.uri, this.volume);

  /// PLAYING, PAUSED_PLAYBACK, STOPPED, TRANSITIONING, NO_MEDIA_PRESENT
  final String state;
  final double pos, duration;
  final String uri;

  /// 0–100, -1 = unknown
  final int volume;
  bool get playing => state == 'PLAYING' || state == 'TRANSITIONING';
}

class DlnaCast {
  DlnaCast({this.log});
  final void Function(String)? log;

  final renderers = <String, DlnaRenderer>{};
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  DateTime? searched;
  bool _searching = false;

  static final _group = InternetAddress('239.255.255.250');

  /// The TVs seen in the last 10 minutes, by name.
  List<DlnaRenderer> get list {
    final out = renderers.values.where((r) => DateTime.now().difference(r.seen).inMinutes < 10).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  static Future<List<InternetAddress>> _lan() async {
    final out = <InternetAddress>[];
    try {
      for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false)) {
        final n = ni.name.toLowerCase();
        if (n.contains('vethernet') || n.contains('virtualbox') || n.contains('vmware') || n.startsWith('docker') || n.startsWith('br-') || n.startsWith('veth')) {
          continue;
        }
        for (final a in ni.addresses) {
          if (!a.isLinkLocal) out.add(a);
        }
      }
    } catch (_) {}
    return out;
  }

  /// Asks the network for renderers (M-SEARCH from each LAN address) and reads their descriptions.
  Future<void> search({Duration wait = const Duration(seconds: 3), List<InternetAddress>? from}) async {
    if (_searching) {
      await Future<void>.delayed(wait);
      return;
    }
    _searching = true;
    try {
      final reads = <Future<void>>[];
      final socks = <RawDatagramSocket>[];
      for (final ip in from ?? await _lan()) {
        RawDatagramSocket s;
        try {
          s = await RawDatagramSocket.bind(ip, 0);
        } catch (_) {
          continue;
        }
        socks.add(s);
        final seen = <String>{};
        s.listen((ev) {
          if (ev != RawSocketEvent.read) return;
          final d = s.receive();
          if (d == null) return;
          final loc = _header(utf8.decode(d.data, allowMalformed: true), 'location');
          if (loc.isEmpty || !seen.add(loc)) return;
          reads.add(add(loc, d.address));
        });
        for (final st in ['urn:schemas-upnp-org:device:MediaRenderer:1', 'urn:schemas-upnp-org:service:AVTransport:1']) {
          s.send(utf8.encode('M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: ${wait.inSeconds.clamp(1, 5)}\r\nST: $st\r\n'
              'USER-AGENT: ${Platform.operatingSystem} UPnP/1.0 Delos/1.0\r\n\r\n'), _group, 1900);
        }
      }
      await Future<void>.delayed(wait);
      for (final s in socks) {
        s.close();
      }
      await Future.wait(reads);
      searched = DateTime.now();
    } finally {
      _searching = false;
    }
  }

  static String _header(String msg, String name) {
    for (final l in msg.split('\r\n')) {
      final i = l.indexOf(':');
      if (i > 0 && l.substring(0, i).trim().toLowerCase() == name) return l.substring(i + 1).trim();
    }
    return '';
  }

  static String _tag(String xml, String tag) {
    final m = RegExp('<(?:[A-Za-z0-9]+:)?$tag(?:\\s[^>]*)?>([^<]*)</(?:[A-Za-z0-9]+:)?$tag>').firstMatch(xml);
    return m == null ? '' : _unescape(m.group(1)!.trim());
  }

  static String _unescape(String s) =>
      s.replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&#39;', "'").replaceAll('&apos;', "'").replaceAll('&amp;', '&');

  static String _esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

  /// Reads a device description. Only one on the address that answered is read, and only control
  /// URLs on that same address are used (an answer can't send us elsewhere).
  Future<void> add(String location, InternetAddress from) async {
    final u = Uri.tryParse(location);
    if (u == null || u.scheme != 'http' || InternetAddress.tryParse(u.host) != from) return;
    String xml;
    try {
      final req = await _http.getUrl(u).timeout(const Duration(seconds: 6));
      final res = await req.close().timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return;
      }
      final b = <int>[];
      await for (final c in res.timeout(const Duration(seconds: 6))) {
        b.addAll(c);
        if (b.length > 512 * 1024) break;
      }
      xml = utf8.decode(b, allowMalformed: true);
    } catch (_) {
      return;
    }
    var base = u;
    final ub = Uri.tryParse(_tag(xml, 'URLBase'));
    if (ub != null && ub.scheme == 'http' && InternetAddress.tryParse(ub.host) == from) base = ub;
    String avt = '', avtType = '', rc = '', rcType = '';
    for (final m in RegExp(r'<(?:\w+:)?service>(.*?)</(?:\w+:)?service>', dotAll: true).allMatches(xml)) {
      final t = _tag(m.group(1)!, 'serviceType');
      final ctl = base.resolve(_tag(m.group(1)!, 'controlURL'));
      if (InternetAddress.tryParse(ctl.host) != from) continue;
      if (t.contains(':service:AVTransport:')) (avt, avtType) = (ctl.toString(), t);
      if (t.contains(':service:RenderingControl:')) (rc, rcType) = (ctl.toString(), t);
    }
    final udn = _tag(xml, 'UDN');
    if (avt.isEmpty || udn.isEmpty) return;
    final name = _tag(xml, 'friendlyName');
    final r = DlnaRenderer(
        id: udn, name: name.isEmpty ? from.address : name, ip: from, maker: _tag(xml, 'manufacturer'), model: _tag(xml, 'modelName'),
        avt: avt, avtType: avtType, rc: rc, rcType: rcType);
    final had = renderers.containsKey(udn);
    renderers[udn] = r;
    if (!had) log?.call('cast: found ${r.name} (${r.maker} ${r.model}) at ${from.address}');
  }

  // ------------------------------------------------------------------ SOAP

  Future<Map<String, String>> _call(String ctl, String svc, String action, List<(String, String)> args) async {
    if (ctl.isEmpty) throw StateError("This TV doesn't offer that");
    final body = StringBuffer('<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:$action xmlns:u="${_esc(svc)}">');
    for (final (k, v) in args) {
      body.write('<$k>${_esc(v)}</$k>');
    }
    body.write('</u:$action></s:Body></s:Envelope>');
    final bytes = utf8.encode(body.toString());
    HttpClientResponse res;
    try {
      final req = await _http.postUrl(Uri.parse(ctl)).timeout(const Duration(seconds: 8));
      req.headers.set('Content-Type', 'text/xml; charset="utf-8"');
      req.headers.set('SOAPACTION', '"$svc#$action"');
      req.headers.contentLength = bytes.length;
      req.add(bytes);
      res = await req.close().timeout(const Duration(seconds: 10));
    } catch (e) {
      throw StateError("The TV doesn't answer ($e)");
    }
    final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
    final out = <String, String>{};
    for (final m in RegExp(r'<(?:\w+:)?(\w+)(?:\s[^>]*)?>([^<]*)</(?:\w+:)?\1>').allMatches(text)) {
      out[m.group(1)!] = _unescape(m.group(2)!.trim());
    }
    if (res.statusCode != 200) {
      final c = int.tryParse(out['errorCode'] ?? '');
      if (c != null) throw UpnpError(c, out['errorDescription'] ?? '');
      throw StateError('The TV answered ${res.statusCode}');
    }
    return out;
  }

  static const _i0 = ('InstanceID', '0');

  static String hms(double secs) {
    final t = secs < 0 ? 0 : secs.floor();
    return '${t ~/ 3600}:${(t ~/ 60 % 60).toString().padLeft(2, '0')}:${(t % 60).toString().padLeft(2, '0')}';
  }

  static double parseHms(String s) {
    var t = 0.0;
    for (final p in s.split(':')) {
      final v = double.tryParse(p);
      if (v == null) return 0;
      t = t * 60 + v;
    }
    return t;
  }

  /// Tells [r] to play [uri] (described by the DIDL-Lite [meta]); what it played before stops.
  Future<void> play(DlnaRenderer r, String uri, String meta) async {
    try {
      await _call(r.avt, r.avtType, 'Stop', [_i0]); // many TVs refuse a new URI while playing
    } catch (_) {}
    await _call(r.avt, r.avtType, 'SetAVTransportURI', [_i0, ('CurrentURI', uri), ('CurrentURIMetaData', meta)]);
    for (var i = 0;; i++) {
      try {
        await _call(r.avt, r.avtType, 'Play', [_i0, ('Speed', '1')]);
        return;
      } on UpnpError catch (e) {
        // some TVs need a moment after SetAVTransportURI (701 = not ready yet)
        if (e.code != 701 || i >= 5) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    }
  }

  Future<void> resume(DlnaRenderer r) => _call(r.avt, r.avtType, 'Play', [_i0, ('Speed', '1')]);
  Future<void> pause(DlnaRenderer r) => _call(r.avt, r.avtType, 'Pause', [_i0]);
  Future<void> stop(DlnaRenderer r) => _call(r.avt, r.avtType, 'Stop', [_i0]);
  Future<void> seek(DlnaRenderer r, double secs) => _call(r.avt, r.avtType, 'Seek', [_i0, ('Unit', 'REL_TIME'), ('Target', hms(secs))]);
  Future<void> setVolume(DlnaRenderer r, int v) =>
      _call(r.rc, r.rcType, 'SetVolume', [_i0, ('Channel', 'Master'), ('DesiredVolume', '${v.clamp(0, 100)}')]);

  Future<TvState> state(DlnaRenderer r) async {
    final t = await _call(r.avt, r.avtType, 'GetTransportInfo', [_i0]);
    var pos = 0.0, dur = 0.0, uri = '';
    try {
      final p = await _call(r.avt, r.avtType, 'GetPositionInfo', [_i0]);
      pos = parseHms(p['RelTime'] ?? '');
      dur = parseHms(p['TrackDuration'] ?? '');
      uri = p['TrackURI'] ?? '';
    } catch (_) {}
    var vol = -1;
    if (r.rc.isNotEmpty) {
      try {
        vol = int.tryParse((await _call(r.rc, r.rcType, 'GetVolume', [_i0, ('Channel', 'Master')]))['CurrentVolume'] ?? '') ?? -1;
      } catch (_) {}
    }
    return TvState(t['CurrentTransportState'] ?? '', pos, dur, uri, vol);
  }

  void close() => _http.close(force: true);
}
