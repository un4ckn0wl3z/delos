// ==UserScript==
// @name         StreamMKV
// @namespace    https://github.com/un4ckn0wl3z/streammkv
// @version      1.1.0
// @description  Watch MKV files from your seedbox in the browser — pick audio tracks and subtitles.
// @author       un4ckn0wl3z
// @homepageURL  https://github.com/un4ckn0wl3z/streammkv
// @updateURL    https://raw.githubusercontent.com/un4ckn0wl3z/streammkv/main/web/streammkv.user.js
// @downloadURL  https://raw.githubusercontent.com/un4ckn0wl3z/streammkv/main/web/streammkv.user.js
// @match        *://*/*
// @grant        GM_getValue
// @grant        GM_setValue
// @grant        GM_deleteValue
// @grant        GM_registerMenuCommand
// @grant        GM_openInTab
// @run-at       document-idle
// @noframes
// ==/UserScript==

/*
 * How it works
 *  - Anywhere: Tampermonkey menu → "StreamMKV settings" (server URL, username, password)
 *    and "Open StreamMKV" (opens the server in a new tab).
 *  - On the StreamMKV server page (detected by <meta name="streammkv-app">) the script
 *    logs in with the saved credentials and renders the player. Running on the server's
 *    own origin avoids CORS, mixed-content and page-CSP problems with <video>.
 */
(function () {
  'use strict';

  // ---------------------------------------------------------------- settings
  const DEFAULTS = { server: '', username: '', password: '', audioLang: '', subLang: '', maxh: 1080 };
  const getSettings = () => Object.assign({}, DEFAULTS, GM_getValue('settings', {}));
  const saveSettings = (s) => GM_setValue('settings', s);
  const normBase = (u) => {
    try {
      const x = new URL(u);
      let p = x.pathname;
      if (!p.endsWith('/')) p += '/';
      return x.origin + p;
    } catch { return ''; }
  };

  const isApp = !!document.querySelector('meta[name="streammkv-app"]');

  GM_registerMenuCommand('▶ Open StreamMKV', () => {
    const s = getSettings();
    if (!s.server) return openSettings();
    GM_openInTab(normBase(s.server), { active: true });
  });
  GM_registerMenuCommand('⚙ StreamMKV settings', () => openSettings());

  // ---------------------------------------------------------------- settings modal (works on any page)
  function openSettings(onSaved) {
    if (document.getElementById('smkv-settings-host')) return;
    const s = getSettings();
    if (isApp && !s.server) s.server = normBase(location.href.split(/[?#]/)[0]);
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
        input{width:100%;box-sizing:border-box;padding:8px 10px;background:#0d1015;color:#fff;border:1px solid #2a313c;border-radius:6px;font:inherit}
        input:focus{outline:none;border-color:#4a9eff}
        .hint{font-size:12px;color:#6b7482;margin-top:3px}
        .row{display:flex;gap:8px;margin-top:18px;justify-content:flex-end}
        button{padding:8px 14px;border-radius:6px;border:1px solid #2a313c;background:#222833;color:#d7dce4;font:inherit;cursor:pointer}
        button.primary{background:#2b6fd6;border-color:#2b6fd6;color:#fff}
        .msg{color:#ff8080;font-size:13px;min-height:1em;margin-top:8px}
      </style>
      <div class="bg"><form class="box">
        <h2>StreamMKV settings</h2>
        <label>Server URL</label><input name="server" placeholder="https://seedbox.example.com:8090/" value="">
        <label>Username</label><input name="username" autocomplete="username">
        <label>Password</label><input name="password" type="password" autocomplete="current-password">
        <label>Preferred audio languages</label><input name="audioLang" placeholder="jpn,eng">
        <label>Preferred subtitle languages</label><input name="subLang" placeholder="tha,eng">
        <div class="hint">Comma-separated ISO codes, first match wins. Per-file choices are remembered.</div>
        <label>Max height when transcoding</label><input name="maxh" type="number" min="240" max="2160" step="1">
        <div class="msg"></div>
        <div class="row">
          <button type="button" data-act="cancel">Cancel</button>
          ${isApp ? '' : '<button type="button" data-act="open">Save &amp; open</button>'}
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
      if (n.server && !normBase(n.server)) { root.querySelector('.msg').textContent = 'Invalid server URL'; return null; }
      n.server = n.server ? normBase(n.server) : '';
      saveSettings(n);
      return n;
    };
    form.addEventListener('submit', (e) => { e.preventDefault(); const n = collect(); if (n) { close(); onSaved && onSaved(n); } });
    root.querySelector('[data-act=cancel]').onclick = close;
    const openBtn = root.querySelector('[data-act=open]');
    if (openBtn) openBtn.onclick = () => { const n = collect(); if (n && n.server) { close(); GM_openInTab(n.server, { active: true }); } };
    root.querySelector('.bg').addEventListener('mousedown', (e) => { if (e.target.classList.contains('bg')) close(); });
    document.documentElement.appendChild(host);
    form.elements.server.focus();
  }

  // ================================================================= APP
  function bootApp() {
    const BASE = normBase(location.href.split(/[?#]/)[0]);
    document.getElementById('smkv-placeholder')?.remove();

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
      errCount: 0, lastSave: 0,
    };
    const cur = () => (S.pendingTarget ?? (S.offset + (video.currentTime || 0)));

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
        const s = getSettings();
        if (normBase(s.server) === BASE && s.username) {
          try { await doLogin(s.username, s.password); return; } catch (e) { /* fall through to form */ }
        }
        await showLoginForm(s);
      })().finally(() => { loginPromise = null; });
      return loginPromise;
    }

    function showLoginForm(s) {
      return new Promise((resolve) => {
        const box = $('#smkv-login');
        const f = box.querySelector('form');
        f.elements.username.value = normBase(s.server) === BASE ? s.username : '';
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
            if (f.elements.remember.checked) saveSettings(Object.assign(getSettings(), { server: BASE, username: u, password: p }));
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

    // ------------------------------------------------------------ file list
    async function loadList() {
      $('#smkv-list').innerHTML = '<div class="smkv-dim">Loading…</div>';
      try {
        S.files = (await api('list')).files;
        renderList();
      } catch (e) {
        $('#smkv-list').innerHTML = `<div class="smkv-dim">Error: ${esc(e.message)}</div>`;
      }
    }

    function renderList() {
      const q = $('#smkv-search').value.trim().toLowerCase();
      const words = q.split(/\s+/).filter(Boolean);
      const files = S.files.filter((f) => words.every((w) => f.path.toLowerCase().includes(w)));
      if (!files.length) { $('#smkv-list').innerHTML = '<div class="smkv-dim">No files</div>'; return; }
      let html = '', lastDir = null;
      for (const f of files) {
        if (f.dir !== lastDir) { lastDir = f.dir; html += `<div class="smkv-dir">${esc(f.dir || '/')}</div>`; }
        const pos = f.pos || GM_getValue('pos:' + f.path, 0);
        html += `<div class="smkv-item${S.file && S.file.path === f.path ? ' active' : ''}" data-path="${esc(f.path)}">
          <div class="smkv-name">${esc(f.name)}</div>
          <div class="smkv-sub">${fmtSize(f.size)}${pos ? ` · <span class="smkv-resume">⏵ ${fmtTime(pos)}</span>` : ''}</div></div>`;
      }
      $('#smkv-list').innerHTML = html;
    }

    $('#smkv-list').addEventListener('click', (e) => {
      const it = e.target.closest('.smkv-item');
      if (!it) return;
      const f = S.files.find((x) => x.path === it.dataset.path);
      if (f) openFile(f);
    });
    $('#smkv-search').addEventListener('input', renderList);
    $('#smkv-refresh').onclick = loadList;
    $('#smkv-settings').onclick = () => openSettings((n) => { S.maxh = n.maxh || S.maxh; selH.value = String(S.maxh); });
    $('#smkv-logout').onclick = async () => {
      await fetch(new URL('api/logout', BASE), { method: 'POST', credentials: 'same-origin' });
      const s = getSettings(); s.password = ''; saveSettings(s);
      location.reload();
    };

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
    function effectiveMode() {
      if (S.sub && !S.sub.text) return 'transcode'; // image subs are burned in
      if (S.vmode !== 'auto') return S.vmode;
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
      let saved = GM_getValue('tracks:' + path, null);
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
      GM_setValue('tracks:' + S.file.path, { audio: S.audio, sub: S.sub ? S.sub.idx : null });
      pushProgress({ path: S.file.path, audio: S.audio, sub: S.sub ? S.sub.idx : -1 });
    }

    // ------------------------------------------------------------ open file
    async function openFile(f) {
      savePos(true);
      S.file = f; S.info = null; S.cues = []; S.sub = null; S.forceTranscode = false; S.errCount = 0; S.subDelay = 0;
      S.loadSeq++;
      video.removeAttribute('src'); video.load();
      renderSubs(true); updateSubDelay();
      renderList();
      $('#smkv-empty').style.display = 'none';
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
      const pos = (server && server.pos) || GM_getValue('pos:' + f.path, 0);
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
        `<span class="smkv-badge ${mode}">${mode === 'copy' ? 'direct' : 'transcode ≤' + S.maxh + 'p'}</span>`,
      ].join(' · ');
    }

    // ------------------------------------------------------------ playback
    async function playAt(t, autoplay = true) {
      if (!S.file || !S.info) return;
      const seq = ++S.loadSeq;
      const dur = S.info.duration || 0;
      t = Math.max(0, dur ? Math.min(t, dur - 1) : t);
      const mode = effectiveMode();
      spinner(true);
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

    function seekTo(t) {
      if (!S.info) return;
      S.pendingTarget = Math.max(0, Math.min(t, (S.info.duration || 0) - 1));
      updateTime();
      clearTimeout(S.pendingTimer);
      S.pendingTimer = setTimeout(() => playAt(S.pendingTarget, true), 350);
    }
    const seekBy = (d) => seekTo(cur() + d);

    function togglePlay() {
      if (!S.file) return;
      if (video.paused) video.play().catch(() => {}); else video.pause();
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
      if (t > dur - 120) GM_deleteValue('pos:' + S.file.path);
      else if (t > 30) GM_setValue('pos:' + S.file.path, Math.floor(t));
      if (t > 30) {
        const f = S.files.find((x) => x.path === S.file.path);
        if (f) f.pos = t > dur - 120 ? 0 : t;
        pushProgress({ path: S.file.path, pos: t, duration: dur });
      }
    }
    window.addEventListener('pagehide', () => savePos(true));

    video.addEventListener('timeupdate', () => { updateTime(); savePos(false); });
    video.addEventListener('play', () => { ppBtn.textContent = '❚❚'; });
    video.addEventListener('pause', () => { ppBtn.textContent = '▶'; savePos(true); showControls(); });
    video.addEventListener('waiting', () => spinner(true));
    video.addEventListener('playing', () => { spinner(false); S.errCount = 0; });
    video.addEventListener('canplay', () => spinner(false));
    video.addEventListener('ended', () => {
      if (!S.file) return;
      GM_deleteValue('pos:' + S.file.path);
      pushProgress({ path: S.file.path, done: true });
      const f = S.files.find((x) => x.path === S.file.path);
      if (f) f.pos = 0;
      renderList();
    });
    video.addEventListener('error', async () => {
      if (!S.file || !video.getAttribute('src')) return;
      const t = cur();
      S.errCount++;
      if (S.errCount > 3) { spinner(false); toast('Playback failed: ' + (video.error?.message || 'unknown error'), 8000); return; }
      const me = await fetch(new URL('api/me', BASE), { credentials: 'same-origin' });
      if (!me.ok) { await ensureLogin(); return playAt(t, true); }
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
    video.volume = GM_getValue('volume', 1);
    vol.value = String(video.volume);
    vol.addEventListener('input', () => { video.volume = +vol.value; video.muted = false; GM_setValue('volume', video.volume); });
    $('#smkv-mute').onclick = () => { video.muted = !video.muted; $('#smkv-mute').textContent = video.muted ? '🔇' : '🔊'; };

    const toggleFs = () => (document.fullscreenElement ? document.exitFullscreen() : player.requestFullscreen()).catch?.(() => {});
    $('#smkv-fs').onclick = toggleFs;
    video.addEventListener('click', togglePlay);
    video.addEventListener('dblclick', toggleFs);

    let hideTimer = 0;
    function showControls() {
      player.classList.add('ctl');
      clearTimeout(hideTimer);
      hideTimer = setTimeout(() => { if (!video.paused) player.classList.remove('ctl'); }, 2500);
    }
    player.addEventListener('mousemove', showControls);
    player.addEventListener('touchstart', showControls, { passive: true });

    selAudio.onchange = () => {
      S.audio = +selAudio.value;
      saveTracks();
      playAt(cur(), !video.paused || video.readyState < 2);
    };
    selSub.onchange = () => setSub(selSub.value);
    selV.onchange = () => { S.vmode = selV.value; S.forceTranscode = false; if (S.file) playAt(cur(), !video.paused); };
    selH.value = String(S.maxh);
    selH.onchange = () => { S.maxh = +selH.value; if (S.file && effectiveMode() === 'transcode') playAt(cur(), !video.paused); else updateMeta(); };

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
      const k = e.key;
      const handled = {
        ' ': togglePlay, k: togglePlay,
        ArrowLeft: () => seekBy(-10), ArrowRight: () => seekBy(10),
        j: () => seekBy(-30), l: () => seekBy(30),
        ArrowUp: () => { video.volume = Math.min(1, video.volume + 0.05); vol.value = video.volume; },
        ArrowDown: () => { video.volume = Math.max(0, video.volume - 0.05); vol.value = video.volume; },
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
      if (wasBurn || isBurn) playAt(cur(), !video.paused || video.readyState < 2);
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
      loadList();
    })();
  }

  // ================================================================= markup
  const HTML = `
<div id="smkv-app">
  <aside id="smkv-side">
    <header>
      <b>StreamMKV</b><span class="smkv-sp"></span>
      <button id="smkv-refresh" title="Refresh list">⟳</button>
      <button id="smkv-settings" title="Settings">⚙</button>
      <button id="smkv-logout" title="Log out">⏻</button>
    </header>
    <input id="smkv-search" type="search" placeholder="Search…" autocomplete="off">
    <div id="smkv-list"></div>
  </aside>
  <main id="smkv-main">
    <div id="smkv-player">
      <video id="smkv-video" playsinline preload="auto"></video>
      <div id="smkv-subs"></div>
      <div id="smkv-spinner"></div>
      <div id="smkv-toast"></div>
      <div id="smkv-empty">Pick a file from the list</div>
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
      <h2 id="smkv-title"></h2>
      <div id="smkv-meta"></div>
      <div class="smkv-opts">
        <label>Audio <select id="smkv-audio"><option>—</option></select></label>
        <label>Subtitles <select id="smkv-sub"><option value="">Off</option></select></label>
        <label>Sub delay <span class="smkv-group"><button id="smkv-sd-minus" title="z">−</button><span id="smkv-sd">0.0s</span><button id="smkv-sd-plus" title="x">+</button></span></label>
        <label>Video <select id="smkv-vmode">
          <option value="auto">Auto</option><option value="copy">Direct (copy)</option><option value="transcode">Transcode H.264</option>
        </select></label>
        <label>Max height <select id="smkv-maxh">
          <option value="2160">2160p</option><option value="1440">1440p</option><option value="1080">1080p</option>
          <option value="720">720p</option><option value="480">480p</option>
        </select></label>
      </div>
      <div class="smkv-keys">Keys: space play · ←/→ ±10s · j/l ±30s · a audio · c subs · z/x sub delay · f fullscreen · m mute</div>
    </section>
  </main>
</div>
<div id="smkv-login"><form>
  <h2>Sign in to StreamMKV</h2>
  <input name="username" placeholder="Username" autocomplete="username">
  <input name="password" type="password" placeholder="Password" autocomplete="current-password">
  <label class="smkv-check"><input type="checkbox" name="remember" checked> Save in userscript settings</label>
  <button type="submit">Sign in</button>
  <div class="msg"></div>
</form></div>`;

  const CSS = `
html,body{margin:0;height:100%;background:#0d0f13;color:#c9cfd8;font:14px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif}
#smkv-app{display:grid;grid-template-columns:320px 1fr;height:100vh}
#smkv-side{display:flex;flex-direction:column;border-right:1px solid #1f242d;background:#11141a;min-height:0}
#smkv-side header{display:flex;align-items:center;gap:6px;padding:12px 12px 8px}
#smkv-side header b{color:#fff;font-size:16px;letter-spacing:.3px}
.smkv-sp{flex:1}
#smkv-app button,#smkv-login button{background:#1c212a;color:#c9cfd8;border:1px solid #2a313c;border-radius:6px;padding:5px 9px;cursor:pointer;font:inherit}
#smkv-app button:hover{background:#262c37}
#smkv-search{margin:0 12px 8px;padding:8px 10px;background:#0b0d11;border:1px solid #2a313c;border-radius:6px;color:#fff;font:inherit}
#smkv-list{overflow:auto;flex:1;padding-bottom:20px}
.smkv-dir{padding:10px 14px 4px;color:#6f7988;font-size:11px;text-transform:uppercase;letter-spacing:.5px;word-break:break-all}
.smkv-item{padding:7px 14px;cursor:pointer;border-left:3px solid transparent}
.smkv-item:hover{background:#171b22}
.smkv-item.active{background:#18202c;border-left-color:#4a9eff}
.smkv-name{color:#e3e7ed;word-break:break-word}
.smkv-sub{font-size:12px;color:#6f7988}
.smkv-resume{color:#7cc4ff}
.smkv-dim{padding:14px;color:#6f7988}
#smkv-main{display:flex;flex-direction:column;min-width:0;min-height:0;overflow:auto}
#smkv-player{position:relative;background:#000;aspect-ratio:16/9;max-height:78vh;width:100%;overflow:hidden;user-select:none}
#smkv-player:fullscreen{max-height:none;aspect-ratio:auto}
#smkv-video{width:100%;height:100%;display:block;background:#000}
#smkv-player:not(.ctl) #smkv-video{cursor:none}
#smkv-subs{position:absolute;left:5%;right:5%;bottom:7%;text-align:center;pointer-events:none;color:#fff;line-height:1.25;
  text-shadow:0 0 3px #000,0 0 3px #000,1px 1px 2px #000,-1px -1px 2px #000,1px -1px 2px #000,-1px 1px 2px #000;transition:bottom .2s}
#smkv-player.ctl #smkv-subs{bottom:max(7%,78px)}
#smkv-subs span{background:rgba(0,0,0,.18);padding:0 .2em;border-radius:3px;font-weight:500}
#smkv-controls{position:absolute;left:0;right:0;bottom:0;padding:24px 12px 8px;background:linear-gradient(transparent,rgba(0,0,0,.85));opacity:0;transition:opacity .2s}
#smkv-player.ctl #smkv-controls{opacity:1}
#smkv-controls .smkv-row{display:flex;align-items:center;gap:8px;margin-top:4px}
#smkv-controls button{background:transparent;border:none;color:#fff;font-size:15px;padding:4px 8px}
#smkv-controls button:hover{background:rgba(255,255,255,.12)}
#smkv-time{color:#e3e7ed;font-variant-numeric:tabular-nums;font-size:13px}
#smkv-seek{width:100%;margin:0;-webkit-appearance:none;appearance:none;height:5px;border-radius:3px;cursor:pointer;
  background:linear-gradient(to right,#4a9eff var(--p,0%),rgba(255,255,255,.25) var(--p,0%))}
#smkv-seek::-webkit-slider-thumb{-webkit-appearance:none;width:13px;height:13px;border-radius:50%;background:#fff}
#smkv-seek::-moz-range-thumb{width:13px;height:13px;border-radius:50%;background:#fff;border:none}
#smkv-vol{width:90px}
#smkv-spinner{position:absolute;left:50%;top:50%;width:44px;height:44px;margin:-22px;border:4px solid rgba(255,255,255,.2);border-top-color:#fff;border-radius:50%;
  animation:smkv-spin .8s linear infinite;display:none;pointer-events:none}
#smkv-spinner.show{display:block}
@keyframes smkv-spin{to{transform:rotate(360deg)}}
#smkv-toast{position:absolute;top:14px;left:50%;transform:translateX(-50%);background:rgba(20,24,31,.92);color:#e3e7ed;padding:8px 14px;border-radius:8px;
  font-size:13px;opacity:0;transition:opacity .2s;pointer-events:none;max-width:80%;text-align:center}
#smkv-toast.show{opacity:1;pointer-events:auto}
#smkv-toast button{margin-left:8px;padding:2px 8px}
#smkv-empty{position:absolute;inset:0;display:grid;place-items:center;color:#5d6673;font-size:16px;pointer-events:none}
#smkv-bar{padding:14px 18px 24px}
#smkv-title{margin:0 0 4px;font-size:17px;color:#fff;word-break:break-word}
#smkv-meta{color:#7d8696;font-size:13px}
.smkv-badge{display:inline-block;padding:0 7px;border-radius:9px;font-size:11px;background:#23402a;color:#8fe0a0}
.smkv-badge.transcode{background:#4a3a1c;color:#ffcf7a}
.smkv-opts{display:flex;flex-wrap:wrap;gap:12px 18px;margin-top:14px}
.smkv-opts label{display:flex;flex-direction:column;gap:4px;font-size:11px;color:#7d8696;text-transform:uppercase;letter-spacing:.5px}
.smkv-opts select{background:#151920;color:#e3e7ed;border:1px solid #2a313c;border-radius:6px;padding:6px 8px;font:13px system-ui,sans-serif;max-width:360px;text-transform:none}
.smkv-group{display:flex;align-items:center;gap:6px;text-transform:none}
#smkv-sd{min-width:44px;text-align:center;color:#e3e7ed;font-size:13px;font-variant-numeric:tabular-nums}
.smkv-keys{margin-top:16px;color:#566070;font-size:12px}
#smkv-login{position:fixed;inset:0;background:rgba(5,6,8,.85);display:none;place-items:center;z-index:10}
#smkv-login.show{display:grid}
#smkv-login form{background:#151920;border:1px solid #2a313c;border-radius:10px;padding:22px;width:min(340px,90vw);display:flex;flex-direction:column;gap:10px}
#smkv-login h2{margin:0 0 4px;font-size:17px;color:#fff}
#smkv-login input[name]{padding:9px 10px;background:#0b0d11;border:1px solid #2a313c;border-radius:6px;color:#fff;font:inherit}
#smkv-login button{background:#2b6fd6;border-color:#2b6fd6;color:#fff;padding:9px}
.smkv-check{font-size:13px;color:#8b95a5;display:flex;gap:6px;align-items:center}
#smkv-login .msg{color:#ff8a8a;font-size:13px;min-height:1em}
@media (max-width:820px){
  #smkv-app{grid-template-columns:1fr;grid-template-rows:auto 1fr;height:auto;min-height:100vh}
  #smkv-side{order:2;border-right:none;border-top:1px solid #1f242d;max-height:none}
  #smkv-main{order:1}
  #smkv-vol{display:none}
}`;

  if (isApp) bootApp();
})();
