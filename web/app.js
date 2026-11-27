/*
 * Delos web app (formerly StreamMKV) — served by the Delos server at its own address
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
        .row{display:flex;gap:8px;margin-top:18px;justify-content:flex-end;flex-wrap:wrap}
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
        ${window.isSecureContext ? '' : `<div class="hint" style="color:#f0c674">This page is plain http, so the browser doesn't allow it — open <a style="color:#7cc4ff" href="${'https://' + location.host + location.pathname}">the https address</a> (<a style="color:#7cc4ff" href="tls" target="_blank">help</a>).</div>`}
        <label>Preferred audio languages</label><input name="audioLang" placeholder="jpn,eng">
        <label>Preferred subtitle languages</label><input name="subLang" placeholder="tha,eng">
        <div class="hint">Comma-separated ISO codes, first match wins. Per-file choices are remembered.</div>
        <label>Max height when transcoding</label><input name="maxh" type="number" min="240" max="2160" step="1">
        <div class="msg"></div>
        <div class="row">
          <button type="button" data-act="refresh" title="Rescan the server's libraries">⟳ Reload libraries</button>
          <button type="button" data-act="logout">Log out</button>
          <span style="flex:1"></span>
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
    root.querySelector('[data-act=refresh]').onclick = () => { close(); document.getElementById('smkv-refresh')?.click(); };
    root.querySelector('[data-act=logout]').onclick = () => { close(); document.getElementById('smkv-logout')?.click(); };
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
      subSize: +lsGet('subSize', 100) || 100, subPos: +lsGet('subPos', 0) || 0, // % size, % raise (kept across videos)
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

    // tells admins which app / version people use (the page's version = the server's when it loaded)
    const clientHdr = () => ({ 'X-Delos-Client': 'web/' + ((BR.me && BR.me.version) || '') });
    async function api(path, params = {}, opts = {}, retried = false) {
      const u = new URL('api/' + path, BASE);
      for (const [k, v] of Object.entries(params)) u.searchParams.set(k, v);
      const r = await fetch(u, { credentials: 'same-origin', headers: clientHdr() });
      if (r.status === 401 && !retried) { await ensureLogin(); return api(path, params, opts, true); }
      if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || r.statusText);
      return opts.text ? r.text() : r.json();
    }

    async function apiPost(path, body, retried = false) {
      const r = await fetch(new URL('api/' + path, BASE), {
        method: 'POST', credentials: 'same-origin', keepalive: true,
        headers: Object.assign({ 'Content-Type': 'application/json' }, clientHdr()), body: JSON.stringify(body),
      });
      if (r.status === 401 && !retried) { await ensureLogin(); return apiPost(path, body, true); }
      if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || r.statusText);
      return r.json();
    }
    async function apiSend(method, path, body) {
      const r = await fetch(new URL('api/' + path, BASE), { method, credentials: 'same-origin', headers: { 'Content-Type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
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
    const feat = (k) => !BR.me || !BR.me.features || BR.me.features[k] !== false; // older servers: everything on
    function modeOf(h) {
      if (/^#\/(downloads|ranking|party)/.test(h)) return BR.mode;
      if (/^#\/(music|album|artist|playlist)(\/|$)/.test(h)) return 'music';
      const m = h.match(/^#\/lib\/([^/]+)/);
      if (m && libType(decodeURIComponent(m[1])) === 'music') return 'music';
      return 'videos';
    }
    function renderNav() {
      const cur = location.hash || '#/';
      const music = BR.mode === 'music';
      // "🏠 Home" → icon + text, so the folded sidebar can show just the icon
      const mini = document.body.classList.contains('smkv-side-mini');
      const lbl = (label) => { const i = label.indexOf(' '); return i > 0 ? `<span class="smkv-ni">${label.slice(0, i)}</span><span class="smkv-nt">${label.slice(i + 1)}</span>` : label; };
      const tip = (label, n) => mini ? ` title="${label.slice(label.indexOf(' ') + 1).replace(/<[^>]*>/g, '').replace(/"/g, '&quot;')}${n ? ' · ' + n : ''}"` : '';
      const a = (href, label, on, n) => `<a href="${href}" class="${on ? 'on' : ''}"${tip(label, n)}>${lbl(label)}${n ? `<span class="smkv-n">${n}</span>` : ''}</a>`;
      const musicCount = BR.libs.filter((l) => l.type === 'music').reduce((t, l) => t + (l.count || 0), 0);
      let html = `<div class="smkv-modes">${a('#/', '🎬 Videos', !music)}${a('#/music', '🎵 Music', music)}</div>`;
      // libraries: the server's own first, then each person's (mine first) in a fold-out group
      const libGroups = (list) => {
        const me = BR.me && BR.me.user;
        const link = (l) => a(`#/lib/${encodeURIComponent(l.id)}`, `${typeIcon[l.type] || '📁'} ${esc(l.name)}`, cur === '#/lib/' + encodeURIComponent(l.id) || cur.startsWith('#/lib/' + encodeURIComponent(l.id) + '/'), l.count);
        let h = list.filter((l) => !l.owner).map(link).join('');
        const owners = [...new Set(list.filter((l) => l.owner).map((l) => l.owner))].sort((x, y) => (x === me ? -1 : y === me ? 1 : x.localeCompare(y)));
        const open = lsGet('navOpen', {});
        const narrow = matchMedia('(max-width:820px)').matches;
        for (const o of owners) {
          const mine = list.filter((l) => l.owner === o);
          const here = mine.some((l) => cur.startsWith('#/lib/' + encodeURIComponent(l.id)));
          h += `<details class="smkv-ngrp" data-o="${esc(o)}" ${narrow || here || open[o] ? 'open' : ''}><summary${mini ? ` title="${o === me ? 'My libraries' : esc(o)}"` : ''}>${avatarHtml(o, 20)}<b class="smkv-gn">${o === me ? 'My libraries' : esc(o)}</b><span class="smkv-n">${mine.length}</span></summary>${mine.map(link).join('')}</details>`;
        }
        return h;
      };
      if (!music) {
        const vl = BR.libs.filter((l) => l.type !== 'music');
        html += a('#/', '🏠 Home', cur === '#/') + (vl.some((l) => l.owner) ? '<div class="smkv-navh">Libraries</div>' : '') + libGroups(vl);
      } else {
        const t = (cur.match(/^#\/music\/?([^/]*)/) || [])[1] || '';
        html += a('#/music', '🎧 Listen now', cur === '#/music' || cur === '#/music/')
          + a('#/music/albums', '💿 Albums', t === 'albums' || cur.startsWith('#/album/'))
          + a('#/music/artists', '🎤 Artists', t === 'artists' || cur.startsWith('#/artist/'))
          + a('#/music/genres', '🏷 Genres', t === 'genres')
          + a('#/music/songs', '🎵 Songs', t === 'songs', musicCount)
          + a('#/music/playlists', '📃 Playlists', t === 'playlists' || cur.startsWith('#/playlist/'))
          + a('#/music/now', `▶ Now playing${A.cur ? '' : ''}`, t === 'now', A.queue.length || '');
        const ml = BR.libs.filter((l) => l.type === 'music');
        if (ml.length > 1 || ml.some((l) => l.owner)) html += '<div class="smkv-navh">Libraries</div>' + libGroups(ml);
      }
      html += `<div class="smkv-navsep"></div>` + a('#/party', '🎉 Party', cur.startsWith('#/party')) + a('#/ranking', '🏆 Ranking', cur.startsWith('#/ranking'));
      if (feat('requests') && BR.me) html += a('#/requests', '🙋 Requests', cur.startsWith('#/requests'), BR.rqOpen || '');
      if (canDownload()) html += a('#/downloads', '⬇ Downloads', cur.startsWith('#/downloads'));
      $('#smkv-nav').innerHTML = html;
      $('#smkv-nav').querySelectorAll('details.smkv-ngrp').forEach((d) => d.ontoggle = () => {
        if (matchMedia('(max-width:820px)').matches) return;
        const o = lsGet('navOpen', {}); o[d.dataset.o] = d.open; lsSet('navOpen', o);
      });
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
      toolbar.innerHTML = `<input id="smkv-q" type="search" placeholder="Search…" value="${esc(searchQ)}" autocomplete="off">${html || ''}
        <button id="smkv-rawbtn" class="${lsGet('rawNames', false) ? 'on' : ''}" title="Show the original file names (and the TMDB match) under every title">📄 File names</button>`;
      $('#smkv-rawbtn').onclick = (e) => {
        const on = !lsGet('rawNames', false); lsSet('rawNames', on);
        document.body.classList.toggle('smkv-raw-on', on); e.currentTarget.classList.toggle('on', on);
      };
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
          if (parts[1] === 'playlists') return await playlistsView();
          return await musicView('_all', parts[1], parts[2]);
        }
        if (parts[0] === 'downloads') return await downloadsView();
        if (parts[0] === 'ranking') return await rankingView(parts[1] || 'month');
        if (parts[0] === 'requests') return await requestsView();
        if (parts[0] === 'party') return await partyView();
        if (parts[0] === 'lib') {
          const t = libType(parts[1]);
          if (t === 'movies') return await moviesView(parts[1], parts[2] || '');
          if (t === 'tv') return await showsView(parts[1], parts[2] || '');
          if (t === 'music') return await musicView(parts[1], parts[2] || 'albums', parts[3]);
          return await filesView(parts[1]);
        }
        if (parts[0] === 'show') return await showView(parts[1], parts.slice(2).join('/'));
        if (parts[0] === 'album') return await albumView(parts[1], parts.slice(2).join('/'));
        if (parts[0] === 'playlist') return await playlistView(parts[1]);
        if (parts[0] === 'artist') return await artistView(parts[1], parts.slice(2).join('/'));
        view.innerHTML = '<div class="smkv-dim">Not found</div>';
      } catch (e) {
        view.innerHTML = `<div class="smkv-dim">Error: ${esc(e.message)}</div>`;
      }
    }
    window.addEventListener('hashchange', () => { searchQ = ''; route(); });

    // ------------------------------------------------------------ browse: shared bits
    const progressBar = (it) => it.pos && it.duration ? `<div class="smkv-pbar"><i style="width:${Math.min(100, it.pos / it.duration * 100).toFixed(1)}%"></i></div>` : '';
    // the original file name(s) behind a title — shown when "📄 File names" is on, to check what TMDB / tags matched
    const rawNames = (items, extra) => {
      const names = [...new Set(items.map((i) => i.name))];
      return `<div class="smkv-raw" title="${esc(items.map((i) => i.path).join('\n'))}">${esc(names[0] || '')}${names.length > 1 ? ` <i>+${names.length - 1} more</i>` : ''}${extra ? `<br><i>${esc(extra)}</i>` : ''}</div>`;
    };
    const tmdbTag = (id) => id > 0 ? `TMDB #${id}` : 'not matched on TMDB';
    function posterCard(o) {
      return `<div class="smkv-card" data-k="${esc(o.key)}">
        <div class="smkv-poster${o.square ? ' sq' : ''}${o.wide ? ' wide' : ''}">${o.img ? `<img loading="lazy" src="${esc(o.img)}" alt="">` : `<span>${esc(o.title)}</span>`}${o.badge ? `<em>${esc(o.badge)}</em>` : ''}${o.bar || ''}</div>
        <div class="smkv-ct">${esc(o.title)}</div><div class="smkv-cs">${esc(o.sub || '')}</div>${o.raw || ''}</div>`;
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
      toolbar.querySelector('#smkv-q').style.display = 'none'; $('#smkv-rawbtn').hidden = true;
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
        const showCard = (it) => { const sh = (x.d.shows || {})[it.show] || {}; return posterCard({ key: 's:' + x.l.id + ':' + it.show, title: sh.title || it.title, sub: 'New episodes', img: sh.poster }); };
        if (x.l.type === 'movies' || (x.l.type === 'videos' && items.some((it) => it.show))) {
          const seen = new Set();
          cards = items.filter((it) => { const k = it.show ? 's' + it.show : it.movieId || it.path; if (seen.has(k)) return false; seen.add(k); return true; }).slice(0, 16)
            .map((it) => {
              if (it.show) return showCard(it);
              if (x.l.type === 'videos') return posterCard({ key: 'f:' + it.path, title: it.name, sub: it.dir || '', img: '' });
              const m = it.movieId ? x.d.movies[it.movieId] : null; return posterCard({ key: 'm:' + x.l.id + ':' + (it.movieId || it.path), title: m ? m.title : it.title, sub: String((m && m.year) || it.year || ''), img: m && m.poster });
            }).join('');
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
    // ---- series (TV libraries, and S01E02 files found in movie / plain-folder libraries)
    const epNums = (e) => { const out = []; for (let n = e.episode; n <= Math.max(e.episode, e.episodeEnd || 0); n++) out.push(n); return out; };
    const epLabel = (e) => e.episode ? (e.episodeEnd > e.episode ? `E${e.episode}–${e.episodeEnd}` : 'E' + e.episode) : '';
    // episodes not on the server: from TMDB's season list when matched, otherwise the gaps before the last one we have
    function missingEps(d, sh, eps, season) {
      if (!season) return [];
      const have = new Set(eps.filter((e) => e.season === season).flatMap(epNums));
      const meta = sh && sh.tmdbId && d.seasons ? d.seasons[sh.tmdbId + '/' + season] : null;
      const today = new Date().toISOString().slice(0, 10);
      if (meta && Object.keys(meta).length) {
        return Object.entries(meta).map(([n, m]) => ({ episode: +n, meta: m, future: !!(m.aired && m.aired > today) }))
          .filter((x) => x.episode > 0 && !have.has(x.episode)).sort((a, b) => a.episode - b.episode);
      }
      const out = [];
      for (let n = 1; n < Math.max(0, ...have); n++) if (!have.has(n)) out.push({ episode: n, meta: null, future: false });
      return out;
    }
    function missingCount(d, sh, eps) {
      return [...new Set(eps.map((e) => e.season))].reduce((t, s) => t + missingEps(d, sh, eps, s).filter((x) => !x.future).length, 0);
    }
    function seriesOfLib(d) {
      const shows = new Map();
      for (const it of d.items) {
        if (!it.show) continue;
        if (!shows.has(it.show)) shows.set(it.show, { key: it.show, meta: (d.shows || {})[it.show] || { title: it.title }, eps: [] });
        shows.get(it.show).eps.push(it);
      }
      return shows;
    }
    const seriesCard = (d, s) => {
      const miss = missingCount(d, s.meta, s.eps);
      return posterCard({ key: s.key, title: s.meta.title, img: s.meta.poster, badge: miss ? `${miss} missing` : '',
        sub: `${s.eps.length} file${s.eps.length > 1 ? 's' : ''}${s.meta.year ? ' · ' + s.meta.year : ''}`, raw: rawNames(s.eps, tmdbTag(s.meta.tmdbId || 0)) });
    };
    // the "Series" row on top of a movie / plain-folder library
    function seriesRow(lib, d, genre) {
      const list = [...seriesOfLib(d).values()].filter((s) => (!genre || (s.meta.genres || []).includes(genre)) && matchQ(s.meta.title, s.meta.originalTitle, ...s.eps.map((e) => e.name)))
        .sort((a, b) => Math.max(...b.eps.map((e) => e.added)) - Math.max(...a.eps.map((e) => e.added)));
      return list.length ? `<h3 class="smkv-h">📺 Series</h3><div class="smkv-grid smkv-series">${list.map((s) => seriesCard(d, s)).join('')}</div>` : '';
    }
    const bindSeries = (lib) => view.querySelectorAll('.smkv-series .smkv-card').forEach((c) => c.onclick = (e) => { e.stopPropagation(); location.hash = `#/show/${encodeURIComponent(lib)}/${encodeURIComponent(c.dataset.k)}`; });

    // ---- pick several files → one series
    const selBar = (n) => `<div id="smkv-selbar"><span>${n ? `<b>${n}</b> file${n > 1 ? 's' : ''} picked` : 'Tap files to pick them'}</span>
      <button class="smkv-primary" data-s="group" ${n ? '' : 'disabled'}>📺 Group as series…</button><button data-s="clear" ${n ? '' : 'disabled'}>Clear</button><button data-s="done">Done</button></div>`;
    function bindSelBar(lib, d, picked, clear, done) {
      const bar = $('#smkv-selbar');
      bar.querySelector('[data-s=clear]').onclick = clear;
      bar.querySelector('[data-s=done]').onclick = done;
      bar.querySelector('[data-s=group]').onclick = () => groupSeriesDialog(lib, d, picked());
    }
    const natural = (a, b) => a.localeCompare(b, undefined, { numeric: true, sensitivity: 'base' });
    function groupSeriesDialog(lib, d, items) {
      if (!items.length) return;
      const picked = [...items], byName = [...items].sort((a, b) => natural(a.name, b.name));
      const order = () => root0.querySelector('#smkv-gsf').num.value === 'name' ? byName : picked;
      let root0 = null;
      const existing = [...seriesOfLib(d).values()].map((s) => s.meta.title).filter(Boolean);
      const guess = items.find((i) => i.show)?.title || (seriesOf(items[0].name) || {}).title || '';
      const preview = (root) => {
        const f = root.querySelector('#smkv-gsf'), start = Math.max(1, parseInt(f.start.value, 10) || 1), keep = f.num.value === 'keep';
        f.start.style.visibility = keep ? 'hidden' : '';
        root.querySelector('#smkv-gsp').innerHTML = order().map((it, i) => `<div><b>S${f.season.value || 1}E${keep && it.episode ? it.episode : start + i}</b> ← ${esc(it.name)}</div>`).join('');
      };
      detailModal(`<h2>Group as series</h2><div class="smkv-dim2">${items.length} file${items.length > 1 ? 's' : ''} → one series. You can undo it per episode with ✎ → “Reset to automatic”.</div>
        <form id="smkv-gsf" style="display:grid;grid-template-columns:auto 1fr;gap:8px 12px;align-items:center;margin-top:12px">
          <label>Series</label><input class="smkv-inp" name="title" list="smkv-gsl" value="${esc(guess)}" placeholder="Series title (pick one to add to it)" required autocomplete="off">
          <datalist id="smkv-gsl">${existing.map((t) => `<option value="${esc(t)}">`).join('')}</datalist>
          <label>Season</label><input class="smkv-inp" name="season" type="number" min="0" value="${items[0].season || 1}" style="width:90px">
          <label>Episodes</label><div><select class="smkv-inp" name="num" style="width:auto">
            <option value="picked">Number them in the order I picked them, from</option><option value="name">Number them in name order, from</option>${items.every((i) => i.episode) ? '<option value="keep" selected>Keep the numbers found in the names</option>' : ''}</select>
            <input class="smkv-inp" name="start" type="number" min="1" value="1" style="width:70px;margin-left:6px"></div>
        </form>
        <div id="smkv-gsp" class="smkv-dim2" style="margin-top:12px;max-height:220px;overflow:auto;font-size:12.5px;line-height:1.6"></div>
        <div style="display:flex;gap:8px;justify-content:flex-end;margin-top:14px"><button class="smkv-btn2" id="smkv-gsno">Cancel</button><button class="smkv-primary" id="smkv-gsok">📺 Group</button></div>`,
        (root, close) => {
          root0 = root;
          const f = root.querySelector('#smkv-gsf');
          f.oninput = () => preview(root); preview(root);
          root.querySelector('#smkv-gsno').onclick = close;
          root.querySelector('#smkv-gsok').onclick = async () => {
            const title = f.title.value.trim();
            if (!title) return toast('Name the series');
            const start = Math.max(1, parseInt(f.start.value, 10) || 1), keep = f.num.value === 'keep', season = String(parseInt(f.season.value, 10) || 0);
            const ok = root.querySelector('#smkv-gsok'); ok.disabled = true;
            try {
              for (const [i, it] of order().entries()) {
                ok.textContent = `${i + 1} / ${items.length}…`;
                const fields = Object.assign({}, (d.edits || {})[it.path] || {}, { showTitle: title, season, episode: String(keep && it.episode ? it.episode : start + i) });
                await apiPost('meta/edit', { lib: it.path.split('/')[0], key: it.path, fields });
              }
              close(); reloadAfterEdit(lib, `Grouped ${items.length} file${items.length > 1 ? 's' : ''} into “${title}”`);
            } catch (x) { toast(x.message, 5000); ok.disabled = false; ok.textContent = '📺 Group'; }
          };
        });
    }

    async function moviesView(lib, genre) {
      const d = await libData(lib);
      const groups = new Map(); // movieId|path → {meta, items}
      for (const it of d.items) {
        if (it.show) continue; // an episode: in the Series row
        const k = it.movieId ? 'id' + it.movieId : it.path;
        if (!groups.has(k)) groups.set(k, { key: it.movieId || it.path, meta: it.movieId ? d.movies[it.movieId] : null, items: [] });
        groups.get(k).items.push(it);
      }
      const genres = new Set();
      groups.forEach((g) => (g.meta?.genres || []).forEach((x) => genres.add(x)));
      const sortSel = lsGet('sort:' + lib, 'added');
      setToolbar(`${genreOptions(genres, genre)}<select id="smkv-sort">
          <option value="added">Recently added</option><option value="title">Title</option><option value="year">Year</option><option value="rating">Rating</option></select>
          ${canEditLib(lib) ? '<button id="smkv-selbtn" title="Pick several movies / files, then group them into a series">☑ Select</button>' : ''}`, draw);
      let sel = null; // Set of picked group keys while selecting
      const sb = $('#smkv-selbtn');
      if (sb) sb.onclick = () => { sel = sel ? null : new Set(); sb.classList.toggle('on', !!sel); sb.textContent = sel ? '✕ Done' : '☑ Select'; draw(); };
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
        const series = seriesRow(lib, d, genre);
        view.innerHTML = series + (series && list.length ? '<h3 class="smkv-h">🎬 Movies</h3>' : '') + (list.length ? `<div class="smkv-grid smkv-movies">${list.map((g) => {
          const it = g.items.find((i) => i.pos) || g.items[0];
          return (sel ? `<div class="smkv-pickwrap${sel.has(String(g.key)) ? ' picked' : ''}">` : '') + posterCard({ key: String(g.key), title: g.meta?.title || it.title || it.name, sub: [g.meta?.year || it.year, g.meta?.rating ? '★ ' + g.meta.rating.toFixed(1) : ''].filter(Boolean).join(' · '),
            img: g.meta?.poster, bar: progressBar(it), badge: g.items.length > 1 ? g.items.length + ' versions' : '', raw: rawNames(g.items, tmdbTag(g.meta?.id || 0)) }) + (sel ? '</div>' : '');
        }).join('')}</div>` : series ? '' : '<div class="smkv-dim">No movies</div>') + (sel ? selBar([...groups.values()].filter((g) => sel.has(String(g.key))).reduce((n, g) => n + g.items.length, 0)) : '');
        view.querySelectorAll('.smkv-movies .smkv-card').forEach((c) => c.onclick = () => {
          if (!sel) return movieDetail(lib, c.dataset.k);
          if (sel.has(c.dataset.k)) sel.delete(c.dataset.k); else sel.add(c.dataset.k);
          draw();
        });
        if (sel) bindSelBar(lib, d, () => [...sel].flatMap((k) => ([...groups.values()].find((g) => String(g.key) === k) || { items: [] }).items), () => { sel.clear(); draw(); }, () => sb.click());
        bindSeries(lib);
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

    // ------------------------------------------------------------ trailers (YouTube, found through TMDB)
    const TRL = new Map();
    async function trailerButton(slot, q, title) {
      if (!slot || !feat('trailers') || q.lib === '_legacy') return;
      const k = JSON.stringify(q);
      let d = TRL.get(k);
      if (!d) { try { d = await api('trailers', q); } catch { return; } TRL.set(k, d); }
      const list = d.online.map((x) => ({ ...x, label: x.name }));
      if (!list.length || !slot.isConnected) return;
      slot.innerHTML = `<button class="smkv-trlbtn" title="${list.length > 1 ? list.length + ' trailers' : esc(list[0].label)}">🎞 Trailer${list.length > 1 ? `<small>${list.length}</small>` : ''}</button>`;
      slot.firstChild.onclick = () => trailerPlay(list, 0, title);
    }
    function trailerPlay(list, i, title) {
      const x = list[i];
      let m = $('#smkv-trailer');
      if (!m) { m = document.createElement('div'); m.id = 'smkv-trailer'; document.body.appendChild(m); }
      if (!A.el.paused) { A.el.pause(); m.dataset.resume = '1'; }
      m.innerHTML = `<div class="smkv-trlbox">
          <div class="smkv-trlhead"><b>${esc(title)}</b><span class="smkv-dim2">${esc(x.label)}${x.lang ? ' · ' + esc(x.lang.toUpperCase()) : ''}</span>
            <a class="smkv-trlyt" href="https://www.youtube.com/watch?v=${encodeURIComponent(x.key)}" target="_blank" rel="noopener" title="Open on YouTube">YouTube ↗</a>
            <button class="smkv-x" title="Close (Esc)">✕</button></div>
          <div class="smkv-trlvid"><iframe src="https://www.youtube-nocookie.com/embed/${encodeURIComponent(x.key)}?autoplay=1&rel=0&modestbranding=1&playsinline=1" allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe></div>
          ${list.length > 1 ? `<div class="smkv-trllist">${list.map((y, j) => `<button data-j="${j}" class="${j === i ? 'on' : ''}">${esc(y.label)}</button>`).join('')}</div>` : ''}
        </div>`;
      m.classList.add('show');
      m.querySelector('.smkv-x').onclick = trailerClose;
      m.onclick = (e) => { if (e.target === m) trailerClose(); };
      m.querySelectorAll('.smkv-trllist button').forEach((b) => b.onclick = () => trailerPlay(list, +b.dataset.j, title));
    }
    function trailerClose() {
      const m = $('#smkv-trailer');
      if (!m || !m.classList.contains('show')) return false;
      m.classList.remove('show'); m.innerHTML = ''; // drops the iframe: the video stops
      if (m.dataset.resume) { delete m.dataset.resume; A.el.play().catch(() => {}); }
      return true;
    }
    document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && trailerClose()) { e.stopPropagation(); e.preventDefault(); } }, true);

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
            <div class="smkv-trlslot"></div>
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
        ${canEditLib(lib) && lib !== '_legacy' ? `<div class="smkv-admin-row">${m && m.id > 0 ? `TMDB #${m.id}` : m ? 'Edited manually' : 'Not matched'} · <a href="#" class="smkv-fix">✎ Edit / fix match…</a></div>` : ''}`,
        (root, close) => {
          trailerButton(root.querySelector('.smkv-trlslot'), { lib, movie: String(key) }, t);
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
    // metadata edits / grouping: editors & admins everywhere, anyone in their own personal library
    const canEditLib = (lib) => canEdit() || !!(BR.me && lib && libOf(lib).owner && libOf(lib).owner === BR.me.user);
    const canEditPath = (p) => canEditLib(String(p || '').split('/')[0]);
    // only your own personal libraries (admins: everything)
    const canDelete = (lib) => !!(BR.me && lib !== '_legacy' && (BR.me.admin || (libOf(lib).owner && libOf(lib).owner === BR.me.user)));
    const ownerTag = (l) => !l.owner ? '' : l.owner === (BR.me && BR.me.user) ? ' · mine' : ' · ' + l.owner;
    // whose personal library a file comes from: '' (a server library), 'you', or the user's name
    const ownerOfPath = (p) => { const o = libOf(String(p || '').split('/')[0]).owner; return !o ? '' : o === (BR.me && BR.me.user) ? 'you' : o; };
    const fromTxt = (owners) => { const o = [...owners].filter(Boolean); return o.length ? 'from ' + o.map((x) => x === 'you' ? 'your library' : x + "'s library").join(', ') : ''; };
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
                const r = await api('meta/search', { lib: o.lib, kind: o.search, q: root.querySelector('#eq').value, year: root.querySelector('#ey').value });
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
        view.innerHTML = list.length ? `<div class="smkv-grid">${list.map((s) => seriesCard(d, s)).join('')}</div>` : '<div class="smkv-dim">No shows</div>';
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
      const sh = (d.shows || {})[key] || { title: eps[0]?.title || key };
      const seasons = [...new Set(eps.map((e) => e.season))].sort((a, b) => a - b);
      const next = nextUp(eps);
      let season = lsGet('season:' + lib + ':' + key, next ? next.season : seasons[0]);
      if (!seasons.includes(season)) season = seasons[0];
      setToolbar(`<a class="smkv-back" href="#/lib/${encodeURIComponent(lib)}">← ${esc((BR.libs.find((l) => l.id === lib) || {}).name || 'Back')}</a>`, draw);
      const missing = missingCount(d, sh, eps);
      function draw() {
        const rows = eps.filter((e) => e.season === season && matchQ(e.episodeTitle, e.name, e.episodeOverview)).map((e) => ({ n: e.episode || 0, e }))
          .concat(searchQ ? [] : missingEps(d, sh, eps, season).map((m) => ({ n: m.episode, m })))
          .sort((a, b) => a.n - b.n || (a.e ? 0 : 1));
        view.innerHTML = `
          <div class="smkv-showhead"${sh.backdrop ? ` style="background-image:linear-gradient(90deg,#0d0f13 30%,rgba(13,15,19,.6)),url('${esc(sh.backdrop)}')"` : ''}>
            ${sh.poster ? `<img class="smkv-dposter" src="${esc(sh.poster)}">` : ''}
            <div><h2>${esc(sh.title)}</h2>
              <div class="smkv-facts">${[sh.year, sh.rating ? '★ ' + sh.rating.toFixed(1) : '', eps.length + (eps.length > 1 ? ' files' : ' file'), missing ? `<span class="smkv-miss">${missing} episode${missing > 1 ? 's' : ''} missing</span>` : ''].filter(Boolean).join(' · ')}</div>
              <div class="smkv-chips">${(sh.genres || []).map((g) => `<a href="#/lib/${encodeURIComponent(lib)}/${encodeURIComponent(g)}">${esc(g)}</a>`).join('')}</div>
              ${sh.overview ? `<p class="smkv-ov">${esc(sh.overview)}</p>` : ''}
              <div class="smkv-raw">${esc(tmdbTag(sh.tmdbId || 0))} · series key “${esc(key)}” · parsed title “${esc(eps[0]?.title || '')}”</div>
              <div class="smkv-showbtns">${next ? `<button class="smkv-primary" id="smkv-next">▶ ${next.pos ? 'Resume' : 'Play'} S${next.season}E${next.episode}${next.episodeTitle ? ' · ' + esc(next.episodeTitle) : ''}</button>` : ''}<span class="smkv-trlslot"></span></div>
              ${canEditLib(lib) ? `<div class="smkv-admin-row">${sh.tmdbId ? 'TMDB #' + sh.tmdbId : 'Not matched'} · <a href="#" class="smkv-fix">✎ Edit show / fix match…</a></div>` : ''}
            </div>
          </div>
          ${castRow(sh.cast)}
          <div class="smkv-tabs">${seasons.map((s) => `<button data-s="${s}" class="${s === season ? 'on' : ''}">${s ? 'Season ' + s : 'Other'}</button>`).join('')}</div>
          <div class="smkv-eps">${rows.map(({ e, m }) => m ? `
            <div class="smkv-ep smkv-skel${m.future ? ' future' : ''}" title="${m.future ? 'Not aired yet' : 'Not on the server yet'}">
              <div class="smkv-still"><span>${m.future ? '🗓' : '＋'}</span></div>
              <div style="flex:1"><b>E${m.episode}${m.meta && m.meta.title ? ' · ' + esc(m.meta.title) : ''}</b>
                <div class="smkv-dim2">${m.future ? `Airs ${esc(m.meta.aired)}` : `Missing${m.meta && m.meta.aired ? ' · aired ' + esc(m.meta.aired) : ''}`}</div></div>
            </div>` : `
            <div class="smkv-ep" data-p="${esc(e.path)}">
              <div class="smkv-still">${e.still ? `<img loading="lazy" src="${esc(e.still)}">` : '<span>▶</span>'}${progressBar(e)}</div>
              <div style="flex:1"><b>${e.episode ? epLabel(e) + ' · ' : ''}${esc(e.episodeTitle || e.name)}</b>${canEditLib(lib) ? `<button class="smkv-epedit" data-p="${esc(e.path)}" title="Edit episode">✎</button>` : ''}${canDelete(lib) ? `<button class="smkv-epedit smkv-epdel" data-p="${esc(e.path)}" title="Delete this episode file">🗑</button>` : ''}
                <div class="smkv-dim2">${[e.duration ? fmtTime(e.duration) : '', e.pos ? 'watched to ' + fmtTime(e.pos) : ''].filter(Boolean).join(' · ')}</div>
                ${rawNames([e], (e.dir ? e.dir + '/ · ' : '') + `S${e.season}E${e.episode}${e.episodeEnd ? '–E' + e.episodeEnd : ''}`)}
                ${e.episodeOverview ? `<p>${esc(e.episodeOverview)}</p>` : ''}</div>
            </div>`).join('')}</div>`;
        view.querySelectorAll('.smkv-tabs button').forEach((b) => b.onclick = () => { season = +b.dataset.s; lsSet('season:' + lib + ':' + key, season); draw(); });
        view.querySelectorAll('.smkv-ep[data-p]').forEach((r) => r.onclick = () => playVideo(r.dataset.p));
        const n = view.querySelector('#smkv-next');
        if (n) n.onclick = () => playVideo(next.path);
        trailerButton(view.querySelector('.smkv-trlslot'), { lib, show: key }, sh.title);
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
        if (!m.has(k)) m.set(k, { key: k, album: it.album || it.dir || '(no album)', artist: it.albumArtist || it.artist || 'Unknown artist', cover: it.cover, year: it.year, genres: new Set(), tracks: [], added: 0, owners: new Set() });
        const a = m.get(k);
        a.owners.add(ownerOfPath(it.path));
        a.tracks.push(it); a.added = Math.max(a.added, it.added); if (!a.cover && it.cover) a.cover = it.cover; if (!a.year && it.year) a.year = it.year;
        (it.genres || []).forEach((g) => a.genres.add(g));
      }
      return [...m.values()];
    }

    const mbase = (lib) => lib === '_all' ? '#/music' : '#/lib/' + encodeURIComponent(lib);
    const ownerBadge = (a) => { const o = [...a.owners].filter(Boolean); return o.length ? '👤 ' + (o.length > 1 ? o.length + ' people' : o[0]) : ''; };
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
          view.innerHTML = (arg ? `<h3 class="smkv-h">${esc(arg)}</h3>` : '') + (list.length ? `<div class="smkv-grid sq">${list.map((a) => posterCard({ key: a.key, title: a.album, sub: a.artist + (a.year ? ' · ' + a.year : ''), img: coverUrl(a.cover), square: true, badge: ownerBadge(a), raw: rawNames(a.tracks, a.tracks[0]?.dir ? a.tracks[0].dir + '/' : '') })).join('')}</div>` : '<div class="smkv-dim">No albums</div>');
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
        <td class="n">${t.track || ''}</td><td><b>${esc(t.title || t.name)}</b>${rawNames([t], t.dir)}${showAlbum ? `<div class="smkv-dim2">${esc(t.artist || '')}${t.album ? ' · ' + esc(t.album) : ''}${ownerOfPath(t.path) ? ` · <span class="smkv-from">👤 ${esc(ownerOfPath(t.path))}</span>` : ''}</div>` : (t.artist && t.artist !== t.albumArtist ? `<div class="smkv-dim2">${esc(t.artist)}</div>` : '')}</td>
        <td class="d">${t.duration ? fmtTime(t.duration) : ''}</td><td class="e"><button class="smkv-tadd" data-i="${i}" title="Play next · add to queue · add to a playlist">＋</button>${canSave() ? `<a class="smkv-tdl" href="${esc(dlUrl(t.path))}" download title="Save to this computer" onclick="event.stopPropagation()">⬇</a>` : ''}</td>${editLib && canEditPath(t.path) ? `<td class="e"><button class="smkv-tedit" data-i="${i}" title="Edit tags">✎</button></td>` : ''}</tr>`).join('')}</table>`;
    }
    const canSave = () => !!(BR.me && (BR.me.offline || BR.me.admin));
    const dlUrl = (path) => { const u = new URL('api/download', BASE); u.searchParams.set('path', path); return u.href; };
    // several files as one .zip (the browser saves it; the page stays)
    function downloadZip(tracks, name, numbered) {
      const f = document.createElement('form');
      f.method = 'POST'; f.action = new URL('api/download/zip', BASE).href; f.style.display = 'none';
      const add = (k, v) => { const i = document.createElement('input'); i.type = 'hidden'; i.name = k; i.value = v; f.appendChild(i); };
      add('name', name); if (numbered) add('numbered', '1');
      tracks.forEach((t) => add('path', t.path));
      document.body.appendChild(f); f.submit(); f.remove();
      toast(`Preparing ${tracks.length} songs…`);
    }
    function bindAdd(root, list) {
      root.querySelectorAll('.smkv-tadd').forEach((b) => b.onclick = (ev) => { ev.stopPropagation(); addToPlaylist([list[+b.dataset.i]], b); });
    }
    function bindTracks(root, list, lib) {
      root.querySelectorAll('.smkv-tracks tr').forEach((tr) => tr.onclick = () => playQueue(list, +tr.dataset.i));
      bindAdd(root, list);
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
              ${fromTxt(a.owners) ? `<div class="smkv-dim2" style="margin:2px 0 6px">📦 ${esc(fromTxt(a.owners))}</div>` : ''}
              <div class="smkv-chips">${[...a.genres].map((g) => `<a href="${mbase(lib)}/genres/${encodeURIComponent(g)}">${esc(g)}</a>`).join('')}</div>
              <button class="smkv-primary" id="smkv-playall">▶ Play</button> <button id="smkv-shufall">🔀 Shuffle</button> <button id="smkv-pladd" title="Play next, add to queue, or add to a playlist">＋ Queue / playlist</button>${canSave() ? ' <button id="smkv-zip" title="Save the album to this computer (.zip)">⬇ Download</button>' : ''}
              ${a.tracks.every((t) => canEditPath(t.path)) ? '<button id="smkv-aedit">✎ Edit album</button>' : ''}</div></div>
          ${trackTable(a.tracks.filter((t) => matchQ(t.title, t.artist)), false, lib)}`;
        const ae = $('#smkv-aedit');
        if (ae) ae.onclick = () => editDialog({ lib: lib !== '_all' ? lib : a.tracks[0].path.split('/')[0], title: a.album, keys: a.tracks.map((t) => t.path),
          fields: { album: a.album, albumArtist: a.artist, year: a.year || '', genres: [...a.genres].join(', '), cover: '' } });
        bindTracks(view, a.tracks.filter((t) => matchQ(t.title, t.artist)), lib);
        $('#smkv-playall').onclick = () => playQueue(a.tracks, 0);
        $('#smkv-shufall').onclick = () => playQueue(shuffle([...a.tracks]), 0);
        $('#smkv-pladd').onclick = (e) => addToPlaylist(a.tracks, e.currentTarget);
        if ($('#smkv-zip')) $('#smkv-zip').onclick = () => downloadZip(a.tracks, `${a.artist} - ${a.album}`);
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
            <button class="smkv-primary" id="smkv-playall">▶ Play</button> <button id="smkv-shufall">🔀 Shuffle</button> <button id="smkv-pladd" title="Play next, add to queue, or add to a playlist">＋ Queue / playlist</button>${canSave() ? ' <button id="smkv-zip" title="Save every song to this computer (.zip)">⬇ Download</button>' : ''}</div></div>
          <h3 class="smkv-h">Albums</h3><div class="smkv-grid sq">${albums.map((a) => posterCard({ key: a.key, title: a.album, sub: String(a.year || ''), img: coverUrl(a.cover), square: true, badge: ownerBadge(a) })).join('')}</div>
          <h3 class="smkv-h">Songs</h3>${trackTable(songs.filter((t) => matchQ(t.title, t.album)), true, lib)}`;
        bindCards(view, (k) => (location.hash = `#/album/${encodeURIComponent(lib)}/${encodeURIComponent(k)}`));
        bindTracks(view, songs.filter((t) => matchQ(t.title, t.album)), lib);
        $('#smkv-playall').onclick = () => playQueue(songs, 0);
        $('#smkv-shufall').onclick = () => playQueue(shuffle([...songs]), 0);
        $('#smkv-pladd').onclick = (e) => addToPlaylist(songs, e.currentTarget);
        if ($('#smkv-zip')) $('#smkv-zip').onclick = () => downloadZip(songs, name);
      }
      draw();
    }

    // ------------------------------------------------------------ music: playlists
    async function addToPlaylist(tracks, anchor) {
      tracks = tracks.filter(Boolean);
      if (!tracks.length) return;
      closePops();
      let pls = [];
      try { pls = (await api('playlists')).playlists; } catch (x) { return toast(x.message); }
      const pop = document.createElement('div');
      pop.className = 'smkv-pop smkv-plpop';
      pop.innerHTML = `<div class="smkv-plh">${tracks.length > 1 ? tracks.length + ' songs' : 'Queue'}</div>
        <button data-q="next">⏭ Play next</button><button data-q="end">☰ Add to queue</button>
        <div class="smkv-plh">Add to playlist</div>
        <button data-new>＋ New playlist…</button>${pls.map((p) => `<button data-id="${esc(p.id)}">${esc(p.name)} <small>${p.count}</small></button>`).join('')}`;
      document.body.appendChild(pop);
      placePop(pop, anchor);
      const paths = tracks.map((t) => t.path);
      pop.querySelectorAll('[data-q]').forEach((b) => b.onclick = () => { closePops(); enqueue(tracks, b.dataset.q === 'next'); });
      pop.querySelector('[data-new]').onclick = async () => {
        closePops();
        const name = prompt('Playlist name', tracks.length > 1 && tracks[0].album && tracks.every((t) => t.album === tracks[0].album) ? tracks[0].album : '');
        if (!name || !name.trim()) return;
        try { await apiPost('playlists', { name: name.trim(), tracks: paths }); toast(`Created “${name.trim()}”`); renderNav(); } catch (x) { toast(x.message); }
      };
      pop.querySelectorAll('[data-id]').forEach((b) => b.onclick = async () => {
        closePops();
        try {
          const r = await apiPost(`playlists/${encodeURIComponent(b.dataset.id)}/add`, { tracks: paths });
          toast(r.added ? `Added ${r.added > 1 ? r.added + ' songs' : ''} to “${r.playlist.name}”`.replace('Added  to', 'Added to') : `Already in “${r.playlist.name}”`);
        } catch (x) { toast(x.message); }
      });
    }
    async function playlistsView() {
      setToolbar('<button id="smkv-plnew" class="smkv-primary">＋ New playlist</button>', draw);
      const [d, r] = await Promise.all([libData('_all'), api('playlists')]);
      const byPath = new Map(d.items.map((t) => [t.path, t]));
      $('#smkv-plnew').onclick = async () => {
        const name = prompt('Playlist name');
        if (!name || !name.trim()) return;
        try { const p = await apiPost('playlists', { name: name.trim(), tracks: [] }); location.hash = '#/playlist/' + encodeURIComponent(p.id); } catch (x) { toast(x.message); }
      };
      function draw() {
        const list = r.playlists.filter((p) => matchQ(p.name));
        view.innerHTML = list.length ? `<div class="smkv-grid sq">${list.map((p) => {
          const cover = p.first.map((x) => byPath.get(x)).find((t) => t && t.cover);
          return posterCard({ key: p.id, title: p.name, sub: `${p.count} song${p.count === 1 ? '' : 's'}`, img: cover ? coverUrl(cover.cover) : '', square: true });
        }).join('')}</div>` : '<div class="smkv-dim">No playlists yet. Press ＋ next to any song, album or artist (or on Now playing) to start one.</div>';
        bindCards(view, (k) => (location.hash = '#/playlist/' + encodeURIComponent(k)));
      }
      draw();
    }
    async function playlistView(id) {
      const [d, pl] = await Promise.all([libData('_all'), api('playlists/' + encodeURIComponent(id))]);
      const byPath = new Map(d.items.map((t) => [t.path, t]));
      setToolbar('<a class="smkv-back" href="#/music/playlists">← Playlists</a>', draw);
      const save = async (tracks) => {
        try { Object.assign(pl, await apiSend('PUT', 'playlists/' + encodeURIComponent(id), { tracks })); } catch (x) { toast(x.message); }
        draw();
      };
      function draw() {
        const tracks = pl.tracks.map((p) => byPath.get(p)).filter(Boolean);
        const missing = pl.tracks.length - tracks.length;
        const total = tracks.reduce((s, t) => s + (t.duration || 0), 0);
        const cover = tracks.find((t) => t.cover);
        const shown = tracks.filter((t) => matchQ(t.title, t.artist, t.album));
        view.innerHTML = `<div class="smkv-albumhead">
            <div class="smkv-poster sq big">${cover ? `<img src="${esc(coverUrl(cover.cover))}">` : '<span>📃</span>'}</div>
            <div><div class="smkv-dim2">PLAYLIST</div><h2>${esc(pl.name)}</h2>
              <div class="smkv-facts">${tracks.length} songs · ${fmtTime(total)}${missing ? ` · <span title="Their files are gone, or you can't open their library any more">${missing} unavailable</span>` : ''}</div>
              <button class="smkv-primary" id="smkv-playall" ${tracks.length ? '' : 'disabled'}>▶ Play</button> <button id="smkv-shufall" ${tracks.length ? '' : 'disabled'}>🔀 Shuffle</button>
              <button id="smkv-plq" ${tracks.length ? '' : 'disabled'} title="Play next or add to the queue">＋ Queue</button> <button id="smkv-plren">✎ Rename</button> <button id="smkv-pldel">🗑 Delete</button>${canSave() && tracks.length ? ' <button id="smkv-zip" title="Save the playlist to this computer (.zip, in playlist order)">⬇ Download</button>' : ''}</div></div>
          ${shown.length ? `<table class="smkv-tracks smkv-pltracks">${shown.map((t, i) => `<tr data-i="${i}" draggable="true" class="${A.cur && A.cur.path === t.path ? 'on' : ''}">
            <td class="n smkv-grip" title="Drag to reorder">⠿</td><td><b>${esc(t.title || t.name)}</b><div class="smkv-dim2">${esc(t.artist || '')}${t.album ? ' · ' + esc(t.album) : ''}${ownerOfPath(t.path) ? ` · <span class="smkv-from">👤 ${esc(ownerOfPath(t.path))}</span>` : ''}</div></td>
            <td class="d">${t.duration ? fmtTime(t.duration) : ''}</td>
            <td class="e"><button data-mv="-1" title="Move up">↑</button><button data-mv="1" title="Move down">↓</button><button data-rm title="Remove from the playlist">✕</button></td></tr>`).join('')}</table>`
            : '<div class="smkv-dim">Empty — press ＋ next to songs, albums or artists to add them here.</div>'}`;
        $('#smkv-playall').onclick = () => playQueue(tracks, 0);
        $('#smkv-shufall').onclick = () => playQueue(shuffle([...tracks]), 0);
        if ($('#smkv-zip')) $('#smkv-zip').onclick = () => downloadZip(tracks, pl.name, true);
        $('#smkv-plq').onclick = (e) => addToPlaylist(tracks, e.currentTarget);
        $('#smkv-plren').onclick = async () => {
          const n = prompt('Rename playlist', pl.name);
          if (!n || !n.trim() || n.trim() === pl.name) return;
          try { Object.assign(pl, await apiSend('PUT', 'playlists/' + encodeURIComponent(id), { name: n.trim() })); draw(); } catch (x) { toast(x.message); }
        };
        $('#smkv-pldel').onclick = async () => {
          if (!confirm(`Delete the playlist “${pl.name}”? (The songs stay in your library.)`)) return;
          try { await apiSend('DELETE', 'playlists/' + encodeURIComponent(id)); location.hash = '#/music/playlists'; } catch (x) { toast(x.message); }
        };
        // reorder / remove work on the full list (unavailable entries keep their place)
        const idxOf = (i) => pl.tracks.indexOf(shown[i].path);
        const move = (from, to) => { const t = [...pl.tracks]; const [x] = t.splice(from, 1); t.splice(to, 0, x); save(t); };
        view.querySelectorAll('.smkv-pltracks tr').forEach((tr) => {
          const i = +tr.dataset.i;
          tr.onclick = (e) => { if (!e.target.closest('button')) playQueue(shown, i); };
          tr.querySelector('[data-rm]').onclick = () => save(pl.tracks.filter((_, k) => k !== idxOf(i)));
          tr.querySelectorAll('[data-mv]').forEach((b) => b.onclick = () => {
            const j = i + +b.dataset.mv;
            if (j < 0 || j >= shown.length) return;
            move(idxOf(i), idxOf(j));
          });
          tr.ondragstart = (e) => { e.dataTransfer.setData('text/plain', String(i)); tr.classList.add('drag'); };
          tr.ondragend = () => tr.classList.remove('drag');
          tr.ondragover = (e) => { e.preventDefault(); tr.classList.add('over'); };
          tr.ondragleave = () => tr.classList.remove('over');
          tr.ondrop = (e) => {
            e.preventDefault(); tr.classList.remove('over');
            const from = +e.dataTransfer.getData('text/plain');
            if (!Number.isNaN(from) && from !== i) move(idxOf(from), idxOf(i));
          };
        });
      }
      draw();
    }

    // ------------------------------------------------------------ music: listen now
    async function musicHome() {
      setToolbar('<button id="smkv-shuffle" title="Shuffle every song">🔀 Shuffle all</button>', null);
      toolbar.querySelector('#smkv-q').style.display = 'none'; $('#smkv-rawbtn').hidden = true;
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
        posterCard({ key: 'a:' + a.key, title: a.album, sub: a.artist, img: coverUrl(a.cover), square: true, badge: ownerBadge(a) })).join('')}</div>`;
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
      toolbar.querySelector('#smkv-q').style.display = 'none'; $('#smkv-rawbtn').hidden = true;
      if (!A.cur) { view.innerHTML = '<div class="smkv-dim">Nothing is playing — pick an album, an artist or a song.</div>'; return; }
      view.innerHTML = `<div class="smkv-now">
          <div class="smkv-poster sq big" id="smkv-np-cover"></div>
          <div class="smkv-now-info"><div class="smkv-dim2" id="smkv-np-state">NOW PLAYING</div><h2 id="smkv-np-title"></h2><div class="smkv-facts" id="smkv-np-sub"></div>
            <input id="smkv-np-seek" type="range" min="0" max="0" step="0.1" value="0">
            <div class="smkv-np-times"><span id="smkv-np-t">0:00</span><span id="smkv-np-d">0:00</span></div>
            <div class="smkv-np-btns"><button id="smkv-np-shuf" title="Shuffle what's left">🔀</button><button id="smkv-np-prev" title="Previous">⏮</button>
              <button id="smkv-np-pp" class="big" title="Play/Pause">▶</button><button id="smkv-np-next" title="Next">⏭</button><button id="smkv-np-rep"></button>
              <button id="smkv-np-lyrb" title="Lyrics">🎤</button></div>
          </div>
          <div class="smkv-lyrics" id="smkv-np-lyr" hidden></div></div>
        <h3 class="smkv-h">Up next <button id="smkv-np-clear" title="Remove the songs after this one">Clear upcoming</button> <button id="smkv-np-save" title="Save the whole queue as a playlist">＋ Save as playlist</button></h3><div id="smkv-np-queue"></div>`;
      $('#smkv-np-save').onclick = (e) => addToPlaylist(A.queue, e.currentTarget);
      $('#smkv-np-lyrb').onclick = () => { lsSet('lyrOn', !lsGet('lyrOn', true)); LY.path = null; drawNow(); };
      $('#smkv-np-pp').onclick = aToggle;
      $('#smkv-np-prev').onclick = aPrev;
      $('#smkv-np-next').onclick = () => aNext(true);
      $('#smkv-np-rep').onclick = () => { $('#smkv-arep').click(); drawNow(); };
      $('#smkv-np-shuf').onclick = () => { A.queue = A.queue.slice(0, A.idx + 1).concat(shuffle(A.queue.slice(A.idx + 1))); drawNow(); toast('Shuffled'); aSave(); };
      $('#smkv-np-clear').onclick = () => { A.queue = A.queue.slice(0, A.idx + 1); drawNow(); renderNav(); aSave(); };
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
      bindAdd(q, A.queue);
      q.querySelectorAll('.smkv-tracks tr').forEach((tr, i) => { // remove from the queue
        if (i === A.idx) return;
        const td = document.createElement('td'); td.className = 'e';
        td.innerHTML = '<button class="smkv-qrm" title="Remove from the queue">✕</button>';
        td.firstChild.onclick = (e) => { e.stopPropagation(); A.queue.splice(i, 1); if (i < A.idx) A.idx--; drawNow(); renderNav(); aSave(); };
        tr.appendChild(td);
      });
      const on = q.querySelector('tr.on');
      if (on && !drawNow.scrolled) { on.scrollIntoView({ block: 'nearest' }); drawNow.scrolled = true; }
      drawLyrics();
    }

    // ------------------------------------------------------------ lyrics (synced when we can get them)
    const LY = { path: null, data: null, lines: [], idx: -1, cache: new Map(), userScroll: 0 };
    function parseLrc(text) {
      let offset = 0; const out = [];
      for (const raw of String(text || '').replace(/\r/g, '').split('\n')) {
        const om = raw.match(/^\[offset:\s*([+-]?\d+)\]/i); if (om) { offset = +om[1] / 1000; continue; }
        const times = []; let rest = raw, m;
        while ((m = rest.match(/^\[(\d+):(\d+(?:[.:]\d+)?)\]/))) { times.push(+m[1] * 60 + parseFloat(m[2].replace(':', '.'))); rest = rest.slice(m[0].length); }
        for (const t of times) out.push({ t: Math.max(0, t - offset), text: rest.trim() });
      }
      return out.sort((a, b) => a.t - b.t);
    }
    async function drawLyrics(refresh) {
      const box = $('#smkv-np-lyr');
      if (!box || !A.cur) return;
      if ($('#smkv-np-lyrb')) $('#smkv-np-lyrb').hidden = !feat('lyrics');
      const on = lsGet('lyrOn', true) && feat('lyrics');
      $('#smkv-np-lyrb') && $('#smkv-np-lyrb').classList.toggle('on', on);
      box.hidden = !on;
      if (!on) return;
      const path = A.cur.path;
      // same song and this very box is already filled: nothing to do
      // (coming back to Now playing builds a new, empty box — fill it again, from the cache)
      if (LY.path === path && !refresh && box.dataset.p === path) return;
      box.dataset.p = path;
      LY.path = path; LY.data = null; LY.lines = []; LY.idx = -1;
      box.innerHTML = '<div class="smkv-dim2 smkv-lyr-msg">Looking for lyrics…</div>';
      let d = !refresh && LY.cache.get(path);
      if (!d) {
        try { d = await api('lyrics', { path, ...(refresh ? { refresh: 1 } : {}) }); } catch { d = {}; }
        LY.cache.set(path, d);
      }
      if (LY.path !== path) return; // the song changed meanwhile
      LY.data = d; LY.lines = d.synced ? parseLrc(d.synced) : [];
      const src = d.source ? `<div class="smkv-lyr-src">${d.source === 'lrclib' ? 'Lyrics from LRCLIB' : d.source === 'file' ? 'Lyrics from a .lrc file' : 'Lyrics from the file'}${LY.lines.length ? ' · synced' : ''}</div>` : '';
      if (LY.lines.length) {
        box.innerHTML = `<div class="smkv-lyr-lines">${LY.lines.map((l, i) => `<p data-i="${i}" class="${l.text ? '' : 'gap'}">${esc(l.text) || '♪'}</p>`).join('')}</div>${src}`;
        box.querySelectorAll('p[data-i]').forEach((p) => p.onclick = () => aSeek(LY.lines[+p.dataset.i].t + 0.05));
        const sc = box.querySelector('.smkv-lyr-lines');
        sc.addEventListener('wheel', () => { LY.userScroll = Date.now(); }, { passive: true });
        sc.addEventListener('touchmove', () => { LY.userScroll = Date.now(); }, { passive: true });
        lyrTick(true);
      } else if (d.plain) {
        box.innerHTML = `<div class="smkv-lyr-lines plain">${esc(d.plain)}</div>${src}`;
      } else {
        box.innerHTML = '<div class="smkv-dim2 smkv-lyr-msg">No lyrics found for this song.<br><button class="smkv-link" id="smkv-lyr-again">Search again</button></div>';
        box.querySelector('#smkv-lyr-again').onclick = () => drawLyrics(true);
      }
    }
    function lyrTick(force) {
      if (!LY.lines.length || !A.cur || LY.path !== A.cur.path) return;
      const box = $('#smkv-np-lyr'); if (!box || box.hidden) return;
      const t = aTime() + 0.25;
      let i = -1; for (let k = 0; k < LY.lines.length && LY.lines[k].t <= t; k++) i = k;
      if (i === LY.idx && !force) return;
      LY.idx = i;
      box.querySelectorAll('p.on').forEach((p) => p.classList.remove('on'));
      const cur = box.querySelector(`p[data-i="${i}"]`);
      if (!cur) return;
      cur.classList.add('on');
      const sc = box.querySelector('.smkv-lyr-lines');
      if (Date.now() - LY.userScroll > 4000) sc.scrollTo({ top: cur.offsetTop - sc.clientHeight / 2 + cur.clientHeight / 2, behavior: force ? 'auto' : 'smooth' });
    }

    // ------------------------------------------------------------ ranking
    const badgeIcons = (list, max) => (list || []).length ? `<span class="smkv-badges">${list.slice(0, max || 99).map((b) => `<i title="${esc(b.name + ' — ' + b.desc)}">${esc(b.icon)}</i>`).join('')}</span>` : '';
    const fmtHrs = (sec) => sec >= 3600 ? `${(sec / 3600).toFixed(sec >= 36000 ? 0 : 1)} h` : `${Math.max(1, Math.round(sec / 60))} min`;
    async function rankingView(period) {
      setToolbar('', null);
      toolbar.querySelector('#smkv-q').style.display = 'none'; $('#smkv-rawbtn').hidden = true;
      const r = await api('ranking', { period });
      const periods = { week: 'This week', month: 'This month', year: 'This year', all: 'All time' };
      const medal = (i) => ['🥇', '🥈', '🥉'][i] || `<span class="smkv-rk">${i + 1}</span>`;
      const board = (rows, kind) => {
        if (!rows.length) return `<div class="smkv-dim2" style="padding:12px 0">Nobody yet ${period === 'all' ? '' : periods[period].toLowerCase()} — press play!</div>`;
        const top = kind === 'video' ? rows[0].video : rows[0].music;
        return rows.map((x, i) => {
          const v = kind === 'video' ? x.video : x.music;
          return `<div class="smkv-rank${x.user === BR.me.user ? ' me' : ''}">
            <span class="smkv-rkm">${medal(i)}</span>${avatarHtml(x.user, 30)}
            <div class="smkv-rkb"><div><b>${esc(x.user)}</b>${badgeIcons(r.badges[x.user])}</div>
              <div class="smkv-rkbar"><i style="width:${(v / top * 100).toFixed(1)}%"></i></div></div>
            <div class="smkv-rkv"><b>${fmtHrs(v)}</b><span class="smkv-dim2">${kind === 'video' ? `${x.titles} finished` : `${x.songs} songs`}</span></div></div>`;
        }).join('');
      };
      const mine = r.badges[BR.me.user] || [];
      const me = r.me || {};
      view.innerHTML = `<h2 class="smkv-pageh">🏆 Ranking</h2>
        <div class="smkv-tabs">${Object.entries(periods).map(([k, v]) => `<a href="#/ranking/${k}" class="${k === r.period ? 'on' : ''}">${v}</a>`).join('')}</div>
        <div class="smkv-ranks">
          <section><h3 class="smkv-h">🎬 Watched the most</h3>${board(r.video, 'video')}</section>
          <section><h3 class="smkv-h">🎵 Listened the most</h3>${board(r.music, 'music')}</section>
        </div>
        <h3 class="smkv-h">Your badges</h3>
        ${r.hidden ? '<div class="smkv-dim2">You hide what you watch, so you are not on the ranking and get no badges. Change it in Settings.</div>' : `
        <div class="smkv-mybadges">${mine.length ? mine.map((b) => `<div class="smkv-mybadge"><span>${esc(b.icon)}</span><div><b>${esc(b.name)}</b><div class="smkv-dim2">${esc(b.desc)}</div></div></div>`).join('') : '<div class="smkv-dim2">No badges yet — watch or listen for an hour to get your first.</div>'}</div>
        <div class="smkv-dim2" style="margin-top:10px">${periods[r.period]}: 🎬 ${fmtHrs(me.video || 0)} · ${me.titles || 0} finished · 🎵 ${fmtHrs(me.music || 0)} · ${me.songs || 0} songs${r.streak ? ` · 🔥 ${r.streak}-day streak` : ''}</div>`}
        <details class="smkv-howrank"><summary>How it works</summary><div class="smkv-dim2">Time counts while something is actually playing (paused or skipped-over time doesn't).
          A movie or episode counts as finished once you've watched 90 % of it. Badges come from your all-time totals:
          ${(r.tiers || []).map((t) => `${esc(t.video)} / ${esc(t.music)} at ${t.hours} h`).join(' · ')} · 📺 25 / 📼 100 finished · 📻 1000 songs · 🔥 7+ days in a row · 👑 / 🎤 the most this month.
          People who hide their activity aren't ranked.</div></details>`;
    }

    // ------------------------------------------------------------ requests (ask for films / series that aren't here)
    const RQ = { kind: lsGet('rqKind', 'movie'), q: '', results: null, seq: 0 };
    const rqStatus = { pending: ['⏳', 'Waiting'], approved: ['👍', 'Approved'], available: ['✅', 'Available'], declined: ['✕', 'Declined'] };
    const ago = (ts) => {
      const s = Date.now() / 1000 - ts;
      if (s < 3600) return Math.max(1, Math.round(s / 60)) + ' min ago';
      if (s < 86400) return Math.round(s / 3600) + ' h ago';
      if (s < 86400 * 30) return Math.round(s / 86400) + ' d ago';
      return new Date(ts * 1000).toLocaleDateString();
    };
    const rqPill = (st) => `<span class="smkv-rqpill ${st}">${rqStatus[st][0]} ${rqStatus[st][1]}</span>`;
    function rqOpen(x) {
      if (x.kind === 'tv') location.hash = `#/show/${encodeURIComponent(x.lib)}/${encodeURIComponent(x.where)}`;
      else movieDetail(x.lib, String(x.tmdbId));
    }
    // admins see how many requests wait for them (in the menu)
    function rqCount(d) {
      if (!BR.me || !BR.me.admin || !feat('requests')) return;
      const set = (d) => { const n = d.requests.filter((x) => x.status === 'pending').length; if (n !== BR.rqOpen) { BR.rqOpen = n; renderNav(); } };
      if (d) set(d); else api('requests').then(set).catch(() => {});
    }
    async function requestsView() {
      setToolbar('', null);
      toolbar.querySelector('#smkv-q').style.display = 'none'; $('#smkv-rawbtn').hidden = true;
      const d = await api('requests');
      rqCount(d);
      const open = d.requests.filter((x) => x.status === 'pending' || x.status === 'approved');
      const done = d.requests.filter((x) => x.status === 'available');
      const no = d.requests.filter((x) => x.status === 'declined');
      const row = (x) => `<div class="smkv-rq" data-id="${esc(x.id)}">
          <div class="smkv-rqp">${x.poster ? `<img src="${esc(x.poster)}" loading="lazy" alt="">` : '<span>🎬</span>'}</div>
          <div class="smkv-rqb">
            <div class="smkv-rqt"><b>${esc(x.title)}</b>${x.year ? ` <span class="smkv-dim2">${x.year}</span>` : ''} <span class="smkv-dim2">· ${x.kind === 'tv' ? 'Series' : 'Film'}</span></div>
            <div class="smkv-rqm">${rqPill(x.status)}<span class="smkv-dim2">${x.mine ? 'You asked' : `${avatarHtml(x.by, 16)} ${esc(x.by)} asked`} · ${ago(x.created)}</span></div>
            ${x.note ? `<div class="smkv-rqnote">💬 ${esc(x.note)}</div>` : ''}
            ${x.overview ? `<div class="smkv-rqo smkv-dim2">${esc(x.overview)}</div>` : ''}
          </div>
          <div class="smkv-rqa">
            ${x.status === 'available' ? (x.canOpen ? '<button class="smkv-primary" data-a="open">▶ Open</button>' : '') : `<button class="smkv-btn2 smkv-vote${x.voted ? ' on' : ''}" data-a="vote" ${x.mine ? 'disabled title="You asked for it"' : 'title="I want this too"'}>👍 ${x.voteCount}</button>`}
            ${x.mine && x.status === 'pending' && !d.manage ? '<button class="smkv-btn2" data-a="del" title="Withdraw">Withdraw</button>' : ''}
            ${d.manage ? `<select class="smkv-btn2" data-a="st" title="Change the status">${Object.entries(rqStatus).map(([k, v]) => `<option value="${k}"${k === x.status ? ' selected' : ''}>${v[0]} ${v[1]}</option>`).join('')}</select>
              <button class="smkv-btn2" data-a="del" title="Delete the request">🗑</button>` : ''}
          </div></div>`;
      const sect = (title, list, empty) => `<h3 class="smkv-h">${title} <span class="smkv-dim2">${list.length || ''}</span></h3>${list.length ? `<div class="smkv-rqs">${list.map(row).join('')}</div>` : `<div class="smkv-dim2" style="padding:4px 0 10px">${empty}</div>`}`;
      view.innerHTML = `<h2 class="smkv-pageh">🙋 Requests</h2>
        ${d.tmdb ? `<form class="smkv-rqsearch" id="smkv-rqf">
          <div class="smkv-seg"><button type="button" data-k="movie">🎬 Films</button><button type="button" data-k="tv">📺 Series</button></div>
          <input class="smkv-inp" name="q" placeholder="Find a film or a series to ask for…" autocomplete="off" value="${esc(RQ.q)}">
        </form><div id="smkv-rqres"></div>` : '<div class="smkv-dim2">Searching needs a TMDB API key — an admin can add one in the dashboard.</div>'}
        ${sect('Open', open, 'Nothing asked for yet — search above.')}
        ${done.length ? sect('Here now', done.slice(0, 30), '') : ''}
        ${no.length ? `<details class="smkv-rqdecl"><summary class="smkv-h">Declined <span class="smkv-dim2">${no.length}</span></summary><div class="smkv-rqs">${no.map(row).join('')}</div></details>` : ''}`;
      const f = $('#smkv-rqf');
      if (f) {
        const seg = () => f.querySelectorAll('.smkv-seg button').forEach((b) => b.classList.toggle('on', b.dataset.k === RQ.kind));
        seg();
        f.querySelectorAll('.smkv-seg button').forEach((b) => b.onclick = () => { RQ.kind = b.dataset.k; lsSet('rqKind', RQ.kind); seg(); rqSearch(); });
        let t = 0;
        f.q.oninput = () => { RQ.q = f.q.value; clearTimeout(t); t = setTimeout(rqSearch, 350); };
        f.onsubmit = (e) => { e.preventDefault(); clearTimeout(t); rqSearch(); };
        if (RQ.q) rqSearch(); else if (!open.length) f.q.focus();
      }
      view.querySelectorAll('.smkv-rq').forEach((el) => {
        const x = d.requests.find((r) => r.id === el.dataset.id);
        el.querySelectorAll('[data-a]').forEach((b) => {
          const act = async () => {
            try {
              if (b.dataset.a === 'open') return rqOpen(x);
              if (b.dataset.a === 'vote') await apiSend('POST', `requests/${x.id}/vote`, { on: !x.voted });
              if (b.dataset.a === 'del') {
                if (!confirm(x.mine && !d.manage ? `Withdraw your request for “${x.title}”?` : `Delete the request for “${x.title}”?`)) return;
                await apiSend('DELETE', `requests/${x.id}`);
              }
              if (b.dataset.a === 'st') {
                let note = x.note || '';
                if (b.value === 'declined') { const n = prompt('Why? (shown to the people who asked — optional)', note); if (n === null) { b.value = x.status; return; } note = n; }
                await apiSend('POST', `requests/${x.id}/status`, { status: b.value, note });
              }
              requestsView();
            } catch (e) { toast(e.message); }
          };
          if (b.tagName === 'SELECT') b.onchange = act; else b.onclick = act;
        });
      });
    }
    async function rqSearch() {
      const box = $('#smkv-rqres'); if (!box) return;
      const q = RQ.q.trim(), seq = ++RQ.seq;
      if (!q) { box.innerHTML = ''; return; }
      box.innerHTML = '<div class="smkv-dim2" style="padding:10px 0">Searching…</div>';
      let r;
      try { r = await api('requests/search', { q, kind: RQ.kind }); } catch (e) { box.innerHTML = `<div class="smkv-dim2">${esc(e.message)}</div>`; return; }
      if (seq !== RQ.seq) return;
      if (!r.results.length) { box.innerHTML = `<div class="smkv-dim2" style="padding:10px 0">Nothing found for “${esc(q)}”. Try the original title, or add the year (e.g. “Dune 2021”).</div>`; return; }
      box.innerHTML = `<div class="smkv-rqgrid">${r.results.map((x, i) => {
        const rq = x.request;
        let btn;
        if (x.have) btn = '<button class="smkv-btn2" data-i="' + i + '" data-a="open">✓ Here — open</button>';
        else if (rq && rq.status === 'declined') btn = `<span class="smkv-dim2">${rqPill('declined')}</span>`;
        else if (rq) btn = rq.voted ? `${rqPill(rq.status)}<span class="smkv-dim2"> · 👍 ${rq.voteCount}</span>` : `<button class="smkv-btn2" data-i="${i}" data-a="vote">👍 Me too · ${rq.voteCount}</button>`;
        else btn = `<button class="smkv-primary" data-i="${i}" data-a="ask">＋ Request</button>`;
        return `<div class="smkv-rqc"><div class="smkv-poster">${x.poster ? `<img src="${esc(x.poster)}" loading="lazy" alt="">` : `<span>${esc(x.title)}</span>`}</div>
          <div class="smkv-rqct" title="${esc(x.overview || '')}"><b>${esc(x.title)}</b> <span class="smkv-dim2">${x.year || ''}</span></div><div class="smkv-rqcb">${btn}</div></div>`;
      }).join('')}</div>`;
      box.querySelectorAll('button[data-i]').forEach((b) => b.onclick = async () => {
        const x = r.results[+b.dataset.i];
        try {
          if (b.dataset.a === 'open') return rqOpen({ kind: x.kind, lib: x.lib, where: x.where, tmdbId: x.id });
          b.disabled = true;
          if (b.dataset.a === 'ask') await apiSend('POST', 'requests', { kind: x.kind, tmdbId: x.id });
          else await apiSend('POST', `requests/${x.request.id}/vote`, { on: true });
          toast(b.dataset.a === 'ask' ? `Asked for “${x.title}” — you'll hear when it's here` : `Added your vote for “${x.title}”`);
          requestsView();
        } catch (e) { b.disabled = false; toast(e.message); }
      });
    }

    // ------------------------------------------------------------ downloads
    // "Show.Name.S01E07-S01E08.1080p…", "Show Name Season 2", "Show.Name.2x05" → the series it belongs to
    function seriesOf(name) {
      const m = /^(.+?)[\s._\-[(]+(?:S\d{1,2}(?:[\s._-]?E\d{1,3})?|Season[\s._-]?\d{1,2}|\d{1,2}x\d{2,3})(?![\p{L}\p{N}])/iu.exec(name || '');
      if (!m) return null;
      const title = m[1].replace(/[._]+/g, ' ').replace(/\s*[[(]?(19|20)\d{2}[\])]?\s*$/, '').replace(/[\s-]+$/, '').trim();
      const key = title.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
      return key ? { key, title } : null;
    }
    // groups of 2+ jobs of the same series (episodes sorted), plus byJob: job id → group key
    function seriesGroups(jobs) {
      const all = new Map();
      for (const j of jobs) {
        const s = seriesOf(j.name);
        if (!s) continue;
        if (!all.has(s.key)) all.set(s.key, { title: s.title, jobs: [] });
        all.get(s.key).jobs.push(j);
      }
      const out = new Map(); out.byJob = new Map();
      for (const [k, g] of all) {
        if (g.jobs.length < 2) continue;
        g.jobs.sort((a, b) => (a.name || '').localeCompare(b.name || '', undefined, { numeric: true, sensitivity: 'base' }));
        out.set(k, g); g.jobs.forEach((j) => out.byJob.set(j.id, k));
      }
      return out;
    }
    // the library picker of the download form; "＋ New library…" makes a typed one on the spot
    const libOptions = (libs) => libs.map((l) => `<option value="${esc(l.id)}">${typeIcon[l.type] || '📁'} ${esc(l.name)}${esc(ownerTag(l))}</option>`).join('')
      + '<option value="__new">＋ New library (movies / TV / music)…</option>';
    function newLibraryDialog() {
      return new Promise((res) => detailModal(`<h2>New library</h2>
        <div class="smkv-dim2">A folder of its own in your space. Movies and TV series get posters and details from TMDB; episode files are grouped into series in any video library.</div>
        <form id="smkv-nlf" style="display:flex;flex-direction:column;gap:10px;margin-top:12px">
          <input class="smkv-inp" name="name" placeholder="Name, e.g. Korean series" autocomplete="off" required>
          <select class="smkv-inp" name="type"><option value="tv">📺 TV series</option><option value="movies">🎬 Movies</option><option value="music">🎵 Music</option><option value="videos">📁 Other videos</option></select>
          <label class="smkv-check"><input type="checkbox" name="shared" ${BR.me.admin ? 'checked' : ''}> Share with everyone</label>
          <div style="display:flex;gap:8px;justify-content:flex-end"><button type="button" class="smkv-btn2" id="smkv-nlno">Cancel</button><button class="smkv-primary">＋ Create</button></div>
        </form>`, (root, close) => {
        const f = root.querySelector('#smkv-nlf');
        f.name.focus();
        root.querySelector('#smkv-nlno').onclick = () => { close(); res(null); };
        f.onsubmit = async (e) => {
          e.preventDefault();
          if (!f.name.value.trim()) return;
          try {
            const r = await fetch(new URL('api/my/libraries', BASE), { method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ name: f.name.value.trim(), type: f.type.value, shared: f.shared.checked }) });
            const j = await r.json().catch(() => ({}));
            if (!r.ok) throw new Error(j.error || r.statusText);
            close(); res(j.id);
          } catch (x) { toast(x.message, 5000); }
        };
      }));
    }
    // give a personal library to everyone: as a server library, or moved into one
    function giveLibrary(l, all) {
      const music = l.type === 'music';
      const targets = all.filter((x) => !x.owner && (x.type === 'music') === music);
      return new Promise((res) => detailModal(`<h2>🎁 Give “${esc(l.name)}” to everyone</h2>
        <div class="smkv-dim2">It stops being yours: it no longer counts toward your space, and only admins can change or delete it.</div>
        <form id="smkv-gvf" class="smkv-pform">
          <label class="smkv-check"><input type="radio" name="mode" value="own" checked> As its own library — everyone sees “${esc(l.name)}”</label>
          <label class="smkv-check"><input type="radio" name="mode" value="into" ${targets.length ? '' : 'disabled'}> Into a library everyone has${targets.length ? '' : ' (none of this kind)'}</label>
          <div id="smkv-gvinto" hidden style="display:flex;flex-direction:column;gap:8px;padding-left:24px">
            <select class="smkv-inp" name="into">${targets.map((x) => `<option value="${esc(x.id)}">${typeIcon[x.type] || '📁'} ${esc(x.name)}</option>`).join('')}</select>
            <label>as the folder <input class="smkv-inp" name="folder" value="${esc(l.name)}"></label>
            <div class="smkv-dim2">The files move there and this library is removed. Torrents still seeding from it stop (the files stay). Watch positions and playlists follow.</div>
          </div>
          <div style="display:flex;gap:8px;justify-content:flex-end"><button type="button" class="smkv-btn2" id="smkv-gvno">Cancel</button><button class="smkv-primary">🎁 Give</button></div>
        </form>`, (root, close) => {
        const f = root.querySelector('#smkv-gvf');
        f.onchange = () => { root.querySelector('#smkv-gvinto').hidden = f.mode.value !== 'into'; };
        root.querySelector('#smkv-gvno').onclick = () => { close(); res(false); };
        f.onsubmit = async (e) => {
          e.preventDefault();
          const body = { mode: f.mode.value, into: f.into ? f.into.value : '', folder: f.folder.value };
          if (!confirm(body.mode === 'own' ? `Give “${l.name}” to everyone? You can't take it back yourself.` : `Move everything in “${l.name}” into “${(targets.find((x) => x.id === body.into) || {}).name}”? You can't take it back yourself.`)) return;
          try {
            await apiPost(`my/libraries/${encodeURIComponent(l.id)}/give`, body);
            close(); toast(body.mode === 'own' ? `🎁 “${l.name}” is now everyone's` : '🎁 Moved — the library is being scanned', 5000);
            await loadLibs(); res(true);
          } catch (x) { toast(x.message, 6000); }
        };
      }));
    }
    // simple pages for long lists: pager(key, list, redraw) → {items, bar, bind(root)}; page size remembered
    const PG = {};
    function pager(key, list, redraw) {
      const st = PG[key] || (PG[key] = { p: 0, n: lsGet('pg:' + key, 20) });
      const pages = Math.max(1, Math.ceil(list.length / st.n));
      st.p = Math.min(st.p, pages - 1);
      const items = list.slice(st.p * st.n, st.p * st.n + st.n);
      const bar = list.length > 10 ? `<div class="smkv-pager" data-pg="${esc(key)}">
          <button data-go="0" ${st.p ? '' : 'disabled'}>«</button><button data-go="${st.p - 1}" ${st.p ? '' : 'disabled'}>‹</button>
          <span>${st.p * st.n + 1}–${Math.min(list.length, (st.p + 1) * st.n)} of ${list.length}</span>
          <button data-go="${st.p + 1}" ${st.p < pages - 1 ? '' : 'disabled'}>›</button><button data-go="${pages - 1}" ${st.p < pages - 1 ? '' : 'disabled'}>»</button>
          <select>${[10, 20, 50, 100].map((n) => `<option ${n === st.n ? 'selected' : ''}>${n}</option>`).join('')}</select><span class="smkv-dim2">per page</span></div>` : '';
      return {
        items, bar,
        bind(root) {
          const b = root.querySelector(`.smkv-pager[data-pg="${key}"]`);
          if (!b) return;
          b.querySelectorAll('[data-go]').forEach((x) => x.onclick = () => { st.p = +x.dataset.go; redraw(); root.scrollIntoView({ block: 'start' }); });
          b.querySelector('select').onchange = (e) => { st.n = +e.target.value; st.p = 0; lsSet('pg:' + key, st.n); redraw(); };
        },
      };
    }
    async function downloadsView() {
      setToolbar('', null);
      toolbar.querySelector('#smkv-q').style.display = 'none'; $('#smkv-rawbtn').hidden = true;
      if (!canDownload()) { view.innerHTML = '<div class="smkv-dim">Ask an admin for the downloader role.</div>'; return; }
      let d = await api('downloads');
      const libs = [...d.libraries].sort((a, b) => ((a.type === 'music') === (BR.mode === 'music') ? 0 : 1) - ((b.type === 'music') === (BR.mode === 'music') ? 0 : 1));
      view.innerHTML = `<h2 class="smkv-pageh">Downloads</h2>
        <form id="smkv-dlf" class="smkv-dlform">
          <input name="source" placeholder="https://… link, YouTube link / playlist, or magnet:?xt=…" autocomplete="off">
          <label class="smkv-check" id="smkv-ytpl" hidden title="This YouTube link is in a playlist: download every video of it"><input type="checkbox" name="playlist"> Whole playlist</label>
          <label class="smkv-tfile" title="Upload .torrent files (you can pick several)"><input type="file" name="file" multiple accept=".torrent,application/x-bittorrent"><span>📎 .torrent</span></label>
          <select name="lib">${libOptions(libs)}</select>
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
      let lastLib = f.lib.value;
      f.lib.onchange = async () => {
        if (f.lib.value !== '__new') { lastLib = f.lib.value; return loadDirs(); }
        f.lib.value = lastLib;
        const id = await newLibraryDialog();
        if (!id) return;
        toast('Library created'); await loadLibs();
        d = await api('downloads');
        f.lib.innerHTML = libOptions(d.libraries);
        f.lib.value = lastLib = id; loadDirs(); drawMine();
      };
      loadDirs();
      f.source.oninput = () => { // a YouTube video that's part of a playlist: offer the whole playlist
        let u = null; try { u = new URL(f.source.value.trim()); } catch { /* not a URL */ }
        $('#smkv-ytpl').hidden = !(u && /(^|\.)(youtube\.com|youtu\.be)$/.test(u.hostname) && u.searchParams.get('list') && u.searchParams.get('v'));
      };
      f.file.onchange = () => {
        const n = f.file.files.length;
        f.querySelector('.smkv-tfile span').textContent = n > 1 ? `📎 ${n} files` : n ? '📎 ' + f.file.files[0].name : '📎 .torrent';
        f.querySelector('.smkv-tfile').title = n ? [...f.file.files].map((x) => x.name).join('\n') : 'Upload .torrent files (you can pick several)';
      };
      const sendFile = (file) => (force) => {
        const fd = new FormData(); fd.append('file', file); fd.append('lib', f.lib.value); fd.append('subdir', f.subdir.value);
        if (force) fd.append('force', '1');
        return fetch(new URL('api/downloads/torrent', BASE), { method: 'POST', body: fd, credentials: 'same-origin' });
      };
      const sendLink = (force) => fetch(new URL('api/downloads', BASE), { method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ source: f.source.value.trim(), lib: f.lib.value, subdir: f.subdir.value, force, playlist: !$('#smkv-ytpl').hidden && f.playlist.checked }) });
      // one download; a duplicate asks first (409 = may download anyway, 422 = can't, e.g. already in rtorrent). false = skipped
      async function addOne(send, label) {
        let r = await send(false);
        if (r.status === 409 || r.status === 422) {
          const j = await r.json().catch(() => ({}));
          const items = ((j.duplicate && j.duplicate.items) || []).slice(0, 6).map((i) => `• ${i.libName} · ${i.name}`).join('\n');
          if (!j.canForce) throw new Error(j.error || 'Already downloaded');
          if (!confirm(`${label ? label + '\n\n' : ''}${j.error}${items ? '\n\n' + items : ''}\n\nDownload anyway?`)) return false;
          r = await send(true);
        }
        if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || r.statusText);
        return true;
      }
      f.onsubmit = async (e) => {
        e.preventDefault();
        const files = [...f.file.files], link = f.source.value.trim();
        if (!files.length && !link) return toast('Paste a link or choose .torrent files');
        const btn = f.querySelector('button.smkv-primary'); btn.disabled = true;
        let added = 0; const failed = [];
        try {
          for (const [i, file] of files.entries()) {
            if (files.length > 1) btn.textContent = `⬇ ${i + 1} / ${files.length}…`;
            try { if (await addOne(sendFile(file), files.length > 1 ? file.name : '')) added++; } catch (x) { failed.push(`${file.name}: ${x.message}`); }
          }
          if (link) { try { if (await addOne(sendLink, '')) added++; } catch (x) { failed.push(x.message); } }
        } finally { btn.disabled = false; btn.textContent = '⬇ Download'; }
        if (added) { f.source.value = ''; f.file.value = ''; f.file.onchange(); f.source.oninput(); refresh(); }
        if (failed.length) toast(`${added ? `${added} added · ` : ''}${failed.length} failed — ${failed.slice(0, 3).join(' · ')}${failed.length > 3 ? ' …' : ''}`, 8000);
        else if (added) toast(added > 1 ? `${added} downloads added` : 'Download added');
      };
      async function drawMine() {
        let m;
        try { m = await api('my/libraries'); } catch (_) { return; }
        const u = m.usage || {};
        $('#smkv-myuse').textContent = `· ${u.items || 0}${m.maxItems ? '/' + m.maxItems : ''} items · ${fmtSize(u.bytes || 0)}${m.maxBytes ? ' / ' + fmtSize(m.maxBytes) : ''}`;
        $('#smkv-mylibs').innerHTML = m.libraries.length ? m.libraries.map((l) => `<div class="smkv-dl" data-id="${esc(l.id)}">
            <div class="smkv-dlf2"><span><b>${typeIcon[l.type] || '📁'} ${esc(l.name)}</b> <span class="smkv-dim2">${l.count} items · ${fmtSize(l.size || 0)}</span></span>
              <label class="smkv-check"><input type="checkbox" data-a="share" ${l.shared ? 'checked' : ''}> Shared</label>
              <a href="#/lib/${encodeURIComponent(l.id)}">Open</a><button data-a="scan">Scan</button><button data-a="give" title="Give it to everyone: a library of the server, or into one">🎁 Give…</button><button data-a="del">Delete…</button></div></div>`).join('')
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
              else if (el.dataset.a === 'give') { if (!(await giveLibrary(l, d.libraries))) return; }
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
          $('#smkv-dlf').lib.innerHTML = libOptions(d.libraries);
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
      function ytLine(j) {
        const n = j.items > 1 ? ` · ${j.state === 'done' ? j.itemsDone || 0 : Math.max(j.itemIndex || 0, j.itemsDone || 0)} / ${j.items}` : '';
        const cur = j.state === 'downloading' && j.current && j.current !== j.name ? ` · ${esc(j.current)}` : '';
        return `${j.playlist ? ' · ▶ playlist' : ''}${n}${cur}`;
      }
      const dlOpen = new Set(lsGet('dlOpen', []));
      const mineJ = (j) => BR.me.admin || j.user === BR.me.user;
      const isTor = (j) => j.kind === 'torrent' && j.hash && j.tstate && j.tstate !== 'removed';
      const BULK = { pause: ['downloading', 'seeding'], resume: ['paused'], stop: ['seeding'], start: ['stopped', 'finished'] };
      let groups = new Map();
      function groupHtml(key, g, one) {
        const js = g.jobs, size = js.reduce((a, j) => a + (j.size || 0), 0), got = js.reduce((a, j) => a + Math.min(j.done || 0, j.size || 0), 0);
        const rate = js.reduce((a, j) => a + (j.rate || 0), 0), up = js.reduce((a, j) => a + (j.up || 0), 0);
        const counts = {};
        js.forEach((j) => { const st = j.kind === 'torrent' && j.tstate ? tName[j.tstate] || j.tstate : state[j.state] || j.state; counts[st] = (counts[st] || 0) + 1; });
        const tors = js.filter((j) => mineJ(j) && isTor(j)), has = (a) => tors.some((j) => BULK[a].includes(j.tstate));
        const lbl = { pause: '⏸ Pause all', resume: '▶ Resume all', stop: '⏹ Stop seeding all', start: '▶ Start all' };
        const bulk = Object.keys(BULK).filter(has).map((a) => `<button data-g="${a}">${lbl[a]}</button>`).join('');
        const failed = js.some((j) => j.state === 'failed');
        const allDone = js.every((j) => j.state === 'done');
        return `<details class="smkv-dlg${failed ? ' failed' : ''}${allDone ? ' alldone' : ''}" data-k="${esc(key)}" ${dlOpen.has(key) ? 'open' : ''}><summary>
          <div class="smkv-dlgh"><b>📺 ${esc(g.title)}</b><span class="smkv-dim2">${js.length} downloads${size ? ` · ${fmtSize(got)} / ${fmtSize(size)}` : ''} · ${Object.entries(counts).map(([k, n]) => `${n} ${esc(k.toLowerCase())}`).join(' · ')}${rate > 0 ? ` · ↓ ${fmtSize(rate)}/s` : ''}${up > 0 ? ` · ↑ ${fmtSize(up)}/s` : ''}</span></div>
          ${bulk ? `<span class="smkv-dlgb">${bulk}</span>` : ''}
          <div class="smkv-pbar big"><i style="width:${(size ? got / size * 100 : 0).toFixed(1)}%"></i></div></summary>${js.map(one).join('')}</details>`;
      }
      function draw() {
        const t = d.torrent || {};
        $('#smkv-dlrt').innerHTML = t.ok ? `Torrents go to rtorrent ${esc(t.version || '')}` : `⚠ Torrents unavailable: ${esc(t.error || '')} — http(s) links still work`;
        const names = Object.fromEntries(d.libraries.map((l) => [l.id, l.name]));
        groups = seriesGroups(d.jobs);
        const one = (j) => {
          const yt = j.kind === 'youtube';
          const itemFrac = j.size > 0 ? Math.min(1, j.done / j.size) : 0;
          const pct = yt ? (j.state === 'done' ? 100 : j.items > 0 ? Math.min(100, ((j.itemIndex || 1) - 1 + itemFrac) / j.items * 100) : itemFrac * 100)
            : j.size > 0 ? Math.min(100, j.done / j.size * 100) : 0;
          const mine = BR.me.admin || j.user === BR.me.user;
          const tor = j.kind === 'torrent' && j.hash && j.tstate && j.tstate !== 'removed';
          const st = j.kind === 'torrent' && j.tstate ? tName[j.tstate] || j.tstate : state[j.state] || j.state;
          return `<div class="smkv-dl ${esc(j.state)}" data-id="${esc(j.id)}">
            <div class="smkv-dlh"><b>${esc(j.name || j.source)}</b><span class="smkv-dim2">${j.kind} → ${esc(names[j.lib] || j.lib)}${j.subdir ? ' / ' + esc(j.subdir) : ''} · ${esc(j.user)}</span></div>
            <div class="smkv-pbar big"><i style="width:${pct.toFixed(1)}%"></i></div>
            <div class="smkv-dlf2"><span class="smkv-dim2">${st}${yt ? ytLine(j) : j.size > 0 ? ` · ${fmtSize(j.done)} / ${fmtSize(j.size)}` : ''}${j.rate > 0 ? ` · ↓ ${fmtSize(j.rate)}/s` : ''}${j.up > 0 ? ` · ↑ ${fmtSize(j.up)}/s` : ''}${j.kind === 'torrent' && j.tstate ? `<br>ratio <b>${(j.ratio || 0).toFixed(2)}</b> · ↑ ${fmtSize(j.uploaded || 0)}${tor ? ` · ${j.peers || 0} peers (${j.seeds || 0} seeds)` : ''} · ${seedTxt(j)}${j.autoStopped ? ` · <span style="color:#f5a623">auto-stopped: ${esc(j.autoStopped)}</span>` : ''}` : ''}${j.error ? ` · <span class="smkv-err">${esc(j.error)}</span>` : ''}${j.dupes && j.dupes.length ? `<br><span style="color:#f5a623" title="${esc(j.dupes.join('\n'))}">⚠ Also in the library: ${esc(j.dupes.slice(0, 2).join(' · '))}${j.dupes.length > 2 ? ` +${j.dupes.length - 2}` : ''}</span>` : ''}</span>
              ${mine ? `${(j.kind === 'http' || yt) && (j.state === 'failed' || j.state === 'canceled') ? '<button data-a="retry">Retry</button>' : ''}${yt && j.playlist && j.state === 'done' ? '<button data-a="retry" title="Download what was added to the playlist since">🔄 Update</button>' : ''}${tor ? torBtns(j.tstate) + '<button data-a="more" title="Recheck, seeding limit, trackers & files">⋯</button>' : ''}<button data-a="rm">${j.state === 'queued' || j.state === 'downloading' ? 'Cancel' : 'Remove'}</button>` : ''}</div></div>`;
        };
        // episodes / seasons of the same series sit together under one fold-out
        // one entry per download or per series group, then paged
        const shown = new Set(), entries = [];
        for (const j of d.jobs) {
          const k = groups.byJob.get(j.id);
          if (!k) entries.push({ j });
          else if (!shown.has(k)) { shown.add(k); entries.push({ k }); }
        }
        const pg = pager('downloads', entries, draw);
        $('#smkv-dllist').innerHTML = entries.length ? pg.items.map((e) => e.j ? one(e.j) : groupHtml(e.k, groups.get(e.k), one)).join('') + pg.bar
          : '<div class="smkv-dim">No downloads yet.</div>';
        pg.bind($('#smkv-dllist'));
        $('#smkv-dllist').querySelectorAll('details.smkv-dlg').forEach((el) => el.ontoggle = () => {
          if (el.open) dlOpen.add(el.dataset.k); else dlOpen.delete(el.dataset.k);
          lsSet('dlOpen', [...dlOpen].slice(-100));
        });
        $('#smkv-dllist').querySelectorAll('button[data-g]').forEach((b) => b.onclick = async (e) => {
          e.preventDefault(); e.stopPropagation();
          const g = groups.get(b.closest('.smkv-dlg').dataset.k), a = b.dataset.g;
          const ts = g.jobs.filter((j) => mineJ(j) && isTor(j) && BULK[a].includes(j.tstate));
          b.disabled = true;
          let bad = 0;
          for (const j of ts) { try { await apiPost(`downloads/${encodeURIComponent(j.id)}/torrent`, { action: a }); } catch (_) { bad++; } }
          toast(bad ? `${ts.length - bad} done, ${bad} failed` : `${ts.length} torrents: ${b.textContent.replace(/^\S+\s/, '').toLowerCase()}`);
          refresh();
        });
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
      setToolbar(canEditLib(lib) ? '<button id="smkv-selbtn" title="Pick several files, then group them into a series">☑ Select</button>' : '', draw);
      let sel = null; // Set of picked paths while selecting
      const sb = $('#smkv-selbtn');
      if (sb) sb.onclick = () => { sel = sel ? null : new Set(); sb.classList.toggle('on', !!sel); sb.textContent = sel ? '✕ Done' : '☑ Select'; draw(); };
      function draw() {
        const files = d.items.filter((f) => !f.show && matchQ(f.path, f.name)).sort((a, b) => (a.dir || '').localeCompare(b.dir || '') || a.name.localeCompare(b.name));
        const series = seriesRow(lib, d, '');
        let html = series ? series + (files.length ? '<h3 class="smkv-h">📁 Files</h3>' : '') : '', lastDir = null;
        for (const f of files) {
          if (f.dir !== lastDir) { lastDir = f.dir; html += `<div class="smkv-dir">${esc(f.dir || '/')}</div>`; }
          html += `<div class="smkv-item${sel && sel.has(f.path) ? ' picked' : ''}" data-path="${esc(f.path)}"><div class="smkv-name">${sel ? `<input type="checkbox" class="smkv-pick" ${sel.has(f.path) ? 'checked' : ''}>` : ''}${esc(f.name)}${canEditLib(lib) && !sel ? '<button class="smkv-epedit smkv-fser" title="Put this file in a series">📺</button>' : ''}${canDelete(lib) ? '<button class="smkv-epedit smkv-fdel" title="Delete this file">🗑</button>' : ''}</div>
            <div class="smkv-sub">${fmtSize(f.size)}${f.pos ? ` · <span class="smkv-resume">⏵ ${fmtTime(f.pos)}</span>` : ''}</div></div>`;
        }
        view.innerHTML = (html || '<div class="smkv-dim">No files</div>') + (sel ? selBar(sel.size) : '');
        bindSeries(lib);
        view.querySelectorAll('.smkv-item').forEach((el) => el.onclick = () => {
          if (!sel) return playVideo(el.dataset.path);
          const p = el.dataset.path;
          if (sel.has(p)) sel.delete(p); else sel.add(p);
          draw();
        });
        if (sel) bindSelBar(lib, d, () => [...sel].map((p) => d.items.find((f) => f.path === p)).filter(Boolean), () => { sel.clear(); draw(); }, () => sb.click());
        view.querySelectorAll('.smkv-fser').forEach((b) => b.onclick = (ev) => {
          ev.stopPropagation();
          const f = d.items.find((x) => x.path === b.closest('.smkv-item').dataset.path);
          editDialog({ lib, title: f.name, keys: [f.path], fields: { showTitle: '', season: 1, episode: '', episodeTitle: '' } });
        });
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
      document.title = 'Delos';
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
          image: (sh && sh.poster) || (m && m.poster) || '', pos: Math.round(cur()), dur: Math.round(S.info.duration || 0), playing: !media.paused };
      }
      if (A.cur && !A.el.paused) {
        return { kind: 'music', path: A.cur.path, title: A.cur.title || A.cur.name, sub: [A.cur.artist, A.cur.album].filter(Boolean).join(' — '),
          image: A.cur.cover ? 'cover:' + A.cur.cover : '', pos: Math.round(aTime()), dur: Math.round(A.cur.duration || 0), playing: true };
      }
      return null;
    }
    async function heartbeat(force) {
      const a = myActivity(), key = a ? a.kind + a.path + a.title + a.playing : '';
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
    // someone's roles, compact: the first one, +N for the rest (all in the tooltip)
    const roleBadge = (name) => {
      const r = (SO.people.find((x) => x.name === name) || {}).roles || [];
      if (!r.length) return '';
      const g = r[0] === 'Guest' && r.length === 1;
      return `<span class="smkv-role sm ${g ? 'guest' : ''}" title="${esc(g ? 'Guest — no role yet' : 'Roles: ' + r.join(', '))}">${g ? '' : '🏷 '}${esc(r[0])}${r.length > 1 ? ` +${r.length - 1}` : ''}</span>`;
    };
    // my roles (what decides which libraries I see); no role = Guest
    const myRoles = () => (BR.me && BR.me.admin ? '<span class="smkv-role adm" title="Admin: sees everything">Admin</span>' : '')
      + ((BR.me && BR.me.roles) || []).map((r) => `<span class="smkv-role ${r.id === 'guest' ? 'guest' : ''}" title="${r.id === 'guest' ? 'No role yet — ask the admin for one' : 'Your role'}">${r.id === 'guest' ? '' : '🏷 '}${esc(r.name)}</span>`).join('');
    function drawWhoami() {
      const el = $('#smkv-whoami');
      if (!el || !BR.me || !BR.me.user) return;
      el.hidden = false;
      el.innerHTML = `${avatarHtml(BR.me.user, 24)}<b>${esc(BR.me.user)}</b><span class="smkv-roles">${myRoles()}</span>`;
      el.title = `Signed in as ${BR.me.user}`;
      el.onclick = () => toggleChat(true);
    }
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
        others.map((p) => `<div class="smkv-person ${p.online ? 'on' : ''}" data-u="${esc(p.name)}" title="${esc(p.name)} · ${p.online ? 'Online' : p.lastSeen ? 'Last seen ' + new Date(p.lastSeen * 1000).toLocaleString() : 'Offline'}">
          ${avatarHtml(p.name, 30, p.online)}<div style="min-width:0;flex:1"><b>${esc(p.name)}</b>${adminBadge(p.name)}${roleBadge(p.name)}${badgeIcons(p.badges, 3)}${p.online && p.activity && p.activity.path ? `<button class="smkv-askj" data-ask="${esc(p.name)}" title="Ask ${esc(p.name)} to ${p.activity.kind === 'music' ? 'listen' : 'watch'} together">🎉</button>` : ''}${p.activity ? `<div class="smkv-act ${p.activity.path ? 'link' : ''}" data-p="${esc(p.activity.path || '')}" data-k="${esc(p.activity.kind)}">${actLine(p.activity)}</div>` : ''}</div></div>`).join('');
      el.querySelectorAll('.smkv-person').forEach((r) => r.onclick = (e) => {
        const ask = e.target.closest('[data-ask]');
        if (ask) { e.stopPropagation(); return askToJoin(ask.dataset.ask); }
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
      partySocial(es);
      es.addEventListener('remote-cmd', (e) => { const c = JSON.parse(e.data); if (c.to === RM.id) remoteCmd(c).catch((x) => toast(x.message, 3000)); });
      es.addEventListener('open', () => remoteHello(true));
      es.addEventListener('people', (e) => { SO.people = JSON.parse(e.data); drawPeople(); });
      es.addEventListener('announcement', () => loadAnnouncements());
      es.addEventListener('request', (e) => {
        const x = JSON.parse(e.data);
        const msg = { available: `✅ “${x.title}” is here now`, approved: `👍 Your request for “${x.title}” was approved`, declined: `✕ Your request for “${x.title}” was declined${x.note ? ' — ' + x.note : ''}`, pending: `⏳ “${x.title}” is waiting again` }[x.status];
        if (msg) toast(msg, 9000, x.status === 'available' && x.lib ? { label: 'Open', fn: () => rqOpen(x) } : null);
        if (location.hash.startsWith('#/requests')) requestsView();
      });
      es.addEventListener('request-new', (e) => {
        const x = JSON.parse(e.data);
        toast(`🙋 ${x.by} asked for “${x.title}”${x.year ? ` (${x.year})` : ''}`, 8000, { label: 'See', fn: () => (location.hash = '#/requests') });
        if (location.hash.startsWith('#/requests')) requestsView(); else rqCount();
      });
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
          toast(`💬 ${m.from}${c && c.kind === 'group' ? ' in ' + c.title : ''}: ${msgPreview(m)}`, 6000, { label: 'Open', fn: () => openConv(conv) });
        }
      });
      es.addEventListener('reaction', (e) => {
        const r = JSON.parse(e.data);
        if (!SO.open || SO.open.id !== r.conv) return;
        const m = SO.msgs.find((x) => x.seq === r.seq);
        if (m) { m.reactions = r.reactions || null; drawMsgs(false); }
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
        <div class="smkv-me">${avatarHtml(BR.me.user, 40)}<div style="flex:1;min-width:0"><b>${esc(BR.me.user)}</b>${adminBadge(BR.me.user)}<div class="smkv-roles">${(BR.me.roles || []).map((r) => `<span class="smkv-role ${r.id === 'guest' ? 'guest' : ''}">${r.id === 'guest' ? '' : '🏷 '}${esc(r.name)}</span>`).join('')}</div>
          <div><button class="smkv-link" id="smkv-avset">Change picture</button>${BR.me.avatar ? ' · <button class="smkv-link" id="smkv-avdel">Remove</button>' : ''}</div></div></div>
        <label class="smkv-check smkv-priv"><input type="checkbox" id="smkv-hideact" ${SO.hide ? 'checked' : ''}> Hide what I'm watching from others</label>
        <div class="smkv-convs">${SO.convs.length ? SO.convs.map((v) => `<div class="smkv-conv" data-id="${esc(v.id)}">
          ${v.kind === 'group' ? '<div class="smkv-av">👥</div>' : avatarHtml(v.title, 36, (SO.people.find((x) => x.name === v.title) || {}).online || false)}
          <div class="smkv-cm"><b>${esc(v.title)}${v.kind === 'group' ? '' : adminBadge(v.title)}</b><span class="smkv-dim2">${v.last ? esc((v.last.sys ? '' : v.last.from + ': ') + msgPreview(v.last)) : 'No messages yet'}</span></div>
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
        <div class="smkv-uploads"></div>
        <form class="smkv-send"><button type="button" class="smkv-cbtn" data-a="emo" title="Emoji">😊</button>
          ${BR.me.chatMaxMB > 0 ? `<label class="smkv-cbtn" title="Attach pictures or files (max ${BR.me.chatMaxMB} MB) — you can also paste or drop them"><input type="file" multiple hidden>📎</label>` : ''}
          <input placeholder="Message…" autocomplete="off" maxlength="4000"><button class="smkv-sendb" title="Send">➤</button></form>`;
      c.querySelector('.smkv-back').onclick = drawConvs;
      c.querySelector('.smkv-x').onclick = () => toggleChat(false);
      c.querySelector('.smkv-cmore').onclick = () => groupDialog(SO.open);
      const inpEl = c.querySelector('.smkv-send input:not([type])');
      c.querySelector('[data-a=emo]').onclick = (e) => emojiPicker(e.currentTarget, (em) => {
        const a = inpEl.selectionStart ?? inpEl.value.length, b = inpEl.selectionEnd ?? a;
        inpEl.value = inpEl.value.slice(0, a) + em + inpEl.value.slice(b);
        inpEl.focus(); inpEl.setSelectionRange(a + em.length, a + em.length);
      }, { keepOpen: true });
      const fileInp = c.querySelector('.smkv-send input[type=file]');
      if (fileInp) fileInp.onchange = () => { uploadFiles(id, [...fileInp.files], inpEl); fileInp.value = ''; };
      inpEl.addEventListener('paste', (e) => {
        const files = [...(e.clipboardData?.files || [])];
        if (files.length && BR.me.chatMaxMB > 0) { e.preventDefault(); uploadFiles(id, files, inpEl); }
      });
      c.ondragover = (e) => { if (SO.open && BR.me.chatMaxMB > 0 && [...e.dataTransfer.types].includes('Files')) { e.preventDefault(); c.classList.add('smkv-drop'); } };
      c.ondragleave = (e) => { if (!c.contains(e.relatedTarget)) c.classList.remove('smkv-drop'); };
      c.ondrop = (e) => {
        c.classList.remove('smkv-drop');
        if (!SO.open || !e.dataTransfer.files.length) return;
        e.preventDefault(); uploadFiles(SO.open.id, [...e.dataTransfer.files], inpEl);
      };
      c.querySelector('.smkv-send').onsubmit = async (e) => {
        e.preventDefault();
        const inp = inpEl, text = inp.value.trim();
        if (!text) return;
        inp.value = '';
        try { const r = await apiPost(`chat/${encodeURIComponent(id)}/messages`, { text }); if (!SO.msgs.some((x) => x.seq === r.message.seq)) { SO.msgs.push(r.message); drawMsgs(true); } }
        catch (x) { toast(x.message); inp.value = text; }
      };
      drawChatHead(); drawMsgs(true);
      inpEl.focus();
      if (SO.open.unread) apiPost(`chat/${encodeURIComponent(id)}/read`, { seq: SO.open.seq }).catch(() => {});
      SO.open.unread = 0; drawUnread();
    }
    function drawChatHead() {
      const t = $('#smkv-ctitle');
      if (!t || !SO.open) return;
      const p = SO.people.find((x) => x.name === SO.open.title);
      t.innerHTML = SO.open.kind === 'group' ? `👥 ${esc(SO.open.title)} <span class="smkv-dim2">${SO.open.members.length}</span>`
        : `${avatarHtml(SO.open.title, 26)} ${esc(SO.open.title)}${adminBadge(SO.open.title)}${roleBadge(SO.open.title)} <span class="smkv-dim2">${p && p.online ? '● online' : ''}</span>`;
      $('#smkv-chat .smkv-cmore').hidden = SO.open.kind !== 'group';
    }
    function drawMsgs(scroll) {
      const box = $('#smkv-chat .smkv-msgs');
      if (!box) return;
      const keep = scroll ? null : box.scrollTop;
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
        const rx = m.reactions ? `<div class="smkv-rxs">${Object.entries(m.reactions).map(([e, us]) =>
          `<button class="smkv-rx${us.includes(BR.me.user) ? ' on' : ''}" data-e="${esc(e)}" title="${esc(us.join(', '))}">${esc(e)}${us.length > 1 ? ` <b>${us.length}</b>` : ''}</button>`).join('')}</div>` : '';
        const body = `${!mine && SO.open.kind === 'group' ? `<small class="smkv-from">${esc(m.from)}${adminBadge(m.from)}</small>` : ''}
          ${ref}${attHtml(m)}${m.text ? `<div class="smkv-bubble">${linkify(m.text).replace(/<br>/g, "\n")}</div>` : ''}${rx}
          <small class="smkv-time">${d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}<button class="smkv-rxadd" title="React">☺︎+</button></small>`;
        return sep + (mine ? `<div class="smkv-msg me" data-seq="${m.seq}">${body}</div>`
          : `<div class="smkv-mrow">${avatarHtml(m.from, 28)}<div class="smkv-msg" data-seq="${m.seq}">${body}</div></div>`);
      }).join('') || '<div class="smkv-dim" style="padding:16px">Say hi 👋</div>';
      box.querySelectorAll('.smkv-ref').forEach((r) => r.onclick = () => openRef({ path: r.dataset.p, kind: r.dataset.k }));
      const seqOf = (el) => +el.closest('.smkv-msg').dataset.seq;
      box.querySelectorAll('.smkv-rx').forEach((b) => b.onclick = () => react(seqOf(b), b.dataset.e));
      box.querySelectorAll('.smkv-rxadd').forEach((b) => b.onclick = (e) => { e.stopPropagation(); quickReact(b, seqOf(b)); });
      box.querySelectorAll('.smkv-msg').forEach((el) => el.onclick = (e) => { // touch: tap a message to show its react button
        if (e.target.closest('button,a,img,.smkv-ref')) return;
        box.querySelectorAll('.smkv-msg.act').forEach((x) => x !== el && x.classList.remove('act'));
        el.classList.toggle('act');
      });
      box.querySelectorAll('.smkv-attimg').forEach((im) => {
        im.onclick = () => viewImage(im.dataset.full, im.dataset.name, im.dataset.dl);
        if (scroll) im.onload = () => { if (box.scrollHeight - box.scrollTop - box.clientHeight < im.height + 80) box.scrollTop = box.scrollHeight; };
      });
      if (scroll) box.scrollTop = box.scrollHeight;
      else if (keep != null) box.scrollTop = keep;
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
    // ---- chat: attachments, reactions, emoji
    function msgPreview(m) {
      if (!m) return '';
      if (m.ref) return '📎 ' + m.ref.title;
      if (m.att) return (m.att.image ? '🖼 Photo' : '📎 ' + m.att.name) + (m.text ? ' · ' + m.text : '');
      return m.text || '';
    }
    const fileUrl = (conv, att, q = '') => new URL(`api/chat/${encodeURIComponent(conv)}/files/${att.id}${q}`, BASE).href;
    function attHtml(m) {
      const a = m.att;
      if (!a) return '';
      if (a.gone) return `<div class="smkv-attf gone">📎 <span>${esc(a.name)}</span><small>expired</small></div>`;
      const conv = SO.open.id;
      if (a.image) {
        const w = Math.min(240, a.w || 240), h = a.w && a.h ? Math.round(w * a.h / a.w) : 0;
        return `<img class="smkv-attimg" loading="lazy" src="${esc(fileUrl(conv, a, a.thumb ? '?thumb=1' : ''))}" ${h ? `width="${w}" height="${Math.min(h, 360)}"` : ''}
          alt="${esc(a.name)}" data-full="${esc(fileUrl(conv, a))}" data-dl="${esc(fileUrl(conv, a, '?dl=1'))}" data-name="${esc(a.name)}">`;
      }
      const ic = /^video\//.test(a.mime) ? '🎞' : /^audio\//.test(a.mime) ? '🎵' : /pdf/.test(a.mime) ? '📄' : /zip|rar|7z|tar|gzip/.test(a.mime) ? '🗜' : '📎';
      return `<a class="smkv-attf" href="${esc(fileUrl(conv, a, '?dl=1'))}" download="${esc(a.name)}" title="Download">${ic} <span>${esc(a.name)}</span><small>${fmtSize(a.size)} ⬇</small></a>`;
    }
    function viewImage(src, name, dl) {
      detailModal(`<div class="smkv-imgview"><img src="${esc(src)}" alt="${esc(name)}"></div>
        <div class="smkv-row" style="margin-top:10px"><span class="smkv-dim2" style="flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(name)}</span><a class="smkv-btnlink" href="${esc(dl)}" download="${esc(name)}">⬇ Download</a></div>`);
    }
    async function react(seq, emoji) {
      if (!SO.open) return;
      try {
        const r = await apiPost(`chat/${encodeURIComponent(SO.open.id)}/messages/${seq}/react`, { emoji });
        const m = SO.msgs.find((x) => x.seq === seq);
        if (m) { m.reactions = r.reactions || null; drawMsgs(false); }
        rememberEmoji(emoji);
      } catch (x) { toast(x.message); }
    }
    function quickReact(anchor, seq) {
      closePops();
      const quick = [...new Set([...lsGet('emojiRecent', []), '👍', '❤️', '😂', '😮', '😢', '🙏'])].slice(0, 6);
      const pop = document.createElement('div');
      pop.className = 'smkv-pop smkv-quick';
      pop.innerHTML = quick.map((e) => `<button data-e="${esc(e)}">${esc(e)}</button>`).join('') + '<button data-more title="More">＋</button>';
      document.body.appendChild(pop);
      placePop(pop, anchor);
      pop.querySelectorAll('[data-e]').forEach((b) => b.onclick = () => { closePops(); react(seq, b.dataset.e); });
      pop.querySelector('[data-more]').onclick = () => { closePops(); emojiPicker(anchor, (e) => react(seq, e)); };
    }
    function closePops() { document.querySelectorAll('.smkv-pop').forEach((p) => p.remove()); }
    document.addEventListener('pointerdown', (e) => { if (!e.target.closest('.smkv-pop,[data-a=emo],.smkv-rxadd')) closePops(); });
    document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && document.querySelector('.smkv-pop')) { closePops(); e.stopPropagation(); } }, true);
    function placePop(pop, anchor) {
      const r = anchor.getBoundingClientRect(), pw = pop.offsetWidth, ph = pop.offsetHeight;
      let x = Math.min(Math.max(8, anchor.classList.contains('smkv-rxadd') ? r.right - pw : r.left), innerWidth - pw - 8);
      let y = r.top - ph - 6;
      if (y < 8) y = Math.min(r.bottom + 6, innerHeight - ph - 8);
      pop.style.left = x + 'px'; pop.style.top = y + 'px';
    }
    function rememberEmoji(e) { lsSet('emojiRecent', [e, ...lsGet('emojiRecent', []).filter((x) => x !== e)].slice(0, 24)); }
    let emojiData = null;
    async function emojiPicker(anchor, onPick, opts = {}) {
      if (document.querySelector('.smkv-emo')) { closePops(); return; }
      closePops();
      const pop = document.createElement('div');
      pop.className = 'smkv-pop smkv-emo';
      pop.innerHTML = '<div class="smkv-dim2" style="padding:20px">Loading…</div>';
      document.body.appendChild(pop);
      placePop(pop, anchor);
      if (!emojiData) {
        try { emojiData = await (await fetch(new URL('emoji.json?v=' + (window.SMKV_VERSION || ''), BASE))).json(); }
        catch { pop.remove(); return toast("Couldn't load emoji"); }
      }
      if (!pop.isConnected) return;
      const groups = [{ name: 'Recent', icon: '🕘', items: lsGet('emojiRecent', []).map((e) => [e, '']) }, ...emojiData.groups].filter((g) => g.items.length);
      pop.innerHTML = `<input class="smkv-emoq" placeholder="Search emoji" autocomplete="off">
        <div class="smkv-emotabs">${groups.map((g, i) => `<button data-g="${i}" title="${esc(g.name)}">${g.icon}</button>`).join('')}</div>
        <div class="smkv-emogrid"></div>`;
      const grid = pop.querySelector('.smkv-emogrid'), q = pop.querySelector('.smkv-emoq');
      const cell = (e, kw) => `<button data-e="${esc(e)}" title="${esc(kw.split(' ').slice(0, 3).join(' '))}">${esc(e)}</button>`;
      const show = () => {
        const t = q.value.trim().toLowerCase();
        if (t) {
          const hits = [];
          for (const g of emojiData.groups) for (const [e, kw] of g.items) if (kw.includes(t)) hits.push(cell(e, kw));
          grid.innerHTML = hits.slice(0, 240).join('') || '<div class="smkv-dim2" style="padding:12px">No emoji found</div>';
        } else {
          grid.innerHTML = groups.map((g, i) => `<div class="smkv-emoh" data-h="${i}">${esc(g.name)}</div>${g.items.map(([e, kw]) => cell(e, kw)).join('')}`).join('');
        }
      };
      show();
      q.oninput = show;
      pop.querySelectorAll('.smkv-emotabs button').forEach((b) => b.onclick = () => {
        q.value = ''; show();
        const h = grid.querySelector(`[data-h="${b.dataset.g}"]`); if (h) grid.scrollTop = h.offsetTop - grid.offsetTop;
      });
      grid.onclick = (e) => {
        const b = e.target.closest('[data-e]');
        if (!b) return;
        rememberEmoji(b.dataset.e);
        onPick(b.dataset.e);
        if (!opts.keepOpen) closePops();
      };
      placePop(pop, anchor);
      if (matchMedia('(pointer:fine)').matches) q.focus();
    }
    // Uploads: one at a time per file, with a progress row above the composer.
    function uploadFiles(conv, files, captionInput) {
      const max = (BR.me.chatMaxMB || 0) * 1048576;
      for (const f of files) {
        if (max && f.size > max) { toast(`${f.name} is too big (max ${BR.me.chatMaxMB} MB)`, 4000); continue; }
        const caption = captionInput && files.length === 1 ? captionInput.value.trim() : '';
        if (caption) captionInput.value = '';
        const row = document.createElement('div');
        row.className = 'smkv-up';
        row.innerHTML = `<span>${esc(f.name || 'pasted image')}</span><progress max="100" value="0"></progress><button title="Cancel">✕</button>`;
        $('#smkv-chat .smkv-uploads')?.appendChild(row);
        const fd = new FormData();
        if (caption) fd.append('text', caption);
        fd.append('file', f, f.name || 'image.png');
        const x = new XMLHttpRequest();
        x.open('POST', new URL(`api/chat/${encodeURIComponent(conv)}/attachments`, BASE));
        x.withCredentials = true;
        x.upload.onprogress = (e) => { if (e.lengthComputable) row.querySelector('progress').value = e.loaded / e.total * 100; };
        x.onload = () => {
          row.remove();
          let r = {}; try { r = JSON.parse(x.responseText); } catch { /* ignore */ }
          if (x.status !== 200) return toast(`${f.name}: ${r.error || x.statusText}`, 5000);
          if (SO.open && SO.open.id === conv && r.message && !SO.msgs.some((m) => m.seq === r.message.seq)) { SO.msgs.push(r.message); drawMsgs(true); }
        };
        x.onerror = () => { row.remove(); toast(`${f.name}: upload failed`, 4000); };
        row.querySelector('button').onclick = () => { x.abort(); row.remove(); };
        x.send(fd);
      }
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
    // Queue songs: "next" plays them right after the current song, otherwise at the end of the queue.
    function enqueue(list, next) {
      list = list.filter(Boolean);
      if (!list.length) return;
      if (!A.cur) { playQueue(list, 0); toast(`Playing ${list.length > 1 ? list.length + ' songs' : list[0].title || list[0].name}`); return; }
      if (next) A.queue.splice(A.idx + 1, 0, ...list); else A.queue.push(...list);
      renderNav();
      if (location.hash.startsWith('#/music/now')) drawNow();
      aSave();
      toast(`${next ? 'Playing next' : 'Added to queue'}: ${list.length > 1 ? list.length + ' songs' : list[0].title || list[0].name}`);
    }
    function loadTrack(start, play = true) {
      const t = A.queue[A.idx];
      if (!t) return;
      A.cur = t; A.want = play;
      const adl = $('#smkv-adl');
      adl.hidden = !canSave(); adl.href = dlUrl(t.path);
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
      if (play) A.el.play().catch(() => { if (A.restoring) toast('Press ▶ to continue where you left off', 4000); });
      else $('#smkv-app-pp').textContent = '▶';
      A.restoring = false;
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
      document.title = `♪ ${t.title || t.name} — Delos`;
      drawNow.scrolled = false;
      drawNow(); drawMini(); aSave();
    }
    // Remember the queue, the song and the spot in it, so a page refresh carries on where it was.
    function aSave() {
      if (!A.cur) return lsSet('aState', null);
      const lo = Math.max(0, A.idx - 200);
      lsSet('aState', { u: BR.me?.user || '', q: A.queue.slice(lo, A.idx + 800), i: A.idx - lo, t: Math.floor(aTime()), p: !A.el.paused || A.want, at: Date.now() });
    }
    function aRestore() {
      const s = lsGet('aState', null);
      if (!s || !Array.isArray(s.q) || !s.q.length || A.cur) return;
      if ((s.u && BR.me?.user && s.u !== BR.me.user) || Date.now() - (s.at || 0) > 14 * 864e5) return lsSet('aState', null);
      A.queue = s.q; A.idx = Math.min(Math.max(0, s.i | 0), s.q.length - 1);
      A.restoring = !!s.p;
      loadTrack(Math.max(0, (s.t || 0) - 2), !!s.p);
      renderNav();
      if (location.hash.startsWith('#/music/now') && !$('#smkv-np-cover')) route(); // it said "nothing is playing" before we restored
    }
    const aTime = () => A.offset + (A.el.currentTime || 0);
    const aDur = () => A.cur?.duration || (isFinite(A.el.duration) ? A.el.duration : 0);
    function aNext(manual) {
      if (manual && partyLocked('music')) return;
      if (!manual && P.party && P.party.kind === 'music' && !partyHost()) return; // the host says what's next
      if (A.repeat === 'one' && !manual) return loadTrack(0);
      if (A.idx + 1 < A.queue.length) { A.idx++; loadTrack(0); }
      else if (A.repeat === 'all' && A.queue.length) { A.idx = 0; loadTrack(0); }
      else { A.want = false; aSave(); }
    }
    function aPrev() {
      if (partyLocked('music')) return;
      if (aTime() > 4 || A.idx === 0) return aSeek(0);
      A.idx--; loadTrack(0);
    }
    function aSeek(t) {
      if (!A.cur || partyLocked('music')) return;
      t = Math.max(0, Math.min(t, aDur() - 0.5));
      if (A.transcoded) loadTrack(t); else A.el.currentTime = t;
    }
    function aToggle() { if (!A.cur || partyLocked('music')) return; A.el.paused ? A.el.play().catch(() => {}) : A.el.pause(); }
    A.el.addEventListener('ended', () => aNext(false));
    A.el.addEventListener('play', () => { A.want = true; $('#smkv-app-pp').textContent = '❚❚'; drawMini(); drawNow(); aSave(); });
    A.el.addEventListener('pause', () => { if (!A.el.ended) A.want = false; $('#smkv-app-pp').textContent = '▶'; drawMini(); drawNow(); aSave(); });
    window.addEventListener('pagehide', aSave);
    document.addEventListener('visibilitychange', () => { if (document.hidden) aSave(); });
    A.el.addEventListener('timeupdate', () => lyrTick());
    A.el.addEventListener('timeupdate', () => {
      const t = aTime(), dd = aDur();
      if (Date.now() - (A.savedAt || 0) > 5000) { A.savedAt = Date.now(); aSave(); }
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
        A.el.src = u.href; if (A.want) A.el.play().catch(() => {});
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
    $('#smkv-aclose').onclick = () => { A.el.pause(); A.el.removeAttribute('src'); A.cur = null; A.queue = []; lsSet('aState', null); $('#smkv-abar').classList.remove('show'); document.body.classList.remove('smkv-audio-on'); drawMini(); if (location.hash.startsWith('#/music/now')) route(); };
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

    // fold the sidebar to a rail of icons (remembered; Ctrl/⌘+B)
    function setFold(on) {
      document.body.classList.toggle('smkv-side-mini', on);
      lsSet('sideMini', on);
      $('#smkv-fold').title = on ? 'Unfold the sidebar (Ctrl+B)' : 'Fold the sidebar (Ctrl+B)';
      renderNav();
    }
    document.body.classList.toggle('smkv-side-mini', !!lsGet('sideMini', false));
    $('#smkv-fold').onclick = () => setFold(!document.body.classList.contains('smkv-side-mini'));
    document.addEventListener('keydown', (e) => {
      if ((e.ctrlKey || e.metaKey) && !e.shiftKey && !e.altKey && e.key.toLowerCase() === 'b' && !e.target.closest('input,textarea,[contenteditable]')) {
        e.preventDefault(); setFold(!document.body.classList.contains('smkv-side-mini'));
      }
    });
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
      { const v = $('#smkv-vdl'); v.hidden = !canSave(); v.href = dlUrl(f.path); }
      S.file = f; S.info = null; S.cues = []; S.sub = null; S.forceTranscode = false; S.errCount = 0; S.subDelay = 0;
      S.browserFail = null;
      S.loadSeq++;
      stopServerStream();
      if (wp) wp.pause();
      S.engFile = null;
      renderSubs(true); updateSubDelay();
      $('#smkv-title').textContent = f.name;
      $('#smkv-meta').textContent = 'Probing…';
      document.title = f.name + ' — Delos';
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
      tpLoad(f);
      updateMeta();

      // resume (a party says where instead)
      let start = 0;
      const pos = opts.fromStart ? 0 : ((server && server.pos) || lsGet('pos:' + f.path, 0));
      if (opts.start != null) start = opts.start;
      else if (pos > 30 && pos < (info.duration || 0) - 120) {
        start = pos;
        toast(`Resumed at ${fmtTime(pos)}`, 6000, { label: 'Start over', fn: () => playAt(0, true) });
      }
      playAt(start, opts.autoplay !== false);
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
      if (S.sub && !S.sub.text) {
        q.burn = S.sub.idx;
        if (S.subSize !== 100) q.subscale = S.subSize;
        if (S.subPos) q.subpos = S.subPos;
      }
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
      if (partyLocked('video')) return;
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
      if (partyLocked('video')) return;
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
    seek.addEventListener('input', () => { S.dragging = true; updateTime(); tpAt(+seek.value); });
    seek.addEventListener('change', () => { S.dragging = false; seekTo(+seek.value); tpHide(); });
    seek.addEventListener('mousemove', (e) => {
      const r = seek.getBoundingClientRect(), d = +seek.max || 0;
      if (d && r.width) tpAt(Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)) * d, e.clientX);
    });
    seek.addEventListener('mouseleave', () => { if (!S.dragging) tpHide(); });

    // ---------------------------------------------------------- seek-bar previews (sprite sheets made by the server)
    const TP = { path: null, info: null, timer: 0, pending: null };
    function tpLoad(f) {
      clearTimeout(TP.timer); TP.path = f.path; TP.info = null; TP.pending = null;
      if (!feat('trickplay')) return;
      const go = async (n) => {
        if (TP.path !== f.path) return;
        let d; try { d = await api('trickplay', { path: f.path }); } catch { return; } // no video / turned off
        if (TP.path !== f.path) return;
        TP.pending = d.pending ? d.progress || 0 : null;
        if (d.ready) { TP.info = d; [...Array(Math.min(d.sheets, 3)).keys()].forEach((n) => { new Image().src = tpSheet(n); }); }
        else if (d.pending && n < 400) TP.timer = setTimeout(() => go(n + 1), 3000);
      };
      go(0);
    }
    function tpSheet(n) { const u = new URL('api/trickplay/sheet', BASE); u.searchParams.set('path', TP.path); u.searchParams.set('n', n); return u.href; }
    function tpHide() { $('#smkv-tp').hidden = true; }
    function tpAt(t, clientX) {
      const box = $('#smkv-tp'), ctl = $('#smkv-controls').getBoundingClientRect(), r = seek.getBoundingClientRect(), d = +seek.max || 0;
      if (!d) return;
      if (clientX == null) clientX = r.left + 6 + (r.width - 12) * (t / d); // where the thumb is
      const i = TP.info, img = box.querySelector('.img');
      box.querySelector('span').textContent = fmtTime(t) + (!i && TP.pending != null ? ` · preparing previews ${Math.round(TP.pending * 100)}%` : '');
      let w = !i && TP.pending != null ? 220 : 56;
      if (i && i.count) {
        const k = Math.min(i.count - 1, Math.max(0, Math.round(t / i.interval))), per = i.cols * i.rows, c = k % per;
        const sc = ctl.width < 560 ? 0.6 : 1; w = i.w * sc;
        img.style.cssText = `display:block;width:${w}px;height:${i.h * sc}px;background-image:url("${tpSheet(Math.floor(k / per))}");`
          + `background-size:${i.cols * w}px auto;background-position:-${(c % i.cols) * w}px -${Math.floor(c / i.cols) * i.h * sc}px`;
      } else img.style.display = 'none';
      box.style.left = Math.max(6, Math.min(ctl.width - w - 6, clientX - ctl.left - w / 2)) + 'px';
      box.hidden = false;
    }

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
    // Subtitle size / position: text subs are styled here; burned-in picture subs restart the stream.
    let subLookTimer = 0;
    function updateSubLook(changed) {
      S.subSize = Math.min(200, Math.max(50, Math.round(S.subSize)));
      S.subPos = Math.min(40, Math.max(-10, Math.round(S.subPos)));
      lsSet('subSize', S.subSize); lsSet('subPos', S.subPos);
      $('#smkv-ss').textContent = S.subSize + '%';
      $('#smkv-sp').textContent = (S.subPos > 0 ? '+' : '') + S.subPos + '%';
      player.style.setProperty('--sraise', S.subPos + '%');
      sizeSubs();
      if (changed && S.file && S.sub && !S.sub.text) {
        clearTimeout(subLookTimer);
        subLookTimer = setTimeout(() => { if (S.file && S.sub && !S.sub.text) playAt(cur(), !media.paused); }, 700);
      }
    }
    $('#smkv-ss-minus').onclick = () => { S.subSize -= 10; updateSubLook(true); };
    $('#smkv-ss-plus').onclick = () => { S.subSize += 10; updateSubLook(true); };
    $('#smkv-sp-down').onclick = () => { S.subPos -= 2; updateSubLook(true); };
    $('#smkv-sp-up').onclick = () => { S.subPos += 2; updateSubLook(true); };
    $('#smkv-ss').ondblclick = () => { S.subSize = 100; updateSubLook(true); };
    $('#smkv-sp').ondblclick = () => { S.subPos = 0; updateSubLook(true); };

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
        '[': () => { $('#smkv-ss-minus').click(); toast('Subtitle size ' + S.subSize + '%', 1000); },
        ']': () => { $('#smkv-ss-plus').click(); toast('Subtitle size ' + S.subSize + '%', 1000); },
        '{': () => { $('#smkv-sp-down').click(); toast('Subtitle position ' + $('#smkv-sp').textContent, 1000); },
        '}': () => { $('#smkv-sp-up').click(); toast('Subtitle position ' + $('#smkv-sp').textContent, 1000); },
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

    function sizeSubs() {
      const h = player.clientHeight;
      subsEl.style.fontSize = Math.max(12, Math.round(h * 0.048 * S.subSize / 100)) + 'px';
    }
    new ResizeObserver(sizeSubs).observe(player);
    updateSubLook(false);

    // ------------------------------------------------------------ https hint
    // On plain http the browser hides WebCodecs, so in-browser playback can't work. The server
    // also speaks https on the same port: offer a one-click switch (the login cookie carries over).
    function drawSecBar() {
      const bar = $('#smkv-secbar');
      const later = +lsGet('secbarLater', 0);
      const show = location.protocol === 'http:' && !window.isSecureContext && BR.me && BR.me.https
        && getSettings().engine !== 'server' && Date.now() > later;
      bar.hidden = !show;
      if (!show) return;
      const url = 'https://' + location.host + location.pathname + location.search + location.hash;
      bar.innerHTML = `<span>🔒</span><div><b>Play original files right in this browser</b>
        <div>Browsers only allow it on a secure page. Switch to https — the first time, the browser may warn: choose <i>Advanced → Proceed</i>,
        or <a href="${esc(new URL('tls', BASE).href)}" target="_blank">install the certificate</a> to skip the warning.</div></div>
        <button data-a="go" class="smkv-primary">Switch to https</button><button data-a="later" title="Hide for 30 days">✕</button>`;
      bar.querySelector('[data-a=go]').onclick = () => { location.href = url; };
      bar.querySelector('[data-a=later]').onclick = () => { lsSet('secbarLater', Date.now() + 30 * 864e5); bar.hidden = true; };
    }

    // ------------------------------------------------------------ watch party
    // One host plays, everyone in the party follows. Chat + floating emoji beside the player.
    const P = { party: null, skew: 0, applying: false, last: null, hostTimer: 0, driftTimer: 0, muted: !!lsGet('partyMute', false), min: false };
    const REACTS = ['😂', '❤️', '👏', '😮', '😢', '🔥', '🎉', '👍'];
    const partyHost = () => !!(P.party && P.party.host === BR.me.user);
    // a viewer may not pause / seek / skip what the party is playing
    function partyLocked(kind) {
      if (!P.party || P.applying || partyHost()) return false;
      if (kind && P.party.kind !== kind) return false;
      if (kind === 'video' && !(S.file && S.file.path === P.party.path)) return false;
      if (kind === 'music' && !(A.cur && A.cur.path === P.party.path)) return false;
      toast(`🎉 ${P.party.host} controls playback in this party`, 1800);
      return true;
    }
    const serverNow = () => Date.now() + P.skew;
    document.body.insertAdjacentHTML('beforeend', '<aside id="smkv-party" hidden></aside><div id="smkv-pnotes"></div><div id="smkv-floats"></div>');

    // --- notices with buttons (invites, requests, reminders…)
    function partyNote(html, buttons, ms = 20000) {
      const box = document.createElement('div');
      box.className = 'smkv-pnote';
      box.innerHTML = `<div>${html}</div><div class="smkv-pnb">${buttons.map((b, i) => `<button data-i="${i}" class="${b.primary ? 'smkv-primary' : ''}">${esc(b.label)}</button>`).join('')}<button data-x title="Dismiss">✕</button></div>`;
      const close = () => box.remove();
      box.querySelectorAll('button[data-i]').forEach((el) => el.onclick = () => { close(); buttons[+el.dataset.i].fn(); });
      box.querySelector('[data-x]').onclick = close;
      $('#smkv-pnotes').appendChild(box);
      if (ms) setTimeout(close, ms);
    }

    async function enterParty(id, password) {
      try {
        let d = await api(`parties/${encodeURIComponent(id)}`);
        if (!d.msgs) { // not a member yet
          try { d = await apiPost(`parties/${encodeURIComponent(id)}/join`, password != null ? { password } : {}); }
          catch (x) {
            if (/password/.test(x.message)) {
              const pw = prompt(`🔒 “${d.title}” has a password${/wrong/.test(x.message) ? ' (that one was wrong)' : ''}:`);
              if (pw != null && pw !== '') return enterParty(id, pw);
              return;
            }
            if (/private/.test(x.message)) {
              if (confirm(`“${d.title}” is private. Ask ${d.host} to let you in?`)) { await apiPost(`parties/${encodeURIComponent(id)}/request`, {}); toast(`Asked ${d.host} — you'll get in when they say yes`, 5000); }
              return;
            }
            throw x;
          }
        }
        setParty(d);
        if (partyHost()) hostTakeOver(); else applyState(d, true);
      } catch (x) { toast(x.message, 5000); }
    }
    function setParty(d) {
      const was = P.party && P.party.id;
      if (d && d.now) P.skew = d.now - Date.now();
      P.party = d;
      if (d) lsSet('partyId', d.id); else lsSet('partyId', null);
      document.body.classList.toggle('smkv-in-party', !!d);
      if (d && !was) P.min = false;
      clearInterval(P.hostTimer); clearInterval(P.driftTimer);
      if (d && partyHost()) P.hostTimer = setInterval(() => hostPush(false), 5000);
      if (d && !partyHost()) P.driftTimer = setInterval(() => applyState(P.last || P.party, false), 4000);
      drawParty();
    }
    async function leaveParty(silent) {
      const d = P.party;
      if (!d) return;
      setParty(null);
      if (!silent) { try { await apiPost(`parties/${encodeURIComponent(d.id)}/leave`, {}); } catch (_) { /* gone */ } }
      if (location.hash.startsWith('#/party')) route();
    }

    // --- host: tell the party what's playing
    function hostState() {
      if ((P.party && P.party.kind === 'music' && A.cur) || (!S.file && A.cur)) {
        if (!A.cur) return null;
        return { kind: 'music', path: A.cur.path, name: [A.cur.title || A.cur.name, A.cur.artist].filter(Boolean).join(' · '), playing: !A.el.paused, pos: aTime() };
      }
      if (!S.file) return null;
      return { kind: 'video', path: S.file.path, name: S.file.name, playing: !media.paused, pos: cur() };
    }
    let lastPushKey = '';
    async function hostPush(force) {
      if (!partyHost()) return;
      const st = hostState();
      if (!st) return;
      const key = `${st.path}|${st.playing}`;
      if (!force && key === lastPushKey && !st.playing) return; // paused and nothing changed
      lastPushKey = key;
      try { await apiPost(`parties/${encodeURIComponent(P.party.id)}/state`, st); if (st.path !== P.party.path) { P.party.path = st.path; P.party.kind = st.kind; P.party.name = st.name; drawParty(); } }
      catch (x) { if (/ended|not found/i.test(x.message)) leaveParty(true); }
    }
    // the host opens what the party is about (or keeps what's already playing)
    function hostTakeOver() {
      const d = P.party;
      if (S.file || A.cur) { hostPush(true); return; }
      if (d.path) applyState(d, true, true);
    }
    const partyEvents = () => {
      ['play', 'pause', 'seeked'].forEach((ev) => { video.addEventListener(ev, () => { if (partyHost() && P.party.kind === 'video') hostPush(true); }); A.el.addEventListener(ev, () => { if (partyHost() && P.party.kind === 'music') hostPush(true); }); });
      video.addEventListener('loadeddata', () => { if (partyHost()) hostPush(true); });
      A.el.addEventListener('loadeddata', () => { if (partyHost() && P.party.kind === 'music') hostPush(true); });
    };
    partyEvents();

    // --- viewer: follow the host
    async function applyState(st, hard, asHost) {
      if (!P.party || !st || !st.path) return;
      if (!asHost && partyHost()) return;
      P.last = st;
      const target = Math.max(0, (st.pos || 0) + (st.playing ? Math.max(0, serverNow() - (st.at || serverNow())) / 1000 : 0));
      P.applying = true;
      try {
        if (st.kind === 'music') {
          if (S.file) closeVideo();
          if (!A.cur || A.cur.path !== st.path) {
            const lib = st.path.split('/')[0];
            let t = null;
            try { const d = await libData(lib); t = d.items.find((x) => x.path === st.path); } catch (_) { /* no access */ }
            if (!t) { toast('Can’t open the song the party is playing', 4000); return; }
            A.queue = [t]; A.idx = 0;
            loadTrack(target, st.playing);
            return;
          }
          if (Math.abs(aTime() - target) > 2.5) { if (A.transcoded) loadTrack(target, st.playing); else A.el.currentTime = target; }
          if (st.playing && A.el.paused) A.el.play().catch(() => partyNote('▶ Tap to start playing with the party', [{ label: '▶ Play', primary: true, fn: () => { P.applying = true; A.el.play().catch(() => {}); P.applying = false; } }], 0));
          if (!st.playing && !A.el.paused) A.el.pause();
        } else {
          if (!S.file || S.file.path !== st.path) {
            if (A.cur && !A.el.paused) A.el.pause();
            await playVideo(st.path, { start: target, autoplay: st.playing });
            return;
          }
          if (!S.info) return;
          if (Math.abs(cur() - target) > 2.5) seekTo(target);
          if (st.playing && media.paused) Promise.resolve(media.play()).catch(() => partyNote('▶ Tap to start playing with the party', [{ label: '▶ Play', primary: true, fn: () => { P.applying = true; Promise.resolve(media.play()).catch(() => {}); P.applying = false; } }], 0));
          if (!st.playing && !media.paused) media.pause();
        }
      } finally { setTimeout(() => { P.applying = false; }, 300); }
    }

    // --- floating emoji over the player
    function floatEmoji(e, from) {
      if (P.muted) return;
      const el = document.createElement('div');
      el.className = 'smkv-float';
      el.innerHTML = `<span>${esc(e)}</span><small>${esc(from)}</small>`;
      el.style.left = (10 + Math.random() * 70) + '%';
      $('#smkv-floats').appendChild(el);
      setTimeout(() => el.remove(), 3200);
    }

    // --- the panel
    function msgHtml(m) {
      if (m.sys) return `<div class="smkv-pm sys">${esc(m.text)}</div>`;
      return `<div class="smkv-pm${m.from === BR.me.user ? ' me' : ''}">${avatarHtml(m.from, 22)}<div><b>${esc(m.from)}</b> ${linkify(m.text)}</div></div>`;
    }
    function drawParty() {
      const el = $('#smkv-party'), d = P.party;
      el.hidden = !d;
      if (!d) { el.innerHTML = ''; return; }
      const host = partyHost();
      el.classList.toggle('min', P.min);
      document.body.classList.toggle('smkv-party-min', P.min);
      if (P.min) {
        el.innerHTML = `<button class="smkv-pmin" title="Open the party">🎉 ${esc(d.title)} · ${d.members.length}</button>`;
        el.querySelector('.smkv-pmin').onclick = () => { P.min = false; drawParty(); };
        return;
      }
      const reqs = host ? (d.requests || []) : [];
      el.innerHTML = `
        <header><div><b>🎉 ${esc(d.title)}</b><div class="smkv-dim2">${d.visibility === 'public' ? '🌐 public' : '🔒 private'}${d.locked ? ' · 🔑 password' : ''} · ${d.live ? (d.playing ? '▶ playing' : '⏸ paused') : '🗓 ' + new Date(d.scheduled * 1000).toLocaleString()}</div></div>
          <button data-a="min" title="Minimise">—</button></header>
        <div class="smkv-pnow">${d.name ? `${d.kind === 'music' ? '🎵' : '🎬'} ${esc(d.name)}` : '<span class="smkv-dim2">Nothing chosen yet</span>'}
          ${host ? '' : `<div class="smkv-dim2">👑 ${esc(d.host)} controls playback${S.file || A.cur ? '' : ' · <a href="#" data-a="sync">▶ open it</a>'}</div>`}
          ${host && !d.live ? '<button class="smkv-primary" data-a="start">🎉 Start the party now</button>' : ''}</div>
        <div class="smkv-pmembers">${d.members.map((m) => `<span class="smkv-pmem${m.online ? ' on' : ''}" title="${esc(m.name)}${m.name === d.host ? ' — host' : ''}">${avatarHtml(m.name, 26, m.online)}${m.name === d.host ? '<i>👑</i>' : ''}${host && m.name !== d.host ? `<button data-kick="${esc(m.name)}" title="Remove ${esc(m.name)}">✕</button>` : ''}</span>`).join('')}
          ${host || d.visibility === 'public' ? '<button data-a="invite" class="smkv-pinv" title="Invite people">＋</button>' : ''}</div>
        ${reqs.length ? `<div class="smkv-preqs">${reqs.map((r) => `<div>${avatarHtml(r.name, 22)} <b>${esc(r.name)}</b> wants to join <button class="smkv-primary" data-ok="${esc(r.name)}">Let in</button><button data-no="${esc(r.name)}">No</button></div>`).join('')}</div>` : ''}
        ${(d.invitedUsers || []).length ? `<div class="smkv-dim2" style="padding:0 12px 6px">Invited: ${d.invitedUsers.map(esc).join(', ')}</div>` : ''}
        <div class="smkv-pmsgs">${P.muted ? '<div class="smkv-pm sys">🔕 Chat muted for you — the party goes on</div>' : (d.msgs || []).map(msgHtml).join('')}</div>
        <div class="smkv-preact">${REACTS.map((e) => `<button data-r="${e}">${e}</button>`).join('')}</div>
        <form class="smkv-psend"><input placeholder="${d.chatOn || host ? 'Say something…' : '🤫 The host turned chat off'}" maxlength="1000" ${d.chatOn || host ? '' : 'disabled'}><button class="smkv-primary" ${d.chatOn || host ? '' : 'disabled'}>➤</button></form>
        <footer>
          <button data-a="mute" title="Hide chat and emoji for yourself">${P.muted ? '🔔 Show chat' : '🔕 Mute chat'}</button>
          ${host ? `<button data-a="settings">⚙ Party</button>` : ''}
          <button data-a="leave">${host ? 'Leave' : '🚪 Leave'}</button>
          ${host ? '<button data-a="end" class="smkv-danger">End</button>' : ''}
        </footer>`;
      const msgs = el.querySelector('.smkv-pmsgs'); msgs.scrollTop = msgs.scrollHeight;
      const id = encodeURIComponent(d.id);
      const act = async (a, body) => { try { const r = await apiPost(`parties/${id}/${a}`, body || {}); if (r && r.msgs) setParty(r); } catch (x) { toast(x.message, 4000); } };
      el.querySelectorAll('[data-a]').forEach((b) => b.onclick = async (e) => {
        e.preventDefault();
        const a = b.dataset.a;
        if (a === 'min') { P.min = true; drawParty(); }
        if (a === 'sync') applyState(P.last || d, true);
        if (a === 'start') { await act('start'); hostTakeOver(); }
        if (a === 'mute') { P.muted = !P.muted; lsSet('partyMute', P.muted); drawParty(); }
        if (a === 'leave') leaveParty();
        if (a === 'end') { if (confirm('End the party for everyone?')) { try { await apiSend('DELETE', `parties/${id}`); } catch (_) { /* gone */ } setParty(null); } }
        if (a === 'invite') invitePeople(d, (users) => act('invite', { users }));
        if (a === 'settings') partySettings(d);
      });
      el.querySelectorAll('[data-kick]').forEach((b) => b.onclick = () => { if (confirm(`Remove ${b.dataset.kick} from the party?`)) act('kick', { user: b.dataset.kick }); });
      el.querySelectorAll('[data-ok]').forEach((b) => b.onclick = () => act('answer', { user: b.dataset.ok, accept: true }));
      el.querySelectorAll('[data-no]').forEach((b) => b.onclick = () => act('answer', { user: b.dataset.no, accept: false }));
      el.querySelectorAll('[data-r]').forEach((b) => b.onclick = () => { floatEmoji(b.dataset.r, BR.me.user); apiPost(`parties/${id}/react`, { emoji: b.dataset.r }).catch((x) => toast(x.message, 3000)); });
      const f = el.querySelector('.smkv-psend');
      f.onsubmit = async (e) => {
        e.preventDefault();
        const inp = f.querySelector('input'), text = inp.value.trim();
        if (!text) return;
        inp.value = '';
        try { await apiPost(`parties/${id}/msg`, { text }); } catch (x) { toast(x.message, 4000); inp.value = text; }
      };
    }
    function invitePeople(d, send) {
      const others = SO.people.filter((p) => p.name !== BR.me.user && !d.members.some((m) => m.name === p.name));
      if (!others.length) return toast('Everyone is already here', 2500);
      detailModal(`<h2>Invite to “${esc(d.title)}”</h2><div class="smkv-share">${others.map((p) => `<label class="smkv-check"><input type="checkbox" value="${esc(p.name)}"> <span class="smkv-dot ${p.online ? 'on' : ''}"></span> ${esc(p.name)}</label>`).join('')}</div>
        <div style="display:flex;justify-content:flex-end;margin-top:12px"><button class="smkv-primary" id="smkv-pinvok">Invite</button></div>`, (root, close) => {
        root.querySelector('#smkv-pinvok').onclick = () => { const u = [...root.querySelectorAll('input:checked')].map((i) => i.value); close(); if (u.length) { send(u); toast(`Invited ${u.join(', ')}`); } };
      });
    }
    function partySettings(d) {
      detailModal(`<h2>⚙ Party settings</h2>
        <form id="smkv-psf" class="smkv-pform">
          <label>Title <input class="smkv-inp" name="title" value="${esc(d.title)}" maxlength="120"></label>
          <label>Who can find it <select class="smkv-inp" name="visibility"><option value="private">🔒 Private — invited people only</option><option value="public" ${d.visibility === 'public' ? 'selected' : ''}>🌐 Public — everyone sees it in Party</option></select></label>
          <label>Password <input class="smkv-inp" name="password" type="password" placeholder="${d.locked ? '•••••• (leave as is) — type to change' : 'none'}" autocomplete="new-password"></label>
          ${d.locked ? '<label class="smkv-check"><input type="checkbox" name="nopw"> Remove the password</label>' : ''}
          <label class="smkv-check"><input type="checkbox" name="chatOn" ${d.chatOn ? 'checked' : ''}> Chat and emoji on (off: only you can write)</label>
          <label>Hand over to <select class="smkv-inp" name="host"><option value="">— keep hosting —</option>${d.members.filter((m) => m.name !== d.host).map((m) => `<option>${esc(m.name)}</option>`).join('')}</select></label>
          <div style="display:flex;justify-content:flex-end"><button class="smkv-primary">Save</button></div>
        </form>`, (root, close) => {
        const f = root.querySelector('#smkv-psf');
        f.onsubmit = async (e) => {
          e.preventDefault();
          const body = { title: f.title.value, visibility: f.visibility.value, chatOn: f.chatOn.checked };
          if (f.password.value) body.password = f.password.value;
          if (f.nopw && f.nopw.checked) body.password = '';
          if (f.host.value) body.host = f.host.value;
          try { const r = await apiPost(`parties/${encodeURIComponent(d.id)}/settings`, body); close(); if (r.msgs) setParty(r); toast('Saved'); } catch (x) { toast(x.message, 4000); }
        };
      });
    }

    // --- new party (now or scheduled) from anything in the libraries
    async function allPlayable() {
      const libs = BR.libs.filter((l) => l.id !== '_legacy');
      const out = [];
      await Promise.all(libs.map(async (l) => {
        try {
          const d = await libData(l.id);
          for (const it of d.items) out.push({ path: it.path, kind: l.type === 'music' ? 'music' : 'video', label: l.type === 'music' ? [it.title || it.name, it.artist].filter(Boolean).join(' · ') : itemLabel(it, d), lib: l.name });
        } catch (_) { /* skip */ }
      }));
      return out;
    }
    async function newPartyDialog(pre = {}) {
      const nowItem = pre.path ? pre : S.file ? { path: S.file.path, kind: 'video', label: S.file.name } : A.cur ? { path: A.cur.path, kind: 'music', label: [A.cur.title || A.cur.name, A.cur.artist].filter(Boolean).join(' · ') } : null;
      let pick = nowItem;
      const dt = new Date(Date.now() + 3600e3); dt.setMinutes(0, 0, 0);
      const local = new Date(dt.getTime() - dt.getTimezoneOffset() * 60e3).toISOString().slice(0, 16);
      detailModal(`<h2>🎉 New party</h2>
        <form id="smkv-npf" class="smkv-pform">
          <label>Title <input class="smkv-inp" name="title" placeholder="${esc(BR.me.user)}'s party" maxlength="120"></label>
          <label>What to watch / listen <input class="smkv-inp" name="q" placeholder="Search movies, episodes, songs…" autocomplete="off"></label>
          <div id="smkv-npick" class="smkv-dim2">${pick ? `Chosen: <b>${esc(pick.label)}</b>` : 'Nothing chosen yet (you can pick later by playing something)'}</div>
          <div id="smkv-nres" class="smkv-nres"></div>
          <label>When <select class="smkv-inp" name="when"><option value="now">Now</option><option value="later">Later…</option></select></label>
          <input class="smkv-inp" type="datetime-local" name="at" value="${local}" hidden>
          <label>Note <input class="smkv-inp" name="note" placeholder="e.g. bring snacks 🍿" maxlength="500"></label>
          <label>Who can find it <select class="smkv-inp" name="visibility"><option value="private">🔒 Private — invited people only</option><option value="public">🌐 Public — everyone sees it</option></select></label>
          <label>Password (optional) <input class="smkv-inp" name="password" type="password" autocomplete="new-password"></label>
          <div><div class="smkv-dim2" style="margin-bottom:4px">Invite</div><div class="smkv-share">${SO.people.filter((p) => p.name !== BR.me.user).map((p) => `<label class="smkv-check"><input type="checkbox" name="inv" value="${esc(p.name)}"> <span class="smkv-dot ${p.online ? 'on' : ''}"></span> ${esc(p.name)}</label>`).join('')}</div></div>
          <div style="display:flex;justify-content:flex-end"><button class="smkv-primary">🎉 Create</button></div>
        </form>`, async (root, close) => {
        const f = root.querySelector('#smkv-npf');
        f.when.onchange = () => { f.at.hidden = f.when.value !== 'later'; };
        let all = null;
        f.q.oninput = async () => {
          const q = f.q.value.trim().toLowerCase();
          const box = root.querySelector('#smkv-nres');
          if (q.length < 2) { box.innerHTML = ''; return; }
          all = all || await allPlayable();
          const words = q.split(/\s+/);
          const hits = all.filter((x) => words.every((w) => (x.label + ' ' + x.path).toLowerCase().includes(w))).slice(0, 30);
          box.innerHTML = hits.length ? hits.map((x, i) => `<div data-i="${i}">${x.kind === 'music' ? '🎵' : '🎬'} ${esc(x.label)} <span class="smkv-dim2">${esc(x.lib)}</span></div>`).join('') : '<div class="smkv-dim2">Nothing found</div>';
          box.querySelectorAll('[data-i]').forEach((el) => el.onclick = () => { pick = hits[+el.dataset.i]; root.querySelector('#smkv-npick').innerHTML = `Chosen: <b>${esc(pick.label)}</b>`; box.innerHTML = ''; f.q.value = ''; });
        };
        f.onsubmit = async (e) => {
          e.preventDefault();
          const later = f.when.value === 'later';
          const body = { title: f.title.value.trim(), visibility: f.visibility.value, password: f.password.value, note: f.note.value,
            invite: [...f.querySelectorAll('input[name=inv]:checked')].map((i) => i.value) };
          if (pick) Object.assign(body, { path: pick.path, kind: pick.kind, name: pick.label });
          if (later) {
            const t = new Date(f.at.value).getTime();
            if (!(t > Date.now() + 60e3)) return toast('Pick a time in the future', 3000);
            body.scheduled = Math.floor(t / 1000);
          } else if (pick && ((S.file && S.file.path === pick.path) || (A.cur && A.cur.path === pick.path))) {
            const st = hostState(); if (st) { body.pos = st.pos; body.playing = st.playing; }
          }
          try {
            const d = await apiPost('parties', body);
            close();
            if (later) { toast(`🗓 Scheduled for ${new Date(body.scheduled * 1000).toLocaleString()}`, 5000); if (location.hash.startsWith('#/party')) route(); return; }
            setParty(d);
            if (pick && !((S.file && S.file.path === pick.path) || (A.cur && A.cur.path === pick.path))) applyState({ path: pick.path, kind: pick.kind, pos: 0, playing: false, at: serverNow() }, true, true);
            else hostPush(true);
            toast('🎉 Party started — invite people with ＋', 5000);
          } catch (x) { toast(x.message, 5000); }
        };
      });
    }

    // --- the Party page
    async function partyView() {
      setToolbar('<button id="smkv-pnew" class="smkv-primary">🎉 New party</button>', null);
      toolbar.querySelector('#smkv-q').style.display = 'none'; $('#smkv-rawbtn').hidden = true;
      $('#smkv-pnew').onclick = () => newPartyDialog();
      const r = await api('parties');
      if (r.now) P.skew = r.now - Date.now();
      const live = r.parties.filter((x) => x.live), soon = r.parties.filter((x) => !x.live);
      const card = (x) => {
        const mine = x.member, when = x.live ? '' : `🗓 ${new Date(x.scheduled * 1000).toLocaleString()}`;
        const btn = mine ? (P.party && P.party.id === x.id ? '<span class="smkv-dim2">You’re here</span>' : `<button class="smkv-primary" data-go="${esc(x.id)}">${x.live ? 'Open' : 'Open'}</button>`)
          : x.kicked ? '<span class="smkv-dim2">Removed by the host</span>'
          : x.invited || x.visibility === 'public' ? `<button class="smkv-primary" data-go="${esc(x.id)}">${x.locked && !x.invited ? '🔑 ' : ''}${x.live ? 'Join' : 'I’m in'}</button>`
          : x.requested ? '<span class="smkv-dim2">Asked to join…</span>' : `<button data-req="${esc(x.id)}">Ask to join</button>`;
        return `<div class="smkv-pcard">
          <div class="smkv-pcl">${avatarHtml(x.host, 34)}<div><b>${esc(x.title)}</b>${x.invited ? ' <span class="smkv-tag">invited</span>' : ''}
            <div class="smkv-dim2">👑 ${esc(x.host)} · ${x.visibility === 'public' ? '🌐 public' : '🔒 private'}${x.locked ? ' · 🔑' : ''} · ${x.members.length} in${when ? ' · ' + when : ''}</div>
            ${x.name ? `<div>${x.kind === 'music' ? '🎵' : '🎬'} ${esc(x.name)}${x.live ? (x.playing ? ' · ▶' : ' · ⏸') : ''}</div>` : ''}
            ${x.note ? `<div class="smkv-dim2">“${esc(x.note)}”</div>` : ''}
            <div class="smkv-pav">${x.members.slice(0, 12).map((m) => avatarHtml(m.name, 20, m.online)).join('')}</div></div></div>
          <div class="smkv-pcb">${btn}</div></div>`;
      };
      view.innerHTML = `<h2 class="smkv-pageh">🎉 Party</h2>
        <div class="smkv-dim2" style="margin:-6px 0 14px">Watch or listen together: the host plays, everyone follows, with chat and emoji. Friends who are watching something have a 🎉 next to their name — ask to join them.</div>
        <h3 class="smkv-h">Live now</h3>${live.length ? live.map(card).join('') : '<div class="smkv-dim2">No party right now — start one!</div>'}
        <h3 class="smkv-h">Coming up</h3>${soon.length ? soon.map(card).join('') : '<div class="smkv-dim2">Nothing scheduled.</div>'}`;
      view.querySelectorAll('[data-go]').forEach((b) => b.onclick = () => enterParty(b.dataset.go).then(() => route()));
      view.querySelectorAll('[data-req]').forEach((b) => b.onclick = async () => { try { await apiPost(`parties/${encodeURIComponent(b.dataset.req)}/request`, {}); toast('Asked — the host will let you in', 4000); route(); } catch (x) { toast(x.message, 4000); } });
    }

    // --- "can I watch with you?" (from the People list)
    async function askToJoin(user) {
      try {
        const r = await apiPost('parties/ask', { user });
        if (r.party) { setParty(r.party); applyState(r.party, true); return; }
        toast(r.requested ? `Asked ${user}'s party — waiting for a yes` : `🎉 Asked ${user} — waiting for a yes`, 5000);
      } catch (x) { toast(x.message, 5000); }
    }

    // --- live events
    function partySocial(es) {
      es.addEventListener('party', (e) => {
        const d = JSON.parse(e.data).party;
        if (!P.party || d.id !== P.party.id) return;
        const wasHost = partyHost();
        setParty(d);
        if (!wasHost && partyHost()) { toast('👑 You are the host now', 4000); hostPush(true); }
      });
      es.addEventListener('party-state', (e) => {
        const st = JSON.parse(e.data);
        if (!P.party || st.id !== P.party.id) return;
        if (st.now) P.skew = st.now - Date.now();
        Object.assign(P.party, { path: st.path, kind: st.kind, name: st.name, playing: st.playing, pos: st.pos, at: st.at });
        applyState(st, true);
        drawParty();
      });
      es.addEventListener('party-msg', (e) => {
        const v = JSON.parse(e.data);
        if (!P.party || v.id !== P.party.id) return;
        if (!(P.party.msgs || []).some((m) => m.seq === v.msg.seq)) (P.party.msgs = P.party.msgs || []).push(v.msg);
        if (P.muted) return;
        const box = $('#smkv-party .smkv-pmsgs');
        if (box) { box.insertAdjacentHTML('beforeend', msgHtml(v.msg)); box.scrollTop = box.scrollHeight; }
        if (P.min && !v.msg.sys && v.msg.from !== BR.me.user) toast(`🎉 ${v.msg.from}: ${v.msg.text}`, 3000);
      });
      es.addEventListener('party-react', (e) => {
        const v = JSON.parse(e.data);
        if (P.party && v.id === P.party.id && v.from !== BR.me.user) floatEmoji(v.emoji, v.from);
      });
      es.addEventListener('parties', () => { if (location.hash.startsWith('#/party')) route(); });
      es.addEventListener('party-notice', (e) => {
        const n = JSON.parse(e.data), x = n.party || {}, t = esc(x.title || '');
        switch (n.kind) {
          case 'invite': partyNote(`🎉 <b>${esc(n.from)}</b> invited you to <b>${t}</b>${x.live ? '' : ` · 🗓 ${new Date(x.scheduled * 1000).toLocaleString()}`}`, [{ label: x.live ? 'Join' : 'Open Party', primary: true, fn: () => (x.live ? enterParty(x.id) : (location.hash = '#/party')) }]); break;
          case 'request': partyNote(`🙋 <b>${esc(n.from)}</b> wants to join <b>${t}</b>`, [{ label: 'Let in', primary: true, fn: () => apiPost(`parties/${encodeURIComponent(x.id)}/answer`, { user: n.from, accept: true }).catch((y) => toast(y.message)) }, { label: 'No', fn: () => apiPost(`parties/${encodeURIComponent(x.id)}/answer`, { user: n.from, accept: false }).catch(() => {}) }], 60000); break;
          case 'accepted': toast(`🎉 ${n.from} let you in — joining`, 4000); enterParty(x.id); break;
          case 'declined': toast(`${n.from} said no this time`, 4000); break;
          case 'ask-declined': toast(`${n.from} wants to watch alone right now`, 4000); break;
          case 'kicked': if (P.party && P.party.id === x.id) setParty(null); toast(`🚫 ${n.from} removed you from the party`, 5000); break;
          case 'ended': if (P.party && P.party.id === x.id) { setParty(null); toast('🎉 The party has ended', 4000); } break;
          case 'reminder': if (!(P.party && P.party.id === x.id)) partyNote(`⏰ <b>${t}</b> is starting${x.name ? ` — ${esc(x.name)}` : ''}`, [{ label: 'Join', primary: true, fn: () => enterParty(x.id) }], 0); break;
          case 'ask': {
            const a = n.activity || {};
            partyNote(`🎉 <b>${esc(n.from)}</b> wants to ${a.kind === 'music' ? 'listen' : 'watch'} with you${a.title ? ` — ${esc(a.title)}` : ''}`, [
              { label: 'Let them join', primary: true, fn: async () => { const st = hostState() || {}; try { const d = await apiPost('parties/ask/answer', { user: n.from, accept: true, pos: st.pos || 0, playing: !!st.playing }); setParty(d); hostPush(true); } catch (y) { toast(y.message, 4000); } } },
              { label: 'No', fn: () => apiPost('parties/ask/answer', { user: n.from, accept: false }).catch(() => {}) }], 60000);
            break;
          }
        }
      });
    }
    // back in after a page refresh
    $('#smkv-vparty').onclick = () => (P.party ? (P.min = false, drawParty()) : newPartyDialog());
    $('#smkv-aparty').onclick = () => (P.party ? (P.min = false, drawParty()) : newPartyDialog());
    // ------------------------------------------------------------ horizontal rows: arrows + fades instead of a scrollbar
    function enhanceRow(row) {
      if (row.dataset.rw || !row.parentNode || !(row.classList.contains('smkv-cast') || row.querySelector('.smkv-card'))) return;
      row.dataset.rw = '1';
      const wrap = document.createElement('div'); wrap.className = 'smkv-rowwrap';
      row.parentNode.insertBefore(wrap, row); wrap.appendChild(row);
      const mk = (cls, txt, dir) => {
        const b = document.createElement('button'); b.type = 'button'; b.className = 'smkv-rowbtn ' + cls;
        b.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="${dir < 0 ? 'M15 5l-7 7 7 7' : 'M9 5l7 7-7 7'}"/></svg>`;
        b.setAttribute('aria-label', dir < 0 ? 'Scroll left' : 'Scroll right');
        b.onclick = (e) => { e.stopPropagation(); row.scrollBy({ left: dir * Math.max(200, row.clientWidth * 0.85), behavior: 'smooth' }); };
        wrap.appendChild(b); return b;
      };
      const l = mk('l', '‹', -1), r = mk('r', '›', 1);
      const bar = document.createElement('div'); bar.className = 'smkv-rowbar'; bar.appendChild(document.createElement('i')); wrap.appendChild(bar);
      const upd = () => {
        const max = row.scrollWidth - row.clientWidth, x = row.scrollLeft;
        const start = x > 4, more = x < max - 4;
        l.classList.toggle('on', start); r.classList.toggle('on', more);
        wrap.classList.toggle('fade-l', start); wrap.classList.toggle('fade-r', more);
        bar.classList.toggle('on', max > 4);
        if (max > 4) { const w = row.clientWidth / row.scrollWidth; bar.firstChild.style.width = (w * 100) + '%'; bar.firstChild.style.left = (x / row.scrollWidth * 100) + '%'; }
        // arrows sit in the middle of the pictures, not of the captions
        const img = row.querySelector('.smkv-poster,.smkv-face');
        if (img) wrap.style.setProperty('--rb-top', (img.offsetTop - row.offsetTop + img.offsetHeight / 2) + 'px');
      };
      row.addEventListener('scroll', upd, { passive: true });
      // the bar: drag the thumb, or click / drag anywhere on it; the wheel over it scrolls sideways
      const barTo = (clientX, grabOff) => {
        const r0 = bar.getBoundingClientRect(), tw = bar.firstChild.offsetWidth;
        const f = (clientX - r0.left - grabOff) / Math.max(1, r0.width - tw);
        row.style.scrollBehavior = 'auto';
        row.scrollLeft = Math.max(0, Math.min(1, f)) * (row.scrollWidth - row.clientWidth);
        row.style.scrollBehavior = '';
      };
      bar.addEventListener('pointerdown', (e) => {
        if (e.button !== 0) return;
        e.preventDefault(); e.stopPropagation();
        const th = bar.firstChild.getBoundingClientRect();
        const off = e.clientX >= th.left && e.clientX <= th.right ? e.clientX - th.left : th.width / 2;
        bar.classList.add('drag'); bar.setPointerCapture(e.pointerId);
        barTo(e.clientX, off);
        const mv = (ev) => barTo(ev.clientX, off);
        const up = () => { bar.classList.remove('drag'); bar.removeEventListener('pointermove', mv); bar.removeEventListener('pointerup', up); bar.removeEventListener('pointercancel', up); };
        bar.addEventListener('pointermove', mv); bar.addEventListener('pointerup', up); bar.addEventListener('pointercancel', up);
      });
      bar.addEventListener('wheel', (e) => { const d = Math.abs(e.deltaX) > Math.abs(e.deltaY) ? e.deltaX : e.deltaY; if (!d) return; e.preventDefault(); row.scrollBy({ left: d * 2 }); }, { passive: false });
      // mouse: click-and-drag the row itself (a drag doesn't open the card)
      let drag = null;
      row.addEventListener('pointerdown', (e) => {
        if (e.pointerType !== 'mouse' || e.button !== 0) return;
        drag = { x: e.clientX, left: row.scrollLeft, id: e.pointerId, moved: false };
      });
      row.addEventListener('pointermove', (e) => {
        if (!drag || e.pointerId !== drag.id) return;
        const dx = e.clientX - drag.x;
        if (!drag.moved && Math.abs(dx) < 6) return;
        if (!drag.moved) { drag.moved = true; row.classList.add('grab'); try { row.setPointerCapture(e.pointerId); } catch (_) { /* fine */ } }
        row.scrollLeft = drag.left - dx;
      });
      const endDrag = () => {
        if (!drag) return;
        const moved = drag.moved; drag = null;
        row.classList.remove('grab');
        if (moved) { const stop = (ev) => { ev.stopPropagation(); ev.preventDefault(); }; row.addEventListener('click', stop, { capture: true, once: true }); setTimeout(() => row.removeEventListener('click', stop, { capture: true }), 50); }
      };
      row.addEventListener('pointerup', endDrag); row.addEventListener('pointercancel', endDrag);
      row.addEventListener('dragstart', (e) => e.preventDefault());
      if (window.ResizeObserver) new ResizeObserver(upd).observe(row);
      requestAnimationFrame(upd); setTimeout(upd, 600);
    }
    function enhanceRows(root) { (root.querySelectorAll ? root : document).querySelectorAll('.smkv-row,.smkv-cast').forEach(enhanceRow); }
    new MutationObserver((ms) => {
      for (const m of ms) for (const n of m.addedNodes) {
        if (n.nodeType !== 1) continue;
        if (n.matches('.smkv-row,.smkv-cast')) enhanceRow(n); else if (n.querySelector('.smkv-row,.smkv-cast')) enhanceRows(n);
      }
    }).observe(document.body, { childList: true, subtree: true });
    enhanceRows(document);

    // ------------------------------------------------------------ remote control
    // This page is a device your phone (the Delos app) can drive: open, play/pause, seek, volume…
    const RM = { id: lsGet('deviceId', null), timer: 0, last: 0 };
    if (!RM.id) { RM.id = 'w' + Math.random().toString(36).slice(2, 12); lsSet('deviceId', RM.id); }
    function deviceName() {
      const ua = navigator.userAgent;
      const b = /Edg\//.test(ua) ? 'Edge' : /Firefox\//.test(ua) ? 'Firefox' : /Chrome\//.test(ua) ? 'Chrome' : /Safari\//.test(ua) ? 'Safari' : 'Browser';
      const os = /Web0S|webOS/i.test(ua) ? 'LG TV' : /Tizen/i.test(ua) ? 'Samsung TV' : /Android/.test(ua) ? 'Android' : /iPhone|iPad/.test(ua) ? 'iOS' : /Windows/.test(ua) ? 'Windows' : /Mac OS X/.test(ua) ? 'Mac' : /Linux/.test(ua) ? 'Linux' : '';
      return lsGet('deviceName', '') || `${b}${os ? ' on ' + os : ''}`;
    }
    function remoteState() {
      let a = myActivity();
      if (!a && A.cur) a = { kind: 'music', path: A.cur.path, title: A.cur.title || A.cur.name, sub: [A.cur.artist, A.cur.album].filter(Boolean).join(' — '),
        image: A.cur.cover ? 'cover:' + A.cur.cover : '', pos: Math.round(aTime()), dur: Math.round(A.cur.duration || 0) };
      if (!a) return { idle: true };
      if (S.file && S.info) {
        const n = BR.ctx && BR.ctx.next;
        Object.assign(a, {
          audios: [...selAudio.options].map((o) => o.textContent), audioSel: S.audio || 0,
          subs: [...selSub.options].filter((o) => o.value !== '').map((o) => o.textContent), subSel: S.sub ? S.sub.idx : -1,
          subDelay: Math.round(S.subDelay * 10) / 10, fs: !!document.fullscreenElement,
          next: n ? `S${n.season}E${n.episode}${n.episodeTitle ? ' · ' + n.episodeTitle : ''}` : null,
        });
      } else if (A.cur) a.queue = A.queue.length > 1;
      return Object.assign({}, a, { playing: S.file ? !media.paused : !A.el.paused, volume: Math.round(((S.file ? video.volume : A.el.volume) || 0) * 100) });
    }
    function remoteHello(withState) {
      const body = { id: RM.id, name: deviceName(), platform: navigator.platform || '', kind: 'web' };
      if (withState) body.state = remoteState();
      apiPost('remote/hello', body).catch(() => {});
    }
    // state goes out at most once a second, and on every play / pause / seek / new file
    function remoteChanged() {
      const now = Date.now();
      clearTimeout(RM.timer);
      if (now - RM.last > 1000) { RM.last = now; remoteHello(true); } else RM.timer = setTimeout(() => remoteChanged(), 1000 - (now - RM.last));
    }
    document.addEventListener('fullscreenchange', () => remoteChanged());
    ['play', 'pause', 'seeked', 'loadeddata', 'volumechange'].forEach((ev) => { video.addEventListener(ev, remoteChanged); A.el.addEventListener(ev, remoteChanged); });
    setInterval(() => remoteHello(true), 30000);
    window.addEventListener('pagehide', () => { try { navigator.sendBeacon && navigator.sendBeacon(new URL('api/remote/bye', BASE), new Blob([JSON.stringify({ id: RM.id })], { type: 'application/json' })); } catch (_) { /* gone */ } });
    async function remoteCmd(c) {
      const vid = !!S.file;
      switch (c.cmd) {
        case 'open': {
          const lib = String(c.path || '').split('/')[0];
          if (libType(lib) === 'music') {
            const d = await libData(lib), t = d.items.find((x) => x.path === c.path);
            if (!t) return toast('Remote: song not found', 3000);
            if (S.file) closeVideo();
            A.queue = [t]; A.idx = 0; loadTrack(+c.pos || 0, true);
          } else {
            if (A.cur && !A.el.paused) A.el.pause();
            await playVideo(c.path, c.pos != null ? { start: +c.pos } : {});
          }
          toast(`📱 ${c.from || 'Remote'}: playing here`, 2500);
          break;
        }
        case 'toggle': vid ? togglePlay() : aToggle(); break;
        case 'play': if (vid ? media.paused : A.el.paused) (vid ? togglePlay() : aToggle()); break;
        case 'pause': if (!(vid ? media.paused : A.el.paused)) (vid ? togglePlay() : aToggle()); break;
        case 'seek': vid ? seekTo(+c.pos || 0) : aSeek(+c.pos || 0); break;
        case 'seekBy': vid ? seekBy(+c.by || 0) : aSeek(aTime() + (+c.by || 0)); break;
        case 'stop': if (vid) closeVideo(); else if (A.cur) A.el.pause(); break;
        case 'next': if (!vid) aNext(true); break;
        case 'previous': if (!vid) aPrev(); break;
        case 'volume': { const v = Math.max(0, Math.min(100, +c.volume || 0)) / 100; if (vid) setVolume(v); else { A.el.volume = v; $('#smkv-avol').value = String(v); } break; }
        case 'fullscreen': try { if (document.fullscreenElement) await document.exitFullscreen(); else await (vid ? player : document.documentElement).requestFullscreen(); } catch (_) { toast('Full screen needs one click on this screen first (browser rule)', 4000); } break;
        case 'audio': if (vid && S.info && +c.index >= 0 && +c.index < selAudio.options.length) { selAudio.value = String(+c.index); selAudio.onchange(); toast('Audio: ' + selAudio.selectedOptions[0].textContent, 2000); } break;
        case 'subs': if (vid && S.info) { const v = +c.index >= 0 && S.info.subs[+c.index] ? String(+c.index) : ''; selSub.value = v; await setSub(v); toast(v === '' ? 'Subtitles off' : 'Subtitles: ' + selSub.selectedOptions[0].textContent, 2000); } break;
        case 'subDelay': if (vid) { S.subDelay = c.by == null ? 0 : S.subDelay + (+c.by || 0); updateSubDelay(); toast(`Subtitle delay ${(S.subDelay > 0 ? '+' : '') + S.subDelay.toFixed(1)}s`, 1500); } break;
        case 'nextEp': if (vid && BR.ctx && BR.ctx.next) await playVideo(BR.ctx.next.path); break;
        case 'home': if (vid) closeVideo(); location.hash = '#/'; break;
      }
      remoteChanged();
    }

    async function partyResume() {
      const id = lsGet('partyId', null);
      if (!id) return;
      try { const d = await api(`parties/${encodeURIComponent(id)}`); if (d.msgs) { setParty(d); if (partyHost()) toast('🎉 You’re hosting — press play to carry on', 5000); else applyState(d, true); } else lsSet('partyId', null); }
      catch (_) { lsSet('partyId', null); }
    }

    // ------------------------------------------------------------ start
    document.body.classList.toggle('smkv-raw-on', !!lsGet('rawNames', false));
    (async () => {
      await ensureLogin();
      try {
        BR.me = await api('me');
        $('#smkv-admin').hidden = !BR.me.admin;
        rqCount();
        $('#smkv-side header b').title = `Signed in as ${BR.me.user} · server ${BR.me.version || '?'}`;
        const ver = $('#smkv-ver'), v = BR.me.version || '';
        ver.textContent = v ? (/^\d/.test(v) ? 'v' + v : v) : '';
        ver.title = `Delos ${v} · signed in as ${BR.me.user}`;
        drawSecBar();
        drawWhoami();
      } catch { /* old server */ }
      await loadLibs();
      route();
      aRestore();
      startSocial();
      partyResume();
    })();
  }

  // ================================================================= markup
  const HTML = `
<div id="smkv-app">
  <aside id="smkv-side">
    <header>
      <b title="Delos — Artemis for films, Apollo for music">Delos</b><small id="smkv-ver"></small><span class="smkv-sp"></span>
      <a id="smkv-admin" class="smkv-hb" href="admin" target="_blank" title="Admin dashboard" hidden><svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l7 3v5c0 4.6-3 8.4-7 10-4-1.6-7-5.4-7-10V6z"/><path d="M9 12l2 2 4-4"/></svg></a>
      <button id="smkv-refresh" class="smkv-hb" title="Reload libraries" hidden><svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M20 12a8 8 0 1 1-2.34-5.66"/><path d="M20 4v5h-5"/></svg></button>
      <button id="smkv-ann" class="smkv-hb" title="Announcements"><svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 10v4a1 1 0 0 0 1 1h2l6 4V5L7 9H5a1 1 0 0 0-1 1z"/><path d="M17 9.5a3.5 3.5 0 0 1 0 5"/><path d="M19.5 7a7 7 0 0 1 0 10"/></svg><i hidden></i></button>
      <button id="smkv-settings" class="smkv-hb" title="Settings · reload libraries · log out"><svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h9M17 7h3M4 17h3M11 17h9"/><circle cx="15" cy="7" r="2"/><circle cx="9" cy="17" r="2"/></svg></button>
      <button id="smkv-logout" class="smkv-hb" title="Log out" hidden><svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M14 4h4a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-4"/><path d="M10 16l-4-4 4-4"/><path d="M6 12h10"/></svg></button>
    </header>
    <div id="smkv-whoami" hidden></div>
    <nav id="smkv-nav"></nav>
    <div id="smkv-people"></div>
    <div id="smkv-mini" hidden title="Music is playing — open the music player"><span class="smkv-mini-i">🎵</span><div><b></b><span></span></div><button title="Play/Pause">❚❚</button></div>
    <footer id="smkv-sidefoot"><button id="smkv-fold" title="Fold the sidebar (Ctrl+B)"><svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16"/><path class="smkv-fold-ar" d="M15.5 10l-2 2 2 2"/></svg><span>Fold sidebar</span><kbd>Ctrl B</kbd></button></footer>
  </aside>
  <section id="smkv-chat"></section>
  <main id="smkv-browse">
    <div id="smkv-secbar" hidden></div>
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
      <div id="smkv-tp" hidden><div class="img"></div><span></span></div>
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
    <div class="smkv-titlerow"><button id="smkv-close" title="Back to library (Esc)">← Back</button><h2 id="smkv-title"></h2><a id="smkv-vdl" class="smkv-dlbtn" title="Save this file to this computer" download hidden>⬇ Save</a><button id="smkv-vparty" class="smkv-dlbtn" title="Watch this together: start a party">🎉 Watch together</button></div>
    <div id="smkv-meta"></div>
    <div class="smkv-opts">
      <label>Audio <select id="smkv-audio"><option>—</option></select></label>
      <label>Subtitles <select id="smkv-sub"><option value="">Off</option></select></label>
      <label>Sub delay <span class="smkv-group"><button id="smkv-sd-minus" title="z">−</button><span id="smkv-sd">0.0s</span><button id="smkv-sd-plus" title="x">+</button></span></label>
      <label>Sub size <span class="smkv-group"><button id="smkv-ss-minus" title="Smaller subtitles">−</button><span id="smkv-ss" title="Double-click to reset">100%</span><button id="smkv-ss-plus" title="Bigger subtitles">+</button></span></label>
      <label>Sub position <span class="smkv-group"><button id="smkv-sp-down" title="Move subtitles down">↓</button><span id="smkv-sp" title="Double-click to reset">0</span><button id="smkv-sp-up" title="Move subtitles up">↑</button></span></label>
      <label>Video <select id="smkv-vmode">
        <option value="auto">Auto</option><option value="browser">In browser (original file)</option><option value="copy">Server remux</option><option value="transcode">Server transcode H.264</option>
      </select></label>
      <label>Max height <select id="smkv-maxh">
        <option value="2160">2160p</option><option value="1440">1440p</option><option value="1080">1080p</option>
        <option value="720">720p</option><option value="480">480p</option>
      </select></label>
    </div>
    <div class="smkv-keys">Keys: space play · ←/→ ±10s · j/l ±30s · a audio · c subs · z/x sub delay · [/] sub size · {/} sub position · f fullscreen · m mute · Esc back</div>
  </section>
</div>
<div id="smkv-abar">
  <div id="smkv-acover">♪</div>
  <div class="smkv-ainfo"><b id="smkv-atitle"></b><span id="smkv-aartist"></span></div>
  <div class="smkv-actl">
    <div class="smkv-abtns"><button id="smkv-aprev" title="Previous">⏮</button><button id="smkv-app-pp" class="big" title="Play/Pause (space)">▶</button><button id="smkv-anext" title="Next">⏭</button><button id="smkv-arep">🔁</button></div>
    <div class="smkv-aseekrow"><input id="smkv-aseek" type="range" min="0" max="0" step="0.1" value="0"><span id="smkv-atime">0:00 / 0:00</span></div>
  </div>
  <div class="smkv-aright"><button id="smkv-aparty" title="Listen together: start a party">🎉</button><a id="smkv-adl" class="smkv-dlbtn" title="Save this song to this computer" download hidden>⬇</a><button id="smkv-aqueue" title="Queue">☰</button><input id="smkv-avol" type="range" min="0" max="1" step="0.05"><button id="smkv-aclose" title="Stop">✕</button></div>
  <audio id="smkv-aud" preload="auto"></audio>
</div>
<div id="smkv-detail"></div>
<div id="smkv-toast"></div>
<div id="smkv-login"><form>
  <h2>Sign in to Delos</h2><div class="smkv-tagline">🌙 Artemis for films · ☀️ Apollo for music</div>
  <input name="username" placeholder="Username" autocomplete="username">
  <input name="password" type="password" placeholder="Password" autocomplete="current-password">
  <button type="submit">Sign in</button>
  <div class="msg"></div>
</form></div>`;

  const CSS = `
@supports not selector(::-webkit-scrollbar){*{scrollbar-width:thin;scrollbar-color:rgba(255,255,255,.18) transparent}}
*::-webkit-scrollbar{width:10px;height:10px;background:transparent}
*::-webkit-scrollbar-track,*::-webkit-scrollbar-corner{background:transparent}
*::-webkit-scrollbar-button{display:none;width:0;height:0}
*::-webkit-scrollbar-thumb{background:rgba(255,255,255,.16);border-radius:10px;border:3px solid transparent;background-clip:padding-box;min-height:40px}
*::-webkit-scrollbar-thumb:hover{background-color:rgba(255,255,255,.32)}
*::-webkit-scrollbar-thumb:active{background-color:rgba(255,255,255,.45)}
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
#smkv-admin{font-size:13px}
#smkv-admin[hidden]{display:none}
#smkv-nav{display:flex;flex-direction:column;padding:4px 8px;overflow:auto}
#smkv-nav a{color:#c9cfd8;padding:8px 10px;border-radius:7px;display:flex;gap:6px;align-items:center}
#smkv-nav a:hover{background:#181c24}
#smkv-nav a.on{background:#1b2533;color:#fff}
.smkv-modes{display:flex;gap:4px;background:#0c0f14;border:1px solid #1f242d;border-radius:9px;padding:3px;margin:2px 0 10px}
.smkv-navh{font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:#6f7988;padding:12px 10px 4px}
#smkv-nav details.smkv-ngrp>summary{list-style:none;display:flex;gap:8px;align-items:center;padding:7px 10px;border-radius:7px;color:#c9cfd8;cursor:pointer;user-select:none}
#smkv-nav details.smkv-ngrp>summary::-webkit-details-marker{display:none}
#smkv-nav details.smkv-ngrp>summary::before{content:'▸';color:#6f7988;font-size:11px;width:10px;transition:transform .15s}
#smkv-nav details.smkv-ngrp[open]>summary::before{transform:rotate(90deg)}
#smkv-nav details.smkv-ngrp>summary:hover{background:#1a1f27}
#smkv-nav details.smkv-ngrp>summary .smkv-gn{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-weight:500}
#smkv-nav details.smkv-ngrp>a{padding-left:38px}
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
.smkv-now-info{flex:1 1 300px;min-width:300px;max-width:620px}
.smkv-now-info h2{font-size:28px;margin:4px 0}
#smkv-np-seek{width:100%;margin-top:18px}
.smkv-np-times{display:flex;justify-content:space-between;color:#8b95a5;font-size:12px}
.smkv-np-btns{display:flex;gap:12px;align-items:center;margin-top:10px;flex-wrap:wrap}
#smkv-np-lyrb:not(.on){opacity:.4;filter:grayscale(1)}
.smkv-np-btns button{background:transparent!important;border:none!important;font-size:22px!important;color:#c9cfd8!important}
.smkv-np-btns button.on{color:#ff7eb6!important}
.smkv-lyrics{flex:1 1 320px;min-width:260px;max-width:520px;align-self:stretch;display:flex;flex-direction:column;background:linear-gradient(180deg,rgba(255,255,255,.035),rgba(255,255,255,.015));border:1px solid #1f242d;border-radius:16px;padding:6px 4px 8px;min-height:300px;max-height:min(62vh,460px)}
.smkv-lyr-lines{flex:1;overflow-y:auto;padding:28% 18px 40%;scrollbar-width:none;-webkit-mask-image:linear-gradient(180deg,transparent,#000 18%,#000 80%,transparent);mask-image:linear-gradient(180deg,transparent,#000 18%,#000 80%,transparent)}
.smkv-lyr-lines::-webkit-scrollbar{display:none}
.smkv-lyr-lines p{margin:0;padding:7px 6px;font-size:21px;font-weight:700;line-height:1.3;color:rgba(255,255,255,.32);cursor:pointer;border-radius:8px;transition:color .25s,transform .25s;transform-origin:left center}
.smkv-lyr-lines p:hover{color:rgba(255,255,255,.6)}
.smkv-lyr-lines p.on{color:#fff;transform:scale(1.03)}
.smkv-lyr-lines p.gap{font-size:16px}
.smkv-lyr-lines.plain{white-space:pre-wrap;font-size:16px;line-height:1.7;color:#d6dbe3;padding:16px 18px;-webkit-mask-image:none;mask-image:none}
.smkv-lyrics[hidden]{display:none}
.smkv-lyr-src{font-size:11px;color:#6f7988;text-align:center;padding-top:4px}
.smkv-lyr-msg{margin:auto;text-align:center;line-height:1.8}
.smkv-np-btns button.big{background:#fff!important;color:#000!important;border-radius:50%!important;width:56px;height:56px;font-size:20px!important}
.smkv-tracks tr.played td{opacity:.55}
.smkv-pageh{margin:18px 0 12px}
.smkv-rqsearch{display:flex;gap:10px;align-items:center;max-width:760px;margin-bottom:6px}
.smkv-seg{display:flex;background:#151920;border:1px solid #2a313c;border-radius:9px;padding:3px;flex:none}
.smkv-seg button{background:transparent;border:0;color:#aab3c0;padding:6px 12px;border-radius:6px;cursor:pointer;font:inherit;font-size:13px;white-space:nowrap}
.smkv-seg button.on{background:#2a313c;color:#fff}
.smkv-rqgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:16px;margin:14px 0 20px}
.smkv-rqc .smkv-poster img{width:100%;height:100%;object-fit:cover}
.smkv-rqct{font-size:13px;margin:7px 0 6px;line-height:1.3;overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}
.smkv-rqcb{font-size:12px}.smkv-rqcb button{width:100%;font-size:12.5px;padding:6px 8px}
.smkv-rqs{display:flex;flex-direction:column;gap:10px;margin-bottom:16px}
.smkv-rq{display:flex;gap:14px;align-items:flex-start;background:#12161d;border:1px solid #1f242d;border-radius:12px;padding:10px}
.smkv-rqp{width:64px;flex:none;aspect-ratio:2/3;border-radius:7px;overflow:hidden;background:#1a2029;display:flex;align-items:center;justify-content:center}
.smkv-rqp img{width:100%;height:100%;object-fit:cover}
.smkv-rqb{flex:1;min-width:0}
.smkv-rqt{font-size:15px}
.smkv-rqm{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-top:5px;font-size:12.5px}
.smkv-rqm .smkv-av{vertical-align:-3px}
.smkv-rqo{font-size:12.5px;margin-top:6px;overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}
.smkv-rqnote{font-size:13px;margin-top:6px;color:#d6dbe3}
.smkv-rqa{display:flex;gap:6px;align-items:center;flex:none;flex-wrap:wrap;justify-content:flex-end}
.smkv-vote.on{border-color:#3b6fd6;background:#1b2a45;color:#cfe0ff}
.smkv-rqpill{display:inline-block;font-size:11.5px;font-weight:600;padding:2px 8px;border-radius:20px;background:#2a313c;color:#d6dbe3;white-space:nowrap}
.smkv-rqpill.pending{background:#3a3218;color:#ffd77a}.smkv-rqpill.approved{background:#1b2a45;color:#9cc2ff}
.smkv-rqpill.available{background:#163222;color:#7fe0a5}.smkv-rqpill.declined{background:#3a1c1c;color:#ff9a9a}
.smkv-rqdecl summary{cursor:pointer;list-style:none}
@media (max-width:600px){.smkv-rq{flex-wrap:wrap}.smkv-rqa{width:100%;justify-content:flex-start}.smkv-rqsearch{flex-wrap:wrap}.smkv-rqgrid{grid-template-columns:repeat(auto-fill,minmax(110px,1fr))}}
.smkv-dlform{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-bottom:6px}
.smkv-dlform input[name=source]{flex:1;min-width:260px}
.smkv-dlform input,.smkv-dlform select{background:#151920;color:#e6e9ee;border:1px solid #2a313c;border-radius:6px;padding:7px 9px;font:inherit}
.smkv-tfile{position:relative;overflow:hidden;background:#1c212a;border:1px solid #2a313c;border-radius:6px;padding:6px 10px;cursor:pointer;white-space:nowrap;max-width:200px;text-overflow:ellipsis}
.smkv-tfile input{position:absolute;inset:0;opacity:0;cursor:pointer}
.smkv-dl{background:#141820;border:1px solid #20262f;border-radius:10px;padding:10px 12px;margin:8px 0}
.smkv-dlg{background:#10141a;border:1px solid #232a34;border-radius:12px;padding:0 12px;margin:8px 0}
.smkv-dlg[open]{padding-bottom:4px}
.smkv-dlg.failed{border-color:#5a2a2a}
.smkv-dlg>summary{list-style:none;display:flex;flex-wrap:wrap;align-items:center;gap:8px 10px;padding:11px 0;cursor:pointer;user-select:none}
.smkv-dlg>summary::-webkit-details-marker{display:none}
.smkv-dlg>summary::before{content:'▸';color:#6f7988;font-size:12px;width:10px;transition:transform .15s}
.smkv-dlg[open]>summary::before{transform:rotate(90deg)}
.smkv-dlgh{flex:1;min-width:220px;display:flex;flex-direction:column;gap:2px;word-break:break-word}
.smkv-dlgb{display:flex;gap:6px;flex-wrap:wrap}
.smkv-dlg>summary .smkv-pbar{flex-basis:100%;margin:0}
.smkv-dlg .smkv-dl{margin:6px 0 6px 18px}
.smkv-dlg.alldone>summary .smkv-pbar i{background:#3ecf8e}
.smkv-ep.smkv-skel{cursor:default;opacity:.55;outline:1px dashed #2a313c;outline-offset:-1px}
.smkv-ep.smkv-skel:hover{background:transparent}
.smkv-ep.smkv-skel .smkv-still{background:repeating-linear-gradient(135deg,#171b22 0 10px,#1b2028 10px 20px)}
.smkv-ep.smkv-skel .smkv-still span{color:#5d6675;font-size:22px}
.smkv-ep.smkv-skel.future{opacity:.4}
.smkv-miss{color:#f5a623}
.smkv-pager{display:flex;align-items:center;gap:6px;flex-wrap:wrap;justify-content:center;margin:12px 0;font-size:13px}
.smkv-pager button{min-width:32px}
.smkv-pager button:disabled{opacity:.35;cursor:default}
.smkv-pager select{background:#151920;color:#c9cfd8;border:1px solid #2a313c;border-radius:6px;padding:3px 6px}
/* ---- party */
#smkv-party{position:fixed;right:12px;top:12px;bottom:88px;width:330px;z-index:18;display:flex;flex-direction:column;background:rgba(16,20,27,.97);border:1px solid #2a313c;border-radius:14px;box-shadow:0 10px 40px rgba(0,0,0,.5);overflow:hidden;color:#c9cfd8;font-size:13.5px}
#smkv-party[hidden]{display:none}
#smkv-party.min{top:auto;bottom:96px;width:auto;background:transparent;border:none;box-shadow:none}
.smkv-pmin{background:#3b2a6e!important;border:1px solid #7b5cd6!important;color:#fff!important;border-radius:20px!important;padding:8px 14px!important;box-shadow:0 6px 20px rgba(0,0,0,.4)}
#smkv-party header{display:flex;gap:8px;align-items:flex-start;padding:12px 12px 8px;border-bottom:1px solid #20262f}
#smkv-party header>div{flex:1;min-width:0}
#smkv-party header b{font-size:15px}
#smkv-party button{background:#1c212a;color:#c9cfd8;border:1px solid #2a313c;border-radius:7px;padding:4px 9px;cursor:pointer;font:inherit}
#smkv-party button.smkv-primary{background:#3b6fd6;border-color:#3b6fd6;color:#fff}
#smkv-party button.smkv-danger{background:#5a1f24;border-color:#7a2a30;color:#ffb3b8}
.smkv-pnow{padding:8px 12px;border-bottom:1px solid #20262f;display:flex;flex-direction:column;gap:4px}
.smkv-pnow a{color:#8ab4ff}
.smkv-pmembers{display:flex;flex-wrap:wrap;gap:6px;padding:8px 12px;align-items:center}
.smkv-pmem{position:relative;display:inline-flex}
.smkv-pmem i{position:absolute;top:-9px;left:6px;font-style:normal;font-size:11px}
.smkv-pmem button{position:absolute;top:-6px;right:-8px;padding:0 4px!important;font-size:10px!important;line-height:14px;border-radius:50%!important;display:none}
.smkv-pmem:hover button{display:block}
.smkv-pinv{border-radius:50%!important;width:26px;height:26px;padding:0!important}
.smkv-preqs{padding:4px 12px 8px;display:flex;flex-direction:column;gap:6px}
.smkv-preqs>div{display:flex;align-items:center;gap:6px;flex-wrap:wrap;background:#1a2233;border-radius:8px;padding:6px 8px}
.smkv-pmsgs{flex:1;overflow:auto;padding:8px 12px;display:flex;flex-direction:column;gap:7px;border-top:1px solid #20262f}
.smkv-pm{display:flex;gap:7px;align-items:flex-start;line-height:1.4;word-break:break-word}
.smkv-pm b{color:#e6e9ee}
.smkv-pm.me b{color:#8ab4ff}
.smkv-pm.sys{color:#7d8696;font-size:12px;justify-content:center;text-align:center}
.smkv-preact{display:flex;justify-content:space-between;padding:6px 10px;border-top:1px solid #20262f}
.smkv-preact button{background:transparent!important;border:none!important;font-size:19px!important;padding:2px 4px!important;transition:transform .1s}
.smkv-preact button:hover{transform:scale(1.25)}
.smkv-psend{display:flex;gap:6px;padding:8px 10px}
.smkv-psend input{flex:1;background:#0d1015;border:1px solid #2a313c;border-radius:8px;color:#e6e9ee;padding:7px 10px;font:inherit;min-width:0}
#smkv-party footer{display:flex;gap:6px;padding:8px 10px;border-top:1px solid #20262f;flex-wrap:wrap}
#smkv-floats{position:fixed;inset:0;pointer-events:none;z-index:19;overflow:hidden}
.smkv-float{position:absolute;bottom:90px;display:flex;flex-direction:column;align-items:center;animation:smkvfloat 3.2s ease-out forwards}
.smkv-float span{font-size:38px;filter:drop-shadow(0 2px 6px rgba(0,0,0,.5))}
.smkv-float small{font-size:11px;color:#fff;background:rgba(0,0,0,.55);border-radius:8px;padding:0 6px}
@keyframes smkvfloat{0%{transform:translateY(0) scale(.6);opacity:0}12%{opacity:1;transform:translateY(-40px) scale(1.1)}100%{transform:translateY(-55vh) scale(1);opacity:0}}
#smkv-pnotes{position:fixed;top:14px;left:50%;transform:translateX(-50%);z-index:60;display:flex;flex-direction:column;gap:8px;width:min(440px,92vw)}
.smkv-pnote{background:#1a2030;border:1px solid #7b5cd6;border-radius:12px;padding:10px 12px;box-shadow:0 8px 28px rgba(0,0,0,.5);color:#e6e9ee;display:flex;flex-direction:column;gap:8px;font-size:14px}
.smkv-pnb{display:flex;gap:6px;justify-content:flex-end}
.smkv-pnote button{background:#262d3a;color:#e6e9ee;border:1px solid #333c4b;border-radius:7px;padding:5px 11px;cursor:pointer;font:inherit}
.smkv-pnote button.smkv-primary{background:#7b5cd6;border-color:#7b5cd6}
.smkv-pcard{display:flex;gap:12px;align-items:center;background:#141820;border:1px solid #20262f;border-radius:12px;padding:12px;margin:8px 0}
.smkv-pcl{display:flex;gap:10px;flex:1;min-width:0}
.smkv-pcl>div{display:flex;flex-direction:column;gap:3px;min-width:0}
.smkv-pav{display:flex;gap:3px;margin-top:3px}
.smkv-tag{font-size:11px;background:#3b2a6e;color:#d6c8ff;border-radius:8px;padding:1px 7px}
.smkv-pform{display:flex;flex-direction:column;gap:10px;margin-top:10px}
.smkv-pform label{display:flex;flex-direction:column;gap:4px}
.smkv-pform label.smkv-check{flex-direction:row;align-items:center}
.smkv-nres{max-height:200px;overflow:auto;display:flex;flex-direction:column}
.smkv-nres>div{padding:6px 8px;border-radius:6px;cursor:pointer}
.smkv-nres>div:hover{background:#1c2638}
.smkv-askj{background:none!important;border:none!important;padding:0 2px!important;font-size:14px;cursor:pointer;margin-left:4px;vertical-align:1px}
.smkv-askj:hover{transform:scale(1.2)}
body.smkv-in-party:not(.smkv-party-min).smkv-watching #smkv-watch{padding-right:350px}
body.smkv-in-party:not(.smkv-party-min) #smkv-browse{padding-right:350px}
.smkv-pcl .smkv-pav{display:flex!important;flex-direction:row!important;flex-wrap:wrap;gap:3px}
@media (max-width:820px){#smkv-party{left:8px;right:8px;width:auto;top:auto;height:52vh}body.smkv-in-party.smkv-watching #smkv-watch,body.smkv-in-party #smkv-browse{padding-right:0}}
#smkv-selbar{position:sticky;bottom:12px;z-index:5;display:flex;gap:8px;align-items:center;flex-wrap:wrap;background:#1a2030;border:1px solid #3b6fd6;border-radius:12px;padding:10px 14px;margin-top:16px;box-shadow:0 6px 24px rgba(0,0,0,.45)}
#smkv-selbar span{flex:1;min-width:140px}
#smkv-selbtn.on{background:#2a4a7a!important;border-color:#3b6fd6!important;color:#fff!important}
.smkv-pickwrap{position:relative;border-radius:10px;outline:2px solid transparent;outline-offset:3px}
.smkv-pickwrap::after{content:'';position:absolute;top:8px;left:8px;width:20px;height:20px;border-radius:6px;border:2px solid #fff;background:rgba(0,0,0,.45);pointer-events:none}
.smkv-pickwrap.picked{outline-color:#3b6fd6}
.smkv-pickwrap.picked::after{content:'✓';background:#3b6fd6;border-color:#3b6fd6;color:#fff;font-size:13px;line-height:20px;text-align:center}
.smkv-item.picked{background:#1c2638;outline:1px solid #3b6fd6}
.smkv-pick{margin-right:8px;vertical-align:-2px;pointer-events:none}
#smkv-whoami{display:flex;align-items:center;gap:7px;margin:0 10px 8px;padding:6px 8px;border-radius:10px;background:rgba(255,255,255,.04);cursor:pointer;min-width:0;flex-wrap:wrap}
#smkv-whoami:hover{background:rgba(255,255,255,.08)}
#smkv-whoami b{font-size:13px;color:#e8ecf2;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:110px}
.smkv-roles{display:inline-flex;flex-wrap:wrap;gap:4px}
.smkv-role{font-size:10.5px;font-weight:600;padding:1px 7px;border-radius:999px;background:rgba(160,120,255,.18);color:#cdb6ff;white-space:nowrap}
.smkv-role.guest{background:rgba(255,255,255,.09);color:#aab3c0}
.smkv-role.sm{font-size:9.5px;padding:0 6px;margin-left:5px;vertical-align:1px;font-weight:600}
.smkv-role.adm{background:#4a3a1c;color:#ffcf7a}
#smkv-ver{font-size:11px;color:#6f7988;margin-left:6px;align-self:center;font-weight:500;letter-spacing:.2px}
.smkv-badges{display:inline-flex;gap:1px;margin-left:5px;font-size:12px;vertical-align:1px}
.smkv-badges i{font-style:normal;cursor:default}
.smkv-ranks{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:8px 28px}
.smkv-rank{display:flex;align-items:center;gap:10px;padding:8px 10px;border-radius:10px;margin:4px 0;background:#141820;border:1px solid #20262f}
.smkv-rank.me{border-color:#3b6fd6}
.smkv-rkm{width:26px;text-align:center;font-size:18px;flex:none}
.smkv-rk{font-size:13px;color:#8b95a5;font-weight:600}
.smkv-rkb{flex:1;min-width:0}
.smkv-rkb>div:first-child{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.smkv-rkbar{height:5px;border-radius:3px;background:#252b35;margin-top:6px;overflow:hidden}
.smkv-rkbar i{display:block;height:100%;background:linear-gradient(90deg,#3b6fd6,#7b5cd6);border-radius:3px}
.smkv-rkv{display:flex;flex-direction:column;align-items:flex-end;flex:none;font-size:13px}
.smkv-mybadges{display:flex;flex-wrap:wrap;gap:10px}
.smkv-mybadge{display:flex;gap:10px;align-items:center;background:#141820;border:1px solid #20262f;border-radius:10px;padding:8px 12px}
.smkv-mybadge>span{font-size:24px}
.smkv-howrank{margin-top:18px}.smkv-howrank summary{cursor:pointer;color:#8b95a5}
.smkv-raw{display:none;font:11px/1.35 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;color:#7d8696;word-break:break-all;margin-top:2px}
.smkv-raw i{font-style:normal;color:#5d6675}
body.smkv-raw-on .smkv-raw{display:block}
#smkv-rawbtn{white-space:nowrap}
#smkv-rawbtn.on{background:#2a4a7a!important;border-color:#3b6fd6!important;color:#fff!important}
.smkv-dlh{display:flex;flex-direction:column;gap:2px;word-break:break-all}
.smkv-pbar.big{position:relative;height:6px;border-radius:3px;margin:8px 0 6px;background:#252b35}
.smkv-pbar.big i{display:block;height:100%;border-radius:3px;background:#4a9eff}
.smkv-dl.done .smkv-pbar.big i{background:#3ecf8e}.smkv-dl.failed .smkv-pbar.big i{background:#ff6b6b}
.smkv-dlf2{display:flex;align-items:center;gap:8px;flex-wrap:wrap}.smkv-dlf2 span{flex:1;min-width:220px}
.smkv-btn2{background:#1c212a;color:#e6e9ee;border:1px solid #2a313c;border-radius:6px;padding:6px 12px;cursor:pointer;font:inherit}
.smkv-err{color:#ff7b7b}
#smkv-side header{gap:4px!important}
#smkv-side header .smkv-hb{display:inline-flex;align-items:center;justify-content:center;flex:none;width:30px;height:30px;padding:0!important;min-width:0;
  background:transparent!important;border:1px solid transparent!important;border-radius:8px;color:#aab3c0!important;cursor:pointer;text-decoration:none}
#smkv-side header .smkv-hb:hover{background:#1c212a!important;border-color:#2a313c!important;color:#fff!important}
#smkv-side header .smkv-hb[hidden]{display:none}
#smkv-side header b{white-space:nowrap}
#smkv-side header>b{flex:none}
#smkv-ver{flex:0 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
#smkv-side header .smkv-sp{min-width:0}
#smkv-sidefoot{margin-top:auto;padding:6px 8px 8px;border-top:1px solid #1f242d}
#smkv-mini:not([hidden])~#smkv-sidefoot{margin-top:0}
#smkv-app #smkv-sidefoot #smkv-fold{display:flex;align-items:center;gap:9px;width:100%;padding:7px 10px;background:transparent;border:1px solid transparent;border-radius:7px;color:#8b95a5;font-size:13px;text-align:left}
#smkv-app #smkv-sidefoot #smkv-fold:hover{background:#181c24;color:#fff}
#smkv-sidefoot #smkv-fold svg{flex:none}
#smkv-sidefoot #smkv-fold span{flex:1}
#smkv-sidefoot kbd{font:11px/1 system-ui,sans-serif;color:#6f7988;border:1px solid #2a313c;border-radius:4px;padding:3px 5px}
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
/* the chat panel's ✕ sits in the header row (the global .smkv-x floats over dialogs) */
.smkv-ch .smkv-x{position:static!important;flex:none;width:30px;height:30px;background:transparent!important;font-size:15px}
.smkv-ch .smkv-x:hover{background:rgba(255,255,255,.08)!important}
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
.smkv-send{display:flex;gap:6px;padding:10px;border-top:1px solid #1f242d;align-items:center}
#smkv-chat .smkv-cbtn{background:none!important;border:none!important;font-size:19px;padding:4px 5px!important;cursor:pointer;line-height:1;opacity:.85;flex:none}
#smkv-chat .smkv-cbtn:hover{opacity:1}
#smkv-chat.smkv-drop .smkv-msgs{outline:2px dashed #4a9eff;outline-offset:-8px;background:#121a26}
.smkv-uploads{display:flex;flex-direction:column;gap:4px;padding:0 10px}
.smkv-up{display:flex;gap:8px;align-items:center;font-size:12px;color:#9aa3b2;padding:4px 0}.smkv-up span{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.smkv-up progress{width:90px}
.smkv-attimg{display:block;max-width:240px;max-height:360px;width:auto;height:auto;border-radius:12px;cursor:zoom-in;background:#1a202a;object-fit:cover}
.smkv-attf{display:flex;gap:8px;align-items:center;background:#1a202a;border:1px solid #2a3240;border-radius:12px;padding:9px 11px;color:#d7dce4!important;text-decoration:none;max-width:260px;font-size:13.5px}
.smkv-attf:hover{border-color:#4a9eff}.smkv-attf span{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.smkv-attf small{color:#8b95a5;flex:none}
.smkv-attf.gone{opacity:.6}
.smkv-imgview{display:flex;justify-content:center}.smkv-imgview img{max-width:100%;max-height:78vh;border-radius:8px}
.smkv-btnlink{color:#fff;background:#2b6fd6;border-radius:6px;padding:6px 12px;text-decoration:none;font-size:13px}
.smkv-rxs{display:flex;flex-wrap:wrap;gap:4px}
#smkv-chat .smkv-rx{padding:1px 7px!important;border-radius:11px!important;font-size:13px;background:#1a202a!important;border:1px solid #2a3240!important}
#smkv-chat .smkv-rx.on{border-color:#4a9eff!important;background:#16263d!important}#smkv-chat .smkv-rx b{font-size:11px;color:#c9cfd8}
#smkv-chat .smkv-rxadd{visibility:hidden;background:none!important;border:none!important;padding:0 4px!important;margin-left:6px;color:#8b95a5;font-size:12px;cursor:pointer}
#smkv-chat .smkv-msg:hover .smkv-rxadd,#smkv-chat .smkv-msg.act .smkv-rxadd{visibility:visible}
@media (hover:none){#smkv-chat .smkv-rxadd{visibility:visible;opacity:.55}}
.smkv-from{color:#9db7d8}
.smkv-dlbtn{color:#c9cfd8;text-decoration:none;border:1px solid #2a313c;border-radius:6px;padding:4px 10px;font-size:13px;white-space:nowrap}
.smkv-dlbtn:hover{color:#fff;border-color:#4a9eff}.smkv-dlbtn[hidden]{display:none}
.smkv-titlerow .smkv-dlbtn{margin-left:auto}
.smkv-tagline{color:#8b95a5;font-size:13px;margin:-4px 0 14px}
.smkv-plpop{display:flex;flex-direction:column;min-width:220px;max-height:min(60vh,420px);overflow:auto;padding:6px}
.smkv-plpop .smkv-plh{font:600 11px system-ui,sans-serif;color:#7d8696;text-transform:uppercase;letter-spacing:.5px;padding:6px 10px 4px}
.smkv-pop.smkv-plpop button{font-size:14px;text-align:left;padding:8px 10px;display:flex;justify-content:space-between;gap:12px}
.smkv-plpop button small{color:#7d8696}
.smkv-tracks .smkv-tadd{opacity:.35;background:none!important;border:none!important;font-size:16px;cursor:pointer;color:#c9cfd8;padding:2px 6px!important}
.smkv-tracks tr:hover .smkv-tadd,.smkv-tracks tr:hover .smkv-tdl{opacity:1}
.smkv-tracks .smkv-qrm{opacity:.4;background:none!important;border:none!important;color:#c9cfd8;cursor:pointer;padding:2px 6px!important}
.smkv-tracks tr:hover .smkv-qrm{opacity:1}
.smkv-tracks .smkv-tdl{opacity:.35;color:#c9cfd8;text-decoration:none;font-size:14px;padding:2px 6px}
@media (hover:none){.smkv-tracks .smkv-tadd{opacity:.7}}
.smkv-pltracks .smkv-grip{cursor:grab;color:#5d6675}
.smkv-pltracks td.e{white-space:nowrap}.smkv-pltracks td.e button{background:none;border:none;color:#9aa3b2;cursor:pointer;font-size:14px;padding:2px 6px}
.smkv-pltracks td.e button:hover{color:#fff}
.smkv-pltracks tr.drag{opacity:.4}.smkv-pltracks tr.over td{border-top:2px solid #4a9eff}
.smkv-pop{position:fixed;z-index:2147483646;background:#161b23;border:1px solid #2c3442;border-radius:12px;box-shadow:0 10px 40px rgba(0,0,0,.55)}
.smkv-quick{display:flex;gap:2px;padding:4px}
.smkv-pop button{background:none;border:none;font-size:22px;line-height:1;padding:6px;border-radius:8px;cursor:pointer;color:#c9cfd8}
.smkv-pop button:hover{background:#252c38}
.smkv-emo{width:min(330px,94vw);display:flex;flex-direction:column}
.smkv-emoq{margin:8px 8px 4px;background:#0f1217;color:#e6e9ee;border:1px solid #2a313c;border-radius:8px;padding:7px 10px;font:13px system-ui,sans-serif}
.smkv-emotabs{display:flex;justify-content:space-between;padding:0 6px;border-bottom:1px solid #222935}
.smkv-emotabs button{font-size:17px;padding:5px}
.smkv-emogrid{height:250px;overflow:auto;display:grid;grid-template-columns:repeat(8,1fr);padding:4px 6px 8px;align-content:start}
.smkv-emogrid button{font-size:23px;padding:4px 0}
.smkv-emoh{grid-column:1/-1;font:600 11px system-ui,sans-serif;color:#7d8696;text-transform:uppercase;letter-spacing:.5px;padding:8px 2px 4px}
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
.smkv-row,.smkv-cast{scrollbar-width:none;scroll-behavior:smooth;scroll-snap-type:x proximity;overscroll-behavior-x:contain}
.smkv-row::-webkit-scrollbar,.smkv-cast::-webkit-scrollbar{display:none}
.smkv-row>*,.smkv-cast>*{scroll-snap-align:start}
.smkv-rowwrap{position:relative;min-width:0}
.smkv-rowwrap.fade-l>.smkv-row,.smkv-rowwrap.fade-l>.smkv-cast{-webkit-mask-image:linear-gradient(90deg,transparent 0,#000 48px);mask-image:linear-gradient(90deg,transparent 0,#000 48px)}
.smkv-rowwrap.fade-r>.smkv-row,.smkv-rowwrap.fade-r>.smkv-cast{-webkit-mask-image:linear-gradient(90deg,#000 calc(100% - 48px),transparent);mask-image:linear-gradient(90deg,#000 calc(100% - 48px),transparent)}
.smkv-rowwrap.fade-l.fade-r>.smkv-row,.smkv-rowwrap.fade-l.fade-r>.smkv-cast{-webkit-mask-image:linear-gradient(90deg,transparent 0,#000 48px,#000 calc(100% - 48px),transparent);mask-image:linear-gradient(90deg,transparent 0,#000 48px,#000 calc(100% - 48px),transparent)}
.smkv-rowwrap>button.smkv-rowbtn{padding:0!important;min-width:0!important;width:44px!important;height:44px!important;border-radius:50%!important;margin:0}
.smkv-rowbtn svg{width:22px;height:22px;display:block}
.smkv-rowbtn{position:absolute;top:var(--rb-top,40%);transform:translateY(-50%);z-index:3;width:42px;height:42px;border-radius:50%;border:1px solid rgba(255,255,255,.14);background:rgba(18,21,27,.82);color:#fff;font-size:22px;line-height:1;display:flex;align-items:center;justify-content:center;cursor:pointer;opacity:0;pointer-events:none;transition:opacity .18s,transform .18s,background .18s;backdrop-filter:blur(8px);-webkit-backdrop-filter:blur(8px);box-shadow:0 4px 18px rgba(0,0,0,.45)}
.smkv-rowbtn.l{left:-6px}.smkv-rowbtn.r{right:-6px}
.smkv-rowbtn:hover{background:rgba(40,46,58,.95);transform:translateY(-50%) scale(1.08)}
.smkv-rowwrap:hover>.smkv-rowbtn.on,.smkv-rowbtn.on:focus-visible{opacity:1;pointer-events:auto}
@media (hover:none){.smkv-rowbtn{display:none}}
.smkv-rowbar{position:absolute;left:0;right:0;bottom:-7px;height:16px;opacity:0;transition:opacity .2s;pointer-events:none;cursor:pointer;touch-action:none}
.smkv-rowbar::before{content:"";position:absolute;left:0;right:0;top:6px;height:4px;border-radius:4px;background:rgba(255,255,255,.07);transition:height .15s,top .15s}
.smkv-rowbar>i{position:absolute;top:6px;height:4px;border-radius:4px;background:rgba(255,255,255,.35);transition:height .15s,top .15s,background .15s}
.smkv-rowbar.on{opacity:.55;pointer-events:auto}
.smkv-rowwrap:hover>.smkv-rowbar.on,.smkv-rowbar.drag{opacity:1}
.smkv-rowbar:hover::before,.smkv-rowbar.drag::before{top:4px;height:8px}
.smkv-rowbar:hover>i,.smkv-rowbar.drag>i{top:4px;height:8px;background:rgba(255,255,255,.55)}
.smkv-row.grab,.smkv-cast.grab{cursor:grabbing;scroll-behavior:auto;scroll-snap-type:none;user-select:none}
.smkv-row.grab *,.smkv-cast.grab *{pointer-events:none}
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
#smkv-trailer{position:fixed;inset:0;z-index:40;background:rgba(3,4,6,.9);display:none;place-items:center;padding:24px}
#smkv-trailer.show{display:grid}
.smkv-trlbox{width:min(1100px,100%,calc((100vh - 140px) * 16 / 9));display:flex;flex-direction:column;gap:10px}
.smkv-trlhead{display:flex;align-items:center;gap:10px;min-width:0}
.smkv-trlhead b{font-size:16px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.smkv-trlhead .smkv-dim2{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;flex:1;min-width:0}
.smkv-trlhead .smkv-x{position:static!important;flex:none;display:grid;place-items:center;width:36px;height:36px;font:16px/1 system-ui,sans-serif;color:#fff;border:1px solid rgba(255,255,255,.18)!important;background:rgba(255,255,255,.08)!important;cursor:pointer;transition:background .15s}
.smkv-trlhead .smkv-x:hover{background:rgba(255,255,255,.2)!important}
.smkv-trlyt{color:#8b95a5;font-size:12px;text-decoration:none;white-space:nowrap}.smkv-trlyt:hover{color:#fff}
.smkv-trlvid{position:relative;aspect-ratio:16/9;background:#000;border-radius:12px;overflow:hidden;box-shadow:0 20px 60px rgba(0,0,0,.6)}
.smkv-trlvid iframe{position:absolute;inset:0;width:100%;height:100%;border:0}
.smkv-trllist{display:flex;gap:8px;overflow-x:auto;padding-bottom:4px}
.smkv-trllist button{flex:none;background:#151920;border:1px solid #2a313c;color:#aab3c0;border-radius:8px;padding:6px 10px;font:inherit;font-size:12.5px;cursor:pointer;max-width:280px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.smkv-trllist button.on{border-color:#3b6fd6;color:#fff;background:#1b2a45}
.smkv-trlslot:empty{display:none}
.smkv-dhead .smkv-trlslot{margin-top:10px}
.smkv-trlbtn{display:inline-flex;align-items:center;gap:6px}
.smkv-trlbtn small{background:#2a313c;border-radius:9px;padding:0 6px;font-size:11px}
.smkv-showbtns{display:flex;gap:10px;align-items:center;flex-wrap:wrap}
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
#smkv-ann{position:relative}#smkv-ann i{position:absolute;top:-4px;right:-4px;background:#e5484d;color:#fff;font-style:normal;font-size:10px;border-radius:9px;padding:0 5px;font-weight:700;line-height:15px}
#smkv-annbar{display:flex;gap:12px;align-items:flex-start;margin:12px 24px 0;padding:10px 12px;border-radius:10px;background:#16263d;border:1px solid #234066;color:#d7e6fb;font-size:13.5px}
#smkv-annbar[hidden]{display:none}
#smkv-secbar{display:flex;gap:12px;align-items:center;margin:12px 24px 0;padding:10px 12px;border-radius:10px;background:#12241a;border:1px solid #1f6f43;color:#cfe9d9;font-size:13.5px}
#smkv-secbar[hidden]{display:none}#smkv-secbar>div{flex:1;min-width:0}#smkv-secbar b{color:#fff}#smkv-secbar a{color:#7cc4ff}
#smkv-secbar button{flex:none;font-size:12px!important}#smkv-secbar .smkv-primary{background:#2b6fd6!important;border-color:#2b6fd6!important;color:#fff!important;font-weight:600}
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
@media (max-width:820px){#smkv-annbar,#smkv-secbar{margin:10px 12px 0}#smkv-secbar{flex-wrap:wrap}}
#smkv-player.engine #smkv-canvas{display:block}
#smkv-player.engine #smkv-video{visibility:hidden}
#smkv-player:not(.ctl) #smkv-canvas{cursor:none}
#smkv-player:not(.ctl) #smkv-video{cursor:none}
#smkv-subs{position:absolute;left:5%;right:5%;bottom:calc(7% + var(--sraise,0%));text-align:center;pointer-events:none;color:#fff;line-height:1.25;
  text-shadow:0 0 3px #000,0 0 3px #000,1px 1px 2px #000,-1px -1px 2px #000,1px -1px 2px #000,-1px 1px 2px #000;transition:bottom .2s}
#smkv-player.ctl #smkv-subs{bottom:calc(max(7%,78px) + var(--sraise,0%))}
#smkv-subs span{background:rgba(0,0,0,.18);padding:0 .2em;border-radius:3px;font-weight:500}
#smkv-controls{position:absolute;left:0;right:0;bottom:0;padding:24px 12px 8px;background:linear-gradient(transparent,rgba(0,0,0,.85));opacity:0;transition:opacity .2s}
#smkv-player.ctl #smkv-controls{opacity:1}
#smkv-tp{position:absolute;bottom:calc(100% - 14px);display:flex;flex-direction:column;align-items:center;gap:4px;pointer-events:none;z-index:3}
#smkv-tp[hidden]{display:none}
#smkv-tp .img{border-radius:6px;border:2px solid rgba(255,255,255,.85);background:#000 no-repeat;box-shadow:0 6px 24px rgba(0,0,0,.6)}
#smkv-tp span{font:600 12px/1 system-ui,sans-serif;color:#fff;background:rgba(0,0,0,.75);padding:4px 7px;border-radius:5px;font-variant-numeric:tabular-nums}
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
/* folded sidebar: a rail of icons (desktop widths only) */
@media (min-width:821px){
  body.smkv-side-mini #smkv-app{grid-template-columns:62px 1fr}
  body.smkv-side-mini #smkv-side header{flex-direction:column;padding:10px 0 6px;gap:6px!important}
  body.smkv-side-mini #smkv-side header>b,body.smkv-side-mini #smkv-side header>small,body.smkv-side-mini #smkv-side header>.smkv-sp{display:none}
  body.smkv-side-mini #smkv-sidefoot{padding:6px 7px 8px}
  body.smkv-side-mini #smkv-sidefoot #smkv-fold{justify-content:center;padding:8px 0}
  body.smkv-side-mini #smkv-sidefoot #smkv-fold>span,body.smkv-side-mini #smkv-sidefoot kbd{display:none}
  body.smkv-side-mini .smkv-fold-ar{transform:rotate(180deg);transform-origin:14.5px 12px}
  body.smkv-side-mini #smkv-whoami{justify-content:center;margin:0 8px 8px;padding:6px 0}
  body.smkv-side-mini #smkv-whoami>:not(.smkv-pav){display:none}
  body.smkv-side-mini #smkv-nav{padding:4px 7px;overflow-x:hidden}
  body.smkv-side-mini #smkv-nav a{justify-content:center;padding:9px 0;position:relative;font-size:17px}
  body.smkv-side-mini #smkv-nav .smkv-nt,body.smkv-side-mini .smkv-navh,body.smkv-side-mini #smkv-nav .smkv-gn{display:none}
  body.smkv-side-mini #smkv-nav .smkv-n{position:absolute;top:2px;right:2px;margin:0;font-size:9.5px;line-height:1;padding:2px 4px;border-radius:8px;background:#232a35;color:#aab3c0}
  body.smkv-side-mini .smkv-modes{flex-direction:column}
  body.smkv-side-mini #smkv-nav .smkv-modes a{padding:7px 0}
  body.smkv-side-mini #smkv-nav details.smkv-ngrp>summary{justify-content:center;padding:7px 0;position:relative}
  body.smkv-side-mini #smkv-nav details.smkv-ngrp>summary::before{position:absolute;left:0}
  body.smkv-side-mini #smkv-nav details.smkv-ngrp>summary .smkv-n{display:none}
  body.smkv-side-mini #smkv-nav details.smkv-ngrp>a{padding-left:0}
  body.smkv-side-mini #smkv-people{padding:6px 4px}
  body.smkv-side-mini .smkv-ph{justify-content:center;font-size:0;padding:4px 0 6px}
  body.smkv-side-mini .smkv-ph>:not(#smkv-chat-open){display:none}
  body.smkv-side-mini .smkv-ph #smkv-chat-open{font-size:16px!important;margin:0}
  body.smkv-side-mini .smkv-person{justify-content:center;padding:5px 0}
  body.smkv-side-mini .smkv-person>div{display:none}
  body.smkv-side-mini #smkv-mini{justify-content:center;margin:auto 6px 8px;padding:8px 0}
  body.smkv-side-mini #smkv-mini>div,body.smkv-side-mini #smkv-mini>button{display:none}
}
@media (max-width:820px){#smkv-sidefoot{display:none!important}}
@media (max-width:820px){
  #smkv-app{grid-template-columns:minmax(0,1fr);grid-template-rows:auto 1fr}
  #smkv-app>*{min-width:0}
  #smkv-side{border-right:none;border-bottom:1px solid #1f242d}
  #smkv-nav{flex-direction:row;overflow-x:auto;padding:0 8px 8px}
  #smkv-nav details.smkv-ngrp{display:contents}
  #smkv-nav .smkv-navh{display:none}
  #smkv-nav details.smkv-ngrp>summary{white-space:nowrap;color:#8b95a5;font-size:12px;padding:6px 4px 6px 10px}
  #smkv-nav details.smkv-ngrp>summary::before,#smkv-nav details.smkv-ngrp>summary .smkv-n{display:none}
  #smkv-nav details.smkv-ngrp>a{padding-left:10px}
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
