// CI check for lib/dlna/dlna_cast.dart (Play on a TV), copied next to dlna_server.dart by the
// workflow; plain `dart run`, no Flutter. A fake TV (MediaRenderer) is told to play a file from
// the DLNA server, then paused, seeked, its volume set and its state read back.
import 'dart:convert';
import 'dart:io';

import 'dlna_cast.dart';
import 'dlna_server.dart';

class FakeTv {
  String uri = '', meta = '', state = 'NO_MEDIA_PRESENT', seek = '', volume = '20';
  int got = 0, notYet = 2;
  final calls = <String>[];

  static String _arg(String body, String k) {
    final m = RegExp('<$k>([^<]*)</$k>').firstMatch(body);
    return m == null
        ? ''
        : m.group(1)!.replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&amp;', '&');
  }

  Future<void> handle(HttpRequest r) async {
    final res = r.response;
    if (r.method == 'GET' && r.uri.path == '/desc.xml') {
      res.headers.contentType = ContentType('text', 'xml');
      res.write('<?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><device>'
          '<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType><friendlyName>Living room TV</friendlyName>'
          '<manufacturer>LG Electronics</manufacturer><modelName>OLED55</modelName><UDN>uuid:tv-1</UDN><serviceList>'
          '<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/upnp/avt</controlURL></service>'
          '<service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><controlURL>upnp/rc</controlURL></service>'
          '<service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><controlURL>http://203.0.113.9/cm</controlURL></service>'
          '</serviceList></device></root>');
      return res.close();
    }
    final body = await utf8.decoder.bind(r).join();
    var action = r.headers.value('soapaction') ?? '';
    action = action.replaceAll('"', '').split('#').last;
    calls.add(action);
    var out = '';
    var fault = 0;
    switch (action) {
      case 'SetAVTransportURI':
        uri = _arg(body, 'CurrentURI');
        meta = _arg(body, 'CurrentURIMetaData');
        state = 'STOPPED';
      case 'Play':
        if (notYet > 0) {
          notYet--;
          fault = 701;
        } else {
          state = 'PLAYING';
          _fetch(uri);
        }
      case 'Pause':
        state = 'PAUSED_PLAYBACK';
      case 'Stop':
        state = 'STOPPED';
      case 'Seek':
        seek = _arg(body, 'Target');
      case 'SetVolume':
        volume = _arg(body, 'DesiredVolume');
      case 'GetTransportInfo':
        out = '<CurrentTransportState>$state</CurrentTransportState>';
      case 'GetPositionInfo':
        out = '<TrackDuration>0:01:40</TrackDuration><TrackURI>${uri.replaceAll('&', '&amp;')}</TrackURI><RelTime>0:00:12</RelTime>';
      case 'GetVolume':
        out = '<CurrentVolume>$volume</CurrentVolume>';
    }
    res.headers.contentType = ContentType('text', 'xml');
    if (fault != 0) {
      res.statusCode = 500;
      res.write('<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0">'
          '<errorCode>$fault</errorCode><errorDescription>Transition not available</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>');
    } else {
      res.write('<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:${action}Response xmlns:u="x">$out</u:${action}Response></s:Body></s:Envelope>');
    }
    await res.close();
  }

  Future<void> _fetch(String u) async {
    final c = HttpClient();
    try {
      final res = await (await c.getUrl(Uri.parse(u))).close();
      await for (final b in res) {
        got += b.length;
      }
    } catch (e) {
      print('fake TV: fetch failed: $e');
    }
    c.close();
  }
}

void check(bool ok, String what) {
  if (!ok) {
    print('FAIL: $what');
    exit(1);
  }
  print('ok: $what');
}

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('cast');
  final film = File('${dir.path}/Night & Day (2020).mp4');
  await film.writeAsBytes(List.generate(50000, (i) => i % 251));
  final e = DlnaEntry(key: 'l:film', file: film.path, kind: 'movie', title: 'Night & Day', year: 2020, duration: 100);
  final s = DlnaServer(name: 'Delos cast test', uuid: '4d696e69-444c-164e-9d41-b827eb000002', entries: () => [e], port: 58210, log: print);
  await s.start();

  final tv = FakeTv();
  final h = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  h.listen(tv.handle);
  final loc = 'http://127.0.0.1:${h.port}/desc.xml';
  final cast = DlnaCast(log: print);

  await cast.add(loc, InternetAddress('10.9.9.9'));
  check(cast.list.isEmpty, 'a description on another address than the answer is not read');
  await cast.add(loc, InternetAddress.loopbackIPv4);
  check(cast.list.length == 1 && cast.list.first.name == 'Living room TV' && cast.list.first.maker == 'LG Electronics', 'the TV is found');
  final r = cast.list.first;
  check(r.rc.endsWith('/upnp/rc') && r.avt.endsWith('/upnp/avt'), 'control URLs resolved on the TV only');

  final m = s.mediaFor(e, InternetAddress.loopbackIPv4, 'Night & Day (2020)');
  await cast.play(r, m.uri, m.meta);
  for (var i = 0; i < 50 && tv.got < 50000; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  check(tv.got == 50000, 'the TV read the whole file from the DLNA server (${tv.got} bytes)');
  check(tv.meta.contains('<dc:title>Night &amp; Day (2020)</dc:title>') && tv.meta.contains('http-get:*:video/mp4:'), 'metadata sent with the URL');
  check(tv.calls.where((c) => c == 'Play').length == 3, 'Play retried while the TV says 701');

  await cast.pause(r);
  await cast.seek(r, 3725);
  await cast.setVolume(r, 35);
  final st = await cast.state(r);
  check(st.state == 'PAUSED_PLAYBACK' && st.pos == 12 && st.duration == 100 && st.volume == 35 && st.uri == m.uri, 'state read back');
  check(tv.seek == '1:02:05', 'seek target ${tv.seek}');

  // SSDP: a renderer answering M-SEARCH on the network (skipped where multicast is blocked)
  final lan = <InternetAddress>[];
  for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    lan.addAll(ni.addresses.where((a) => !a.isLoopback && !a.isLinkLocal));
  }
  if (lan.isNotEmpty) {
    final ip = lan.first;
    final h2 = await HttpServer.bind(ip, 0);
    h2.listen(FakeTv().handle);
    try {
      final mc = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 1900, reuseAddress: true);
      mc.joinMulticast(InternetAddress('239.255.255.250'));
      mc.listen((ev) {
        final d = mc.receive();
        if (d == null) return;
        final t = utf8.decode(d.data, allowMalformed: true);
        if (t.startsWith('M-SEARCH') && t.contains('MediaRenderer')) {
          mc.send(utf8.encode('HTTP/1.1 200 OK\r\nLOCATION: http://${ip.address}:${h2.port}/desc.xml\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n'), d.address, d.port);
        }
      });
      final c2 = DlnaCast();
      await c2.search(wait: const Duration(seconds: 2), from: [ip]);
      print(c2.list.isNotEmpty ? 'ok: found over SSDP' : 'skip: nothing over SSDP (multicast blocked here?)');
      mc.close();
    } catch (e) {
      print('skip: SSDP ($e)');
    }
    await h2.close(force: true);
  }

  cast.close();
  await s.stop();
  await h.close(force: true);
  print('CAST OK');
  exit(0);
}
