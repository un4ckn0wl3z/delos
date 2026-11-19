/*
 * StreamMKV web app — served by the StreamMKV server at its own address
 * (no browser extension needed). Movies, TV, music, chat, downloads, player.
 * Small per-browser settings live in localStorage; sign-in is the server's
 * session cookie.
 */
(function () {
  'use strict';

  // per-browser storage (preferences, remembered track choices, …)
  const LS = 'smkv:';
  const lsGet = (k, d) => { try { const v = localStorage.getItem(LS + k); return v === null ? d : JSON.parse(v); } catch { return d; } };
  const lsSet = (k, v) => { try { localStorage.setItem(LS + k, JSON.stringify(v)); } catch { /* full / private mode */ } };
  const lsDel = (k) => { try { localStorage.removeItem(LS + k); } catch { /* ignore */ } };

  // ---------------------------------------------------------------- settings
  const DEFAULTS = { engine: 'auto', audioLang: '', subLang: '', maxh: 1080 };
  const getSettings = () => Object.assign({}, DEFAULTS, lsGet('settings', {}));
  const saveSettings = (s) => lsSet('settings', s);
  const normBase = (u) => {
    try {
      const x = new URL(u);
      let p = x.pathname;
      if (!p.endsWith('/')) p += '/';
      return x.origin + p;
    } catch { return ''; }
  };

  // ---------------------------------------------------------------- settings modal
  function openSettings(onSaved) {
    if (document.getElementById('smkv-settings-host')) return;
    const s = getSettings();
    const host = document.createElement('div');
    host.id = 'smkv-settings-host';
    const root = host.attachShadow({ mode: 'open' });
    root.innerHTML = `
      <style>
        :host{all:initial}
        .bg{position:fixed;inset:0;background:rgba(0,0,0,.6);z-index:2147483647;display:grid;place-items:center;font:14px/1.4 system-ui,sans-serif}
        .box{background:#161a21;color:#d7dce4;border:1px solid #2a313c;border-radius:10px;padding:20px;width:min(420px,92vw);box-shadow:0 10px 40px rgba(0,0,0,.5)}
        h2{margin:0 0 14px;font-size:17px;color:#fff}
        label{display:block;margin:10px 0 4px;color:#8b95a5;font-size:12px;text-transform:uppercase;letter-spacing:.5px}
        input,select{width:100%;box-sizing:border-box;padding:8px 10px;background:#0d1015;color:#fff;border:1px solid #2a313c;border-radius:6px;font:inherit}
        input:focus{outline:none;border-color:#4a9eff}
        .hint{font-size:12px;color:#6b7482;margin-top:3px}
        .row{display:flex;gap:8px;margin-top:18px;justify-content:flex-end}
        button{padding:8px 14px;border-radius:6px;border:1px solid #2a313c;background:#222833;color:#d7dce4;font:inherit;cursor:pointer}
        button.primary{background:#2b6fd6;border-color:#2b6fd6;color:#fff}
        .msg{color:#ff8080;font-size:13px;min-height:1em;margin-top:8px}
      </style>
      <div class="bg"><form class="box">
        <h2>Settings</h2>
        <label>Playback</label><select name="engine">
          <option value="auto">In this browser when possible (original file, any audio track)</option>
          <option value="server">Always through the server (remux / transcode)</option></select>
        <div class="hint">In-browser playback decodes the original file here (AC-3, E-AC-3, DTS, TrueHD audio via WebAssembly) — the server only sends the file. It falls back to the server automatically.</div>
        <label>Preferred audio languages</label><input name="audioLang" placeholder="jpn,eng">
        <label>Preferred subtitle languages</label><input name="subLang" placeholder="tha,eng">
        <div class="hint">Comma-separated ISO codes, first match wins. Per-file choices are remembered.</div>
        <label>Max height when transcoding</label><input name="maxh" type="number" min="240" max="2160" step="1">
        <div class="msg"></div>
        <div class="row">
          <button type="button" data-act="cancel">Cancel</button>
          <button type="submit" class="primary">Save</button>
        </div>
      </form></div>`;
    const form = root.querySelector('form');
    for (const k of Object.keys(DEFAULTS)) form.elements[k].value = s[k] ?? '';
    const close = () => host.remove();
    const collect = () => {
      const n = {};
      for (const k of Object.keys(DEFAULTS)) n[k] = form.elements[k].value.trim();
      n.maxh = parseInt(n.maxh, 10) || 1080;
      saveSettings(n);
      return n;
    };
    form.addEventListener('submit', (e) => { e.preventDefault(); const n = collect(); if (n) { close(); onSaved && onSaved(n); } });
    root.querySelector('[data-act=cancel]').onclick = close;
    root.querySelector('.bg').addEventListener('mousedown', (e) => { if (e.target.classList.contains('bg')) close(); });
    document.documentElement.appendChild(host);
    form.elements.audioLang.focus();
  }

  // ================================================================= APP
  function bootApp() {
    const BASE = normBase(location.href.split(/[?#]/)[0]);
    document.getElementById('smkv-placeholder')?.remove();
    document.getElementById('smkv-boot')?.remove();

    // ------------------------------------------------------------ helpers
    const $ = (sel) => document.querySelector(sel);
    const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    const fmtTime = (t) => {
      if (!isFinite(t) || t < 0) t = 0;
      t = Math.floor(t);
      const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60;
      return (h ? h + ':' + String(m).padStart(2, '0') : m) + ':' + String(s).padStart(2, '0');
    };
    const fmtSize = (b) => {
      const u = ['B', 'KB', 'MB', 'GB', 'TB']; let i = 0;
      while (b >= 1024 && i < u.length - 1) { b /= 1024; i++; }
      return b.toFixed(i >= 3 ? 2 : 0) + ' ' + u[i];
    };
    const langMatch = (lang, prefs) => {
      lang = (lang || '').toLowerCase();
      if (!lang) return -1;
      const list = (prefs || '').toLowerCase().split(',').map((x) => x.trim()).filter(Boolean);
      return list.findIndex((p) => lang.startsWith(p) || p.startsWith(lang));
    };

    // ------------------------------------------------------------ DOM
    const style = document.createElement('style');
    style.textContent = CSS;
    document.head.appendChild(style);
    document.body.insertAdjacentHTML('beforeend', HTML);

    const video = $('#smkv-video'), player = $('#smkv-player'), subsEl = $('#smkv-subs');
    const seek = $('#smkv-seek'), timeEl = $('#smkv-time'), ppBtn = $('#smkv-pp');
    const selAudio = $('#smkv-audio'), selSub = $('#smkv-sub'), selV = $('#smkv-vmode'), selH = $('#smkv-maxh');

    // ------------------------------------------------------------ state
    const S = {
      files: [], file: null, info: null,
      offset: 0,              // stream start position (seconds into the movie)
      audio: 0, sub: null,    // sub: {idx, text}
      cues: [], subDelay: 0, lastCueKey: '',
      vmode: 'auto', forceTranscode: false, maxh: getSettings().maxh || 1080,
      loadSeq: 0, dragging: false, pendingTarget: null, pendingTimer: 0,
      engFile: null, engAudio: -1, browserFail: null, // in-browser engine state
      errCount: 0, lastSave: 0,
    };
    // `media` is what's playing: the <video> (server stream) or the in-browser engine
    let wp = null, media = video;
    const canvas = $('#smkv-canvas');
    const cur = () => (S.pendingTarget ?? (media === wp ? wp.currentTime : S.offset + (video.currentTime || 0)));

    // ------------------------------------------------------------ toast / spinner
    let toastTimer = 0;
    function toast(msg, ms = 3000, action) {
      const t = $('#smkv-toast');
      t.innerHTML = esc(msg) + (action ? ` <button>${esc(action.label)}</button>` : '');
      if (action) t.querySelector('button').onclick = () => { action.fn(); t.classList.remove('show'); };
      t.classList.add('show');
      clearTimeout(toastTimer);
      if (ms) toastTimer = setTimeout(() => t.classList.remove('show'), ms);
    }
    const spinner = (on) => $('#smkv-spinner').classList.toggle('show', on);

    // ------------------------------------------------------------ auth + api
    async function doLogin(username, password) {
      const r = await fetch(new URL('api/login', BASE), {
        method: 'POST', credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username, password }),
      });
      if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || r.statusText);
    }

    let loginPromise = null;
    function ensureLogin() {
      if (loginPromise) return loginPromise;
      loginPromise = (async () => {
        if ((await fetch(new URL('api/me', BASE), { credentials: 'same-origin' })).ok) return;
        await showLoginForm();
      })().finally(() => { loginPromise = null; });
      return loginPromise;
    }

    function showLoginForm() {
      return new Promise((resolve) => {
        const box = $('#smkv-login');
        const f = box.querySelector('form');
        document.getElementById('smkv-boot')?.remove();
        f.elements.username.value = lsGet('lastUser', '');
        f.elements.password.value = '';
        box.classList.add('show');
        f.elements[f.elements.username.value ? 'password' : 'username'].focus();
        f.onsubmit = async (e) => {
          e.preventDefault();
          const u = f.elements.username.value.trim(), p = f.elements.password.value;
          const msg = box.querySelector('.msg');
          msg.textContent = 'Signing in…';
          try {
            await doLogin(u, p);
            lsSet('lastUser', u);
            box.classList.remove('show');
            msg.textContent = '';
            resolve();
          } catch (err) { msg.textContent = err.message; }
        };
      });
    }

    async function api(path, params = {}, opts = {}, retried = false) {
      const u = new URL('api/' + path, BASE);
      for (const [k, v] of Object.entries(params)) u.searchParams.set(k, v);
      const r = await fetch(u, { credentials: 'same-origin' });
      if (r.status === 401 && !retried) { await ensureLogin(); return api(path, params, opts, true); }
      if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || r.statusText);
      return opts.text ? r.text() : r.json();
    }

    async function apiPost(path, body, retried = false) {
      const r = await fetch(new URL('api/' + path, BASE), {
        method: 'POST', credentials: 'same-origin', keepalive: true,
        headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
      });
      if (r.status === 401 && !retried) { await ensureLogin(); return apiPost(path, body, true); }
      if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || r.statusText);
      return r.json();
    }
    // watch progress is stored on the server (shared with the app / other browsers);
    // GM storage is only a fallback
    const pushProgress = (body) => apiPost('progress', body).catch(() => {});

    // ------------------------------------------------------------ browse: data
    const BR = { libs: [], data: {}, me: null, ctx: null };
    const coverUrl = (key) => key ? new URL('api/cover/' + key, BASE).href : '';
    const rawUrl = (path) => { const u = new URL('api/raw', BASE); u.searchParams.set('path', path); return u.href; };
    const libType = (id) => (BR.libs.find((l) => l.id === id) || {}).type;
    const typeIcon = { movies: '🎬', tv: '📺', music: '🎵', videos: '📁' };

    async function loadLibs() {
      try { BR.libs = (await api('libraries')).libraries; }
      catch { // server < 1.4: one flat list
        BR.libs = [{ id: '_legacy', name: 'Files', type: 'videos', count: 0 }];
      }
      renderNav();
    }

    async function libData(id, force) {
      if (id === '_all') { // every music library the user can see, merged
        const ds = await Promise.all(BR.libs.filter((l) => l.type === 'music').map((l) => libData(l.id, force).catch(() => null)));
        const items = [], edits = {};
        ds.forEach((d) => { if (d) { items.push(...d.items); Object.assign(edits, d.edits || {}); } });
        return { items, edits };
      }
      if (!BR.data[id] || force) {
        if (id === '_legacy') {
          const files = (await api('list')).files;
          BR.data[id] = { items: files.map((f) => Object.assign({ added: f.mtime }, f)) };
        } else {
          BR.data[id] = await api('lib/' + encodeURIComponent(id));
        }
        BR.data[id].loaded = Date.now();
      }
      return BR.data[id];
    }

    function setItemPos(path, pos) {
      for (const d of Object.values(BR.data)) {
        const it = d.items && d.items.find((x) => x.path === path);
        if (it) { it.pos = pos; it.watched = Math.floor(Date.now() / 1000); }
      }
    }

    // Two separate sides: Videos (movies / TV / folders + the video player) and
    // Music (all music libraries merged + its own player).
    BR.mode = lsGet('mode', 'videos');
    const canDownload = () => !!(BR.me && (BR.me.admin || BR.me.downloader));
    function modeOf(h) {
      if (/^#\/downloads/.test(h)) return BR.mode;
      if (/^#\/(music|album|artist)(\/|$)/.test(h)) return 'music';
      const m = h.match(/^#\/lib\/([^/]+)/);
      if (m && libType(decodeURIComponent(m[1])) === 'music') return 'music';
      return 'videos';
    }
    function renderNav() {
      const cur = location.hash || '#/';
      const music = BR.mode === 'music';
      const a = (href, label, on, n) => `<a href="${href}" class="${on ? 'on' : ''}">${label}${n ? `<span class="smkv-n">${n}</span>` : ''}</a>`;
      const musicCount = BR.libs.filter((l) => l.type === 'music').reduce((t, l) => t + (l.count || 0), 0);
      let html = `<div class="smkv-modes"><a href="#/" class="${music ? '' : 'on'}">🎬 Videos</a><a href="#/music" class="${music ? 'on' : ''}">🎵 Music</a></div>`;
      if (!music) {
        html += a('#/', '🏠 Home', cur === '#/') + BR.libs.filter((l) => l.type !== 'music').map((l) =>
          a(`#/lib/${encodeURIComponent(l.id)}`, `${typeIcon[l.type] || '📁'} ${esc(l.name)}${l.owner ? `<small class="smkv-own">${esc(ownerTag(l).slice(3))}</small>` : ''}`, cur.startsWith('#/lib/' + encodeURIComponent(l.id)), l.count)).join('');
      } else {
        const t = (cur.match(/^#\/music\/?([^/]*)/) || [])[1] || '';
        html += a('#/music', '🎧 Listen now', cur === '#/music' || cur === '#/music/')
          + a('#/music/albums', '💿 Albums', t === 'albums' || cur.startsWith('#/album/'))
          + a('#/music/artists', '🎤 Artists', t === 'artists' || cur.startsWith('#/artist/'))
          + a('#/music/genres', '🏷 Genres', t === 'genres')
          + a('#/music/songs', '🎵 Songs', t === 'songs', musicCount)
          + a('#/music/now', `▶ Now playing${A.cur ? '' : ''}`, t === 'now', A.queue.length || '');
      }
      if (canDownload()) html += `<div class="smkv-navsep"></div>` + a('#/downloads', '⬇ Downloads', cur.startsWith('#/downloads'));
      $('#smkv-nav').innerHTML = html;
      drawMini();
    }
    // music keeps playing while you browse videos: a small pill in the sidebar
    function drawMini() {
      const m = $('#smkv-mini');
      if (!m) return;
      const show = BR.mode !== 'music' && A.cur;
      m.hidden = !show;
      if (show) {
        m.querySelector('b').textContent = A.cur.title || A.cur.name;
        m.querySelector('div span').textContent = A.cur.artist || '';
        m.querySelector('button').textContent = A.el.paused ? '▶' : '❚❚';
      }
    }

    // ------------------------------------------------------------ browse: router
    const view = $('#smkv-view'), toolbar = $('#smkv-toolbar');
    let searchQ = '';
    function setToolbar(html, onSearch) {
      toolbar.innerHTML = `<input id="smkv-q" type="search" placeholder="Search…" value="${esc(searchQ)}" autocomplete="off">${html || ''}`;
      const q = $('#smkv-q');
      q.oninput = () => { searchQ = q.value; onSearch && onSearch(); };
    }
    const matchQ = (...fields) => {
      const words = searchQ.toLowerCase().split(/\s+/).filter(Boolean);
      const hay = fields.filter(Boolean).join(' ').toLowerCase();
      return words.every((w) => hay.includes(w));
    };

    async function route() {
      BR.mode = modeOf(location.hash || '#/');
      lsSet('mode', BR.mode);
      document.body.classList.toggle('smkv-music-mode', BR.mode === 'music');
      document.body.classList.toggle('smkv-video-mode', BR.mode !== 'music');
      renderNav();
      const parts = (location.hash.replace(/^#\/?/, '') || '').split('/').map(decodeURIComponent);
      view.innerHTML = '<div class="smkv-dim">Loading…</div>';
      try {
        if (!parts[0]) return await homeView();
        if (parts[0] === 'music') {
          if (!parts[1]) return await musicHome();
          if (parts[1] === 'now') return nowView();
          return await musicView('_all', parts[1], parts[2]);
        }
        if (parts[0] === 'downloads') return await downloadsView();
        if (parts[0] === 'lib') {
          const t = libType(parts[1]);
          if (t === 'movies') return await moviesView(parts[1], parts[2] || '');
          if (t === 'tv') return await showsView(parts[1], parts[2] || '');
          if (t === 'music') return await musicView(parts[1], parts[2] || 'albums', parts[3]);
          return await filesView(parts[1]);
        }
        if (parts[0] === 'show') return await showView(parts[1], parts.slice(2).join('/'));
        if (parts[0] === 'album') return await albumView(parts[1], parts.slice(2).join('/'));
        if (parts[0] === 'artist') return await artistView(parts[1], parts.slice(2).join('/'));
        view.innerHTML = '<div class="smkv-dim">Not found</div>';
      } catch (e) {
        view.innerHTML = `<div class="smkv-dim">Error: ${esc(e.message)}</div>`;
      }
    }
    window.addEventListener('hashchange', () => { searchQ = ''; route(); });

    // ------------------------------------------------------------ browse: shared bits
    const progressBar = (it) => it.pos && it.duration ? `<div class="smkv-pbar"><i style="width:${Math.min(100, it.pos / it.duration * 100).toFixed(1)}%"></i></div>` : '';
    function posterCard(o) {
      return `<div class="smkv-card" data-k="${esc(o.key)}">
        <div class="smkv-poster${o.square ? ' sq' : ''}${o.wide ? ' wide' : ''}">${o.img ? `<img loading="lazy" src="${esc(o.img)}" alt="">` : `<span>${esc(o.title)}</span>`}${o.badge ? `<em>${esc(o.badge)}</em>` : ''}${o.bar || ''}</div>
        <div class="smkv-ct">${esc(o.title)}</div><div class="smkv-cs">${esc(o.sub || '')}</div></div>`;
    }
    function bindCards(root, fn) {
      root.querySelectorAll('.smkv-card').forEach((c) => c.onclick = () => fn(c.dataset.k));
    }
    const genreOptions = (genres, cur) => `<select id="smkv-genre"><option value="">All genres</option>${
      [...genres].sort().map((g) => `<option ${g === cur ? 'selected' : ''}>${esc(g)}</option>`).join('')}</select>`;

    // what to show for one video item (movie / episode / file)
    function itemLabel(it, d) {
      if (it.movieId && d && d.movies && d.movies[it.movieId]) return d.movies[it.movieId].title;
      if (it.show && d && d.shows && d.shows[it.show]) {
        const sh = d.shows[it.show];
        return `${sh.title} · S${String(it.season).padStart(2, '0')}E${String(it.episode).padStart(2, '0')}${it.episodeTitle ? ' · ' + it.episodeTitle : ''}`;
      }
      return it.title || it.name;
    }

    // ------------------------------------------------------------ home
    async function homeView() {
      setToolbar('', null);
      toolbar.querySelector('#smkv-q').style.display = 'none';
      const videoLibs = BR.libs.filter((l) => l.type !== 'music');
      const all = await Promise.all(videoLibs.map((l) => libData(l.id).then((d) => ({ l, d })).catch(() => null)));
      let html = '';
      const cont = [];
      for (const x of all.filter(Boolean)) {
        if (x.l.type === 'music') continue;
        for (const it of x.d.items) if (it.pos > 0) cont.push({ it, x });
      }
      cont.sort((a, b) => (b.it.watched || 0) - (a.it.watched || 0));
      if (cont.length) {
        html += `<h3 class="smkv-h">Continue watching</h3><div class="smkv-row">${cont.slice(0, 20).map(({ it, x }) => {
          const m = it.movieId && x.d.movies ? x.d.movies[it.movieId] : null;
          const sh = it.show && x.d.shows ? x.d.shows[it.show] : null;
          return posterCard({ key: 'p:' + it.path, title: m ? m.title : sh ? sh.title : (it.title || it.name),
            sub: sh ? `S${it.season}E${it.episode} · ${fmtTime(it.pos)}` : fmtTime(it.pos), img: (sh && it.still) || (m && m.backdrop) || (sh && sh.backdrop) || '', bar: progressBar(it), wide: true });
        }).join('')}</div>`;
      }
      for (const x of all.filter(Boolean)) {
        const items = [...x.d.items].sort((a, b) => b.added - a.added);
        let cards = '';
        if (x.l.type === 'movies') {
          const seen = new Set();
          cards = items.filter((it) => { const k = it.movieId || it.path; if (seen.has(k)) return false; seen.add(k); return true; }).slice(0, 16)
            .map((it) => { const m = it.movieId ? x.d.movies[it.movieId] : null; return posterCard({ key: 'm:' + x.l.id + ':' + (it.movieId || it.path), title: m ? m.title : it.title, sub: String((m && m.year) || it.year || ''), img: m && m.poster }); }).join('');
        } else if (x.l.type === 'tv') {
          const seen = new Set();
          cards = items.filter((it) => { if (seen.has(it.show)) return false; seen.add(it.show); return true; }).slice(0, 16)
            .map((it) => { const sh = x.d.shows[it.show] || {}; return posterCard({ key: 's:' + x.l.id + ':' + it.show, title: sh.title || it.title, sub: 'New episodes', img: sh.poster }); }).join('');
        } else if (x.l.type === 'music') {
          const seen = new Set();
          cards = items.filter((it) => { const k = albumKey(it); if (seen.has(k)) return false; seen.add(k); return true; }).slice(0, 16)
            .map((it) => posterCard({ key: 'a:' + x.l.id + ':' + albumKey(it), title: it.album || '(no album)', sub: it.albumArtist || it.artist, img: coverUrl(it.cover), square: true })).join('');
        } else {
          cards = items.slice(0, 16).map((it) => posterCard({ key: 'f:' + it.path, title: it.name, sub: it.dir || '', img: '' })).join('');
        }
        if (cards) html += `<h3 class="smkv-h">Recently added · <a href="#/lib/${encodeURIComponent(x.l.id)}">${esc(x.l.name)}</a>${x.l.owner ? `<small class="smkv-own">${x.l.owner === BR.me.user ? 'your library' : 'from ' + esc(x.l.owner)}</small>` : ''}</h3><div class="smkv-row">${cards}</div>`;
      }
      view.innerHTML = html || `<div class="smkv-dim">${videoLibs.length ? 'Nothing here yet.' : 'No libraries yet — an admin can add them in the dashboard.'}</div>`;
      bindCards(view, (k) => {
        const [kind, lib, ...rest] = k.split(':');
        const id = rest.join(':');
        if (kind === 'm') return movieDetail(lib, id);
        if (kind === 's') return (location.hash = `#/show/${encodeURIComponent(lib)}/${encodeURIComponent(id)}`);
        if (kind === 'a') return (location.hash = `#/album/${encodeURIComponent(lib)}/${encodeURIComponent(id)}`);
        if (kind === 'f' || kind === 'p') return playVideo(lib + (id ? ':' + id : ''));
      });
    }

    // ------------------------------------------------------------ movies
    async function moviesView(lib, genre) {
      const d = await libData(lib);
      const groups = new Map(); // movieId|path → {meta, items}
      for (const it of d.items) {
        const k = it.movieId ? 'id' + it.movieId : it.path;
        if (!groups.has(k)) groups.set(k, { key: it.movieId || it.path, meta: it.movieId ? d.movies[it.movieId] : null, items: [] });
        groups.get(k).items.push(it);
      }
      const genres = new Set();
      groups.forEach((g) => (g.meta?.genres || []).forEach((x) => genres.add(x)));
      const sortSel = lsGet('sort:' + lib, 'added');
      setToolbar(`${genreOptions(genres, genre)}<select id="smkv-sort">
          <option value="added">Recently added</option><option value="title">Title</option><option value="year">Year</option><option value="rating">Rating</option></select>`, draw);
      $('#smkv-sort').value = sortSel;
      $('#smkv-genre').onchange = (e) => (location.hash = `#/lib/${encodeURIComponent(lib)}/${encodeURIComponent(e.target.value)}`);
      $('#smkv-sort').onchange = (e) => { lsSet('sort:' + lib, e.target.value); draw(); };
      function draw() {
        const sort = $('#smkv-sort').value;
        let list = [...groups.values()].filter((g) => (!genre || (g.meta?.genres || []).includes(genre)) &&
          matchQ(g.meta?.title, g.meta?.originalTitle, g.items[0].title, g.items[0].name, String(g.meta?.year || g.items[0].year || ''), (g.meta?.cast || []).map((c) => c.name).join(' '), g.meta?.director));
        const title = (g) => (g.meta?.title || g.items[0].title || '').toLowerCase();
        const cmp = {
          added: (a, b) => Math.max(...b.items.map((i) => i.added)) - Math.max(...a.items.map((i) => i.added)),
          title: (a, b) => title(a).localeCompare(title(b)),
          year: (a, b) => (b.meta?.year || b.items[0].year || 0) - (a.meta?.year || a.items[0].year || 0),
          rating: (a, b) => (b.meta?.rating || 0) - (a.meta?.rating || 0),
        }[sort];
        list.sort(cmp);
        view.innerHTML = list.length ? `<div class="smkv-grid">${list.map((g) => {
          const it = g.items.find((i) => i.pos) || g.items[0];
          return posterCard({ key: String(g.key), title: g.meta?.title || it.title || it.name, sub: [g.meta?.year || it.year, g.meta?.rating ? '★ ' + g.meta.rating.toFixed(1) : ''].filter(Boolean).join(' · '),
            img: g.meta?.poster, bar: progressBar(it), badge: g.items.length > 1 ? g.items.length + ' versions' : '' });
        }).join('')}</div>` : '<div class="smkv-dim">No movies</div>';
        bindCards(view, (k) => movieDetail(lib, k));
      }
      draw();
    }

    function castRow(cast) {
      return cast && cast.length ? `<div class="smkv-cast">${cast.map((c) => `<div><div class="smkv-face">${c.photo ? `<img loading="lazy" src="${esc(c.photo)}">` : esc(c.name[0] || '?')}</div><b>${esc(c.name)}</b><span>${esc(c.role || '')}</span></div>`).join('')}</div>` : '';
    }

    function detailModal(html, bind) {
      const m = $('#smkv-detail');
      m.innerHTML = `<div class="smkv-dbox"><button class="smkv-x" title="Close">✕</button>${html}</div>`;
      m.classList.add('show');
      const close = () => m.classList.remove('show');
      m.querySelector('.smkv-x').onclick = close;
      m.onclick = (e) => { if (e.target === m) close(); };
      bind && bind(m, close);
      return close;
    }

    async function movieDetail(lib, key) {
      const d = await libData(lib);
      const items = d.items.filter((it) => String(it.movieId || it.path) === String(key));
      if (!items.length) return;
      const m = items[0].movieId ? d.movies[items[0].movieId] : null;
      const t = m?.title || items[0].title || items[0].name;
      detailModal(`
        ${m?.backdrop ? `<div class="smkv-hero" style="background-image:url('${esc(m.backdrop)}')"></div>` : ''}
        <div class="smkv-dhead">
          ${m?.poster ? `<img class="smkv-dposter" src="${esc(m.poster)}">` : ''}
          <div>
            <h2>${esc(t)}</h2>
            ${m?.originalTitle ? `<div class="smkv-dim2">${esc(m.originalTitle)}</div>` : ''}
            <div class="smkv-facts">${[m?.year || items[0].year, m?.runtime ? m.runtime + ' min' : '', m?.rating ? '★ ' + m.rating.toFixed(1) : ''].filter(Boolean).map(esc).join(' · ')}</div>
            <div class="smkv-chips">${(m?.genres || []).map((g) => `<a href="#/lib/${encodeURIComponent(lib)}/${encodeURIComponent(g)}">${esc(g)}</a>`).join('')}</div>
            ${m?.director ? `<div class="smkv-dim2">Director: ${esc(m.director)}</div>` : ''}
          </div>
        </div>
        ${m?.overview ? `<p class="smkv-ov">${esc(m.overview)}</p>` : ''}
        ${castRow(m?.cast)}
        <div class="smkv-files">${items.map((it) => `<div class="smkv-file" data-p="${esc(it.path)}">
          <button class="smkv-play">${it.pos ? '▶ Resume ' + fmtTime(it.pos) : '▶ Play'}</button>
          ${it.pos ? '<button class="smkv-restart" title="Start from the beginning">↺</button>' : ''}
          <span>${esc(it.name)}<br><small>${fmtSize(it.size)}${it.dir ? ' · ' + esc(it.dir) : ''}</small></span>
          ${BR.me && BR.me.offline ? `<a class="smkv-del smkv-save" href="${esc(new URL('api/download?path=' + encodeURIComponent(it.path), BASE).href)}" title="Save to this computer" download>⬇</a>` : ''}
          ${canDelete(lib) ? '<button class="smkv-del" title="Delete this file from the server">🗑</button>' : ''}</div>`).join('')}</div>
        ${libOf(lib).owner ? `<div class="smkv-dim2" style="margin-top:8px">📦 From ${libOf(lib).owner === BR.me.user ? 'your' : esc(libOf(lib).owner) + "'s"} library “${esc(libOf(lib).name)}”</div>` : ''}
        ${lib !== '_legacy' ? '<button class="smkv-sharebtn">📤 Send to a friend</button>' : ''}
        ${canEdit() && lib !== '_legacy' ? `<div class="smkv-admin-row">${m && m.id > 0 ? `TMDB #${m.id}` : m ? 'Edited manually' : 'Not matched'} · <a href="#" class="smkv-fix">✎ Edit / fix match…</a></div>` : ''}`,
        (root, close) => {
          root.querySelectorAll('.smkv-file').forEach((row) => {
            row.querySelector('.smkv-play').onclick = () => { close(); playVideo(row.dataset.p); };
            const r = row.querySelector('.smkv-restart');
            if (r) r.onclick = () => { close(); playVideo(row.dataset.p, { fromStart: true }); };
            const sv = row.querySelector('.smkv-save');
            if (sv) sv.onclick = (e) => e.stopPropagation();
            const del = row.querySelector('.smkv-del:not(.smkv-save)');
            if (del) del.onclick = async () => { if (await deleteFiles([row.dataset.p], `“${t}” (${row.querySelector('span').firstChild.textContent})`)) close(); };
          });
          const sb = root.querySelector('.smkv-sharebtn');
          if (sb) sb.onclick = () => { close(); shareDialog({ path: items[0].path, title: t, sub: String(m?.year || items[0].year || ''), image: m?.poster || '', kind: 'video' }); };
          const fix = root.querySelector('.smkv-fix');
          if (fix) fix.onclick = (e) => {
            e.preventDefault(); close();
            editDialog({ lib, title: t, search: 'movie', query: items[0].title || t, year: items[0].year || m?.year, target: { path: items[0].path }, keys: items.map((i) => i.path),
              fields: { title: m?.title || items[0].title || '', year: m?.year || items[0].year || '', genres: (m?.genres || []).join(', '), overview: m?.overview || '', director: m?.director || '', poster: m?.poster || '', backdrop: m?.backdrop || '' } });
          };
        });
    }


    // ------------------------------------------------------------ metadata editing (admins & editors)
    const canEdit = () => !!(BR.me && (BR.me.admin || BR.me.editor));
    const libOf = (id) => BR.libs.find((l) => l.id === id) || {};
    // only your own personal libraries (admins: everything)
    const canDelete = (lib) => !!(BR.me && lib !== '_legacy' && (BR.me.admin || (libOf(lib).owner && libOf(lib).owner === BR.me.user)));
    const ownerTag = (l) => !l.owner ? '' : l.owner === (BR.me && BR.me.user) ? ' · mine' : ' · ' + l.owner;
    async function deleteFiles(paths, label) {
      if (!confirm(`Delete ${label} from the server?\n\nThe file${paths.length > 1 ? 's are' : ' is'} removed from disk — this cannot be undone.`)) return false;
      try {
        const r = await fetch(new URL('api/files/delete', BASE), { method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ paths }) });
        if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || r.statusText);
        toast('Deleted', 2500);
        const lib = paths[0].split('/')[0];
        setTimeout(async () => { await libData(lib, true).catch(() => {}); await loadLibs(); route(); }, 1500);
        return true;
      } catch (e) { toast(e.message, 5000); return false; }
    }
    const FIELD_LABELS = {
      title: 'Title', year: 'Year', overview: 'Plot / overview', genres: 'Genres (comma separated)', poster: 'Poster image URL',
      backdrop: 'Backdrop image URL', director: 'Director', showTitle: 'Show title (moves the episode)', season: 'Season', episode: 'Episode',
      episodeTitle: 'Episode title', episodeOverview: 'Episode plot', still: 'Episode image URL', artist: 'Artist', album: 'Album',
      albumArtist: 'Album artist', track: 'Track #', disc: 'Disc #', cover: 'Cover image URL',
    };
    const LONG = { overview: true, episodeOverview: true };

    async function reloadAfterEdit(lib, msg) {
      toast(msg || 'Saved — updating…', 2500);
      await new Promise((r) => setTimeout(r, 1600));
      await libData(lib, true);
      route();
    }

    // opts: {lib, title, search: 'movie'|'tv'|null, target: {path}|{show}, keys: [edit keys], fields: {name: current value}, editsOf(key)}
    function editDialog(o) {
      const keys = o.keys;
      const d = BR.data[o.lib] || {};
      const prev = (k) => Object.assign({}, (d.edits || {})[k] || {});
      const initial = Object.assign({}, o.fields);
      detailModal(`
        <h2 style="margin-top:22px">Edit · ${esc(o.title)}</h2>
        ${o.search ? `<h3 class="smkv-h">Find the right ${o.search === 'tv' ? 'show' : 'movie'} on TMDB</h3>
          <div class="smkv-esearch"><input id="eq" value="${esc(o.query || o.title)}" placeholder="Title"><input id="ey" value="${esc(o.year || '')}" placeholder="Year" style="width:80px">
          <button id="ego" class="smkv-primary">Search</button><input id="eid" placeholder="or TMDB ID" style="width:110px"><button id="eidgo">Use ID</button></div>
          <div id="eres" class="smkv-eres"></div>` : ''}
        <h3 class="smkv-h">${o.search ? 'Or edit the details yourself' : 'Details'}</h3>
        <form class="smkv-eform">${Object.keys(o.fields).map((f) => `<label>${esc(FIELD_LABELS[f] || f)}${LONG[f]
          ? `<textarea name="${f}" rows="4">${esc(o.fields[f] ?? '')}</textarea>` : `<input name="${f}" value="${esc(o.fields[f] ?? '')}">`}</label>`).join('')}</form>
        <div class="smkv-erow"><button class="smkv-primary" id="esave">Save</button><button id="ereset" title="Forget manual changes and use the automatic data again">Reset to automatic</button>
          <span class="smkv-dim2">${keys.length > 1 ? `Applies to ${keys.length} files.` : ''}</span></div>`,
        (root, close) => {
          const match = async (id) => {
            try { await apiPost('meta/match', Object.assign({ lib: o.lib, tmdbId: id }, o.target)); close(); reloadAfterEdit(o.lib, 'Matched — fetching details…'); }
            catch (e) { toast(e.message, 5000); }
          };
          if (o.search) {
            const go = async () => {
              const box = root.querySelector('#eres');
              box.innerHTML = '<div class="smkv-dim">Searching…</div>';
              try {
                const r = await api('meta/search', { lib: o.lib, q: root.querySelector('#eq').value, year: root.querySelector('#ey').value });
                box.innerHTML = r.results.length ? r.results.map((x) => `<div class="smkv-eitem" data-id="${x.id}">
                  ${x.poster ? `<img src="${esc(x.poster)}">` : '<div class="smkv-enop"></div>'}
                  <div><b>${esc(x.title)}</b> ${x.year ? `(${x.year})` : ''}${x.originalTitle ? `<div class="smkv-dim2">${esc(x.originalTitle)}</div>` : ''}
                  <p>${esc((x.overview || '').slice(0, 180))}</p></div></div>`).join('') : '<div class="smkv-dim">No results — try another title or the year.</div>';
                box.querySelectorAll('.smkv-eitem').forEach((el) => el.onclick = () => match(+el.dataset.id));
              } catch (e) { box.innerHTML = `<div class="smkv-dim">${esc(e.message)}</div>`; }
            };
            root.querySelector('#ego').onclick = go;
            root.querySelector('#eq').onkeydown = (e) => { if (e.key === 'Enter') go(); };
            root.querySelector('#eidgo').onclick = () => { const id = parseInt(root.querySelector('#eid').value, 10); if (id > 0) match(id); };
          }
          root.querySelector('#esave').onclick = async () => {
            const form = root.querySelector('.smkv-eform');
            const changed = {};
            for (const f of Object.keys(o.fields)) {
              const v = form.elements[f].value.trim();
              if (v !== String(initial[f] ?? '').trim()) changed[f] = v;
            }
            if (!Object.keys(changed).length) { close(); return; }
            try {
              for (const k of keys) {
                const fields = Object.assign(prev(k), changed);
                for (const [f, v] of Object.entries(fields)) if (v === '') delete fields[f];
                await apiPost('meta/edit', { lib: o.lib, key: k, fields });
              }
              close(); reloadAfterEdit(o.lib);
            } catch (e) { toast(e.message, 5000); }
          };
          root.querySelector('#ereset').onclick = async () => {
            try {
              if (o.search && o.target) await apiPost('meta/match', Object.assign({ lib: o.lib, tmdbId: 0 }, o.target));
              for (const k of keys) {
                const left = prev(k);
                for (const f of Object.keys(o.fields)) delete left[f];
                await apiPost('meta/edit', { lib: o.lib, key: k, fields: Object.keys(left).length ? left : null });
              }
              close(); reloadAfterEdit(o.lib, 'Reset — rescanning…');
            } catch (e) { toast(e.message, 5000); }
          };
        });
    }

    async function fixMatch(lib, target, close) {
      const v = prompt('TMDB ID for this title (the number in themoviedb.org/movie/<ID> or /tv/<ID>).\nLeave empty to go back to automatic matching.', '');
      if (v === null) return;
      const id = parseInt(v, 10) || 0;
      try {
        await apiPost('admin/match', Object.assign({ lib, tmdbId: id }, target));
        toast('Saved — rescanning…', 3000);
        close && close();
        setTimeout(async () => { await libData(lib, true); route(); }, 2500);
      } catch (e) { toast(e.message, 5000); }
    }

    // ------------------------------------------------------------ tv
    async function showsView(lib, genre) {
      const d = await libData(lib);
      const shows = new Map();
      for (const it of d.items) {
        if (!shows.has(it.show)) shows.set(it.show, { key: it.show, meta: d.shows[it.show] || { title: it.title }, eps: [] });
        shows.get(it.show).eps.push(it);
      }
      const genres = new Set();
      shows.forEach((s) => (s.meta.genres || []).forEach((g) => genres.add(g)));
      setToolbar(genreOptions(genres, genre), draw);
      $('#smkv-genre').onchange = (e) => (location.hash = `#/lib/${encodeURIComponent(lib)}/${encodeURIComponent(e.target.value)}`);
      function draw() {
        const list = [...shows.values()].filter((s) => (!genre || (s.meta.genres || []).includes(genre)) && matchQ(s.meta.title, s.meta.originalTitle))
          .sort((a, b) => Math.max(...b.eps.map((e) => e.added)) - Math.max(...a.eps.map((e) => e.added)));
        view.innerHTML = list.length ? `<div class="smkv-grid">${list.map((s) => posterCard({ key: s.key, title: s.meta.title, img: s.meta.poster,
          sub: `${s.eps.length} episode${s.eps.length > 1 ? 's' : ''}${s.meta.year ? ' · ' + s.meta.year : ''}` })).join('')}</div>` : '<div class="smkv-dim">No shows</div>';
        bindCards(view, (k) => (location.hash = `#/show/${encodeURIComponent(lib)}/${encodeURIComponent(k)}`));
      }
      draw();
    }

    const epSort = (a, b) => (a.season - b.season) || (a.episode - b.episode) || a.name.localeCompare(b.name);
    function nextUp(eps) {
      const sorted = [...eps].sort(epSort);
      const inProg = sorted.filter((e) => e.pos > 0).sort((a, b) => (b.watched || 0) - (a.watched || 0))[0];
      if (inProg) return inProg;
      const lastWatched = sorted.map((e, i) => ({ e, i })).filter((x) => x.e.watched).sort((a, b) => b.e.watched - a.e.watched)[0];
      if (lastWatched) return sorted[lastWatched.i + 1] || sorted[0];
      return sorted[0];
    }

    async function showView(lib, key) {
      const d = await libData(lib);
      const eps = d.items.filter((it) => it.show === key).sort(epSort);
      const sh = d.shows[key] || { title: eps[0]?.title || key };
      const seasons = [...new Set(eps.map((e) => e.season))].sort((a, b) => a - b);
      const next = nextUp(eps);
      let season = lsGet('season:' + lib + ':' + key, next ? next.season : seasons[0]);
      if (!seasons.includes(season)) season = seasons[0];
      setToolbar(`<a class="smkv-back" href="#/lib/${encodeURIComponent(lib)}">← ${esc((BR.libs.find((l) => l.id === lib) || {}).name || 'Back')}</a>`, draw);
      function draw() {
        view.innerHTML = `
          <div class="smkv-showhead"${sh.backdrop ? ` style="background-image:linear-gradient(90deg,#0d0f13 30%,rgba(13,15,19,.6)),url('${esc(sh.backdrop)}')"` : ''}>
            ${sh.poster ? `<img class="smkv-dposter" src="${esc(sh.poster)}">` : ''}
            <div><h2>${esc(sh.title)}</h2>
              <div class="smkv-facts">${[sh.year, sh.rating ? '★ ' + sh.rating.toFixed(1) : '', eps.length + ' episodes'].filter(Boolean).join(' · ')}</div>
              <div class="smkv-chips">${(sh.genres || []).map((g) => `<a href="#/lib/${encodeURIComponent(lib)}/${encodeURIComponent(g)}">${esc(g)}</a>`).join('')}</div>
              ${sh.overview ? `<p class="smkv-ov">${esc(sh.overview)}</p>` : ''}
              ${next ? `<button class="smkv-primary" id="smkv-next">▶ ${next.pos ? 'Resume' : 'Play'} S${next.season}E${next.episode}${next.episodeTitle ? ' · ' + esc(next.episodeTitle) : ''}</button>` : ''}
              ${canEdit() ? `<div class="smkv-admin-row">${sh.tmdbId ? 'TMDB #' + sh.tmdbId : 'Not matched'} · <a href="#" class="smkv-fix">✎ Edit show / fix match…</a></div>` : ''}
            </div>
          </div>
          ${castRow(sh.cast)}
          <div class="smkv-tabs">${seasons.map((s) => `<button data-s="${s}" class="${s === season ? 'on' : ''}">${s ? 'Season ' + s : 'Other'}</button>`).join('')}</div>
          <div class="smkv-eps">${eps.filter((e) => e.season === season && matchQ(e.episodeTitle, e.name, e.episodeOverview)).map((e) => `
            <div class="smkv-ep" data-p="${esc(e.path)}">
              <div class="smkv-still">${e.still ? `<img loading="lazy" src="${esc(e.still)}">` : '<span>▶</span>'}${progressBar(e)}</div>
              <div style="flex:1"><b>${e.episode ? 'E' + e.episode + ' · ' : ''}${esc(e.episodeTitle || e.name)}</b>${canEdit() ? `<button class="smkv-epedit" data-p="${esc(e.path)}" title="Edit episode">✎</button>` : ''}${canDelete(lib) ? `<button class="smkv-epedit smkv-epdel" data-p="${esc(e.path)}" title="Delete this episode file">🗑</button>` : ''}
                <div class="smkv-dim2">${[e.duration ? fmtTime(e.duration) : '', e.pos ? 'watched to ' + fmtTime(e.pos) : ''].filter(Boolean).join(' · ')}</div>
                ${e.episodeOverview ? `<p>${esc(e.episodeOverview)}</p>` : ''}</div>
            </div>`).join('')}</div>`;
        view.querySelectorAll('.smkv-tabs button').forEach((b) => b.onclick = () => { season = +b.dataset.s; lsSet('season:' + lib + ':' + key, season); draw(); });
        view.querySelectorAll('.smkv-ep').forEach((r) => r.onclick = () => playVideo(r.dataset.p));
        const n = view.querySelector('#smkv-next');
        if (n) n.onclick = () => playVideo(next.path);
        const fix = view.querySelector('.smkv-fix');
        if (fix) fix.onclick = (ev) => {
          ev.preventDefault();
          editDialog({ lib, title: sh.title, search: 'tv', query: eps[0]?.title || sh.title, year: sh.year, target: { show: key }, keys: ['show:' + key],
            fields: { title: sh.title || '', year: sh.year || '', genres: (sh.genres || []).join(', '), overview: sh.overview || '', poster: sh.poster || '', backdrop: sh.backdrop || '' } });
        };
        view.querySelectorAll('.smkv-epdel').forEach((b) => b.onclick = (ev) => {
          ev.stopPropagation();
          const e = eps.find((x) => x.path === b.dataset.p);
          deleteFiles([e.path], `S${e.season}E${e.episode} (${e.name})`);
        });
        view.querySelectorAll('.smkv-epedit:not(.smkv-epdel)').forEach((b) => b.onclick = (ev) => {
          ev.stopPropagation();
          const e = eps.find((x) => x.path === b.dataset.p);
          editDialog({ lib, title: e.name, keys: [e.path], fields: { showTitle: e.title || sh.title, season: e.season, episode: e.episode, episodeTitle: e.episodeTitle || '', episodeOverview: e.episodeOverview || '', still: e.still || '' } });
        });
      }
      draw();
    }

    // ------------------------------------------------------------ music
    const albumKey = (it) => (it.albumArtist || it.artist || '') + '\u0001' + (it.album || it.dir || '');
    const trackSort = (a, b) => (a.disc || 0) - (b.disc || 0) || (a.track || 0) - (b.track || 0) || a.name.localeCompare(b.name);

    function albumsOf(items) {
      const m = new Map();
      for (const it of items) {
        const k = albumKey(it);
        if (!m.has(k)) m.set(k, { key: k, album: it.album || it.dir || '(no album)', artist: it.albumArtist || it.artist || 'Unknown artist', cover: it.cover, year: it.year, genres: new Set(), tracks: [], added: 0 });
        const a = m.get(k);
        a.tracks.push(it); a.added = Math.max(a.added, it.added); if (!a.cover && it.cover) a.cover = it.cover; if (!a.year && it.year) a.year = it.year;
        (it.genres || []).forEach((g) => a.genres.add(g));
      }
      return [...m.values()];
    }

    const mbase = (lib) => lib === '_all' ? '#/music' : '#/lib/' + encodeURIComponent(lib);
    async function musicView(lib, tab, arg) {
      const d = await libData(lib);
      const tabs = { albums: 'Albums', artists: 'Artists', genres: 'Genres', songs: 'Songs' };
      setToolbar(`<div class="smkv-tabs inline">${Object.entries(tabs).map(([k, v]) => `<a href="${mbase(lib)}/${k}" class="${k === tab ? 'on' : ''}">${v}</a>`).join('')}</div>
        <button id="smkv-shuffle" title="Shuffle everything">🔀 Shuffle all</button>`, draw);
      $('#smkv-shuffle').onclick = () => playQueue(shuffle([...d.items]), 0);
      const albums = albumsOf(d.items);
      function draw() {
        if (tab === 'albums' || (tab === 'genres' && arg)) {
          const list = albums.filter((a) => (!arg || a.genres.has(arg)) && matchQ(a.album, a.artist, String(a.year || ''))).sort((a, b) => b.added - a.added);
          view.innerHTML = (arg ? `<h3 class="smkv-h">${esc(arg)}</h3>` : '') + (list.length ? `<div class="smkv-grid sq">${list.map((a) => posterCard({ key: a.key, title: a.album, sub: a.artist + (a.year ? ' · ' + a.year : ''), img: coverUrl(a.cover), square: true })).join('')}</div>` : '<div class="smkv-dim">No albums</div>');
          bindCards(view, (k) => (location.hash = `#/album/${encodeURIComponent(lib)}/${encodeURIComponent(k)}`));
        } else if (tab === 'artists') {
          const artists = new Map();
          for (const a of albums) {
            if (!artists.has(a.artist)) artists.set(a.artist, { name: a.artist, cover: a.cover, albums: 0, tracks: 0 });
            const x = artists.get(a.artist); x.albums++; x.tracks += a.tracks.length; if (!x.cover) x.cover = a.cover;
          }
          const list = [...artists.values()].filter((a) => matchQ(a.name)).sort((a, b) => a.name.localeCompare(b.name));
          view.innerHTML = `<div class="smkv-grid sq">${list.map((a) => posterCard({ key: a.name, title: a.name, sub: `${a.albums} album${a.albums > 1 ? 's' : ''} · ${a.tracks} songs`, img: coverUrl(a.cover), square: true })).join('')}</div>`;
          view.querySelectorAll('.smkv-poster').forEach((p) => p.classList.add('round'));
          bindCards(view, (k) => (location.hash = `#/artist/${encodeURIComponent(lib)}/${encodeURIComponent(k)}`));
        } else if (tab === 'genres') {
          const g = new Map();
          for (const a of albums) for (const x of (a.genres.size ? a.genres : ['Unknown'])) g.set(x, (g.get(x) || 0) + 1);
          view.innerHTML = `<div class="smkv-chips big">${[...g.entries()].filter(([n]) => matchQ(n)).sort().map(([n, c]) => `<a href="${mbase(lib)}/genres/${encodeURIComponent(n)}">${esc(n)} <small>${c}</small></a>`).join('')}</div>`;
        } else {
          const list = d.items.filter((t) => matchQ(t.title, t.artist, t.album)).sort((a, b) => (a.artist || '').localeCompare(b.artist || '') || (a.album || '').localeCompare(b.album || '') || trackSort(a, b));
          view.innerHTML = trackTable(list, true, lib);
          bindTracks(view, list, lib);
        }
      }
      draw();
    }

    function trackTable(list, showAlbum, editLib) {
      return `<table class="smkv-tracks">${list.map((t, i) => `<tr data-i="${i}" class="${A.cur && A.cur.path === t.path ? 'on' : ''}">
        <td class="n">${t.track || ''}</td><td><b>${esc(t.title || t.name)}</b>${showAlbum ? `<div class="smkv-dim2">${esc(t.artist || '')}${t.album ? ' · ' + esc(t.album) : ''}</div>` : (t.artist && t.artist !== t.albumArtist ? `<div class="smkv-dim2">${esc(t.artist)}</div>` : '')}</td>
        <td class="d">${t.duration ? fmtTime(t.duration) : ''}</td>${editLib && canEdit() ? `<td class="e"><button class="smkv-tedit" data-i="${i}" title="Edit tags">✎</button></td>` : ''}</tr>`).join('')}</table>`;
    }
    function bindTracks(root, list, lib) {
      root.querySelectorAll('.smkv-tracks tr').forEach((tr) => tr.onclick = () => playQueue(list, +tr.dataset.i));
      root.querySelectorAll('.smkv-tedit').forEach((b) => b.onclick = (ev) => {
        ev.stopPropagation();
        const t = list[+b.dataset.i];
        editDialog({ lib: lib && lib !== '_all' ? lib : t.path.split('/')[0], title: t.title || t.name, keys: [t.path],
          fields: { title: t.title || '', artist: t.artist || '', album: t.album || '', albumArtist: t.albumArtist || '', track: t.track || '', disc: t.disc || '', year: t.year || '', genres: (t.genres || []).join(', ') } });
      });
    }

    async function albumView(lib, key) {
      const d = await libData(lib);
      const a = albumsOf(d.items).find((x) => x.key === key);
      setToolbar(`<a class="smkv-back" href="${mbase(lib)}/albums">← Albums</a>`, draw);
      if (!a) { view.innerHTML = '<div class="smkv-dim">Album not found</div>'; return; }
      a.tracks.sort(trackSort);
      function draw() {
        const total = a.tracks.reduce((s, t) => s + (t.duration || 0), 0);
        view.innerHTML = `<div class="smkv-albumhead">
            <div class="smkv-poster sq big">${a.cover ? `<img src="${esc(coverUrl(a.cover))}">` : `<span>${esc(a.album)}</span>`}</div>
            <div><div class="smkv-dim2">ALBUM</div><h2>${esc(a.album)}</h2>
              <div class="smkv-facts"><a href="#/artist/${encodeURIComponent(lib)}/${encodeURIComponent(a.artist)}">${esc(a.artist)}</a>${a.year ? ' · ' + a.year : ''} · ${a.tracks.length} songs · ${fmtTime(total)}</div>
              <div class="smkv-chips">${[...a.genres].map((g) => `<a href="${mbase(lib)}/genres/${encodeURIComponent(g)}">${esc(g)}</a>`).join('')}</div>
              <button class="smkv-primary" id="smkv-playall">▶ Play</button> <button id="smkv-shufall">🔀 Shuffle</button>
              ${canEdit() ? '<button id="smkv-aedit">✎ Edit album</button>' : ''}</div></div>
          ${trackTable(a.tracks.filter((t) => matchQ(t.title, t.artist)), false, lib)}`;
        const ae = $('#smkv-aedit');
        if (ae) ae.onclick = () => editDialog({ lib: lib !== '_all' ? lib : a.tracks[0].path.split('/')[0], title: a.album, keys: a.tracks.map((t) => t.path),
          fields: { album: a.album, albumArtist: a.artist, year: a.year || '', genres: [...a.genres].join(', '), cover: '' } });
        bindTracks(view, a.tracks.filter((t) => matchQ(t.title, t.artist)), lib);
        $('#smkv-playall').onclick = () => playQueue(a.tracks, 0);
        $('#smkv-shufall').onclick = () => playQueue(shuffle([...a.tracks]), 0);
      }
      draw();
    }

    async function artistView(lib, name) {
      const d = await libData(lib);
      const albums = albumsOf(d.items).filter((a) => a.artist === name).sort((a, b) => (b.year || 0) - (a.year || 0));
      const songs = d.items.filter((t) => t.artist === name || t.albumArtist === name).sort((a, b) => (a.album || '').localeCompare(b.album || '') || trackSort(a, b));
      setToolbar(`<a class="smkv-back" href="${mbase(lib)}/artists">← Artists</a>`, draw);
      function draw() {
        view.innerHTML = `<div class="smkv-albumhead"><div class="smkv-poster sq big round">${albums[0]?.cover ? `<img src="${esc(coverUrl(albums[0].cover))}">` : `<span>${esc(name)}</span>`}</div>
            <div><div class="smkv-dim2">ARTIST</div><h2>${esc(name)}</h2><div class="smkv-facts">${albums.length} albums · ${songs.length} songs</div>
            <button class="smkv-primary" id="smkv-playall">▶ Play</button> <button id="smkv-shufall">🔀 Shuffle</button></div></div>
          <h3 class="smkv-h">Albums</h3><div class="smkv-grid sq">${albums.map((a) => posterCard({ key: a.key, title: a.album, sub: String(a.year || ''), img: coverUrl(a.cover), square: true })).join('')}</div>
          <h3 class="smkv-h">Songs</h3>${trackTable(songs.filter((t) => matchQ(t.title, t.album)), true, lib)}`;
        bindCards(view, (k) => (location.hash = `#/album/${encodeURIComponent(lib)}/${encodeURIComponent(k)}`));
        bindTracks(view, songs.filter((t) => matchQ(t.title, t.album)), lib);
        $('#smkv-playall').onclick = () => playQueue(songs, 0);
        $('#smkv-shufall').onclick = () => playQueue(shuffle([...songs]), 0);
      }
      draw();
    }

    // ------------------------------------------------------------ music: listen now
    async function musicHome() {
      setToolbar('<button id="smkv-shuffle" title="Shuffle every song">🔀 Shuffle all</button>', null);
      toolbar.querySelector('#smkv-q').style.display = 'none';
      if (!BR.libs.some((l) => l.type === 'music')) {
        view.innerHTML = '<div class="smkv-dim">No music library yet — an admin can add one (type <b>Music</b>) in the dashboard.</div>';
        $('#smkv-shuffle').hidden = true;
        return;
      }
      const d = await libData('_all');
      $('#smkv-shuffle').onclick = () => { playQueue(shuffle([...d.items]), 0); location.hash = '#/music/now'; };
      const albums = albumsOf(d.items).sort((a, b) => b.added - a.added);
      const artists = new Map();
      for (const a of albums) if (!artists.has(a.artist)) artists.set(a.artist, a);
      const genres = new Map();
      for (const a of albums) for (const g of a.genres) genres.set(g, (genres.get(g) || 0) + 1);
      let html = '';
      if (A.cur) {
        const img = coverUrl(A.cur.cover);
        html += `<a class="smkv-npbanner" href="#/music/now"><div class="smkv-poster sq">${img ? `<img src="${esc(img)}">` : '<span>♪</span>'}</div>
          <div><div class="smkv-dim2">${A.el.paused ? 'PAUSED' : 'NOW PLAYING'}</div><b>${esc(A.cur.title || A.cur.name)}</b><div class="smkv-dim2">${esc(A.cur.artist || '')}</div></div></a>`;
      }
      html += `<h3 class="smkv-h">Recently added · <a href="#/music/albums">all albums</a></h3><div class="smkv-row">${albums.slice(0, 18).map((a) =>
        posterCard({ key: 'a:' + a.key, title: a.album, sub: a.artist, img: coverUrl(a.cover), square: true })).join('')}</div>`;
      html += `<h3 class="smkv-h">Artists · <a href="#/music/artists">all</a></h3><div class="smkv-row smkv-artists">${[...artists.values()].slice(0, 18).map((a) =>
        posterCard({ key: 'r:' + a.artist, title: a.artist, img: coverUrl(a.cover), square: true })).join('')}</div>`;
      if (genres.size) html += `<h3 class="smkv-h">Genres</h3><div class="smkv-chips big">${[...genres.entries()].sort((a, b) => b[1] - a[1]).slice(0, 30).map(([n, c]) =>
        `<a href="#/music/genres/${encodeURIComponent(n)}">${esc(n)} <small>${c}</small></a>`).join('')}</div>`;
      view.innerHTML = html;
      view.querySelectorAll('.smkv-artists .smkv-poster').forEach((p) => p.classList.add('round'));
      bindCards(view, (k) => {
        const id = k.slice(2);
        location.hash = k[0] === 'a' ? `#/album/_all/${encodeURIComponent(id)}` : `#/artist/_all/${encodeURIComponent(id)}`;
      });
    }

    // ------------------------------------------------------------ music: now playing
    function nowView() {
      setToolbar('', null);
      toolbar.querySelector('#smkv-q').style.display = 'none';
      if (!A.cur) { view.innerHTML = '<div class="smkv-dim">Nothing is playing — pick an album, an artist or a song.</div>'; return; }
      view.innerHTML = `<div class="smkv-now">
          <div class="smkv-poster sq big" id="smkv-np-cover"></div>
          <div class="smkv-now-info"><div class="smkv-dim2" id="smkv-np-state">NOW PLAYING</div><h2 id="smkv-np-title"></h2><div class="smkv-facts" id="smkv-np-sub"></div>
            <input id="smkv-np-seek" type="range" min="0" max="0" step="0.1" value="0">
            <div class="smkv-np-times"><span id="smkv-np-t">0:00</span><span id="smkv-np-d">0:00</span></div>
            <div class="smkv-np-btns"><button id="smkv-np-shuf" title="Shuffle what's left">🔀</button><button id="smkv-np-prev" title="Previous">⏮</button>
              <button id="smkv-np-pp" class="big" title="Play/Pause">▶</button><button id="smkv-np-next" title="Next">⏭</button><button id="smkv-np-rep"></button></div>
          </div></div>
        <h3 class="smkv-h">Up next <button id="smkv-np-clear" title="Remove the songs after this one">Clear upcoming</button></h3><div id="smkv-np-queue"></div>`;
      $('#smkv-np-pp').onclick = aToggle;
      $('#smkv-np-prev').onclick = aPrev;
      $('#smkv-np-next').onclick = () => aNext(true);
      $('#smkv-np-rep').onclick = () => { $('#smkv-arep').click(); drawNow(); };
      $('#smkv-np-shuf').onclick = () => { A.queue = A.queue.slice(0, A.idx + 1).concat(shuffle(A.queue.slice(A.idx + 1))); drawNow(); toast('Shuffled'); };
      $('#smkv-np-clear').onclick = () => { A.queue = A.queue.slice(0, A.idx + 1); drawNow(); renderNav(); };
      const sk = $('#smkv-np-seek');
      sk.addEventListener('input', () => { A.dragging = true; $('#smkv-np-t').textContent = fmtTime(+sk.value); });
      sk.addEventListener('change', () => { A.dragging = false; aSeek(+sk.value); });
      drawNow();
    }
    function drawNow() {
      const title = $('#smkv-np-title');
      if (!title || !A.cur) return;
      const t = A.cur, img = coverUrl(t.cover);
      $('#smkv-np-cover').innerHTML = img ? `<img src="${esc(img)}">` : '<span>♪</span>';
      title.textContent = t.title || t.name;
      const artist = t.artist || t.albumArtist;
      $('#smkv-np-sub').innerHTML = [artist ? `<a href="#/artist/_all/${encodeURIComponent(t.albumArtist || artist)}">${esc(artist)}</a>` : '',
        t.album ? `<a href="#/album/_all/${encodeURIComponent(albumKey(t))}">${esc(t.album)}</a>` : '', t.year || ''].filter(Boolean).join(' · ');
      $('#smkv-np-state').textContent = A.el.paused ? 'PAUSED' : 'NOW PLAYING';
      $('#smkv-np-pp').textContent = A.el.paused ? '▶' : '❚❚';
      const rb = $('#smkv-np-rep');
      rb.textContent = A.repeat === 'one' ? '🔂' : '🔁'; rb.classList.toggle('on', A.repeat !== 'off'); rb.title = 'Repeat: ' + A.repeat;
      const q = $('#smkv-np-queue');
      q.innerHTML = A.queue.length ? trackTable(A.queue, true) : '';
      q.querySelectorAll('.smkv-tracks tr').forEach((tr, i) => {
        tr.classList.toggle('on', i === A.idx);
        tr.classList.toggle('played', i < A.idx);
        tr.onclick = () => { A.idx = i; loadTrack(0); };
      });
      const on = q.querySelector('tr.on');
      if (on && !drawNow.scrolled) { on.scrollIntoView({ block: 'nearest' }); drawNow.scrolled = true; }
    }

    // ------------------------------------------------------------ downloads
    async function downloadsView() {
      setToolbar('', null);
      toolbar.querySelector('#smkv-q').style.display = 'none';
      if (!canDownload()) { view.innerHTML = '<div class="smkv-dim">Ask an admin for the downloader role.</div>'; return; }
      let d = await api('downloads');
      const libs = [...d.libraries].sort((a, b) => ((a.type === 'music') === (BR.mode === 'music') ? 0 : 1) - ((b.type === 'music') === (BR.mode === 'music') ? 0 : 1));
      view.innerHTML = `<h2 class="smkv-pageh">Downloads</h2>
        <form id="smkv-dlf" class="smkv-dlform">
          <input name="source" placeholder="https://… link or magnet:?xt=…" autocomplete="off">
          <label class="smkv-tfile" title="Upload a .torrent file"><input type="file" name="file" accept=".torrent,application/x-bittorrent"><span>📎 .torrent</span></label>
          <select name="lib">${libs.map((l) => `<option value="${esc(l.id)}">${typeIcon[l.type] || '📁'} ${esc(l.name)}${esc(ownerTag(l))}</option>`).join('')}</select>
          <input name="subdir" list="smkv-dldirs" placeholder="folder (optional)" autocomplete="off"><datalist id="smkv-dldirs"></datalist>
          <button class="smkv-primary">⬇ Download</button>
        </form>
        <div class="smkv-dim2" id="smkv-dlrt"></div>
        <div id="smkv-dllist"></div>
        <h3 class="smkv-h">My libraries <span class="smkv-dim2" id="smkv-myuse"></span></h3>
        <div id="smkv-mylibs"></div>
        <form id="smkv-mynew" class="smkv-dlform">
          <input name="name" placeholder="New library name" autocomplete="off" style="flex:1;min-width:180px">
          <select name="type"><option value="movies">🎬 Movies</option><option value="tv">📺 TV series</option><option value="music">🎵 Music</option><option value="videos">📁 Other videos</option></select>
          <label class="smkv-check"><input type="checkbox" name="shared"> Share with everyone</label>
          <button>＋ Create</button>
        </form>`;
      const f = $('#smkv-dlf');
      const loadDirs = async () => {
        try { const r = await api('downloads/dirs', { lib: f.lib.value }); $('#smkv-dldirs').innerHTML = r.dirs.map((x) => `<option value="${esc(x)}">`).join(''); } catch (_) {}
      };
      f.lib.onchange = loadDirs; loadDirs();
      f.file.onchange = () => { f.querySelector('.smkv-tfile span').textContent = f.file.files[0] ? '📎 ' + f.file.files[0].name : '📎 .torrent'; };
      const send = (force) => {
        if (f.file.files[0]) {
          const fd = new FormData(); fd.append('file', f.file.files[0]); fd.append('lib', f.lib.value); fd.append('subdir', f.subdir.value);
          if (force) fd.append('force', '1');
          return fetch(new URL('api/downloads/torrent', BASE), { method: 'POST', body: fd, credentials: 'same-origin' });
        }
        return fetch(new URL('api/downloads', BASE), { method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ source: f.source.value.trim(), lib: f.lib.value, subdir: f.subdir.value, force }) });
      };
      f.onsubmit = async (e) => {
        e.preventDefault();
        if (!f.file.files[0] && !f.source.value.trim()) return toast('Paste a link or choose a .torrent file');
        try {
          let r = await send(false);
          if (r.status === 409 || r.status === 422) {
            // looks like a duplicate: 409 = may download anyway, 422 = can't (already in rtorrent)
            const j = await r.json().catch(() => ({}));
            const items = ((j.duplicate && j.duplicate.items) || []).slice(0, 6).map((i) => `• ${i.libName} · ${i.name}`).join('\n');
            if (!j.canForce) { toast(j.error || 'Already downloaded', 6000); return; }
            if (!confirm(`${j.error}${items ? '\n\n' + items : ''}\n\nDownload anyway?`)) return;
            r = await send(true);
          }
          if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || r.statusText);
          f.source.value = ''; f.file.value = ''; f.file.onchange();
          toast('Download added'); refresh();
        } catch (x) { toast(x.message, 5000); }
      };
      async function drawMine() {
        let m;
        try { m = await api('my/libraries'); } catch (_) { return; }
        const u = m.usage || {};
        $('#smkv-myuse').textContent = `· ${u.items || 0}${m.maxItems ? '/' + m.maxItems : ''} items · ${fmtSize(u.bytes || 0)}${m.maxBytes ? ' / ' + fmtSize(m.maxBytes) : ''}`;
        $('#smkv-mylibs').innerHTML = m.libraries.length ? m.libraries.map((l) => `<div class="smkv-dl" data-id="${esc(l.id)}">
            <div class="smkv-dlf2"><span><b>${typeIcon[l.type] || '📁'} ${esc(l.name)}</b> <span class="smkv-dim2">${l.count} items · ${fmtSize(l.size || 0)}</span></span>
              <label class="smkv-check"><input type="checkbox" data-a="share" ${l.shared ? 'checked' : ''}> Shared</label>
              <a href="#/lib/${encodeURIComponent(l.id)}">Open</a><button data-a="scan">Scan</button><button data-a="del">Delete…</button></div></div>`).join('')
          : '<div class="smkv-dim2">Create a library to download into your own space. Private libraries are only visible to you; shared ones are visible to everyone, labelled with your name.</div>';
        $('#smkv-mylibs').querySelectorAll('[data-a]').forEach((el) => {
          const id = el.closest('.smkv-dl').dataset.id, l = m.libraries.find((x) => x.id === id);
          const call = async (method, path, body) => {
            const r = await fetch(new URL('api/' + path, BASE), { method, credentials: 'same-origin', headers: { 'Content-Type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
            if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || r.statusText);
          };
          const act = async () => {
            try {
              if (el.dataset.a === 'share') { await call('PUT', 'my/libraries/' + encodeURIComponent(id), { shared: el.checked }); toast(el.checked ? 'Shared with everyone' : 'Now private'); }
              else if (el.dataset.a === 'scan') { await call('POST', `my/libraries/${encodeURIComponent(id)}/scan`); toast('Scanning…'); }
              else {
                if (!confirm(`Delete the library “${l.name}”?`)) return;
                const files = confirm(`Also delete its ${l.count} files from the server (${fmtSize(l.size || 0)})?\n\nOK = delete files · Cancel = keep them on disk`);
                await call('DELETE', `my/libraries/${encodeURIComponent(id)}${files ? '?files=1' : ''}`); toast('Library deleted');
              }
              await loadLibs(); drawMine();
            } catch (x) { toast(x.message, 5000); if (el.dataset.a === 'share') el.checked = !el.checked; }
          };
          if (el.tagName === 'INPUT') el.onchange = act; else el.onclick = act;
        });
      }
      $('#smkv-mynew').onsubmit = async (e) => {
        e.preventDefault();
        const f = e.target;
        if (!f.name.value.trim()) return toast('Name the library');
        try {
          const r = await fetch(new URL('api/my/libraries', BASE), { method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ name: f.name.value.trim(), type: f.type.value, shared: f.shared.checked }) });
          const j = await r.json().catch(() => ({}));
          if (!r.ok) throw new Error(j.error || r.statusText);
          f.reset(); toast('Library created'); await loadLibs();
          d = await api('downloads');
          $('#smkv-dlf').lib.innerHTML = d.libraries.map((l) => `<option value="${esc(l.id)}">${typeIcon[l.type] || '📁'} ${esc(l.name)}${esc(ownerTag(l))}</option>`).join('');
          $('#smkv-dlf').lib.value = j.id; loadDirs(); drawMine();
        } catch (x) { toast(x.message, 5000); }
      };
      drawMine();
      const state = { queued: 'Queued', downloading: 'Downloading', done: 'Done', failed: 'Failed', canceled: 'Canceled' };
      const tName = { checking: 'Checking', downloading: 'Downloading', seeding: 'Seeding', paused: 'Paused', stopped: 'Stopped', finished: 'Finished (not seeding)', removed: 'Removed from rtorrent' };
      const torBtns = (st) => [
        (st === 'downloading' || st === 'seeding') && '<button data-a="pause">⏸ Pause</button>',
        st === 'paused' && '<button data-a="resume">▶ Resume</button>',
        st === 'seeding' && '<button data-a="stop">⏹ Stop seeding</button>',
        (st === 'downloading' || st === 'paused') && '<button data-a="stop">⏹ Stop</button>',
        st === 'finished' && '<button data-a="start">🌱 Seed</button>',
        st === 'stopped' && '<button data-a="start">▶ Start</button>',
      ].filter(Boolean).join('');
      const limTxt = (r, h) => [r > 0 ? `ratio ${r}` : '', h > 0 ? `${h} h` : ''].filter(Boolean).join(' or ') || 'no limit';
      const seedTxt = (j) => j.seedRatio === -1 && j.seedHours === -1 ? 'seeds without limit'
        : (j.seedRatio || j.seedHours) ? `seed limit: ${limTxt(Math.max(j.seedRatio || 0, 0), Math.max(j.seedHours || 0, 0))}` : 'seed limit: server default';
      function torMore(j) {
        detailModal(`<h2>Torrent</h2><div class="smkv-dim2">${esc(j.name || j.source)}</div>
          <div style="margin:12px 0"><button class="smkv-btn2" id="smkv-rc">🔁 Recheck files</button></div>
          <h3 style="margin:14px 0 6px">Seeding limit</h3>
          <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center">
            <select id="smkv-sm" class="smkv-inp" style="width:170px;flex:none"><option value="def">Server default</option><option value="none">No limit</option><option value="own">Custom</option></select>
            <span id="smkv-so">ratio <input id="smkv-sr" class="smkv-inp" type="number" min="0" step="0.1" style="width:80px"> or <input id="smkv-sh" class="smkv-inp" type="number" min="0" style="width:80px"> h</span>
            <button class="smkv-btn2" id="smkv-sv">Save</button></div>
          <h3 style="margin:14px 0 6px">Trackers & files</h3><div id="smkv-det" class="smkv-dim2" style="max-height:240px;overflow:auto">Loading…</div>`,
          async (root, close) => {
            const q = (x) => root.querySelector(x), mode = q('#smkv-sm');
            mode.value = j.seedRatio === -1 && j.seedHours === -1 ? 'none' : (j.seedRatio || j.seedHours ? 'own' : 'def');
            q('#smkv-sr').value = j.seedRatio > 0 ? j.seedRatio : ''; q('#smkv-sh').value = j.seedHours > 0 ? j.seedHours : '';
            const sync = () => { q('#smkv-so').style.display = mode.value === 'own' ? '' : 'none'; };
            mode.onchange = sync; sync();
            q('#smkv-rc').onclick = async () => { close(); try { await apiPost(`downloads/${encodeURIComponent(j.id)}/torrent`, { action: 'recheck' }); refresh(); } catch (x) { toast(x.message, 5000); } };
            q('#smkv-sv').onclick = async () => {
              let ratio = 0, hours = 0;
              if (mode.value === 'none') { ratio = -1; hours = -1; }
              if (mode.value === 'own') { ratio = +q('#smkv-sr').value || -1; hours = +q('#smkv-sh').value || -1; }
              try { await apiPost(`downloads/${encodeURIComponent(j.id)}/seed`, { ratio, hours }); close(); toast('Seeding limit saved'); refresh(); } catch (x) { toast(x.message, 5000); }
            };
            try {
              const dd = await api(`downloads/${encodeURIComponent(j.id)}/detail`);
              q('#smkv-det').innerHTML = dd.trackers.map((t) => `<div>📡 ${esc(t.url)} · ${t.seeds} seeds · ${t.leechers} leechers${t.failed ? ` · ${t.failed} failed` : ''}</div>`).join('')
                + dd.files.map((f) => `<div>📄 ${esc(f.path)} · ${fmtSize(f.size)} · ${(f.progress * 100).toFixed(0)}%</div>`).join('');
            } catch (x) { q('#smkv-det').textContent = x.message; }
          });
      }
      function removeDlg(j) {
        const running = j.state === 'queued' || j.state === 'downloading';
        return new Promise((res) => detailModal(`<h2>${running ? 'Cancel' : 'Remove'} ${j.kind === 'torrent' ? 'torrent' : 'download'}</h2><div class="smkv-dim2">${esc(j.name || j.source)}</div>
          <label style="display:flex;gap:8px;align-items:center;margin-top:12px"><input type="radio" name="smkv-rm" value="keep" checked> Remove ${j.kind === 'torrent' ? 'the torrent' : 'from the list'} only — keep the files</label>
          <label style="display:flex;gap:8px;align-items:center;margin-top:6px"><input type="radio" name="smkv-rm" value="data"> …and <b style="color:#ff7a7a">delete ${running ? 'what was downloaded so far' : 'the files'}</b></label>
          <div style="margin-top:14px;display:flex;gap:8px;justify-content:flex-end"><button class="smkv-btn2" id="smkv-rmno">Cancel</button><button class="smkv-btn2" id="smkv-rmok" style="background:#a33">Remove</button></div>`,
          (root, close) => {
            root.querySelector('#smkv-rmno').onclick = () => { close(); res(null); };
            root.querySelector('#smkv-rmok').onclick = () => { const v = root.querySelector('input[name=smkv-rm]:checked').value; close(); res(v === 'data'); };
          }));
      }
      function draw() {
        const t = d.torrent || {};
        $('#smkv-dlrt').innerHTML = t.ok ? `Torrents go to rtorrent ${esc(t.version || '')}` : `⚠ Torrents unavailable: ${esc(t.error || '')} — http(s) links still work`;
        const names = Object.fromEntries(d.libraries.map((l) => [l.id, l.name]));
        $('#smkv-dllist').innerHTML = d.jobs.length ? d.jobs.map((j) => {
          const pct = j.size > 0 ? Math.min(100, j.done / j.size * 100) : 0;
          const mine = BR.me.admin || j.user === BR.me.user;
          const tor = j.kind === 'torrent' && j.hash && j.tstate && j.tstate !== 'removed';
          const st = j.kind === 'torrent' && j.tstate ? tName[j.tstate] || j.tstate : state[j.state] || j.state;
          return `<div class="smkv-dl ${esc(j.state)}" data-id="${esc(j.id)}">
            <div class="smkv-dlh"><b>${esc(j.name || j.source)}</b><span class="smkv-dim2">${j.kind} → ${esc(names[j.lib] || j.lib)}${j.subdir ? ' / ' + esc(j.subdir) : ''} · ${esc(j.user)}</span></div>
            <div class="smkv-pbar big"><i style="width:${pct.toFixed(1)}%"></i></div>
            <div class="smkv-dlf2"><span class="smkv-dim2">${st}${j.size > 0 ? ` · ${fmtSize(j.done)} / ${fmtSize(j.size)}` : ''}${j.rate > 0 ? ` · ↓ ${fmtSize(j.rate)}/s` : ''}${j.up > 0 ? ` · ↑ ${fmtSize(j.up)}/s` : ''}${j.kind === 'torrent' && j.tstate ? `<br>ratio <b>${(j.ratio || 0).toFixed(2)}</b> · ↑ ${fmtSize(j.uploaded || 0)}${tor ? ` · ${j.peers || 0} peers (${j.seeds || 0} seeds)` : ''} · ${seedTxt(j)}${j.autoStopped ? ` · <span style="color:#f5a623">auto-stopped: ${esc(j.autoStopped)}</span>` : ''}` : ''}${j.error ? ` · <span class="smkv-err">${esc(j.error)}</span>` : ''}${j.dupes && j.dupes.length ? `<br><span style="color:#f5a623" title="${esc(j.dupes.join('\n'))}">⚠ Also in the library: ${esc(j.dupes.slice(0, 2).join(' · '))}${j.dupes.length > 2 ? ` +${j.dupes.length - 2}` : ''}</span>` : ''}</span>
              ${mine ? `${j.kind === 'http' && (j.state === 'failed' || j.state === 'canceled') ? '<button data-a="retry">Retry</button>' : ''}${tor ? torBtns(j.tstate) + '<button data-a="more" title="Recheck, seeding limit, trackers & files">⋯</button>' : ''}<button data-a="rm">${j.state === 'queued' || j.state === 'downloading' ? 'Cancel' : 'Remove'}</button>` : ''}</div></div>`;
        }).join('') : '<div class="smkv-dim">No downloads yet.</div>';
        $('#smkv-dllist').querySelectorAll('button[data-a]').forEach((b) => b.onclick = async () => {
          const j = d.jobs.find((x) => x.id === b.closest('.smkv-dl').dataset.id);
          try {
            const a = b.dataset.a;
            if (a === 'retry') {
              await apiPost(`downloads/${encodeURIComponent(j.id)}/retry`, {});
            } else if (a === 'more') {
              return torMore(j);
            } else if (a !== 'rm') {
              await apiPost(`downloads/${encodeURIComponent(j.id)}/torrent`, { action: a });
            } else {
              const files = await removeDlg(j);
              if (files === null) return;
              const r = await fetch(new URL(`api/downloads/${encodeURIComponent(j.id)}${files ? '?files=1' : ''}`, BASE), { method: 'DELETE', credentials: 'same-origin' });
              if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || r.statusText);
            }
            refresh();
          } catch (x) { toast(x.message, 5000); }
        });
      }
      let timer = null;
      async function refresh() {
        clearTimeout(timer);
        if (!location.hash.startsWith('#/downloads')) return;
        try { d = await api('downloads'); draw(); } catch (_) {}
        if (d.jobs.some((j) => j.state === 'queued' || j.state === 'downloading' || j.seeding || j.tstate === 'checking' || j.tstate === 'paused')) timer = setTimeout(refresh, 3000);
      }
      draw();
      if (d.jobs.some((j) => j.state === 'queued' || j.state === 'downloading')) timer = setTimeout(refresh, 3000);
    }

    // ------------------------------------------------------------ plain folders
    async function filesView(lib) {
      const d = await libData(lib);
      setToolbar('', draw);
      function draw() {
        const files = d.items.filter((f) => matchQ(f.path, f.name)).sort((a, b) => (a.dir || '').localeCompare(b.dir || '') || a.name.localeCompare(b.name));
        let html = '', lastDir = null;
        for (const f of files) {
          if (f.dir !== lastDir) { lastDir = f.dir; html += `<div class="smkv-dir">${esc(f.dir || '/')}</div>`; }
          html += `<div class="smkv-item" data-path="${esc(f.path)}"><div class="smkv-name">${esc(f.name)}${canDelete(lib) ? '<button class="smkv-epedit smkv-fdel" title="Delete this file">🗑</button>' : ''}</div>
            <div class="smkv-sub">${fmtSize(f.size)}${f.pos ? ` · <span class="smkv-resume">⏵ ${fmtTime(f.pos)}</span>` : ''}</div></div>`;
        }
        view.innerHTML = html || '<div class="smkv-dim">No files</div>';
        view.querySelectorAll('.smkv-item').forEach((el) => el.onclick = () => playVideo(el.dataset.path));
        view.querySelectorAll('.smkv-fdel').forEach((b) => b.onclick = (ev) => { ev.stopPropagation(); const p = b.closest('.smkv-item').dataset.path; deleteFiles([p], p.split('/').pop()); });
      }
      draw();
    }

    // ------------------------------------------------------------ video overlay
    async function playVideo(path, opts = {}) {
      let item = null, lib = path.split('/')[0];
      for (const [id, d] of Object.entries(BR.data)) {
        const it = d.items && d.items.find((x) => x.path === path);
        if (it) { item = it; lib = id; break; }
      }
      const d = BR.data[lib];
      const f = { path, name: item ? itemLabel(item, d) : path.split('/').pop() };
      // what to play next (tv): following episode of the same show
      BR.ctx = null;
      if (item && item.show && d) {
        const eps = d.items.filter((x) => x.show === item.show).sort(epSort);
        const i = eps.findIndex((x) => x.path === path);
        if (i >= 0 && eps[i + 1]) BR.ctx = { next: eps[i + 1], lib };
      }
      if (!A.el.paused) A.el.pause();
      $('#smkv-watch').classList.add('show');
      document.body.classList.add('smkv-watching');
      await openFile(f, opts);
    }

    function closeVideo() {
      savePos(true);
      stopServerStream();
      if (wp) { wp.pause(); wp.destroy(); wp = null; S.engFile = null; }
      media = video;
      S.file = null; S.info = null; S.cues = []; renderSubs(true);
      $('#smkv-watch').classList.remove('show');
      document.body.classList.remove('smkv-watching');
      if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
      document.title = 'StreamMKV';
      route();
      heartbeat(true); // no longer watching
    }
    $('#smkv-close').onclick = closeVideo;

    // ------------------------------------------------------------ announcements
    const AN = { items: [], shown: new Set() };
    const linkify = (t) => esc(t).replace(/https?:\/\/[^\s<]+[^\s<.,;:!?)\]'"]/g, (u) => `<a href="${u}" target="_blank" rel="noopener noreferrer">${u}</a>`).replace(/\n/g, '<br>');
    const annIcon = { info: 'ℹ️', warning: '⚠️', important: '🔴' };
    async function loadAnnouncements() {
      let d;
      try { d = await api('announcements'); } catch { return; }
      AN.items = d.items || [];
      const unread = AN.items.filter((a) => !a.read);
      const badge = $('#smkv-ann i');
      badge.hidden = !unread.length; badge.textContent = unread.length;
      // important ones pop up (one at a time); the rest go to the banner
      const imp = unread.find((a) => a.level === 'important' && !AN.shown.has(a.id));
      if (imp && !$('#smkv-detail').classList.contains('show')) { AN.shown.add(imp.id); annDialog(imp); }
      drawAnnBar();
    }
    function annMarkRead(a) {
      a.read = true;
      apiPost(`announcements/${encodeURIComponent(a.id)}/read`, {}).catch(() => {});
      const n = AN.items.filter((x) => !x.read).length, badge = $('#smkv-ann i');
      badge.hidden = !n; badge.textContent = n;
      drawAnnBar();
    }
    function drawAnnBar() {
      const bar = $('#smkv-annbar');
      const unread = AN.items.filter((a) => !a.read && a.level !== 'important');
      const a = unread[0];
      bar.hidden = !a;
      if (!a) return;
      bar.className = 'lvl-' + a.level;
      bar.innerHTML = `<span>${annIcon[a.level] || 'ℹ️'}</span><div><b>${esc(a.title)}</b>${a.body ? `<div>${linkify(a.body)}</div>` : ''}</div>
        ${unread.length > 1 ? `<button data-a="all">+${unread.length - 1} more</button>` : ''}<button data-a="ok" title="Mark as read">✕</button>`;
      bar.querySelector('[data-a=ok]').onclick = () => annMarkRead(a);
      const all = bar.querySelector('[data-a=all]'); if (all) all.onclick = annList;
    }
    function annDialog(a) {
      detailModal(`<div class="smkv-ann-d lvl-${esc(a.level)}"><div class="smkv-ann-h">${annIcon[a.level] || 'ℹ️'} ${esc(a.title || 'Announcement')}</div>
        ${a.body ? `<div class="smkv-ann-b">${linkify(a.body)}</div>` : ''}
        <div class="smkv-dim2">From ${esc(a.author)} · ${new Date(a.created * 1000).toLocaleString()}</div>
        <div style="text-align:right;margin-top:16px"><button class="smkv-primary" id="smkv-annok">OK</button></div></div>`,
        (root, close) => {
          root.querySelector('.smkv-dbox').classList.add('smkv-ann-box');
          const done = () => { close(); annMarkRead(a); setTimeout(loadAnnouncements, 200); };
          root.querySelector('#smkv-annok').onclick = done;
          root.querySelector('.smkv-x').onclick = done;
        });
    }
    async function annList() {
      let d; try { d = await api('announcements', { all: 1 }); } catch (e) { toast(e.message); return; }
      const items = d.items || [];
      detailModal(`<h2 style="margin:24px 0 12px">📣 Announcements</h2>
        ${items.length ? items.map((a) => `<div class="smkv-ann-item lvl-${esc(a.level)} ${a.read ? 'read' : ''}"><div class="smkv-ann-h">${annIcon[a.level] || 'ℹ️'} ${esc(a.title || 'Announcement')}${a.pinned ? ' 📌' : ''}${a.read ? '' : ' <i class="smkv-new">new</i>'}</div>
          ${a.body ? `<div class="smkv-ann-b">${linkify(a.body)}</div>` : ''}<div class="smkv-dim2">${esc(a.author)} · ${new Date(a.created * 1000).toLocaleString()}</div></div>`).join('')
          : '<div class="smkv-dim2">Nothing right now.</div>'}
        ${items.some((a) => !a.read) ? '<div style="text-align:right;margin-top:12px"><button id="smkv-annall">Mark all as read</button></div>' : ''}`,
        (root, close) => {
          root.querySelector('.smkv-dbox').classList.add('smkv-ann-box');
          const b = root.querySelector('#smkv-annall');
          if (b) b.onclick = async () => { await apiPost('announcements/read-all', {}).catch(() => {}); close(); loadAnnouncements(); };
        });
    }
    $('#smkv-ann').onclick = annList;

    // ------------------------------------------------------------ people & chat
    const SO = { people: [], convs: [], open: null, msgs: [], es: null, hb: null, lastAct: '', hide: false };
    function myActivity() {
      if (S.file && S.info) {
        const it = Object.values(BR.data).flatMap((d) => d.items || []).find((x) => x.path === S.file.path);
        const m = it && it.movieId && BR.data[it.path.split('/')[0]]?.movies?.[it.movieId];
        const sh = it && it.show && BR.data[it.path.split('/')[0]]?.shows?.[it.show];
        return { kind: 'video', path: S.file.path, title: sh ? sh.title : (m ? m.title : S.file.name),
          sub: it && it.show ? `S${it.season}E${it.episode}${it.episodeTitle ? ' · ' + it.episodeTitle : ''}` : (m && m.year ? String(m.year) : ''),
          image: (sh && sh.poster) || (m && m.poster) || '', pos: Math.round(cur()), dur: Math.round(S.info.duration || 0) };
      }
      if (A.cur && !A.el.paused) {
        return { kind: 'music', path: A.cur.path, title: A.cur.title || A.cur.name, sub: [A.cur.artist, A.cur.album].filter(Boolean).join(' — '),
          image: A.cur.cover ? 'cover:' + A.cur.cover : '', pos: Math.round(A.el.currentTime + (A.off || 0)), dur: Math.round(A.cur.duration || 0) };
      }
      return null;
    }
    async function heartbeat(force) {
      const a = myActivity(), key = a ? a.kind + a.path + a.title : '';
      if (!force && key === SO.lastAct && heartbeat.at && Date.now() - heartbeat.at < 30000) return;
      SO.lastAct = key; heartbeat.at = Date.now();
      try { await apiPost('presence', { activity: a }); } catch (_) {}
    }
    const actImg = (img) => img.startsWith('cover:') ? coverUrl(img.slice(6)) : img;
    function actLine(a) {
      if (!a) return '';
      const t = a.kind === 'music' ? '♪ ' : '▶ ';
      return `${t}${esc(a.title)}${a.sub ? ' · ' + esc(a.sub) : ''}${a.kind === 'video' && a.dur ? ` <span class="smkv-dim2">${fmtTime(a.pos)} / ${fmtTime(a.dur)}</span>` : ''}`;
    }
    // profile pictures (initials when there's none) and the admin badge
    const AV_COLORS = ['#3b6fd6', '#2f9e74', '#b8569a', '#c9752c', '#7b5cd6', '#2e8fa8', '#b54a4a', '#5f8f2e'];
    function avatarHtml(name, size = 30, dot = null) {
      const p = SO.people.find((x) => x.name === name) || (name === BR.me.user ? { avatar: BR.me.avatar } : {});
      let h = 0; for (const ch of name) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
      const inner = p.avatar ? `<img src="${esc(new URL(`api/avatar/${encodeURIComponent(name)}?v=${p.avatar}`, BASE).href)}" alt="">`
        : `<span style="background:${AV_COLORS[h % AV_COLORS.length]};font-size:${Math.round(size * 0.42)}px">${esc((name[0] || '?').toUpperCase())}</span>`;
      return `<span class="smkv-pav" style="width:${size}px;height:${size}px">${inner}${dot === null ? '' : `<i class="smkv-pdot ${dot ? 'on' : ''}"></i>`}</span>`;
    }
    const adminBadge = (name) => (SO.people.find((x) => x.name === name) || {}).admin ? '<span class="smkv-adm" title="Admin">ADMIN</span>' : '';
    async function changeAvatar() {
      const inp = document.createElement('input');
      inp.type = 'file'; inp.accept = 'image/jpeg,image/png,image/gif';
      inp.onchange = async () => {
        const f = inp.files[0];
        if (!f) return;
        if (f.size > 10 * 1024 * 1024) return toast('Pictures can be up to 10 MB');
        const fd = new FormData(); fd.append('file', f);
        try {
          const r = await fetch(new URL('api/me/avatar', BASE), { method: 'POST', body: fd, credentials: 'same-origin' });
          const j = await r.json().catch(() => ({}));
          if (!r.ok) throw new Error(j.error || r.statusText);
          BR.me.avatar = j.avatar; toast('Profile picture updated');
          const me = SO.people.find((x) => x.name === BR.me.user); if (me) me.avatar = j.avatar;
          drawPeople(); if (!SO.open) drawConvs(); else drawMsgs();
        } catch (x) { toast(x.message, 5000); }
      };
      inp.click();
    }
    async function removeAvatar() {
      try {
        const r = await fetch(new URL('api/me/avatar', BASE), { method: 'DELETE', credentials: 'same-origin' });
        if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || r.statusText);
        BR.me.avatar = 0; const me = SO.people.find((x) => x.name === BR.me.user); if (me) me.avatar = 0;
        drawPeople(); if (!SO.open) drawConvs();
      } catch (x) { toast(x.message); }
    }
    function drawPeople() {
      const el = $('#smkv-people');
      if (!el) return;
      const others = SO.people.filter((p) => p.name !== BR.me.user);
      const on = others.filter((p) => p.online);
      el.innerHTML = `<div class="smkv-ph">People <span class="smkv-dim2">${on.length} online</span><button id="smkv-chat-open" title="Chats">💬<i id="smkv-unread" hidden></i></button></div>` +
        others.map((p) => `<div class="smkv-person ${p.online ? 'on' : ''}" data-u="${esc(p.name)}" title="${p.online ? 'Online' : p.lastSeen ? 'Last seen ' + new Date(p.lastSeen * 1000).toLocaleString() : 'Offline'}">
          ${avatarHtml(p.name, 30, p.online)}<div style="min-width:0"><b>${esc(p.name)}</b>${adminBadge(p.name)}${p.activity ? `<div class="smkv-act ${p.activity.path ? 'link' : ''}" data-p="${esc(p.activity.path || '')}" data-k="${esc(p.activity.kind)}">${actLine(p.activity)}</div>` : ''}</div></div>`).join('');
      el.querySelectorAll('.smkv-person').forEach((r) => r.onclick = (e) => {
        const act = e.target.closest('.smkv-act.link');
        if (act) { e.stopPropagation(); return openRef({ path: act.dataset.p, kind: act.dataset.k }); }
        openDM(r.dataset.u);
      });
      $('#smkv-chat-open').onclick = (e) => { e.stopPropagation(); toggleChat(); };
      drawUnread();
    }
    function drawUnread() {
      const n = SO.convs.reduce((t, c) => t + (c.unread || 0), 0), b = $('#smkv-unread');
      if (b) { b.hidden = !n; b.textContent = n > 99 ? '99+' : n; }
    }
    function startSocial() {
      if (SO.es || !BR.me || !window.EventSource) return;
      const es = SO.es = new EventSource(new URL('api/events', BASE), { withCredentials: true });
      es.addEventListener('people', (e) => { SO.people = JSON.parse(e.data); drawPeople(); });
      es.addEventListener('announcement', () => loadAnnouncements());
      es.addEventListener('open', () => loadAnnouncements()); // also catches up after a reconnect
      es.addEventListener('conversation', (e) => {
        const c = JSON.parse(e.data);
        const i = SO.convs.findIndex((x) => x.id === c.id);
        if (!c.members) SO.convs = SO.convs.filter((x) => x.id !== c.id); // removed from it
        else if (i >= 0) SO.convs[i] = c; else SO.convs.unshift(c);
        SO.convs.sort((a, b) => (b.last ? b.last.ts : b.created) - (a.last ? a.last.ts : a.created));
        drawUnread();
        if ($('#smkv-chat').classList.contains('show') && !SO.open) drawConvs();
        if (SO.open && SO.open.id === c.id) { SO.open = c; drawChatHead(); }
      });
      es.addEventListener('message', (e) => {
        const { conv, message: m } = JSON.parse(e.data);
        if (SO.open && SO.open.id === conv && $('#smkv-chat').classList.contains('show')) {
          if (!SO.msgs.some((x) => x.seq === m.seq)) { SO.msgs.push(m); drawMsgs(true); }
          apiPost(`chat/${encodeURIComponent(conv)}/read`, { seq: m.seq }).catch(() => {});
        } else if (m.from !== BR.me.user && !m.sys) {
          const c = SO.convs.find((x) => x.id === conv);
          toast(`💬 ${m.from}${c && c.kind === 'group' ? ' in ' + c.title : ''}: ${m.ref ? '📎 ' + m.ref.title : m.text}`, 6000, { label: 'Open', fn: () => openConv(conv) });
        }
      });
      api('chat').then((r) => { SO.convs = r.conversations; drawUnread(); }).catch(() => {});
      api('people').then((r) => { SO.hide = r.hideActivity; }).catch(() => {});
      heartbeat(true);
      SO.hb = setInterval(() => heartbeat(false), 15000);
      ['play', 'pause'].forEach((ev) => { A.el.addEventListener(ev, () => heartbeat(true)); }); // video: in bindMedia
    }

    // chat drawer
    function toggleChat(show) {
      const c = $('#smkv-chat'), on = show ?? !c.classList.contains('show');
      c.classList.toggle('show', on);
      if (on && !SO.open) drawConvs();
    }
    function drawConvs() {
      SO.open = null;
      const c = $('#smkv-chat');
      c.innerHTML = `<div class="smkv-ch"><b>Chats</b><span class="smkv-sp"></span><button id="smkv-newgroup">＋ Group</button><button class="smkv-x">✕</button></div>
        <div class="smkv-me">${avatarHtml(BR.me.user, 40)}<div style="flex:1;min-width:0"><b>${esc(BR.me.user)}</b>${adminBadge(BR.me.user)}
          <div><button class="smkv-link" id="smkv-avset">Change picture</button>${BR.me.avatar ? ' · <button class="smkv-link" id="smkv-avdel">Remove</button>' : ''}</div></div></div>
        <label class="smkv-check smkv-priv"><input type="checkbox" id="smkv-hideact" ${SO.hide ? 'checked' : ''}> Hide what I'm watching from others</label>
        <div class="smkv-convs">${SO.convs.length ? SO.convs.map((v) => `<div class="smkv-conv" data-id="${esc(v.id)}">
          ${v.kind === 'group' ? '<div class="smkv-av">👥</div>' : avatarHtml(v.title, 36, (SO.people.find((x) => x.name === v.title) || {}).online || false)}
          <div class="smkv-cm"><b>${esc(v.title)}${v.kind === 'group' ? '' : adminBadge(v.title)}</b><span class="smkv-dim2">${v.last ? esc((v.last.sys ? '' : v.last.from + ': ') + (v.last.ref ? '📎 ' + v.last.ref.title : v.last.text)) : 'No messages yet'}</span></div>
          ${v.unread ? `<i class="smkv-badge">${v.unread}</i>` : ''}</div>`).join('') : '<div class="smkv-dim" style="padding:16px">No chats yet — click someone in People to start one.</div>'}</div>`;
      c.querySelector('.smkv-x').onclick = () => toggleChat(false);
      c.querySelector('#smkv-newgroup').onclick = () => groupDialog();
      c.querySelector('#smkv-avset').onclick = changeAvatar;
      const avdel = c.querySelector('#smkv-avdel'); if (avdel) avdel.onclick = removeAvatar;
      c.querySelector('#smkv-hideact').onchange = async (e) => {
        try { await apiPost('me/privacy', { hideActivity: e.target.checked }); SO.hide = e.target.checked; toast(SO.hide ? "Others won't see what you play" : "Others can see what you play"); }
        catch (x) { toast(x.message); }
      };
      c.querySelectorAll('.smkv-conv').forEach((r) => r.onclick = () => openConv(r.dataset.id));
    }
    async function openDM(user) {
      try { const v = await apiPost('chat/dm', { user }); upsertConv(v); openConv(v.id); } catch (x) { toast(x.message); }
    }
    function upsertConv(v) {
      const i = SO.convs.findIndex((x) => x.id === v.id);
      if (i >= 0) SO.convs[i] = v; else SO.convs.unshift(v);
    }
    async function openConv(id) {
      toggleChat(true);
      const c = $('#smkv-chat');
      let r;
      try { r = await api(`chat/${encodeURIComponent(id)}/messages`); } catch (x) { return toast(x.message); }
      SO.open = r.conversation; SO.msgs = r.messages;
      upsertConv(r.conversation);
      c.innerHTML = `<div class="smkv-ch"><button class="smkv-back">←</button><b id="smkv-ctitle"></b><span class="smkv-sp"></span><button class="smkv-cmore" title="Group settings" hidden>⋯</button><button class="smkv-x">✕</button></div>
        <div class="smkv-msgs"></div>
        <form class="smkv-send"><input placeholder="Message…" autocomplete="off" maxlength="4000"><button>➤</button></form>`;
      c.querySelector('.smkv-back').onclick = drawConvs;
      c.querySelector('.smkv-x').onclick = () => toggleChat(false);
      c.querySelector('.smkv-cmore').onclick = () => groupDialog(SO.open);
      c.querySelector('.smkv-send').onsubmit = async (e) => {
        e.preventDefault();
        const inp = e.target.querySelector('input'), text = inp.value.trim();
        if (!text) return;
        inp.value = '';
        try { const r = await apiPost(`chat/${encodeURIComponent(id)}/messages`, { text }); if (!SO.msgs.some((x) => x.seq === r.message.seq)) { SO.msgs.push(r.message); drawMsgs(true); } }
        catch (x) { toast(x.message); inp.value = text; }
      };
      drawChatHead(); drawMsgs(true);
      c.querySelector('.smkv-send input').focus();
      if (SO.open.unread) apiPost(`chat/${encodeURIComponent(id)}/read`, { seq: SO.open.seq }).catch(() => {});
      SO.open.unread = 0; drawUnread();
    }
    function drawChatHead() {
      const t = $('#smkv-ctitle');
      if (!t || !SO.open) return;
      const p = SO.people.find((x) => x.name === SO.open.title);
      t.innerHTML = SO.open.kind === 'group' ? `👥 ${esc(SO.open.title)} <span class="smkv-dim2">${SO.open.members.length}</span>`
        : `${avatarHtml(SO.open.title, 26)} ${esc(SO.open.title)}${adminBadge(SO.open.title)} <span class="smkv-dim2">${p && p.online ? '● online' : ''}</span>`;
      $('#smkv-chat .smkv-cmore').hidden = SO.open.kind !== 'group';
    }
    function drawMsgs(scroll) {
      const box = $('#smkv-chat .smkv-msgs');
      if (!box) return;
      let lastDay = '';
      box.innerHTML = SO.msgs.map((m) => {
        const d = new Date(m.ts * 1000), day = d.toLocaleDateString();
        const sep = day !== lastDay ? `<div class="smkv-day">${esc(day)}</div>` : '';
        lastDay = day;
        if (m.sys) return sep + `<div class="smkv-sys">${esc(m.text)}</div>`;
        const mine = m.from === BR.me.user;
        const ref = m.ref ? `<div class="smkv-ref" data-p="${esc(m.ref.path)}" data-k="${esc(m.ref.kind || 'video')}">
            ${m.ref.image ? `<img src="${esc(actImg(m.ref.image))}" onerror="this.remove()">` : `<span>${m.ref.kind === 'music' ? '♪' : '🎬'}</span>`}
            <div><b>${esc(m.ref.title)}</b>${m.ref.sub ? `<small>${esc(m.ref.sub)}</small>` : ''}<em>${m.ref.kind === 'music' ? '▶ Play' : '▶ Watch'}</em></div></div>` : '';
        const body = `${!mine && SO.open.kind === 'group' ? `<small class="smkv-from">${esc(m.from)}${adminBadge(m.from)}</small>` : ''}
          ${ref}${m.text ? `<div class="smkv-bubble">${esc(m.text)}</div>` : ''}<small class="smkv-time">${d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</small>`;
        return sep + (mine ? `<div class="smkv-msg me">${body}</div>`
          : `<div class="smkv-mrow">${avatarHtml(m.from, 28)}<div class="smkv-msg">${body}</div></div>`);
      }).join('') || '<div class="smkv-dim" style="padding:16px">Say hi 👋</div>';
      box.querySelectorAll('.smkv-ref').forEach((r) => r.onclick = () => openRef({ path: r.dataset.p, kind: r.dataset.k }));
      if (scroll) box.scrollTop = box.scrollHeight;
    }
    async function openRef(ref) {
      const lib = ref.path.split('/')[0];
      if (!BR.libs.some((l) => l.id === lib)) return toast("You don't have access to that library");
      if (ref.kind === 'music') {
        try {
          const d = await libData(lib);
          const t = d.items.find((x) => x.path === ref.path);
          if (!t) return toast('That song is gone');
          playQueue([t], 0); location.hash = '#/music/now';
        } catch (x) { toast(x.message); }
        return;
      }
      toggleChat(false);
      await libData(lib).catch(() => {});
      playVideo(ref.path);
    }
    function groupDialog(conv) {
      const others = SO.people.filter((p) => p.name !== BR.me.user);
      detailModal(`<h2>${conv ? 'Group: ' + esc(conv.title) : 'New group'}</h2>
        <label class="smkv-dim2">Name</label><input id="smkv-gname" class="smkv-inp" value="${conv ? esc(conv.name || conv.title) : ''}" maxlength="80">
        <label class="smkv-dim2" style="display:block;margin-top:10px">Members</label>
        <div class="smkv-gmembers">${others.map((p) => `<label class="smkv-check"><input type="checkbox" value="${esc(p.name)}" ${conv && conv.members.includes(p.name) ? 'checked' : ''}> ${esc(p.name)}${p.online ? ' <span class="smkv-dot on"></span>' : ''}</label>`).join('')}</div>
        <div class="smkv-row" style="margin-top:14px">${conv ? '<button id="smkv-gleave" class="smkv-danger">Leave group</button>' : ''}<span class="smkv-sp"></span><button id="smkv-gsave" class="smkv-primary">${conv ? 'Save' : 'Create'}</button></div>`,
        (root, close) => {
          root.querySelector('#smkv-gsave').onclick = async () => {
            const name = root.querySelector('#smkv-gname').value.trim();
            const picked = [...root.querySelectorAll('.smkv-gmembers input:checked')].map((i) => i.value);
            try {
              if (!conv) {
                if (!name) return toast('Name the group');
                const v = await apiPost('chat/groups', { name, members: picked });
                upsertConv(v); close(); openConv(v.id);
              } else {
                const add = picked.filter((u) => !conv.members.includes(u));
                const remove = conv.members.filter((u) => u !== BR.me.user && !picked.includes(u));
                const r = await fetch(new URL(`api/chat/${encodeURIComponent(conv.id)}`, BASE), { method: 'PUT', credentials: 'same-origin', headers: { 'Content-Type': 'application/json' },
                  body: JSON.stringify({ name, add, remove }) });
                if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || r.statusText);
                close(); openConv(conv.id);
              }
            } catch (x) { toast(x.message, 4000); }
          };
          const lv = root.querySelector('#smkv-gleave');
          if (lv) lv.onclick = async () => {
            if (!confirm(`Leave “${conv.title}”?`)) return;
            try { await apiPost(`chat/${encodeURIComponent(conv.id)}/leave`, {}); SO.convs = SO.convs.filter((x) => x.id !== conv.id); close(); drawConvs(); }
            catch (x) { toast(x.message); }
          };
        });
    }
    // "Send to a friend": pick a person or a chat, share the movie/episode/song card
    function shareDialog(ref) {
      const others = SO.people.filter((p) => p.name !== BR.me.user);
      const groups = SO.convs.filter((c) => c.kind === 'group');
      detailModal(`<h2>Send to…</h2><div class="smkv-dim2">${esc(ref.title)}${ref.sub ? ' · ' + esc(ref.sub) : ''}</div>
        <input id="smkv-snote" class="smkv-inp" placeholder="Add a message (optional)" maxlength="500" style="margin-top:10px">
        <div class="smkv-share">${groups.map((g) => `<button data-c="${esc(g.id)}">👥 ${esc(g.title)}</button>`).join('')}
          ${others.map((p) => `<button data-u="${esc(p.name)}"><span class="smkv-dot ${p.online ? 'on' : ''}"></span> ${esc(p.name)}</button>`).join('')}</div>`,
        (root, close) => {
          root.querySelectorAll('.smkv-share button').forEach((b) => b.onclick = async () => {
            try {
              let id = b.dataset.c;
              if (!id) { const v = await apiPost('chat/dm', { user: b.dataset.u }); upsertConv(v); id = v.id; }
              const r = await apiPost(`chat/${encodeURIComponent(id)}/messages`, { text: root.querySelector('#smkv-snote').value.trim(), ref });
              close();
              toast(r.warning ? '⚠ Sent, but ' + r.warning : `Sent to ${b.textContent.trim()}`, r.warning ? 6000 : 2500);
            } catch (x) { toast(x.message, 4000); }
          });
        });
    }

    // ------------------------------------------------------------ audio player
    const A = { el: $('#smkv-aud'), queue: [], idx: -1, cur: null, offset: 0, transcoded: false, repeat: lsGet('repeat', 'off') };
    const aMime = { mp3: 'audio/mpeg', flac: 'audio/flac', m4a: 'audio/mp4', aac: 'audio/aac', ogg: 'audio/ogg', oga: 'audio/ogg', opus: 'audio/ogg; codecs=opus', wav: 'audio/wav' };
    A.el.volume = lsGet('avolume', 1);
    function shuffle(a) { for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; } return a; }

    function playQueue(list, i) {
      A.queue = list.slice(); A.idx = i;
      loadTrack(0);
    }
    function loadTrack(start) {
      const t = A.queue[A.idx];
      if (!t) return;
      A.cur = t;
      const ext = (t.name.split('.').pop() || '').toLowerCase();
      A.transcoded = !(aMime[ext] && A.el.canPlayType(aMime[ext]));
      A.offset = A.transcoded ? start : 0;
      if (A.transcoded) {
        const u = new URL('api/audio', BASE); u.searchParams.set('path', t.path); u.searchParams.set('fmt', 'mp3');
        if (start) u.searchParams.set('start', start.toFixed(2));
        A.el.src = u.href;
      } else {
        A.el.src = rawUrl(t.path);
        if (start) A.el.currentTime = start;
      }
      A.el.play().catch(() => {});
      $('#smkv-abar').classList.add('show');
      document.body.classList.add('smkv-audio-on');
      const img = coverUrl(t.cover);
      $('#smkv-acover').innerHTML = img ? `<img src="${esc(img)}">` : '♪';
      $('#smkv-atitle').textContent = t.title || t.name;
      $('#smkv-aartist').textContent = [t.artist, t.album].filter(Boolean).join(' · ');
      if ('mediaSession' in navigator) {
        navigator.mediaSession.metadata = new MediaMetadata({ title: t.title || t.name, artist: t.artist || '', album: t.album || '', artwork: img ? [{ src: img, sizes: '512x512' }] : [] });
      }
      document.querySelectorAll('.smkv-tracks tr').forEach((tr) => tr.classList.remove('on'));
      document.title = `♪ ${t.title || t.name} — StreamMKV`;
      drawNow.scrolled = false;
      drawNow(); drawMini();
    }
    const aTime = () => A.offset + (A.el.currentTime || 0);
    const aDur = () => A.cur?.duration || (isFinite(A.el.duration) ? A.el.duration : 0);
    function aNext(manual) {
      if (A.repeat === 'one' && !manual) return loadTrack(0);
      if (A.idx + 1 < A.queue.length) { A.idx++; loadTrack(0); }
      else if (A.repeat === 'all' && A.queue.length) { A.idx = 0; loadTrack(0); }
    }
    function aPrev() {
      if (aTime() > 4 || A.idx === 0) return aSeek(0);
      A.idx--; loadTrack(0);
    }
    function aSeek(t) {
      if (!A.cur) return;
      t = Math.max(0, Math.min(t, aDur() - 0.5));
      if (A.transcoded) loadTrack(t); else A.el.currentTime = t;
    }
    function aToggle() { if (!A.cur) return; A.el.paused ? A.el.play().catch(() => {}) : A.el.pause(); }
    A.el.addEventListener('ended', () => aNext(false));
    A.el.addEventListener('play', () => { $('#smkv-app-pp').textContent = '❚❚'; drawMini(); drawNow(); });
    A.el.addEventListener('pause', () => { $('#smkv-app-pp').textContent = '▶'; drawMini(); drawNow(); });
    A.el.addEventListener('timeupdate', () => {
      const t = aTime(), dd = aDur();
      const s = $('#smkv-aseek');
      if (!A.dragging) { s.max = String(dd || 0); s.value = String(t); s.style.setProperty('--p', (dd ? t / dd * 100 : 0) + '%'); }
      $('#smkv-atime').textContent = `${fmtTime(t)} / ${fmtTime(dd)}`;
      const ns = $('#smkv-np-seek');
      if (ns && !A.dragging) { ns.max = String(dd || 0); ns.value = String(t); ns.style.setProperty('--p', (dd ? t / dd * 100 : 0) + '%'); $('#smkv-np-t').textContent = fmtTime(t); $('#smkv-np-d').textContent = fmtTime(dd); }
    });
    A.el.addEventListener('error', () => {
      if (!A.cur || !A.el.getAttribute('src')) return;
      if (!A.transcoded) { // browser could not decode it after all: let the server convert it
        A.transcoded = true; A.offset = 0;
        const u = new URL('api/audio', BASE); u.searchParams.set('path', A.cur.path); u.searchParams.set('fmt', 'mp3');
        A.el.src = u.href; A.el.play().catch(() => {});
      } else { toast('Cannot play ' + (A.cur.title || A.cur.name), 4000); aNext(true); }
    });
    $('#smkv-app-pp').onclick = aToggle;
    $('#smkv-anext').onclick = () => aNext(true);
    $('#smkv-aprev').onclick = aPrev;
    $('#smkv-aseek').addEventListener('input', () => { A.dragging = true; });
    $('#smkv-aseek').addEventListener('change', (e) => { A.dragging = false; aSeek(+e.target.value); });
    $('#smkv-avol').value = String(A.el.volume);
    $('#smkv-avol').addEventListener('input', (e) => { A.el.volume = +e.target.value; lsSet('avolume', A.el.volume); });
    const repeatIcon = { off: '🔁', all: '🔁', one: '🔂' };
    function drawRepeat() { const b = $('#smkv-arep'); b.textContent = repeatIcon[A.repeat]; b.classList.toggle('on', A.repeat !== 'off'); b.title = 'Repeat: ' + A.repeat; }
    $('#smkv-arep').onclick = () => { A.repeat = { off: 'all', all: 'one', one: 'off' }[A.repeat]; lsSet('repeat', A.repeat); drawRepeat(); };
    drawRepeat();
    $('#smkv-aclose').onclick = () => { A.el.pause(); A.el.removeAttribute('src'); A.cur = null; A.queue = []; $('#smkv-abar').classList.remove('show'); document.body.classList.remove('smkv-audio-on'); drawMini(); if (location.hash.startsWith('#/music/now')) route(); };
    // the bar opens the full player; the sidebar pill (videos side) jumps back to music
    $('#smkv-acover').onclick = () => (location.hash = '#/music/now');
    $('.smkv-ainfo').onclick = () => (location.hash = '#/music/now');
    $('#smkv-mini').onclick = (e) => { if (e.target.tagName === 'BUTTON') { e.stopPropagation(); aToggle(); } else location.hash = '#/music/now'; };
    $('#smkv-aqueue').onclick = () => { location.hash = '#/music/now'; };
    $('#smkv-aqueue').ondblclick = () => {
      detailModal(`<h2>Queue</h2>${trackTable(A.queue, true)}`, (root, close) => {
        root.querySelectorAll('.smkv-tracks tr').forEach((tr, i) => { tr.classList.toggle('on', i === A.idx); tr.onclick = () => { A.idx = +tr.dataset.i; loadTrack(0); close(); }; });
      });
    };
    if ('mediaSession' in navigator) {
      navigator.mediaSession.setActionHandler('play', () => A.el.play());
      navigator.mediaSession.setActionHandler('pause', () => A.el.pause());
      navigator.mediaSession.setActionHandler('nexttrack', () => aNext(true));
      navigator.mediaSession.setActionHandler('previoustrack', aPrev);
    }

    $('#smkv-settings').onclick = () => openSettings((n) => { S.maxh = n.maxh || S.maxh; selH.value = String(S.maxh); });
    $('#smkv-logout').onclick = async () => {
      await fetch(new URL('api/logout', BASE), { method: 'POST', credentials: 'same-origin' });
      location.reload();
    };
    $('#smkv-refresh').onclick = async () => { BR.data = {}; await loadLibs(); route(); };

    // ------------------------------------------------------------ track selection
    function canCopy(v) {
      if (!v) return false;
      const pf = v.pixFmt || '';
      const deep = /p1[02]/.test(pf);
      const ok = (t) => (window.MediaSource && MediaSource.isTypeSupported(t)) || !!video.canPlayType(t);
      switch (v.codec) {
        case 'h264': return !deep && (pf === '' || /^yuvj?420p$/.test(pf));
        case 'hevc': return ok(deep ? 'video/mp4; codecs="hvc1.2.4.L153.B0"' : 'video/mp4; codecs="hvc1.1.6.L153.B0"');
        case 'av1': return ok(deep ? 'video/mp4; codecs="av01.0.12M.10"' : 'video/mp4; codecs="av01.0.12M.08"');
        case 'vp9': return ok(deep ? 'video/mp4; codecs="vp09.02.51.10"' : 'video/mp4; codecs="vp09.00.51.08"');
        default: return false;
      }
    }
    // in-browser engine: needs WebCodecs + WebAssembly (Chrome/Edge/Firefox/Safari recent)
    const engineOK = typeof VideoDecoder !== 'undefined' && typeof AudioDecoder !== 'undefined' && typeof WebAssembly !== 'undefined' && typeof AudioContext !== 'undefined';
    function effectiveMode() {
      if (S.sub && !S.sub.text) return 'transcode'; // image subs (PGS) are burned in by the server
      if (S.vmode === 'browser') return engineOK && !S.browserFail ? 'browser' : (canCopy(S.info && S.info.video) ? 'copy' : 'transcode');
      if (S.vmode !== 'auto') return S.vmode;
      if (engineOK && !S.browserFail && getSettings().engine !== 'server') return 'browser';
      if (S.forceTranscode) return 'transcode';
      return canCopy(S.info && S.info.video) ? 'copy' : 'transcode';
    }

    function trackLabel(t, i, kind) {
      const parts = [`${i + 1}.`, (t.language || 'und').toUpperCase()];
      if (t.title) parts.push(t.title);
      if (kind === 'a') parts.push(`· ${t.codec} ${t.layout || (t.channels ? t.channels + 'ch' : '')}`.trim());
      else parts.push(`· ${t.codec}${t.text ? '' : ' (burn-in)'}`);
      if (t.forced) parts.push('[forced]');
      if (t.default) parts.push('★');
      return parts.join(' ');
    }

    function pickTracks(info, path, server) {
      let saved = lsGet('tracks:' + path, null);
      if (server && (server.audio != null || server.sub != null)) {
        saved = { audio: server.audio ?? null };
        if (server.sub != null) saved.sub = server.sub < 0 ? null : server.sub;
      }
      const s = getSettings();
      // audio
      let audio = 0;
      if (saved && saved.audio != null && saved.audio < info.audio.length) audio = saved.audio;
      else if (info.audio.length) {
        const ranked = info.audio.map((a, i) => ({ i, r: langMatch(a.language, s.audioLang) })).filter((x) => x.r >= 0).sort((a, b) => a.r - b.r);
        if (ranked.length) audio = ranked[0].i;
        else { const d = info.audio.findIndex((a) => a.default); audio = d >= 0 ? d : 0; }
      }
      // subtitles
      let sub = null;
      if (saved && 'sub' in saved) sub = saved.sub != null && saved.sub < info.subs.length ? saved.sub : null;
      else if (info.subs.length) {
        const ranked = info.subs.map((t, i) => ({ i, r: langMatch(t.language, s.subLang), text: t.text, forced: t.forced }))
          .filter((x) => x.r >= 0)
          .sort((a, b) => a.r - b.r || (b.text - a.text) || (a.forced - b.forced));
        if (ranked.length) sub = ranked[0].i;
      }
      return { audio, sub };
    }

    function saveTracks() {
      if (!S.file) return;
      lsSet('tracks:' + S.file.path, { audio: S.audio, sub: S.sub ? S.sub.idx : null });
      pushProgress({ path: S.file.path, audio: S.audio, sub: S.sub ? S.sub.idx : -1 });
    }

    // ------------------------------------------------------------ open file
    async function openFile(f, opts = {}) {
      savePos(true);
      S.file = f; S.info = null; S.cues = []; S.sub = null; S.forceTranscode = false; S.errCount = 0; S.subDelay = 0;
      S.browserFail = null;
      S.loadSeq++;
      stopServerStream();
      if (wp) wp.pause();
      S.engFile = null;
      renderSubs(true); updateSubDelay();
      $('#smkv-title').textContent = f.name;
      $('#smkv-meta').textContent = 'Probing…';
      document.title = f.name + ' — StreamMKV';
      spinner(true);
      let info, server = null;
      try {
        [info, server] = await Promise.all([
          api('probe', { path: f.path }),
          api('progress', { path: f.path }).catch(() => null),
        ]);
      } catch (e) {
        spinner(false); $('#smkv-meta').textContent = 'Probe failed: ' + e.message; return;
      }
      if (S.file !== f) return;
      S.info = info;
      const v = info.video;
      const pick = pickTracks(info, f.path, server);
      S.audio = pick.audio;
      S.sub = pick.sub != null ? { idx: pick.sub, text: info.subs[pick.sub].text } : null;

      selAudio.innerHTML = info.audio.length
        ? info.audio.map((a, i) => `<option value="${i}">${esc(trackLabel(a, i, 'a'))}</option>`).join('')
        : '<option value="-1">No audio</option>';
      selAudio.value = String(info.audio.length ? S.audio : -1);
      selSub.innerHTML = '<option value="">Off</option>' +
        info.subs.map((t, i) => `<option value="${i}">${esc(trackLabel(t, i, 's'))}</option>`).join('');
      selSub.value = S.sub ? String(S.sub.idx) : '';
      seek.max = String(info.duration || 0);
      updateMeta();

      // resume
      let start = 0;
      const pos = opts.fromStart ? 0 : ((server && server.pos) || lsGet('pos:' + f.path, 0));
      if (pos > 30 && pos < (info.duration || 0) - 120) {
        start = pos;
        toast(`Resumed at ${fmtTime(pos)}`, 6000, { label: 'Start over', fn: () => playAt(0, true) });
      }
      playAt(start, true);
      if (S.sub && S.sub.text) loadSubCues();
      if (v) $('#smkv-meta').title = JSON.stringify(v);
    }

    function updateMeta() {
      const i = S.info;
      if (!i) return;
      const v = i.video;
      const mode = effectiveMode();
      $('#smkv-meta').innerHTML = [
        fmtTime(i.duration),
        v ? `${v.width}×${v.height} ${esc(v.codec)}${v.pixFmt ? ' ' + esc(v.pixFmt) : ''}` : 'no video',
        `${i.audio.length} audio · ${i.subs.length} subs`,
        `<span class="smkv-badge ${mode}" title="${mode === 'browser' ? 'Decoded by this browser from the original file — the server only sends bytes' : mode === 'copy' ? 'The server repackages the video and converts the audio' : 'The server re-encodes the video'}">${mode === 'browser' ? 'direct · in browser' : mode === 'copy' ? 'remux · server' : 'transcode ≤' + S.maxh + 'p'}</span>`,
        S.browserFail && S.vmode !== 'copy' && S.vmode !== 'transcode' ? `<span class="smkv-dim2" title="${esc(S.browserFail)}">in-browser: ${esc(S.browserFail)}</span>` : '',
      ].filter(Boolean).join(' · ');
    }

    // ------------------------------------------------------------ playback
    async function playAt(t, autoplay = true) {
      if (!S.file || !S.info) return;
      const seq = ++S.loadSeq;
      const dur = S.info.duration || 0;
      t = Math.max(0, dur ? Math.min(t, dur - 1) : t);
      const mode = effectiveMode();
      spinner(true);
      if (mode === 'browser') return playInBrowser(t, autoplay, seq);
      if (media === wp && wp) { wp.pause(); }
      media = video;
      player.classList.remove('engine');
      let start = t;
      if (mode === 'copy' && t > 0) {
        try { start = (await api('keyframe', { path: S.file.path, t: t.toFixed(3) })).t; } catch { /* use t */ }
      }
      if (seq !== S.loadSeq) return;
      S.offset = start;
      S.pendingTarget = null;
      const u = new URL('api/stream', BASE);
      const q = { path: S.file.path, audio: S.audio, start: start.toFixed(3), v: mode, maxh: S.maxh };
      if (S.sub && !S.sub.text) q.burn = S.sub.idx;
      for (const [k, v] of Object.entries(q)) u.searchParams.set(k, v);
      video.src = u.href;
      if (autoplay) video.play().catch(() => {});
      updateMeta();
      updateTime();
    }

    // ---- in-browser engine (original file → Mediabunny demux → WebCodecs / WASM audio)
    async function playInBrowser(t, autoplay, seq) {
      const f = S.file;
      try {
        if (!wp) {
          const m = await import(new URL('player-wasm.mjs?v=' + (window.SMKV_VERSION || ''), BASE).href);
          wp = new m.WasmPlayer(canvas, BASE);
          bindMedia(wp);
          wp.volume = video.volume; wp.muted = video.muted;
        }
        stopServerStream();
        media = wp;
        player.classList.add('engine');
        const raw = new URL('api/raw', BASE);
        raw.searchParams.set('path', f.path);
        if (S.engFile !== f.path) {
          S.engFile = null;
          await wp.load(raw.href, { audioIndex: S.audio, start: t, duration: S.info.duration || 0 });
          if (wp.audioTracks.length !== S.info.audio.length) console.warn('audio track count differs', wp.audioTracks.length, S.info.audio.length);
          S.engFile = f.path; S.engAudio = S.audio;
        } else if (S.engAudio !== S.audio) {
          await wp.setAudioTrack(S.audio); S.engAudio = S.audio;
          if (Math.abs(wp.currentTime - t) > 0.5) await wp.seek(t);
        } else {
          await wp.seek(t);
        }
        if (seq !== S.loadSeq || S.file !== f) return;
        S.offset = 0; S.pendingTarget = null;
        spinner(false);
        if (autoplay) await wp.play();
        updateMeta(); updateTime();
      } catch (e) {
        if (S.file !== f) return;
        S.engFile = null;
        S.browserFail = (e && e.message) || String(e);
        console.warn('in-browser playback:', e);
        toast(`Playing through the server (${S.browserFail})`, 5000);
        media = video; player.classList.remove('engine');
        if (seq === S.loadSeq) playAt(t, autoplay);
      }
    }
    function stopServerStream() {
      video.pause();
      if (video.getAttribute('src')) { video.removeAttribute('src'); video.load(); }
    }

    function seekTo(t) {
      if (!S.info) return;
      if (media === wp && wp && effectiveMode() === 'browser') { // instant
        S.pendingTarget = Math.max(0, Math.min(t, (S.info.duration || 0) - 1));
        updateTime();
        clearTimeout(S.pendingTimer);
        S.pendingTimer = setTimeout(async () => { const x = S.pendingTarget; await wp.seek(x); if (S.pendingTarget === x) S.pendingTarget = null; updateTime(); }, 80);
        return;
      }
      S.pendingTarget = Math.max(0, Math.min(t, (S.info.duration || 0) - 1));
      updateTime();
      clearTimeout(S.pendingTimer);
      S.pendingTimer = setTimeout(() => playAt(S.pendingTarget, true), 350);
    }
    const seekBy = (d) => seekTo(cur() + d);

    function togglePlay() {
      if (!S.file) return;
      if (media.paused) Promise.resolve(media.play()).catch(() => {}); else media.pause();
    }

    function updateTime() {
      const d = S.info ? S.info.duration : 0;
      const t = S.dragging ? +seek.value : cur();
      timeEl.textContent = `${fmtTime(t)} / ${fmtTime(d)}`;
      if (!S.dragging) seek.value = String(t);
      const pct = d ? (t / d) * 100 : 0;
      seek.style.setProperty('--p', pct + '%');
    }

    function savePos(force) {
      if (!S.file || !S.info) return;
      const now = Date.now();
      if (!force && now - S.lastSave < 5000) return;
      S.lastSave = now;
      const t = cur(), dur = S.info.duration || 0;
      if (t > dur - 120) lsDel('pos:' + S.file.path);
      else if (t > 30) lsSet('pos:' + S.file.path, Math.floor(t));
      if (t > 30) {
        setItemPos(S.file.path, t > dur - 120 ? 0 : t);
        pushProgress({ path: S.file.path, pos: t, duration: dur });
      }
    }
    window.addEventListener('pagehide', () => savePos(true));

    function bindMedia(el) {
      const mine = (fn) => (e) => { if (media === el) fn(e); };
      el.addEventListener('timeupdate', mine(() => { updateTime(); savePos(false); }));
      el.addEventListener('play', mine(() => { ppBtn.textContent = '❚❚'; heartbeat(true); }));
      el.addEventListener('pause', mine(() => { ppBtn.textContent = '▶'; savePos(true); showControls(); heartbeat(true); }));
      el.addEventListener('waiting', mine(() => spinner(true)));
      el.addEventListener('playing', mine(() => { spinner(false); S.errCount = 0; }));
      el.addEventListener('canplay', mine(() => spinner(false)));
      el.addEventListener('ended', mine(onEnded));
      if (el !== video) el.addEventListener('error', mine((e) => { // engine failed mid-play → server
        const t = cur();
        S.browserFail = (e && e.detail) || 'decode error';
        S.engFile = null;
        toast(`In-browser playback stopped (${S.browserFail}) — continuing through the server`, 6000);
        playAt(t, true);
      }));
    }
    bindMedia(video);
    function onEnded() {
      if (!S.file) return;
      lsDel('pos:' + S.file.path);
      pushProgress({ path: S.file.path, done: true });
      setItemPos(S.file.path, 0);
      if (BR.ctx && BR.ctx.next) {
        const n = BR.ctx.next;
        toast(`Up next: S${n.season}E${n.episode}${n.episodeTitle ? ' · ' + n.episodeTitle : ''}`, 15000, { label: '▶ Play next', fn: () => playVideo(n.path) });
      }
    }
    video.addEventListener('error', async () => {
      if (!S.file || !video.getAttribute('src') || media !== video) return;
      const t = cur();
      S.errCount++;
      if (S.errCount > 3) { spinner(false); toast('Playback failed: ' + (video.error?.message || 'unknown error'), 8000); return; }
      const me = await fetch(new URL('api/me', BASE), { credentials: 'same-origin' });
      if (!me.ok) { await ensureLogin(); return playAt(t, true); }
      // a stream limit? show the server's reason instead of retrying
      try { await api('stream/check', { path: S.file.path, kind: S.sub && !S.sub.text ? 'transcode' : effectiveMode() }); }
      catch (e) { spinner(false); S.errCount = 99; toast(e.message, 12000); return; }
      if (effectiveMode() === 'copy' && S.vmode === 'auto') {
        S.forceTranscode = true;
        toast('Direct play failed — switching to transcode');
      }
      setTimeout(() => playAt(t, true), 800);
    });

    // ------------------------------------------------------------ controls
    ppBtn.onclick = togglePlay;
    $('#smkv-back').onclick = () => seekBy(-10);
    $('#smkv-fwd').onclick = () => seekBy(30);
    seek.addEventListener('input', () => { S.dragging = true; updateTime(); });
    seek.addEventListener('change', () => { S.dragging = false; seekTo(+seek.value); });

    const vol = $('#smkv-vol');
    const setVolume = (v) => { video.volume = v; if (wp) wp.volume = v; vol.value = String(v); lsSet('volume', v); };
    const setMuted = (m) => { video.muted = m; if (wp) wp.muted = m; $('#smkv-mute').textContent = m ? '🔇' : '🔊'; };
    video.volume = lsGet('volume', 1);
    vol.value = String(video.volume);
    vol.addEventListener('input', () => { setVolume(+vol.value); setMuted(false); });
    $('#smkv-mute').onclick = () => setMuted(!video.muted);

    const toggleFs = () => (document.fullscreenElement ? document.exitFullscreen() : player.requestFullscreen()).catch?.(() => {});
    $('#smkv-fs').onclick = toggleFs;
    video.addEventListener('click', togglePlay);
    video.addEventListener('dblclick', toggleFs);
    canvas.addEventListener('click', togglePlay);
    canvas.addEventListener('dblclick', toggleFs);

    let hideTimer = 0;
    function showControls() {
      player.classList.add('ctl');
      clearTimeout(hideTimer);
      hideTimer = setTimeout(() => { if (!media.paused) player.classList.remove('ctl'); }, 2500);
    }
    player.addEventListener('mousemove', showControls);
    player.addEventListener('touchstart', showControls, { passive: true });

    selAudio.onchange = () => {
      S.audio = +selAudio.value;
      saveTracks();
      playAt(cur(), !media.paused || media.readyState < 2);
    };
    selSub.onchange = () => setSub(selSub.value);
    selV.onchange = () => { S.vmode = selV.value; S.forceTranscode = false; if (S.vmode === 'browser') S.browserFail = null; if (S.file) playAt(cur(), !media.paused); };
    selH.value = String(S.maxh);
    selH.onchange = () => { S.maxh = +selH.value; if (S.file && effectiveMode() === 'transcode') playAt(cur(), !media.paused); else updateMeta(); };

    $('#smkv-sd-minus').onclick = () => { S.subDelay -= 0.1; updateSubDelay(); };
    $('#smkv-sd-plus').onclick = () => { S.subDelay += 0.1; updateSubDelay(); };
    function updateSubDelay() {
      if (Math.abs(S.subDelay) < 0.001) S.subDelay = 0;
      $('#smkv-sd').textContent = (S.subDelay > 0 ? '+' : '') + S.subDelay.toFixed(1) + 's';
      S.lastCueKey = '';
    }

    document.addEventListener('keydown', (e) => {
      if (e.target.closest('input,select,textarea') && e.target.type !== 'range') return;
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      if (!$('#smkv-watch').classList.contains('show')) {
        if (e.key === 'Escape' && $('#smkv-detail').classList.contains('show')) { $('#smkv-detail').classList.remove('show'); return; }
        if (e.key === ' ' && A.cur) { e.preventDefault(); aToggle(); }
        return;
      }
      if (e.key === 'Escape' && !document.fullscreenElement) { closeVideo(); return; }
      const k = e.key;
      const handled = {
        ' ': togglePlay, k: togglePlay,
        ArrowLeft: () => seekBy(-10), ArrowRight: () => seekBy(10),
        j: () => seekBy(-30), l: () => seekBy(30),
        ArrowUp: () => setVolume(Math.min(1, video.volume + 0.05)),
        ArrowDown: () => setVolume(Math.max(0, video.volume - 0.05)),
        f: toggleFs, m: () => $('#smkv-mute').click(),
        z: () => $('#smkv-sd-minus').click(), x: () => $('#smkv-sd-plus').click(),
        c: () => { // cycle subtitles
          const opts = [...selSub.options].map((o) => o.value);
          const n = opts[(opts.indexOf(selSub.value) + 1) % opts.length];
          selSub.value = n; setSub(n);
          toast('Subtitles: ' + selSub.selectedOptions[0].textContent, 1500);
        },
        a: () => { // cycle audio
          if (selAudio.options.length < 2) return;
          selAudio.selectedIndex = (selAudio.selectedIndex + 1) % selAudio.options.length;
          selAudio.onchange();
          toast('Audio: ' + selAudio.selectedOptions[0].textContent, 1500);
        },
      }[k];
      if (handled) { e.preventDefault(); handled(); showControls(); }
    });

    // ------------------------------------------------------------ subtitles
    async function setSub(value) {
      if (!S.info) return;
      const wasBurn = !!(S.sub && !S.sub.text);
      S.cues = []; renderSubs(true);
      S.sub = value === '' ? null : { idx: +value, text: S.info.subs[+value].text };
      saveTracks();
      const isBurn = !!(S.sub && !S.sub.text);
      if (wasBurn || isBurn) playAt(cur(), !media.paused || media.readyState < 2);
      else updateMeta();
      if (S.sub && S.sub.text) loadSubCues();
    }

    async function loadSubCues() {
      const file = S.file, idx = S.sub.idx;
      toast('Loading subtitles… (first load extracts the track from the MKV)', 0);
      try {
        const txt = await api('subtitle', { path: file.path, sub: idx }, { text: true });
        if (S.file !== file || !S.sub || S.sub.idx !== idx) return;
        S.cues = parseVTT(txt);
        S.lastCueKey = '';
        toast(`Subtitles loaded (${S.cues.length} lines)`, 2000);
      } catch (e) {
        toast('Subtitle error: ' + e.message, 6000);
      }
    }

    function parseTs(s) {
      const p = s.replace(',', '.').split(':').map(Number);
      return p.length === 3 ? p[0] * 3600 + p[1] * 60 + p[2] : p[0] * 60 + p[1];
    }
    function cleanCue(t) {
      t = t.replace(/\{\\[^}]*\}/g, '');                                       // leftover ASS override tags
      t = t.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
      t = t.replace(/&lt;(\/?)(i|b|u)&gt;/gi, '<$1$2>');                       // keep basic styling
      t = t.replace(/&lt;\/?[a-z][^&]*?&gt;/gi, '');                           // drop <c.x>, <font>, <v> …
      return t.replace(/\\N/g, '<br>').replace(/\n/g, '<br>');
    }
    function parseVTT(txt) {
      const cues = [];
      for (const block of txt.replace(/\r/g, '').split(/\n{2,}/)) {
        const lines = block.split('\n');
        const i = lines.findIndex((l) => l.includes('-->'));
        if (i < 0) continue;
        const m = lines[i].match(/([\d:.,]+)\s*-->\s*([\d:.,]+)/);
        if (!m) continue;
        const text = lines.slice(i + 1).join('\n').trim();
        if (!text) continue;
        cues.push({ start: parseTs(m[1]), end: parseTs(m[2]), html: cleanCue(text) });
      }
      cues.sort((a, b) => a.start - b.start);
      return cues;
    }

    function renderSubs(force) {
      const cues = S.cues;
      let key = '', html = '';
      if (cues.length && S.file) {
        const t = cur() - S.subDelay; // ffmpeg already rebases VTT cues to the container start
        // binary search: last cue with start <= t
        let lo = 0, hi = cues.length - 1, idx = -1;
        while (lo <= hi) { const mid = (lo + hi) >> 1; if (cues[mid].start <= t) { idx = mid; lo = mid + 1; } else hi = mid - 1; }
        const active = [];
        for (let i = idx; i >= 0 && i > idx - 30; i--) if (cues[i].end > t) active.unshift(i);
        key = active.join(',');
        html = active.map((i) => `<span>${cues[i].html}</span>`).join('<br>');
      }
      if (force || key !== S.lastCueKey) { S.lastCueKey = key; subsEl.innerHTML = html; }
    }
    (function loop() { renderSubs(false); if (S.dragging || S.pendingTarget != null) updateTime(); requestAnimationFrame(loop); })();

    new ResizeObserver(() => {
      const h = player.clientHeight;
      subsEl.style.fontSize = Math.max(14, Math.round(h * 0.048)) + 'px';
    }).observe(player);

    // ------------------------------------------------------------ start
    (async () => {
      await ensureLogin();
      try {
        BR.me = await api('me');
        $('#smkv-admin').hidden = !BR.me.admin;
        $('#smkv-side header b').title = `Signed in as ${BR.me.user} · server ${BR.me.version || '?'}`;
      } catch { /* old server */ }
      await loadLibs();
      route();
      startSocial();
    })();
  }

  // ================================================================= markup
  const HTML = `
<div id="smkv-app">
  <aside id="smkv-side">
    <header>
      <b>StreamMKV</b><span class="smkv-sp"></span>
      <a id="smkv-admin" href="admin" target="_blank" title="Admin dashboard" hidden>🛡</a>
      <button id="smkv-refresh" title="Reload libraries">⟳</button>
      <button id="smkv-ann" title="Announcements">📣<i hidden></i></button>
      <button id="smkv-settings" title="Settings">⚙</button>
      <button id="smkv-logout" title="Log out">⏻</button>
    </header>
    <nav id="smkv-nav"></nav>
    <div id="smkv-people"></div>
    <div id="smkv-mini" hidden title="Music is playing — open the music player"><span class="smkv-mini-i">🎵</span><div><b></b><span></span></div><button title="Play/Pause">❚❚</button></div>
  </aside>
  <section id="smkv-chat"></section>
  <main id="smkv-browse">
    <div id="smkv-annbar" hidden></div>
    <div id="smkv-toolbar"></div>
    <div id="smkv-view"></div>
  </main>
</div>
<div id="smkv-watch">
  <div id="smkv-player">
    <video id="smkv-video" playsinline preload="auto"></video>
    <canvas id="smkv-canvas"></canvas>
    <div id="smkv-subs"></div>
    <div id="smkv-spinner"></div>
    <div id="smkv-controls">
      <input id="smkv-seek" type="range" min="0" max="0" step="0.1" value="0">
      <div class="smkv-row">
        <button id="smkv-pp" title="Play/Pause (space)">▶</button>
        <button id="smkv-back" title="Back 10s (←)">↺10</button>
        <button id="smkv-fwd" title="Forward 30s (l)">30↻</button>
        <span id="smkv-time">0:00 / 0:00</span>
        <span class="smkv-sp"></span>
        <button id="smkv-mute" title="Mute (m)">🔊</button>
        <input id="smkv-vol" type="range" min="0" max="1" step="0.05">
        <button id="smkv-fs" title="Fullscreen (f)">⛶</button>
      </div>
    </div>
  </div>
  <section id="smkv-bar">
    <div class="smkv-titlerow"><button id="smkv-close" title="Back to library (Esc)">← Back</button><h2 id="smkv-title"></h2></div>
    <div id="smkv-meta"></div>
    <div class="smkv-opts">
      <label>Audio <select id="smkv-audio"><option>—</option></select></label>
      <label>Subtitles <select id="smkv-sub"><option value="">Off</option></select></label>
      <label>Sub delay <span class="smkv-group"><button id="smkv-sd-minus" title="z">−</button><span id="smkv-sd">0.0s</span><button id="smkv-sd-plus" title="x">+</button></span></label>
      <label>Video <select id="smkv-vmode">
        <option value="auto">Auto</option><option value="browser">In browser (original file)</option><option value="copy">Server remux</option><option value="transcode">Server transcode H.264</option>
      </select></label>
      <label>Max height <select id="smkv-maxh">
        <option value="2160">2160p</option><option value="1440">1440p</option><option value="1080">1080p</option>
        <option value="720">720p</option><option value="480">480p</option>
      </select></label>
    </div>
    <div class="smkv-keys">Keys: space play · ←/→ ±10s · j/l ±30s · a audio · c subs · z/x sub delay · f fullscreen · m mute · Esc back</div>
  </section>
</div>
<div id="smkv-abar">
  <div id="smkv-acover">♪</div>
  <div class="smkv-ainfo"><b id="smkv-atitle"></b><span id="smkv-aartist"></span></div>
  <div class="smkv-actl">
    <div class="smkv-abtns"><button id="smkv-aprev" title="Previous">⏮</button><button id="smkv-app-pp" class="big" title="Play/Pause (space)">▶</button><button id="smkv-anext" title="Next">⏭</button><button id="smkv-arep">🔁</button></div>
    <div class="smkv-aseekrow"><input id="smkv-aseek" type="range" min="0" max="0" step="0.1" value="0"><span id="smkv-atime">0:00 / 0:00</span></div>
  </div>
  <div class="smkv-aright"><button id="smkv-aqueue" title="Queue">☰</button><input id="smkv-avol" type="range" min="0" max="1" step="0.05"><button id="smkv-aclose" title="Stop">✕</button></div>
  <audio id="smkv-aud" preload="auto"></audio>
</div>
<div id="smkv-detail"></div>
<div id="smkv-toast"></div>
<div id="smkv-login"><form>
  <h2>Sign in to StreamMKV</h2>
  <input name="username" placeholder="Username" autocomplete="username">
  <input name="password" type="password" placeholder="Password" autocomplete="current-password">
  <button type="submit">Sign in</button>
  <div class="msg"></div>
</form></div>`;

  const CSS = `
html,body{margin:0;height:100%;background:#0d0f13;color:#c9cfd8;font:14px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif}
a{color:#7cc4ff;text-decoration:none}
#smkv-app{display:grid;grid-template-columns:230px 1fr;height:100vh}
body.smkv-audio-on #smkv-app{height:calc(100vh - 76px)}
#smkv-side{display:flex;flex-direction:column;border-right:1px solid #1f242d;background:#11141a;min-height:0}
#smkv-side header{display:flex;align-items:center;gap:5px;padding:12px 10px 10px 14px}
#smkv-side header b{color:#fff;font-size:16px;letter-spacing:.3px}
.smkv-sp{flex:1}
button{font:inherit}
#smkv-app button,#smkv-login button,#smkv-watch button,#smkv-abar button,#smkv-detail button{background:#1c212a;color:#c9cfd8;border:1px solid #2a313c;border-radius:6px;padding:5px 9px;cursor:pointer;font:inherit}
#smkv-app button:hover,#smkv-detail button:hover{background:#262c37}
button.smkv-primary,#smkv-detail .smkv-play{background:#2b6fd6!important;border-color:#2b6fd6!important;color:#fff!important}
#smkv-admin{background:#1c212a;border:1px solid #2a313c;border-radius:6px;padding:4px 8px;font-size:13px}
#smkv-admin[hidden]{display:none}
#smkv-nav{display:flex;flex-direction:column;padding:4px 8px;overflow:auto}
#smkv-nav a{color:#c9cfd8;padding:8px 10px;border-radius:7px;display:flex;gap:6px;align-items:center}
#smkv-nav a:hover{background:#181c24}
#smkv-nav a.on{background:#1b2533;color:#fff}
.smkv-modes{display:flex;gap:4px;background:#0c0f14;border:1px solid #1f242d;border-radius:9px;padding:3px;margin:2px 0 10px}
#smkv-nav .smkv-modes a{flex:1;justify-content:center;padding:7px 6px;border-radius:6px;font-weight:600}
#smkv-nav .smkv-modes a.on{background:#2b6fd6;color:#fff}
body.smkv-music-mode #smkv-nav .smkv-modes a.on{background:#c2417a}
body.smkv-music-mode #smkv-nav a.on:not(.smkv-modes a){background:#2c1b26}
.smkv-navsep{height:1px;background:#1f242d;margin:8px 4px}
#smkv-mini{margin:auto 10px 10px;display:flex;align-items:center;gap:8px;background:#1a1420;border:1px solid #3a2333;border-radius:10px;padding:8px 10px;cursor:pointer}
#smkv-mini[hidden]{display:none}
#smkv-mini div{flex:1;min-width:0;display:flex;flex-direction:column}
#smkv-mini b,#smkv-mini div span{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:12.5px}
#smkv-mini div span{color:#8b95a5;font-size:11.5px}
#smkv-mini button{background:#fff!important;color:#000!important;border-radius:50%!important;width:28px;height:28px;padding:0!important;font-size:11px}
body.smkv-video-mode #smkv-abar{display:none!important}
body.smkv-video-mode.smkv-audio-on #smkv-app{height:100vh}
#smkv-acover,.smkv-ainfo{cursor:pointer}
.smkv-npbanner{display:flex;gap:14px;align-items:center;background:linear-gradient(90deg,#2a1622,#151920);border:1px solid #3a2333;border-radius:12px;padding:12px;margin:14px 0;color:#e6e9ee;max-width:560px}
.smkv-npbanner .smkv-poster{width:72px;flex:none}
.smkv-now{display:flex;gap:28px;align-items:center;margin:22px 0 10px;flex-wrap:wrap}
.smkv-now .smkv-poster.big{width:min(300px,70vw);flex:none;box-shadow:0 18px 50px rgba(0,0,0,.55)}
.smkv-now-info{flex:1;min-width:260px;max-width:620px}
.smkv-now-info h2{font-size:28px;margin:4px 0}
#smkv-np-seek{width:100%;margin-top:18px}
.smkv-np-times{display:flex;justify-content:space-between;color:#8b95a5;font-size:12px}
.smkv-np-btns{display:flex;gap:14px;align-items:center;margin-top:10px}
.smkv-np-btns button{background:transparent!important;border:none!important;font-size:22px!important;color:#c9cfd8!important}
.smkv-np-btns button.on{color:#ff7eb6!important}
.smkv-np-btns button.big{background:#fff!important;color:#000!important;border-radius:50%!important;width:56px;height:56px;font-size:20px!important}
.smkv-tracks tr.played td{opacity:.55}
.smkv-pageh{margin:18px 0 12px}
.smkv-dlform{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-bottom:6px}
.smkv-dlform input[name=source]{flex:1;min-width:260px}
.smkv-dlform input,.smkv-dlform select{background:#151920;color:#e6e9ee;border:1px solid #2a313c;border-radius:6px;padding:7px 9px;font:inherit}
.smkv-tfile{position:relative;overflow:hidden;background:#1c212a;border:1px solid #2a313c;border-radius:6px;padding:6px 10px;cursor:pointer;white-space:nowrap;max-width:200px;text-overflow:ellipsis}
.smkv-tfile input{position:absolute;inset:0;opacity:0;cursor:pointer}
.smkv-dl{background:#141820;border:1px solid #20262f;border-radius:10px;padding:10px 12px;margin:8px 0}
.smkv-dlh{display:flex;flex-direction:column;gap:2px;word-break:break-all}
.smkv-pbar.big{position:relative;height:6px;border-radius:3px;margin:8px 0 6px;background:#252b35}
.smkv-pbar.big i{display:block;height:100%;border-radius:3px;background:#4a9eff}
.smkv-dl.done .smkv-pbar.big i{background:#3ecf8e}.smkv-dl.failed .smkv-pbar.big i{background:#ff6b6b}
.smkv-dlf2{display:flex;align-items:center;gap:8px;flex-wrap:wrap}.smkv-dlf2 span{flex:1;min-width:220px}
.smkv-btn2{background:#1c212a;color:#e6e9ee;border:1px solid #2a313c;border-radius:6px;padding:6px 12px;cursor:pointer;font:inherit}
.smkv-err{color:#ff7b7b}
#smkv-side header{gap:4px!important}
#smkv-side header button,#smkv-side header a{padding:4px 7px!important;min-width:0}
#smkv-people{border-top:1px solid #1f242d;padding:6px 8px;max-height:38vh;overflow:auto}
.smkv-ph{display:flex;align-items:center;gap:6px;font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:#8b95a5;padding:4px 4px 6px}
.smkv-ph button{margin-left:auto;position:relative;background:transparent!important;border:none!important;font-size:16px!important;padding:2px 4px!important}
.smkv-ph i,.smkv-badge{background:#e5484d;color:#fff;font-style:normal;font-size:10px;border-radius:9px;padding:1px 5px;font-weight:700}
.smkv-ph i{position:absolute;top:-4px;right:-6px}
.smkv-person{display:flex;gap:8px;align-items:flex-start;padding:5px 6px;border-radius:7px;cursor:pointer;opacity:.55}
.smkv-person.on{opacity:1}.smkv-person{align-items:center}.smkv-person:hover{background:#171c24}
.smkv-person b{font-size:13px;color:#dfe4ea;font-weight:600}
.smkv-dot{width:8px;height:8px;border-radius:50%;background:#4a5260;flex:none;margin-top:6px;display:inline-block}
.smkv-person.on .smkv-dot,.smkv-dot.on{background:#3ecf8e;box-shadow:0 0 0 2px rgba(62,207,142,.18)}
.smkv-pav{position:relative;display:inline-block;flex:none;border-radius:50%;vertical-align:middle}
.smkv-pav img,.smkv-pav>span{width:100%;height:100%;border-radius:50%;object-fit:cover;display:flex;align-items:center;justify-content:center;color:#fff;font-weight:700}
.smkv-pdot{position:absolute;right:-1px;bottom:-1px;width:10px;height:10px;border-radius:50%;background:#4a5260;border:2px solid #0f1217}
.smkv-pdot.on{background:#3ecf8e}
.smkv-adm{display:inline-block;font-size:9px;font-weight:800;letter-spacing:.5px;color:#ffcf7a;background:#4a3a1c;border-radius:6px;padding:0 5px;margin-left:6px;vertical-align:2px;font-style:normal}
.smkv-me{display:flex;gap:10px;align-items:center;padding:10px 14px;border-bottom:1px solid #1f242d}
#smkv-chat .smkv-link{background:none!important;border:none!important;color:#7cc4ff!important;padding:0!important;min-width:0!important;cursor:pointer;font:inherit;font-size:12px}
.smkv-mrow{display:flex;gap:7px;align-items:flex-end;max-width:88%}
.smkv-mrow .smkv-msg{max-width:100%}
.smkv-act{font-size:11.5px;color:#9aa3b2;line-height:1.35;margin-top:1px}
.smkv-act.link:hover{color:#fff;text-decoration:underline}
#smkv-chat{position:fixed;top:0;right:0;bottom:0;width:min(380px,100vw);background:#10131a;border-left:1px solid #222935;z-index:2147483600;display:none;flex-direction:column;box-shadow:-10px 0 40px rgba(0,0,0,.5)}
#smkv-chat.show{display:flex}
body.smkv-audio-on.smkv-music-mode #smkv-chat{bottom:72px}
.smkv-ch{display:flex;align-items:center;gap:8px;padding:12px;border-bottom:1px solid #1f242d}
.smkv-ch b{font-size:15px}
.smkv-priv{padding:8px 14px;font-size:12px;color:#9aa3b2;display:flex;gap:6px;align-items:center}
.smkv-convs{overflow:auto;flex:1}
.smkv-conv{display:flex;gap:10px;align-items:center;padding:10px 14px;cursor:pointer;border-bottom:1px solid #161b22}
.smkv-conv:hover{background:#151a22}
.smkv-av{width:36px;height:36px;border-radius:50%;background:#253043;display:flex;align-items:center;justify-content:center;font-weight:700;flex:none}
.smkv-cm{flex:1;min-width:0;display:flex;flex-direction:column}.smkv-cm span{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.smkv-msgs{flex:1;overflow:auto;padding:10px 12px;display:flex;flex-direction:column;gap:6px}
.smkv-msg{max-width:82%;align-self:flex-start;display:flex;flex-direction:column;gap:3px}
.smkv-msg.me{align-self:flex-end;align-items:flex-end}
.smkv-bubble{background:#1d2430;padding:7px 11px;border-radius:14px;white-space:pre-wrap;word-break:break-word;font-size:14px}
.smkv-msg.me .smkv-bubble{background:#2b6fd6;color:#fff}
.smkv-time,.smkv-from{font-size:10.5px;color:#7d8696}
.smkv-sys,.smkv-day{align-self:center;font-size:11.5px;color:#7d8696;padding:2px 8px}
.smkv-day{background:#171c24;border-radius:9px;margin:6px 0}
.smkv-ref{display:flex;gap:10px;background:#1a202a;border:1px solid #2a3240;border-radius:12px;padding:8px;cursor:pointer;max-width:280px}
.smkv-ref:hover{border-color:#4a9eff}
.smkv-ref img,.smkv-ref>span{width:46px;height:68px;object-fit:cover;border-radius:5px;flex:none;background:#252c38;display:flex;align-items:center;justify-content:center}
.smkv-ref div{display:flex;flex-direction:column;gap:2px;min-width:0}
.smkv-ref small{color:#9aa3b2}.smkv-ref em{font-style:normal;color:#6ab0ff;font-size:12px;margin-top:auto}
.smkv-send{display:flex;gap:8px;padding:10px;border-top:1px solid #1f242d}
.smkv-send input,.smkv-inp{flex:1;width:100%;box-sizing:border-box;background:#151920;color:#e6e9ee;border:1px solid #2a313c;border-radius:18px;padding:9px 14px;font:inherit}
.smkv-inp{border-radius:8px}
.smkv-gmembers{display:flex;flex-wrap:wrap;gap:6px 14px;margin-top:6px}
.smkv-share{display:flex;flex-wrap:wrap;gap:8px;margin-top:12px}
.smkv-share .smkv-dot{margin:0}
.smkv-sharebtn{margin-top:12px}
.smkv-danger{color:#ff7b7b!important}
.smkv-own{margin-left:6px;font-size:10.5px;color:#8b95a5;background:#1c222b;border-radius:8px;padding:1px 6px;font-weight:normal}
.smkv-file .smkv-del{margin-left:auto;opacity:.6}.smkv-file .smkv-del:hover{opacity:1;color:#ff7b7b}
.smkv-dlf2 .smkv-check{display:flex;align-items:center;gap:4px;color:#c9cfd8;font-size:13px}
.smkv-n{margin-left:auto;color:#5f6876;font-size:12px}
#smkv-browse{overflow:auto;min-width:0}
#smkv-toolbar{position:sticky;top:0;z-index:2;display:flex;gap:8px;align-items:center;flex-wrap:wrap;padding:12px 22px;background:rgba(13,15,19,.94);backdrop-filter:blur(6px);border-bottom:1px solid #191d24}
#smkv-toolbar input,#smkv-toolbar select{padding:7px 10px;background:#0b0d11;border:1px solid #2a313c;border-radius:7px;color:#fff;font:inherit}
#smkv-q{width:min(320px,50vw)}
.smkv-back{color:#9aa3b2;padding:6px 8px}
#smkv-view{padding:6px 22px 40px}
.smkv-h{color:#fff;font-size:16px;margin:22px 0 10px}
.smkv-h a{color:#9cc8ff}
.smkv-dim{padding:24px 0;color:#6f7988}
.smkv-dim2{color:#7d8696;font-size:13px}
.smkv-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:18px 16px;margin-top:14px}
.smkv-grid.sq{grid-template-columns:repeat(auto-fill,minmax(160px,1fr))}
.smkv-row{display:grid;grid-auto-flow:column;grid-auto-columns:150px;gap:14px;overflow-x:auto;padding-bottom:8px}
.smkv-row:has(.wide){grid-auto-columns:260px}
.smkv-card{cursor:pointer;min-width:0}
.smkv-card:hover .smkv-poster{outline:2px solid #4a9eff}
.smkv-poster{position:relative;aspect-ratio:2/3;background:linear-gradient(135deg,#1d2430,#11151c);border-radius:8px;overflow:hidden;display:grid;place-items:center;text-align:center}
.smkv-poster.sq{aspect-ratio:1}
.smkv-poster.wide{aspect-ratio:16/9}
.smkv-poster.round{border-radius:50%}
.smkv-poster img{width:100%;height:100%;object-fit:cover;display:block}
.smkv-poster span{padding:10px;color:#8b95a5;font-size:13px;word-break:break-word}
.smkv-poster em{position:absolute;top:6px;right:6px;font-style:normal;font-size:11px;background:rgba(0,0,0,.7);color:#fff;border-radius:6px;padding:1px 6px}
.smkv-pbar{position:absolute;left:0;right:0;bottom:0;height:4px;background:rgba(0,0,0,.5)}
.smkv-pbar i{display:block;height:100%;background:#4a9eff}
.smkv-ct{color:#e3e7ed;margin-top:7px;font-size:13.5px;line-height:1.3;overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}
.smkv-cs{color:#6f7988;font-size:12px}
.smkv-chips{display:flex;flex-wrap:wrap;gap:6px;margin:8px 0}
.smkv-chips a{background:#1c2430;color:#c4d4ea;border-radius:12px;padding:2px 10px;font-size:12px}
.smkv-chips.big a{font-size:14px;padding:6px 14px}
.smkv-chips small{color:#6f7988}
.smkv-tabs{display:flex;gap:6px;margin:18px 0 6px;flex-wrap:wrap}
.smkv-tabs.inline{margin:0}
.smkv-tabs button,.smkv-tabs a{background:#151920!important;border:1px solid #232a34!important;border-radius:16px!important;padding:5px 12px!important;color:#c9cfd8}
.smkv-tabs .on{background:#2b6fd6!important;border-color:#2b6fd6!important;color:#fff!important}
.smkv-facts{color:#9aa3b2;margin:4px 0}
.smkv-ov{color:#b7bfcb;line-height:1.55;max-width:860px}
.smkv-cast{display:grid;grid-auto-flow:column;grid-auto-columns:92px;gap:12px;overflow-x:auto;padding:6px 0 10px}
.smkv-cast>div{text-align:center;font-size:12px}
.smkv-cast b{display:block;color:#e3e7ed;font-weight:500;margin-top:5px}
.smkv-cast span{color:#6f7988}
.smkv-face{width:72px;height:72px;margin:auto;border-radius:50%;overflow:hidden;background:#1d2430;display:grid;place-items:center;color:#8b95a5;font-size:22px}
.smkv-face img{width:100%;height:100%;object-fit:cover}
.smkv-showhead,.smkv-albumhead{display:flex;gap:22px;align-items:flex-start;margin-top:12px;padding:20px;border-radius:12px;background-size:cover;background-position:center right}
.smkv-showhead h2,.smkv-albumhead h2{color:#fff;margin:0;font-size:26px}
.smkv-dposter{width:170px;border-radius:8px;flex:none;box-shadow:0 8px 30px rgba(0,0,0,.5)}
.smkv-albumhead .smkv-poster.big{width:190px;flex:none}
.smkv-eps{display:flex;flex-direction:column;gap:4px;margin-top:8px}
.smkv-ep{display:flex;gap:14px;padding:8px;border-radius:8px;cursor:pointer}
.smkv-ep:hover{background:#151a22}
.smkv-ep b{color:#e3e7ed;font-weight:500}
.smkv-ep p{margin:4px 0 0;color:#8b95a5;font-size:13px;overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}
.smkv-still{position:relative;width:180px;aspect-ratio:16/9;flex:none;border-radius:6px;overflow:hidden;background:#1a1f28;display:grid;place-items:center;color:#5d6673}
.smkv-still img{width:100%;height:100%;object-fit:cover}
.smkv-tracks{width:100%;border-collapse:collapse;margin-top:12px}
.smkv-tracks tr{cursor:pointer}
.smkv-tracks tr:hover{background:#151a22}
.smkv-tracks tr.on b{color:#4a9eff}
.smkv-tracks td{padding:7px 10px;border-bottom:1px solid #161a21}
.smkv-tracks td.n{width:32px;color:#6f7988;text-align:right}
.smkv-tracks td.d{width:60px;color:#6f7988;text-align:right;font-variant-numeric:tabular-nums}
.smkv-tracks b{color:#e3e7ed;font-weight:500}
.smkv-dir{padding:14px 0 4px;color:#6f7988;font-size:11px;text-transform:uppercase;letter-spacing:.5px;word-break:break-all}
.smkv-item{padding:7px 10px;cursor:pointer;border-radius:6px}
.smkv-item:hover{background:#171b22}
.smkv-name{color:#e3e7ed;word-break:break-word}
.smkv-sub{font-size:12px;color:#6f7988}
.smkv-resume{color:#7cc4ff}
/* detail modal */
#smkv-detail{position:fixed;inset:0;background:rgba(4,5,7,.78);display:none;place-items:center;z-index:20;padding:20px}
#smkv-detail.show{display:grid}
.smkv-dbox{position:relative;box-sizing:border-box;background:#12161d;border:1px solid #232a34;border-radius:14px;width:min(900px,100%);max-height:92vh;overflow:auto;padding:0 24px 24px}
@media (max-width:600px){#smkv-detail{padding:8px}.smkv-dbox{padding:0 14px 16px;max-height:96vh}}
.smkv-dbox h2{color:#fff;margin:0;font-size:24px}
.smkv-x{position:absolute;top:10px;right:10px;z-index:2;border-radius:50%!important;width:34px;height:34px;padding:0!important;background:rgba(0,0,0,.6)!important}
.smkv-hero{height:260px;margin:0 -24px;background-size:cover;background-position:center;mask-image:linear-gradient(#000 55%,transparent)}
.smkv-dhead{display:flex;gap:20px;align-items:flex-end;margin-top:28px;position:relative;padding-right:40px}
.smkv-hero+.smkv-dhead{margin-top:-90px}
.smkv-files{display:flex;flex-direction:column;gap:8px;margin-top:14px}
.smkv-file{display:flex;gap:10px;align-items:center;background:#171c24;border-radius:8px;padding:8px 10px}
.smkv-file span{color:#c9cfd8;font-size:13px;word-break:break-all;flex:1;min-width:0}
.smkv-file button,.smkv-file a{flex:none}
.smkv-file small{color:#6f7988}
.smkv-admin-row{margin-top:14px;color:#6f7988;font-size:12px}
.smkv-esearch,.smkv-erow{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
.smkv-erow{margin-top:16px}
.smkv-esearch input,.smkv-eform input,.smkv-eform textarea{padding:7px 10px;background:#0b0d11;border:1px solid #2a313c;border-radius:7px;color:#fff;font:inherit}
.smkv-esearch #eq{flex:1;min-width:180px}
.smkv-eres{display:flex;flex-direction:column;gap:6px;margin-top:10px;max-height:340px;overflow:auto}
.smkv-eitem{display:flex;gap:12px;padding:8px;border-radius:8px;cursor:pointer;background:#171c24}
.smkv-eitem:hover{outline:2px solid #4a9eff}
.smkv-eitem img,.smkv-enop{width:54px;height:80px;object-fit:cover;border-radius:5px;flex:none;background:#232a34}
.smkv-eitem b{color:#fff}.smkv-eitem p{margin:4px 0 0;color:#8b95a5;font-size:12px}
.smkv-eform{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:10px 14px}
.smkv-eform label{display:flex;flex-direction:column;gap:4px;color:#8b95a5;font-size:12px}
.smkv-eform label:has(textarea){grid-column:1/-1}
.smkv-epedit,.smkv-tedit{margin-left:8px;padding:1px 7px!important;font-size:12px!important;opacity:.6}
.smkv-ep:hover .smkv-epedit,.smkv-tracks tr:hover .smkv-tedit{opacity:1}
.smkv-tracks td.e{width:36px}
/* video overlay */
#smkv-watch{position:fixed;inset:0;z-index:15;background:#0d0f13;display:none;flex-direction:column;overflow:auto}
#smkv-watch.show{display:flex}
#smkv-player{position:relative;background:#000;aspect-ratio:16/9;max-height:80vh;width:100%;overflow:hidden;user-select:none;flex:none}
#smkv-player:fullscreen{max-height:none;aspect-ratio:auto}
#smkv-video{width:100%;height:100%;display:block;background:#000}
#smkv-canvas{position:absolute;inset:0;width:100%;height:100%;display:none;background:#000}
#smkv-ann{position:relative}#smkv-ann i{position:absolute;top:-5px;right:-5px;background:#e5484d;color:#fff;font-style:normal;font-size:10px;border-radius:9px;padding:0 5px;font-weight:700;line-height:15px}
#smkv-annbar{display:flex;gap:12px;align-items:flex-start;margin:12px 24px 0;padding:10px 12px;border-radius:10px;background:#16263d;border:1px solid #234066;color:#d7e6fb;font-size:13.5px}
#smkv-annbar[hidden]{display:none}
#smkv-annbar.lvl-warning{background:#2e2514;border-color:#5a4520;color:#f6e3bd}
#smkv-annbar>div{flex:1;min-width:0;word-break:break-word}#smkv-annbar b{color:#fff}
#smkv-annbar a,.smkv-ann-b a{color:#7cc4ff}
#smkv-annbar button{flex:none;font-size:12px!important}
.smkv-ann-box{width:min(560px,100%)!important}
.smkv-ann-d{padding-top:24px}.smkv-ann-h{font-size:18px;font-weight:600;color:#fff;margin-bottom:8px;padding-right:36px}
.smkv-ann-b{color:#d0d6df;line-height:1.55;margin-bottom:10px;word-break:break-word}
.smkv-ann-item{border:1px solid #232a34;border-left:3px solid #3b6fd6;border-radius:8px;padding:10px 12px;margin-bottom:10px}
.smkv-ann-item.lvl-warning{border-left-color:#d9a43b}.smkv-ann-item.lvl-important{border-left-color:#e5484d}
.smkv-ann-item.read{opacity:.7}.smkv-ann-item .smkv-ann-h{font-size:15px}
.smkv-new{font-style:normal;font-size:10px;background:#e5484d;color:#fff;border-radius:8px;padding:0 6px;vertical-align:2px}
@media (max-width:820px){#smkv-annbar{margin:10px 12px 0}}
#smkv-player.engine #smkv-canvas{display:block}
#smkv-player.engine #smkv-video{visibility:hidden}
#smkv-player:not(.ctl) #smkv-canvas{cursor:none}
#smkv-player:not(.ctl) #smkv-video{cursor:none}
#smkv-subs{position:absolute;left:5%;right:5%;bottom:7%;text-align:center;pointer-events:none;color:#fff;line-height:1.25;
  text-shadow:0 0 3px #000,0 0 3px #000,1px 1px 2px #000,-1px -1px 2px #000,1px -1px 2px #000,-1px 1px 2px #000;transition:bottom .2s}
#smkv-player.ctl #smkv-subs{bottom:max(7%,78px)}
#smkv-subs span{background:rgba(0,0,0,.18);padding:0 .2em;border-radius:3px;font-weight:500}
#smkv-controls{position:absolute;left:0;right:0;bottom:0;padding:24px 12px 8px;background:linear-gradient(transparent,rgba(0,0,0,.85));opacity:0;transition:opacity .2s}
#smkv-player.ctl #smkv-controls{opacity:1}
#smkv-controls .smkv-row{display:flex;align-items:center;gap:8px;margin-top:4px}
#smkv-watch #smkv-controls button{background:transparent;border:none;color:#fff;font-size:15px;padding:4px 8px}
#smkv-watch #smkv-controls button:hover{background:rgba(255,255,255,.12)}
#smkv-time,#smkv-atime{color:#e3e7ed;font-variant-numeric:tabular-nums;font-size:13px;white-space:nowrap}
#smkv-seek,#smkv-aseek{width:100%;margin:0;-webkit-appearance:none;appearance:none;height:5px;border-radius:3px;cursor:pointer;
  background:linear-gradient(to right,#4a9eff var(--p,0%),rgba(255,255,255,.25) var(--p,0%))}
#smkv-seek::-webkit-slider-thumb,#smkv-aseek::-webkit-slider-thumb{-webkit-appearance:none;width:13px;height:13px;border-radius:50%;background:#fff}
#smkv-seek::-moz-range-thumb,#smkv-aseek::-moz-range-thumb{width:13px;height:13px;border-radius:50%;background:#fff;border:none}
#smkv-vol,#smkv-avol{width:90px}
#smkv-spinner{position:absolute;left:50%;top:50%;width:44px;height:44px;margin:-22px;border:4px solid rgba(255,255,255,.2);border-top-color:#fff;border-radius:50%;
  animation:smkv-spin .8s linear infinite;display:none;pointer-events:none}
#smkv-spinner.show{display:block}
@keyframes smkv-spin{to{transform:rotate(360deg)}}
#smkv-toast{position:fixed;top:16px;left:50%;transform:translateX(-50%);z-index:40;background:rgba(20,24,31,.95);border:1px solid #2a313c;color:#e3e7ed;padding:8px 14px;border-radius:8px;
  font-size:13px;opacity:0;transition:opacity .2s;pointer-events:none;max-width:80%;text-align:center}
#smkv-toast.show{opacity:1;pointer-events:auto}
#smkv-toast button{margin-left:8px;padding:2px 8px;background:#2b6fd6;border:none;color:#fff;border-radius:5px;cursor:pointer}
#smkv-bar{padding:14px 18px 24px}
.smkv-titlerow{display:flex;gap:12px;align-items:center}
#smkv-title{margin:0;font-size:17px;color:#fff;word-break:break-word}
#smkv-meta{color:#7d8696;font-size:13px;margin-top:4px}
.smkv-badge{display:inline-block;padding:0 7px;border-radius:9px;font-size:11px;background:#23402a;color:#8fe0a0}
.smkv-badge.transcode{background:#4a3a1c;color:#ffcf7a}
.smkv-badge.copy{background:#1e3352;color:#9cc8ff}
.smkv-opts{display:flex;flex-wrap:wrap;gap:12px 18px;margin-top:14px}
.smkv-opts label{display:flex;flex-direction:column;gap:4px;font-size:11px;color:#7d8696;text-transform:uppercase;letter-spacing:.5px}
.smkv-opts select{background:#151920;color:#e3e7ed;border:1px solid #2a313c;border-radius:6px;padding:6px 8px;font:13px system-ui,sans-serif;max-width:360px;text-transform:none}
.smkv-group{display:flex;align-items:center;gap:6px;text-transform:none}
#smkv-sd{min-width:44px;text-align:center;color:#e3e7ed;font-size:13px;font-variant-numeric:tabular-nums}
.smkv-keys{margin-top:16px;color:#566070;font-size:12px}
/* audio bar */
#smkv-abar{position:fixed;left:0;right:0;bottom:0;height:76px;z-index:12;background:#12161d;border-top:1px solid #232a34;display:none;align-items:center;gap:14px;padding:0 16px}
#smkv-abar.show{display:flex}
#smkv-acover{width:54px;height:54px;border-radius:6px;overflow:hidden;background:#1d2430;display:grid;place-items:center;color:#6f7988;flex:none}
#smkv-acover img{width:100%;height:100%;object-fit:cover}
.smkv-ainfo{width:220px;min-width:0;display:flex;flex-direction:column}
.smkv-ainfo b{color:#fff;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.smkv-ainfo span{color:#7d8696;font-size:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.smkv-actl{flex:1;display:flex;flex-direction:column;align-items:center;gap:4px;min-width:0}
.smkv-abtns{display:flex;gap:6px;align-items:center}
#smkv-abar button{background:transparent;border:none;color:#c9cfd8;font-size:16px}
#smkv-abar button.big{background:#fff;color:#000;border-radius:50%;width:34px;height:34px;padding:0;font-size:13px}
#smkv-arep{opacity:.45}#smkv-arep.on{opacity:1}
.smkv-aseekrow{display:flex;gap:10px;align-items:center;width:100%;max-width:640px}
.smkv-aright{display:flex;gap:6px;align-items:center}
#smkv-login{position:fixed;inset:0;background:rgba(5,6,8,.85);display:none;place-items:center;z-index:50}
#smkv-login.show{display:grid}
#smkv-login form{background:#151920;border:1px solid #2a313c;border-radius:10px;padding:22px;width:min(340px,90vw);display:flex;flex-direction:column;gap:10px}
#smkv-login h2{margin:0 0 4px;font-size:17px;color:#fff}
#smkv-login input[name]{padding:9px 10px;background:#0b0d11;border:1px solid #2a313c;border-radius:6px;color:#fff;font:inherit}
#smkv-login button{background:#2b6fd6;border-color:#2b6fd6;color:#fff;padding:9px}
.smkv-check{font-size:13px;color:#8b95a5;display:flex;gap:6px;align-items:center}
#smkv-login .msg{color:#ff8a8a;font-size:13px;min-height:1em}
@media (max-width:820px){
  #smkv-app{grid-template-columns:1fr;grid-template-rows:auto 1fr}
  #smkv-side{border-right:none;border-bottom:1px solid #1f242d}
  #smkv-nav{flex-direction:row;overflow-x:auto;padding:0 8px 8px}
  #smkv-nav a{white-space:nowrap}
  .smkv-n{display:none}
  #smkv-view,#smkv-toolbar{padding-left:12px;padding-right:12px}
  .smkv-grid{grid-template-columns:repeat(auto-fill,minmax(110px,1fr));gap:12px}
  .smkv-showhead,.smkv-albumhead,.smkv-dhead{flex-direction:column;align-items:flex-start}
  .smkv-dposter{width:120px}
  .smkv-still{width:120px}
  #smkv-vol,.smkv-ainfo,#smkv-avol,#smkv-aqueue{display:none}
}`;

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', bootApp);
  else bootApp();
})();
