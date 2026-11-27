# Fake TMDB for the demo catalog (fictional titles).
import json, re, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
from catalog import MOVIES, SHOWS
CAST = [("Mira Solano", "Ana"), ("Theo Hartley", "Jonah"), ("Ploy Chanthara", "Nim"), ("Idris Vale", "The Captain"), ("June Okafor", "Sasha")]
# original demo lyrics (written for the demo)
LYR = {
  'Neon Hearts': ['City lights are humming low', 'Every window keeps a glow', '', 'We were running out of night', 'Chasing signals, holding tight',
                  'Neon hearts, electric skies', 'Static dancing in your eyes', 'Turn it up and let it play', 'Neon hearts will find a way',
                  '', 'Midnight trains and empty streets', 'Bassline counting all the beats', 'Neon hearts, electric skies', 'Hold on till the morning light'],
  'Undertow': ['Salt on the window, grey on the sea', 'The tide keeps calling you back to me', 'Pull of the water, hush of the shore',
               'Undertow, undertow', 'Carry me home once more'],
}
def norm(s): return re.sub(r'[^a-z0-9]+', ' ', s.lower().replace('&', ' and ')).strip()
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, o, code=200):
        b = json.dumps(o).encode(); self.send_response(code); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        u = urlparse(self.path); p = u.path; q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if p.startswith('/3/search'): print(p, q, flush=True)
        if p == '/3/search/movie':
            r = [m for m in MOVIES if norm(m['title']) == norm(q.get('query', ''))]
            return self.send({'results': [{'id': m['id'], 'title': m['title'], 'release_date': f"{m['year']}-05-01"} for m in r]})
        if p == '/3/search/tv':
            r = [s for s in SHOWS if norm(s['title']) == norm(q.get('query', ''))]
            return self.send({'results': [{'id': s['id'], 'name': s['title'], 'first_air_date': f"{s['year']}-03-01"} for s in r]})
        m = re.match(r'^/3/movie/(\d+)$', p)
        if m:
            x = next((m for m in MOVIES if m['id'] == int(m.group(1))), None) if False else next((mm for mm in MOVIES if mm['id'] == int(m.group(1))), None)
            if not x: return self.send({}, 404)
            k = x['id'] % 5
            return self.send({'id': x['id'], 'title': x['title'], 'original_title': x['title'], 'overview': x['overview'], 'release_date': f"{x['year']}-05-01",
                              'runtime': 96 + (x['id'] % 7) * 6, 'poster_path': f"/p{x['id']}.jpg", 'backdrop_path': f"/b{x['id']}.jpg", 'vote_average': x['rating'],
                              'genres': [{'id': i, 'name': g} for i, g in enumerate(x['genres'])],
                              'credits': {'cast': [{'name': n, 'character': c, 'profile_path': None} for n, c in CAST[k:] + CAST[:k]][:4],
                                          'crew': [{'name': ['Rin Takeda', 'Lukas Brandt', 'Aree Wongsa'][x['id'] % 3], 'job': 'Director'}]}})
        m = re.match(r'^/3/tv/(\d+)$', p)
        if m:
            s = next((s for s in SHOWS if s['id'] == int(m.group(1))), None)
            return self.send({'id': s['id'], 'name': s['title'], 'original_name': s['title'], 'overview': s['overview'], 'first_air_date': f"{s['year']}-03-01",
                              'poster_path': f"/p{s['id']}.jpg", 'backdrop_path': f"/b{s['id']}.jpg", 'vote_average': s['rating'],
                              'genres': [{'name': g} for g in s['genres']], 'number_of_seasons': len(s['seasons']),
                              'seasons': [{'season_number': n, 'episode_count': len(e), 'name': f'Season {n}'} for n, e in s['seasons'].items()],
                              'credits': {'cast': [{'name': n, 'character': c, 'profile_path': None} for n, c in CAST[:4]]}})
        m = re.match(r'^/3/tv/(\d+)/season/(\d+)$', p)
        if m:
            s = next((s for s in SHOWS if s['id'] == int(m.group(1))), None); se = int(m.group(2))
            eps = s['seasons'].get(se, [])
            return self.send({'episodes': [{'episode_number': i, 'name': n, 'overview': f'{n}. ' + s['overview'].split('—')[0].strip() + '.', 'still_path': f"/s{s['id']}_{se}_{i}.jpg",
                                            'air_date': f"{s['year'] + se - 1}-03-{i:02d}", 'runtime': 44} for i, n in enumerate(eps, 1)]})
        if p in ('/api/get', '/api/search'):
            t = q.get('track_name', '')
            if t in LYR:
                lines = LYR[t]; step = 6.0
                synced = '\n'.join(f'[{int(i*step+4)//60:02d}:{(i*step+4)%60:05.2f}] {l}' for i, l in enumerate(lines))
                body = {'syncedLyrics': synced, 'plainLyrics': '\n'.join(lines), 'duration': float(q.get('duration', 0) or 0)}
                return self.send([body] if p == '/api/search' else body)
            return self.send([] if p == '/api/search' else {'code': 404}, 200 if p == '/api/search' else 404)
        if p.startswith('/ws/2/'): return self.send({'release-groups': [], 'releases': [], 'recordings': []})
        self.send({'error': 'not found ' + p}, 404)
ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
