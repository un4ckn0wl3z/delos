"""Talks to tool/dlna_check.dart like a TV would: SSDP M-SEARCH, description, Browse, ranged GET."""
import re, socket, sys, time, urllib.request, xml.etree.ElementTree as ET
from html import unescape

def msearch(st, dest):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
    s.sendto((f'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 1\r\nST: {st}\r\n\r\n').encode(), (dest, 1900))
    out = []
    try:
        while True:
            d, _ = s.recvfrom(4096); out.append(d.decode())
    except socket.timeout:
        pass
    return out

def soap(ctl, action, args):
    body = ('<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
            f'<s:Body><u:{action} xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">' + ''.join(f'<{k}>{v}</{k}>' for k, v in args.items()) +
            f'</u:{action}></s:Body></s:Envelope>')
    req = urllib.request.Request(ctl, body.encode(), {'Content-Type': 'text/xml; charset="utf-8"', 'SOAPACTION': f'"urn:schemas-upnp-org:service:ContentDirectory:1#{action}"'})
    return urllib.request.urlopen(req, timeout=5).read().decode()

ok = True
def check(cond, msg):
    global ok
    print(('PASS ' if cond else 'FAIL ') + msg); ok = ok and cond

r = msearch('urn:schemas-upnp-org:device:MediaServer:1', '127.0.0.1')
check(len(r) >= 1, f'M-SEARCH unicast answered ({len(r)})')
try:
    r2 = msearch('ssdp:all', '239.255.255.250')
    check(any('MediaServer' in x for x in r2), f'M-SEARCH multicast answered ({len(r2)})')
except OSError as e:
    print('SKIP multicast: this runner has no multicast route:', e)
check(not msearch('urn:schemas-upnp-org:device:MediaRenderer:1', '127.0.0.1'), 'ignores other device types')
loc = re.search(r'LOCATION: (\S+)', r[0], re.I).group(1)
print('location', loc)
desc = urllib.request.urlopen(loc).read().decode()
ET.fromstring(desc)  # well-formed
check('Delos test &amp; co' in desc, 'friendlyName escaped')
base = loc.rsplit('/', 1)[0]
ctl = base + '/ctl/cd'
for p in ('/cd.xml', '/cm.xml'):
    ET.fromstring(urllib.request.urlopen(base + p).read())

def browse(oid, flag='BrowseDirectChildren', start=0, count=0):
    x = soap(ctl, 'Browse', {'ObjectID': oid, 'BrowseFlag': flag, 'Filter': '*', 'StartingIndex': start, 'RequestedCount': count, 'SortCriteria': ''})
    env = ET.fromstring(x)
    res = env.find('.//Result').text
    didl = ET.fromstring(res)
    n = int(env.find('.//NumberReturned').text); t = int(env.find('.//TotalMatches').text)
    return didl, n, t

NS = {'d': 'urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/', 'dc': 'http://purl.org/dc/elements/1.1/', 'upnp': 'urn:schemas-upnp-org:metadata-1-0/upnp/'}
didl, n, t = browse('0')
titles = [c.find('dc:title', NS).text for c in didl.findall('d:container', NS)]
print('root', titles)
check(titles == ['Recently added', 'Movies', 'TV shows', 'Music', 'Online'], 'root folders')
didl, n, t = browse('0', 'BrowseMetadata'); check(n == 1, 'root metadata')

# walk everything
items = []
def walk(oid, depth=0):
    didl, n, t = browse(oid)
    for c in didl.findall('d:container', NS):
        print('  ' * depth + '[' + c.find('dc:title', NS).text + ']', c.get('childCount'))
        walk(c.get('id'), depth + 1)
    for i in didl.findall('d:item', NS):
        items.append(i); print('  ' * depth + '- ' + i.find('dc:title', NS).text, i.find('upnp:class', NS).text)
walk('0')
check(not any('Missing' in i.find('dc:title', NS).text for i in items), 'missing files are hidden')
check(any(i.find('dc:title', NS).text == 'S01E01 · Pilot <1>' for i in items), 'episode titles (escaped)')
mv = [i for i in items if i.find('dc:title', NS).text == 'Pitch Black (2000)'][0]
res = mv.findall('d:res', NS)
check(res[0].get('duration') == '1:49:00.000' and res[0].get('size') == '300000', 'res size/duration')
check('video/x-matroska' in res[0].get('protocolInfo'), 'mime mkv')
murl = res[0].text
check(mv.find('upnp:albumArtURI', NS) is not None, 'poster uri')

# paging
root = {c.find('dc:title', NS).text: c.get('id') for c in browse('0')[0].findall('d:container', NS)}
didl, n, t = browse(root['TV shows'], start=0, count=1); check(n == 1 and t == 1, 'paging tv')
sid = didl.find('d:container', NS).get('id')
didl, n, t = browse(sid); check(t == 2, 'two seasons')
didl, n, t = browse(sid + '/s1', start=1, count=5); check(n == 1 and t == 2, 'paging episodes')

# media with ranges
req = urllib.request.Request(murl, headers={'Range': 'bytes=100-199'})
r = urllib.request.urlopen(req)
data = r.read()
check(r.status == 206 and len(data) == 100 and data[0] == 100 % 251, 'range 100-199')
check(r.headers['Content-Range'] == 'bytes 100-199/300000', 'content-range')
check(r.headers.get('CaptionInfo.sec', '').endswith('.srt'), 'CaptionInfo.sec header')
check('DLNA.ORG_OP=01' in r.headers.get('contentFeatures.dlna.org', ''), 'contentFeatures')
r = urllib.request.urlopen(urllib.request.Request(murl, headers={'Range': 'bytes=-50'})); check(len(r.read()) == 50, 'suffix range')
r = urllib.request.urlopen(urllib.request.Request(murl, method='HEAD')); check(r.headers['Content-Length'] == '300000', 'HEAD length')
srt = urllib.request.urlopen(r.headers['CaptionInfo.sec']).read().decode(); check('Hello' in srt, 'srt served')
try:
    urllib.request.urlopen(base + '/m/nope.mkv'); check(False, '404')
except urllib.error.HTTPError as e:
    check(e.code == 404, '404 for unknown')
try:
    browse('nope'); check(False, 'fault')
except urllib.error.HTTPError as e:
    check(e.code == 500 and '701' in e.read().decode(), 'fault 701 for unknown object')
x = soap(ctl, 'GetSystemUpdateID', {}); check('<Id>' in x, 'GetSystemUpdateID')

# online (passthrough): Online → Films → the movie, ranges forwarded
on = [i for i in items if i.find('dc:title', NS).text == 'Pitch Black online']
check(len(on) == 1, 'online item listed')
ou = on[0].find('d:res', NS).text
r = urllib.request.urlopen(urllib.request.Request(ou, headers={'Range': 'bytes=1000-1099'})); d = r.read()
check(r.status == 206 and len(d) == 100 and d[0] == 1000 % 251, 'passthrough range')
check(r.headers['Content-Range'] == 'bytes 1000-1099/300000', 'passthrough content-range')

import os, subprocess, tempfile
ff = os.environ.get('FFMPEG')
if ff:
    dv = [i for i in items if i.find('dc:title', NS).text == 'DTS Movie (TV audio)' or i.find('dc:title', NS).text.startswith('DTS Movie')]
    check(len(dv) >= 1, 'DTS movie listed')
    res = dv[0].find('d:res', NS)
    check('DLNA.ORG_OP=10' in res.get('protocolInfo') and res.get('size') is None, 'converted: time-seek flags, no size')
    probe = os.path.join(os.path.dirname(ff), 'ffprobe' + ('.exe' if ff.lower().endswith('.exe') else ''))
    def grab(hdr):
        r = urllib.request.urlopen(urllib.request.Request(res.text, headers=hdr), timeout=60)
        f = tempfile.NamedTemporaryFile(suffix='.mkv', delete=False); f.write(r.read()); f.close()
        out = subprocess.run([probe, '-v', 'error', '-show_entries', 'stream=codec_type,codec_name', '-of', 'compact', f.name], capture_output=True, text=True).stdout
        pts = [float(x) for x in subprocess.run([probe, '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'packet=pts_time', '-of', 'csv=p=0', f.name],
                                                capture_output=True, text=True).stdout.split() if x.strip() not in ('', 'N/A')]
        out += f'\nduration={max(pts) - min(pts) if pts else 0:.2f}'
        return r, out
    r, out = grab({})
    print(out)
    check('codec_name=ac3' in out and 'codec_name=h264' in out and 'codec_type=subtitle' in out, 'converted: h264 + ac3 + subs')
    r, out = grab({'TimeSeekRange.dlna.org': 'npt=10.0-'})
    dur = float(re.search(r'duration=([0-9.]+)', out).group(1))
    print('seek out', r.headers.get('TimeSeekRange.dlna.org'), dur)
    check(r.headers.get('TimeSeekRange.dlna.org', '').startswith('npt=10.000-20.000/20.000') and 8 <= dur <= 12, 'time seek to 10 s')
    log = open(os.environ['SRVLOG'], encoding='utf-8', errors='replace').read() if os.environ.get('SRVLOG') else ''
    check('COPY OK' in log, 'TV copy made through the loopback route (' + (re.search(r'COPY \S+ ?[^\n]*', log) or [''])[0] + ')')
else:
    print('no FFMPEG: conversion not checked')
sys.exit(0 if ok else 1)
