// Owns a capture from the first permission request through its final cleanup.
// A tab ID can be reused; callbacks must belong to the exact session instance.
export class CaptureSessions {
  #sessions = new Map();
  constructor({getUserMedia, createContext, now = Date.now}) {
    this.getUserMedia = getUserMedia;
    this.createContext = createContext;
    this.now = now;
  }
  active(id) { return this.#sessions.get(id)?.active === true; }
  async #dispose(session) {
    session.stream?.getTracks().forEach(track => track.stop());
    session.stream = undefined;
    const context = session.context;
    session.context = undefined;
    if (context && context.state !== 'closed') await context.close();
  }
  async release(id, expected = this.#sessions.get(id)) {
    if (!expected || this.#sessions.get(id) !== expected) return;
    this.#sessions.delete(id); // Invalidate before stopping resources that can emit callbacks.
    await this.#dispose(expected);
  }
  async releaseAll() {
    await Promise.all([...this.#sessions.keys()].map(id => this.release(id)));
  }
  targets(gain) {
    if (!Number.isFinite(gain) || gain < 0 || gain > 1) throw Error('增益无效');
    for (const session of this.#sessions.values()) {
      session.expires = this.now() + 5000;
      session.target = gain;
      session.gain?.gain.setTargetAtTime(gain, session.context.currentTime, 0.02);
    }
  }
  expire() {
    return Promise.all([...this.#sessions].filter(([, s]) => s.expires <= this.now())
      .map(([id, s]) => this.release(id, s)));
  }
  async capture(id, streamId) {
    if (!Number.isInteger(id) || !streamId) throw Error('捕获参数无效');
    const previous = this.#sessions.get(id);
    const session = {expires: this.now() + 5000, target: 1, active: false};
    this.#sessions.set(id, session);
    const current = () => this.#sessions.get(id) === session;
    try {
      if (previous) await this.#dispose(previous);
      if (!current()) return {active: false};
      session.stream = await this.getUserMedia({audio: {mandatory: {
        chromeMediaSource: 'tab', chromeMediaSourceId: streamId}}, video: false});
      if (!current()) { await this.#dispose(session); return {active: false}; }
      const context = session.context = this.createContext();
      const source = context.createMediaStreamSource(session.stream);
      const gain = session.gain = context.createGain();
      gain.gain.value = session.target;
      source.connect(gain).connect(context.destination);
      const ended = () => { this.release(id, session).catch(() => {}); };
      session.stream.getAudioTracks().forEach(track => track.addEventListener('ended', ended, {once: true}));
      await context.resume();
      if (!current()) { await this.#dispose(session); return {active: false}; }
      if (context.state !== 'running') throw Error('网页重放未运行');
      context.addEventListener('statechange', () => {
        if (context.state !== 'running') ended();
      });
      session.active = true;
      return {active: true};
    } catch (error) {
      const cancelled = !current();
      if (current()) this.#sessions.delete(id);
      await this.#dispose(session);
      if (cancelled) return {active: false};
      throw error;
    }
  }
}
