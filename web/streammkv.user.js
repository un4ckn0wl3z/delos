// ==UserScript==
// @name         StreamMKV (retired — no longer needed)
// @namespace    https://github.com/un4ckn0wl3z/streammkv
// @version      2.6.5
// @description  StreamMKV is now a website: open your server's address in any browser. You can remove this userscript.
// @author       un4ckn0wl3z
// @homepageURL  https://github.com/un4ckn0wl3z/delos
// @updateURL    https://raw.githubusercontent.com/un4ckn0wl3z/delos/main/web/streammkv.user.js
// @downloadURL  https://raw.githubusercontent.com/un4ckn0wl3z/delos/main/web/streammkv.user.js
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
 * Since 2.0 the StreamMKV server serves the whole web app itself — just open
 * http://your-server:port/ (installable as an app). This userscript is kept
 * only so that installed copies don't break:
 *  - on a 2.x server it does nothing except suggest removing it (once);
 *  - on an older server (page marked streammkv-app) it runs that server's own
 *    userscript, so things keep working until the server is updated.
 */
(function () {
  'use strict';
  const note = (html) => {
    const d = document.createElement('div');
    d.innerHTML = html;
    d.style.cssText = 'position:fixed;left:50%;bottom:24px;transform:translateX(-50%);z-index:2147483647;background:#1d2430;color:#e6e9ee;border:1px solid #2f3a4a;border-radius:10px;padding:10px 14px;font:14px system-ui,sans-serif;box-shadow:0 8px 30px rgba(0,0,0,.5);max-width:90vw';
    d.onclick = () => d.remove();
    document.body.appendChild(d);
    setTimeout(() => d.remove(), 12000);
  };
  if (document.querySelector('meta[name="streammkv-web"]')) {
    if (!GM_getValue('retiredNote', false)) {
      GM_setValue('retiredNote', true);
      note('StreamMKV no longer needs Tampermonkey — you can remove the <b>StreamMKV</b> userscript. (Click to close)');
    }
    return;
  }
  if (!document.querySelector('meta[name="streammkv-app"]')) return;
  // an older server: run the userscript it ships
  fetch(new URL('streammkv.user.js', location.href.split(/[?#]/)[0]), { credentials: 'same-origin' })
    .then((r) => r.text())
    .then((code) => {
      if (/@name\s+StreamMKV \(retired/.test(code)) return;
      new Function('GM_getValue', 'GM_setValue', 'GM_deleteValue', 'GM_registerMenuCommand', 'GM_openInTab', code)(
        GM_getValue, GM_setValue, GM_deleteValue, GM_registerMenuCommand, GM_openInTab);
      setTimeout(() => note('Update your StreamMKV server: since 2.0 it works in any browser without Tampermonkey.'), 4000);
    })
    .catch(() => note('StreamMKV: update your server — since 2.0 it works in any browser without Tampermonkey.'));
})();
