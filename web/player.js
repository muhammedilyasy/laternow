/* Minimal YouTube embed controller over the documented postMessage protocol.
 * Same surface as the subset of YT.Player that Later Now uses, without loading youtube.com/iframe_api,
 * so it also runs in a Chrome extension page (MV3 forbids remote scripts). */
(() => {
  const ORIGIN = 'https://www.youtube.com';
  const State = {UNSTARTED: -1, ENDED: 0, PLAYING: 1, PAUSED: 2, BUFFERING: 3, CUED: 5};

  class LaterNowPlayer {
    constructor(host, {onReady, onStateChange, onError, vars = {}} = {}) {
      this.cb = {onReady, onStateChange, onError};
      this.ready = false; this.queue = [];
      this.info = {currentTime: 0, playerState: State.UNSTARTED, muted: true, playbackRate: 1};
      this.infoAt = performance.now();
      const p = new URLSearchParams({enablejsapi: 1, origin: location.origin, widgetid: 1, ...vars});
      const f = this.iframe = document.createElement('iframe');
      f.src = `${ORIGIN}/embed/?${p}`;
      f.allow = 'autoplay; encrypted-media; picture-in-picture';
      f.title = 'YouTube video player';
      f.style.cssText = 'width:100%;height:100%;border:0;display:block';
      host.appendChild(f);
      this._onMsg = e => this._message(e);
      addEventListener('message', this._onMsg);
      // Ask the player to start talking to us. Repeat until it answers.
      f.addEventListener('load', () => {
        clearInterval(this._hello);
        this._hello = setInterval(() => this._post({event: 'listening', id: 1, channel: 'widget'}), 250);
      });
    }

    _post(msg) { try { this.iframe.contentWindow.postMessage(JSON.stringify(msg), ORIGIN); } catch {} }
    _cmd(func, args = []) {
      const m = {event: 'command', func, args, id: 1, channel: 'widget'};
      this.ready ? this._post(m) : this.queue.push(m);
    }
    _message(e) {
      if (e.source !== this.iframe.contentWindow) return;
      let d; try { d = typeof e.data === 'string' ? JSON.parse(e.data) : e.data; } catch { return; }
      if (!d || !d.event) return;
      if (d.event === 'initialDelivery' || d.event === 'infoDelivery') {
        const prev = this.info.playerState;
        if (d.info) { Object.assign(this.info, d.info); if ('currentTime' in d.info) this.infoAt = performance.now(); }
        if (d.info && 'playerState' in d.info && d.info.playerState !== prev) this.cb.onStateChange?.({data: d.info.playerState});
      } else if (d.event === 'onReady') {
        if (this.ready) return;
        clearInterval(this._hello); this.ready = true;
        for (const ev of ['onStateChange', 'onError', 'onPlaybackRateChange']) this._post({event: 'command', func: 'addEventListener', args: [ev], id: 1, channel: 'widget'});
        this.queue.splice(0).forEach(m => this._post(m));
        this.cb.onReady?.();
      } else if (d.event === 'onStateChange') {
        if (d.info === this.info.playerState) return;
        this.info.playerState = d.info; this.infoAt = performance.now();
        this.cb.onStateChange?.({data: d.info});
      } else if (d.event === 'onError') {
        this.cb.onError?.({data: d.info});
      } else if (d.event === 'onPlaybackRateChange') {
        this.info.playbackRate = d.info;
      }
    }

    loadVideoById(o) {
      this.info.currentTime = o.startSeconds || 0; this.infoAt = performance.now();
      this._cmd('loadVideoById', [o]);
    }
    playVideo() { this._cmd('playVideo'); }
    pauseVideo() { this._cmd('pauseVideo'); }
    seekTo(t, ahead = true) { this.info.currentTime = t; this.infoAt = performance.now(); this._cmd('seekTo', [t, ahead]); }
    mute() { this.info.muted = true; this._cmd('mute'); }
    unMute() { this.info.muted = false; this._cmd('unMute'); }
    isMuted() { return !!this.info.muted; }
    setVolume(v) { this._cmd('setVolume', [v]); }
    setPlaybackRate(r) { this.info.playbackRate = r; this._cmd('setPlaybackRate', [r]); }
    getPlayerState() { return this.info.playerState; }
    // infoDelivery arrives a few times a second; interpolate in between for smooth captions.
    getCurrentTime() {
      const i = this.info;
      return i.playerState === State.PLAYING ? i.currentTime + (performance.now() - this.infoAt) / 1000 * (i.playbackRate || 1) : i.currentTime;
    }
  }

  LaterNowPlayer.State = State;
  window.LaterNowPlayer = LaterNowPlayer;
})();
