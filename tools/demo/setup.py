# Starts nothing: configures a running demo server on :8097 (libraries, users, progress, roles).
import json, time, urllib.request
B = 'http://127.0.0.1:8097/api/'
def call(path, body=None, method=None, tok=None):
    req = urllib.request.Request(B + path, json.dumps(body).encode() if body is not None else None, method=method or ('POST' if body is not None else 'GET'))
    req.add_header('Content-Type', 'application/json')
    if tok: req.add_header('Authorization', 'Bearer ' + tok)
    try:
        return json.loads(urllib.request.urlopen(req).read() or b'null')
    except urllib.error.HTTPError as e:
        print('ERR', path, e.code, e.read()[:200]); return None
T = call('login', {'username': 'mira', 'password': 'demo-pass-1'})['token']
a = lambda *x, **k: call(*x, tok=T, **k)
a('admin/settings', {'tmdbKey': 'demo-key', 'autoUpdate': False})
a('admin/libraries/main', {'name': 'Movies', 'type': 'movies', 'path': '/tmp/demo/media/Movies'}, 'PUT')
libs = a('admin/libraries')['libraries']
if not any(l['type'] == 'tv' for l in libs): a('admin/libraries', {'name': 'TV Shows', 'type': 'tv', 'path': '/tmp/demo/media/TV'})
if not any(l['type'] == 'music' for l in libs): a('admin/libraries', {'name': 'Music', 'type': 'music', 'path': '/tmp/demo/media/Music'})
for l in a('admin/libraries')['libraries']:
    a(f"admin/libraries/{l['id']}/scan", {})
for _ in range(120):
    st = a('admin/libraries'); s = st.get('status') or {}
    if not s.get('running') and all(l.get('scanned') for l in st['libraries']): break
    time.sleep(1)
print([(l['id'], l['type'], l['count']) for l in a('admin/libraries')['libraries']])
for n in ['theo', 'ploy', 'june', 'sam']:
    a('admin/users', {'name': n, 'password': 'demo-pass-1', 'admin': False})
fam = a('admin/roles', {'name': 'Family', 'libraries': [l['id'] for l in a('admin/libraries')['libraries'] if l['type'] in ('movies', 'tv')], 'offline': True})
mus = a('admin/roles', {'name': 'Music lovers', 'libraries': [l['id'] for l in a('admin/libraries')['libraries'] if l['type'] == 'music']})
a('admin/users/theo/roles', {'roles': ['family', 'music-lovers']}); a('admin/users/ploy/roles', {'roles': ['family']}); a('admin/users/june/roles', {'roles': ['music-lovers']})
a('admin/users/theo/downloader', {'downloader': True})
# continue watching for mira
items = {}
for l in a('libraries')['libraries'] if isinstance(a('libraries'), dict) else a('libraries'):
    d = a('lib/' + l['id'])
    for it in d['items']: items[it['path']] = it
def prog(sub, frac):
    p = next(k for k in items if sub in k)
    dur = items[p].get('duration') or (2640 if '.S0' in p else 6000)
    a('progress', {'path': p, 'pos': dur * frac, 'duration': dur})
    time.sleep(1.1)
prog('The.Glass.Orchard', .2); prog('Harbor.Lights.S01E03', .3); prog('Neon.Tide', .7); prog('Low.Orbit', .45)
print('items', len(items))
