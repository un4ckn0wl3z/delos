/*
 * StreamMKV in-browser player engine.
 *
 * Reads the original file straight from the server (HTTP Range on api/raw),
 * demuxes it in the browser (Mediabunny), decodes video with the device's
 * WebCodecs decoder (usually hardware) and audio with WebCodecs or — for
 * AC-3 / E-AC-3 / DTS / TrueHD — FFmpeg compiled to WebAssembly. The server
 * only sends bytes: no ffmpeg, no stream slot, instant seeking, any audio track.
 *
 * The engine behaves like a small <video> element so the player UI can drive
 * either: play() / pause() / currentTime / paused / volume / muted / duration,
 * events timeupdate · play · pause · waiting · playing · ended · error.
 * The audio clock (AudioContext) is the master; video frames follow it. While
 * data is missing the AudioContext is suspended, which freezes the clock.
 */
import { Input, ALL_FORMATS, UrlSource, VideoSampleSink, AudioBufferSink } from 'mediabunny';

const EXT = {
  ac3: 'ac3', eac3: 'ac3', dts: 'dts', truehd: 'truehd',
};
const extLoaded = {};
async function ensureAudioExtension(codec, base) {
  const ext = EXT[codec];
  if (!ext || extLoaded[ext]) return;
  extLoaded[ext] = (async () => {
    const m = await import(new URL(`vendor/mediabunny-${ext}.min.mjs`, base).href);
    if (ext === 'ac3') m.registerAc3Decoder();
    if (ext === 'dts') m.registerDtsDecoder();
    if (ext === 'truehd') m.registerTrueHdDecoder();
  })();
  await extLoaded[ext];
}

/** Can this browser run the engine at all? */
export function engineSupported() {
  return typeof VideoDecoder !== 'undefined' && typeof AudioDecoder !== 'undefined'
    && typeof AudioContext !== 'undefined' && typeof WebAssembly !== 'undefined';
}

// AudioContext.resume()/suspend() promises can stay pending when they race each
// other — never let playback wait on them for long.
const settle = (p, ms = 250) => Promise.race([Promise.resolve(p).catch(() => {}), new Promise((r) => setTimeout(r, ms))]);

export class WasmPlayer extends EventTarget {
  /**
   * @param {HTMLCanvasElement} canvas  where video is drawn (sized to its CSS box)
   * @param {string} base               the app's base URL (for the WASM extensions)
   */
  constructor(canvas, base) {
    super();
    this.canvas = canvas;
    this.base = base;
    this.ctx2d = canvas.getContext('2d', { alpha: false, desynchronized: true });
    this.input = null;
    this.videoTrack = null;
    this.audioTracks = [];
    this.audioIndex = 0;
    this.duration = 0;
    this.readyState = 0;
    this.paused = true;
    this._volume = 1;
    this._muted = false;
    this._gen = 0;            // bumps on every load/seek/track change: stale loops stop
    this._clockBase = 0;      // playback time when the clock (re)started
    this._ctxBase = 0;        // AudioContext time at that moment
    this._ac = null;
    this._gain = null;
    this._nodes = new Set();
    this._scheduledUntil = 0; // playback time up to which audio is queued
    this._audioDone = false;
    this._stalled = false;
    this._frame = null;       // next video sample waiting for its time
    this._lastDrawn = -1;
    this._videoIter = null;
    this._audioIter = null;
    this._lastTU = 0;
    this._raf = 0;
    this._fit();
    this._ro = new ResizeObserver(() => this._fit());
    this._ro.observe(canvas);
  }

  // ------------------------------------------------------------ <video>-like surface
  get currentTime() { return this._now(); }
  get volume() { return this._volume; }
  set volume(v) { this._volume = Math.max(0, Math.min(1, v)); this._applyGain(); }
  get muted() { return this._muted; }
  set muted(v) { this._muted = !!v; this._applyGain(); }
  get error() { return this._error ? { message: this._error } : null; }

  _emit(type, detail) { this.dispatchEvent(new CustomEvent(type, { detail })); }

  /** Open a file. Throws (with a reason) if this browser can't decode it. */
  async load(url, { audioIndex = 0, start = 0, duration = 0 } = {}) {
    this._teardown();
    const gen = ++this._gen;
    this.input = new Input({
      formats: ALL_FORMATS,
      source: new UrlSource(url, { requestInit: { credentials: 'same-origin' }, maxCacheSize: 96 * 1024 * 1024, parallelism: 2 }),
    });
    const [video, audios] = await Promise.all([this.input.getPrimaryVideoTrack(), this.input.getAudioTracks()]);
    if (gen !== this._gen) return;
    if (!video) throw new Error('no video track');
    if (!(await video.canDecode())) throw new Error(`this browser can't decode ${video.codec || 'the'} video`);
    this.videoTrack = video;
    this.audioTracks = audios;
    this.duration = duration || (await this.input.computeDuration().catch(() => 0));
    await this._useAudio(audioIndex);
    // fetch decoders for the other audio tracks in the background (instant switching)
    for (const t of audios) ensureAudioExtension(t.codec, this.base).catch(() => {});
    if (gen !== this._gen) return;
    this.readyState = 4;
    this._clockBase = Math.max(0, start);
    await this._startVideo(this._clockBase, gen);
    this._loop();
    this._emit('loadedmetadata');
  }

  async _useAudio(i) {
    this.audioIndex = i;
    this.audioSink = null;
    const t = this.audioTracks[i];
    if (!t) return;
    await ensureAudioExtension(t.codec, this.base);
    if (!(await t.canDecode())) throw new Error(`this browser can't decode ${t.codec} audio`);
    this.audioSink = new AudioBufferSink(t);
  }

  /** Switch audio track at the current position. */
  async setAudioTrack(i) {
    const t = this._now();
    await this._useAudio(i);
    await this._restart(t);
  }

  async play() {
    if (!this.input || !this.paused) return;
    if (this._now() >= this.duration - 0.05 && this.duration) await this._restart(0);
    const t = this._now(); // read while still paused
    this._ensureAudioContext();
    await settle(this._ac.resume());
    if (!this.paused) return;
    this._stalled = false;
    this._clockBase = t;
    this._ctxBase = this._ac.currentTime;
    this.paused = false;
    this._scheduledUntil = this._clockBase;
    this._startAudio(this._clockBase, this._gen);
    this._emit('play');
    this._emit('playing');
  }

  pause() {
    if (this.paused) return;
    this._clockBase = this._now();
    this.paused = true;
    this._stopAudio();
    this._emit('pause');
  }

  /** Jump to t seconds (keeps playing if it was). */
  async seek(t) {
    t = Math.max(0, Math.min(t, (this.duration || t) - 0.05));
    await this._restart(t);
    this._emit('seeked');
  }

  destroy() {
    this._teardown();
    this._ro.disconnect();
    if (this._ac) this._ac.close().catch(() => {});
    this._ac = null;
  }

  // ------------------------------------------------------------ clock
  _now() {
    if (this.paused || !this._ac) return this._clockBase;
    return this._clockBase + Math.max(0, this._ac.currentTime - this._ctxBase);
  }

  _ensureAudioContext() {
    if (this._ac) return;
    this._ac = new AudioContext({ latencyHint: 'playback' });
    this._gain = this._ac.createGain();
    this._gain.connect(this._ac.destination);
    this._applyGain();
  }
  _applyGain() { if (this._gain) this._gain.gain.value = this._muted ? 0 : this._volume; }

  async _restart(t) {
    const gen = ++this._gen;
    const wasPlaying = !this.paused;
    this._stopAudio();
    this._clockBase = t;
    if (this._ac) this._ctxBase = this._ac.currentTime;
    this._scheduledUntil = t;
    this._stalled = false;
    if (this._ac && wasPlaying) await settle(this._ac.resume());
    await this._startVideo(t, gen);
    if (gen !== this._gen) return;
    if (wasPlaying) {
      this._clockBase = t;
      this._ctxBase = this._ac.currentTime;
      this._startAudio(t, gen);
    }
    this._emit('timeupdate');
  }

  // ------------------------------------------------------------ video
  async _startVideo(t, gen) {
    if (this._videoIter) { this._videoIter.return().catch(() => {}); this._videoIter = null; }
    if (this._frame) { this._frame.close(); this._frame = null; }
    const sink = this._videoSink || (this._videoSink = new VideoSampleSink(this.videoTrack));
    this._videoIter = sink.samples(t);
    // show the frame at t right away (also when paused)
    const first = await this._nextFrame(gen);
    if (gen !== this._gen) { first && first.close(); return; }
    if (first) { this._draw(first); first.close(); }
    this._frame = await this._nextFrame(gen);
    if (gen !== this._gen && this._frame) { this._frame.close(); this._frame = null; }
  }

  async _nextFrame(gen) {
    const it = this._videoIter;
    if (!it) return null;
    try {
      const r = await it.next();
      if (gen !== this._gen) { r.value && r.value.close(); return null; }
      return r.done ? null : r.value;
    } catch (e) {
      if (gen === this._gen) this._fail(e);
      return null;
    }
  }

  _fit() {
    const r = this.canvas.getBoundingClientRect();
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const w = Math.max(2, Math.round(r.width * dpr)), h = Math.max(2, Math.round(r.height * dpr));
    if (this.canvas.width !== w || this.canvas.height !== h) {
      this.canvas.width = w; this.canvas.height = h;
      if (this._lastSample) this._redraw();
    }
  }

  _draw(sample) {
    const c = this.ctx2d;
    c.fillStyle = '#000';
    c.fillRect(0, 0, this.canvas.width, this.canvas.height);
    sample.drawWithFit(c, { fit: 'contain' });
    this._lastDrawn = sample.timestamp;
    // keep a copy for redraws on resize (cheap: a VideoFrame reference)
    try { if (this._lastSample) this._lastSample.close(); this._lastSample = sample.clone(); } catch { this._lastSample = null; }
  }
  _redraw() {
    const c = this.ctx2d;
    c.fillStyle = '#000';
    c.fillRect(0, 0, this.canvas.width, this.canvas.height);
    try { this._lastSample.drawWithFit(c, { fit: 'contain' }); } catch { /* closed */ }
  }

  _fetchingFrame = false;
  _loop() {
    cancelAnimationFrame(this._raf);
    const tick = () => {
      this._raf = requestAnimationFrame(tick);
      if (!this.input) return;
      const gen = this._gen;
      const t = this._now();
      // far behind (tab was hidden, slow device): jump the video to now instead of decoding every frame
      if (!this.paused && !this._jumping && this._frame && this._frame.timestamp < t - 1.0) {
        this._jumping = true;
        this._gen++; // stops the frame fetch in flight
        const g = this._gen, at = t;
        this._startVideo(at, g).finally(() => { this._jumping = false; });
        // the audio iterator belongs to the old generation: restart it on the new one
        this._stopAudio();
        this._clockBase = this._now(); this._ctxBase = this._ac.currentTime;
        this._scheduledUntil = this._clockBase;
        this._startAudio(this._clockBase, g);
        return;
      }
      // draw the newest frame that is due; drop late ones
      if (this._frame && this._frame.timestamp <= t && !this._fetchingFrame) {
        this._fetchingFrame = true;
        (async () => {
          let f = this._frame; this._frame = null;
          while (f) {
            const next = await this._nextFrame(gen);
            if (gen !== this._gen) { f.close(); next && next.close(); break; }
            if (next && next.timestamp <= this._now()) { f.close(); f = next; continue; } // late: skip
            this._draw(f); f.close();
            this._frame = next;
            break;
          }
          this._fetchingFrame = false;
        })();
      }
      if (this.paused) return;
      // buffering: audio ran out (or video is far behind) → freeze the clock
      const audioShort = this.audioSink && !this._audioDone && t > this._scheduledUntil - 0.04;
      const videoShort = !this._frame && this._fetchingFrame && t - this._lastDrawn > 0.6;
      if (!this._stalled && (audioShort || videoShort)) {
        this._stalled = true;
        this._ac.suspend().catch(() => {});
        this._emit('waiting');
      } else if (this._stalled && !(audioShort || videoShort)) {
        this._stalled = false;
        this._ac.resume().catch(() => {});
        this._emit('playing');
      }
      if (performance.now() - this._lastTU > 250) { this._lastTU = performance.now(); this._emit('timeupdate'); }
      const end = this.duration || 0;
      if (end && t >= end - 0.05 && !this._frame && (this._audioDone || !this.audioSink)) {
        this._clockBase = end;
        this.paused = true;
        this._stopAudio();
        this._emit('timeupdate');
        this._emit('ended');
      }
    };
    this._raf = requestAnimationFrame(tick);
  }

  // ------------------------------------------------------------ audio
  _startAudio(t, gen) {
    this._audioDone = !this.audioSink;
    if (!this.audioSink) return;
    const iter = this._audioIter = this.audioSink.buffers(t);
    (async () => {
      try {
        for await (const { buffer, timestamp } of iter) {
          if (gen !== this._gen || this.paused) break;
          const node = this._ac.createBufferSource();
          node.buffer = buffer;
          node.connect(this._gain);
          const when = this._ctxBase + (timestamp - this._clockBase);
          if (when >= this._ac.currentTime) node.start(when);
          else {
            const off = this._ac.currentTime - when;
            if (off < buffer.duration) node.start(this._ac.currentTime, off);
          }
          this._nodes.add(node);
          node.onended = () => this._nodes.delete(node);
          this._scheduledUntil = Math.max(this._scheduledUntil, timestamp + buffer.duration);
          // stay ~1.5 s ahead of the clock (more in a background tab: timers are throttled there)
          while (gen === this._gen && !this.paused && this._scheduledUntil - this._now() > (document.hidden ? 8 : 1.5)) {
            await new Promise((r) => setTimeout(r, 100));
          }
        }
        if (gen === this._gen) this._audioDone = true;
      } catch (e) {
        if (gen === this._gen) this._fail(e);
      }
    })();
  }

  _stopAudio() {
    if (this._audioIter) { this._audioIter.return().catch(() => {}); this._audioIter = null; }
    for (const n of this._nodes) { try { n.stop(); } catch { /* not started */ } }
    this._nodes.clear();
  }

  _fail(e) {
    this._error = (e && e.message) || String(e);
    this.pause();
    this._emit('error', this._error);
  }

  _teardown() {
    this._gen++;
    cancelAnimationFrame(this._raf);
    this._stopAudio();
    if (this._videoIter) { this._videoIter.return().catch(() => {}); this._videoIter = null; }
    if (this._frame) { this._frame.close(); this._frame = null; }
    if (this._lastSample) { try { this._lastSample.close(); } catch { /* ignore */ } this._lastSample = null; }
    if (this.input) { try { this.input.dispose(); } catch { /* ignore */ } }
    this.input = null; this._videoSink = null; this.audioSink = null;
    this.paused = true; this.readyState = 0; this._error = null;
    this._clockBase = 0;
  }
}
