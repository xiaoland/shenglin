// Executes the shipped observer and replay logic in a VM; no microphone or browser is opened.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const root = path.join(__dirname, '..', 'BrowserExtension');
async function observer() {
  const listeners = new Map(), timers = [];
  let nextStream;
  const media = {getUserMedia: async () => nextStream};
  const original = media.getUserMedia;
  const window = {postMessage(data) { for (const fn of listeners.get('message') || []) fn({source: window, data}); },
    addEventListener(type, fn) { const all = listeners.get(type) || []; all.push(fn); listeners.set(type, all); },
    removeEventListener(type, fn) { listeners.set(type, (listeners.get(type) || []).filter(value => value !== fn)); }};
  const context = vm.createContext({window, navigator: {mediaDevices: media}, location: {origin: 'https://chatgpt.com'},
    Date, Set, setInterval: fn => { timers.push(fn); return timers.length; }, clearInterval() {}});
  for (const file of ['input-bridge.js', 'input-main.js']) vm.runInContext(fs.readFileSync(path.join(root, file), 'utf8'), context);
  const state = window.__shenglinInputState;
  assert.equal(state.input, 'unknown'); // Late injection cannot claim no existing input.
  const disabled = {readyState: 'live', enabled: false, muted: false};
  const muted = {readyState: 'live', enabled: true, muted: true};
  nextStream = {getAudioTracks: () => [disabled, muted]};
  const stream = await media.getUserMedia();
  assert.equal(stream, nextStream);
  assert.equal(state.input, 'idle'); // Separate enabled/unmuted counts must not fabricate one active track.
  disabled.enabled = true; timers[0](); assert.equal(state.input, 'active');
  disabled.enabled = false; timers[0](); assert.equal(state.input, 'idle');
  disabled.enabled = true; disabled.readyState = muted.readyState = 'ended';
  timers[0](); assert.equal(state.input, 'idle');
  window.postMessage({type: 'shenglin-input-stop'});
  assert.equal(media.getUserMedia, original);
}
async function replay() {
  let listener, checkLease, now = 1000, stopped = 0, closed = 0, currentGain;
  const track = {stop() { stopped++; }, addEventListener() {}};
  const stream = {getTracks: () => [track], getAudioTracks: () => [track]};
  class AudioContext {
    constructor() { this.state = 'running'; this.currentTime = 0; this.destination = {}; }
    createMediaStreamSource() { return {connect(node) { return node; }}; }
    createGain() { return {gain: {value: 1, setTargetAtTime(value) { currentGain = value; }}, connect() {}}; }
    async resume() {}
    addEventListener() {}
    async close() { this.state = 'closed'; closed++; }
  }
  const chrome = {runtime: {id: 'test', getURL: file => 'chrome-extension://test/' + file,
    onMessage: {addListener(fn) { listener = fn; }}}};
  const context = vm.createContext({Map, AudioContext, navigator: {mediaDevices: {getUserMedia: async () => stream}},
    Date: {now: () => now}, chrome, setInterval(fn) { checkLease = fn; }});
  vm.runInContext(fs.readFileSync(path.join(root, 'offscreen.js'), 'utf8'), context);
  const send = message => new Promise(resolve => listener({...message, target: 'audio'},
    {id: 'test', url: chrome.runtime.getURL('worker.js')}, resolve));
  assert.equal((await send({command: 'capture', tabId: 7, streamId: 'grant'})).active, true);
  await send({command: 'targets', gain: 0.2}); assert.equal(currentGain, 0.2);
  assert.ok((await send({command: 'targets', gain: NaN})).error);
  now = 5999; checkLease(); assert.equal(stopped, 0);
  now = 6000; checkLease(); await Promise.resolve();
  assert.equal(stopped, 1); assert.equal(closed, 1);
  assert.equal((await send({command: 'status', tabId: 7})).active, false);
  await send({command: 'capture', tabId: 8, streamId: 'new-grant'});
  await send({command: 'release-all'});
  assert.equal(stopped, 2); assert.equal(closed, 2);
}
(async () => { await observer(); await replay(); console.log('通过：同轨有效输入、软件静音、结束、未知、原方法恢复、网页增益、租约与断线释放。'); })().catch(error => { console.error(error); process.exit(1); });

async function worker() {
  const pages = new Map([[7, {url: 'https://chatgpt.com/c/example', documentId: 'doc-a', input: 'active'}],
                         [8, {url: 'https://example.com/music', documentId: 'doc-b', input: 'idle'}]]);
  const captured = new Set(), frames = [];
  let handler, onUpdated, onRemoved, timer, onNativeMessage, onNativeDisconnect;
  let connections = 0;
  const chrome = {
    runtime: {id: 'test', getURL: file => 'chrome-extension://test/' + file,
      getContexts: async () => [{}],
      sendMessage: async message => {
        if (message.command === 'capture') { captured.add(message.tabId); return {active: true}; }
        if (message.command === 'release') captured.delete(message.tabId);
        if (message.command === 'release-all') captured.clear();
        if (message.command === 'status') return {active: captured.has(message.tabId)};
        return {};
      },
      connectNative: () => { connections++; let disconnected = false; return {onMessage: {addListener(fn) { onNativeMessage = fn; }},
        onDisconnect: {addListener(fn) { onNativeDisconnect = fn; }},
        postMessage(frame) { assert.equal(disconnected, false); frames.push(frame); },
        disconnect() { disconnected = true; }}; },
      onMessage: {addListener(fn) { handler = fn; }}},
    scripting: {executeScript: async request => {
      const page = pages.get(request.target.tabId);
      if (!page) throw Error('tab closed');
      return [{documentId: page.documentId, result: {input: page.input, updated: Date.now()}}];
    }},
    tabs: {get: async id => pages.get(id),
      onUpdated: {addListener(fn) { onUpdated = fn; }}, onRemoved: {addListener(fn) { onRemoved = fn; }}},
    tabCapture: {getMediaStreamId: async () => 'user-grant'}, offscreen: {createDocument: async () => {}}
  };
  const context = vm.createContext({chrome, Map, Set, URL, Date, Number, Error, Promise,
    setInterval(fn) { timer = fn; return 1; }, clearInterval() {}});
  vm.runInContext(fs.readFileSync(path.join(root, 'worker.js'), 'utf8'), context);
  const send = message => new Promise(resolve => handler({...message, target: 'worker'},
    {id: 'test', url: chrome.runtime.getURL('popup.html')}, resolve));
  const acknowledge = () => onNativeMessage({ok: true, browser: {gain: 0.2, leaseSeconds: 5}});
  async function drain() { for (let i = 0; i < 40; i++) await Promise.resolve(); }
  await send({command: 'conversation', tabId: 7});
  assert.equal(frames.at(-1).pages[0].input, 'active'); acknowledge();
  await send({command: 'background', tabId: 8}); assert.equal(captured.has(8), true); acknowledge();
  pages.get(7).input = 'idle'; timer(); await drain();
  assert.equal(frames.at(-1).pages.find(page => page.id === 'doc-a').input, 'idle'); acknowledge();
  // Same document SPA navigation keeps conversation participation.
  onUpdated(7, {url: 'https://chatgpt.com/c/another', status: 'loading'}); await drain();
  assert.ok(frames.at(-1).pages.some(page => page.id === 'doc-a')); acknowledge();
  // Cross-site navigation ends participation even after activeTab permission disappears.
  pages.delete(7); onUpdated(7, {url: 'https://elsewhere.example/'}); await drain();
  assert.ok(!frames.at(-1).pages.some(page => page.id === 'doc-a')); acknowledge();
  onNativeDisconnect(); await drain(); assert.equal(captured.size, 0);
  onRemoved(8); await drain();
  pages.set(7, {url: 'https://chatgpt.com/', documentId: 'new-doc', input: 'idle'});
  await send({command: 'conversation', tabId: 7});
  assert.ok(connections >= 2);
  assert.equal(frames.at(-1).pages[0].id, 'new-doc'); acknowledge();
  pages.delete(7); onUpdated(7, {status: 'loading'}); await drain();
  assert.ok(!frames.at(-1).pages.some(page => page.id === 'new-doc'));
  console.log('通过：正式 worker 逐页参与、静音、SPA、跨站导航、关闭、Native Messaging 与断线释放。');
}
worker().catch(error => { console.error(error); process.exitCode = 1; });
