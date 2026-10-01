import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';

// 验证会触发捕获的边界；实际音频隔离必须在浏览器实测，不能用此模拟替代。
let listener, tabURL = 'http://127.0.0.1:18763/?source=B', hasDocument = false;
const calls = [];
const chrome = {
  runtime: {id: 'probe', getURL: path => `chrome-extension://probe/${path}`,
    onMessage: {addListener: fn => { listener = fn; }},
    getContexts: async () => hasDocument ? [{}] : [],
    sendMessage: async message => { calls.push(message); return message.command === 'status' ? {active: false} : {active: true}; }},
  tabs: {get: async id => ({id, url: tabURL}), onRemoved: {addListener() {}}, onUpdated: {addListener() {}}},
  offscreen: {createDocument: async () => { hasDocument = true; }},
  tabCapture: {getMediaStreamId: async options => { calls.push({capture: options}); return 'test-stream'; }},
};
vm.runInNewContext(await fs.readFile(new URL('extension/worker.js', import.meta.url), 'utf8'), {chrome, URL});
const trusted = {id: 'probe', url: 'chrome-extension://probe/popup.html'};
const invoke = message => new Promise(resolve => {
  assert.equal(listener({target: 'worker', ...message}, trusted, resolve), true);
});
assert.equal(listener({target: 'worker'}, {id: 'foreign'}, () => assert.fail('不应响应非扩展来源')), undefined);
tabURL = 'https://example.com/';
assert.match((await invoke({command: 'gain', tabId: 7, gain: 0.2})).error, /仅允许/);
assert.equal(calls.length, 0);
tabURL = 'http://127.0.0.1:18763/?source=B';
assert.match((await invoke({command: 'gain', tabId: 7, gain: 5})).error, /无效增益/);
assert.equal(calls.length, 0);
assert.equal((await invoke({command: 'gain', tabId: 7, gain: 0.2})).active, true);
assert.deepEqual(calls.find(x => x.capture).capture.targetTabId, 7);
assert.equal(calls.at(-1).streamId, 'test-stream');
assert.equal(calls.at(-1).gain, 0.2);
console.log('通过：拒绝非扩展来源、非实验页及无效增益；捕获只针对明确指定的实验标签页。');

// 轨道状态观察不会启动采集，也不把软件静音、stop 当成“结束通话”的指令。
let poll;
const events = [], track = {readyState: 'live', enabled: true, muted: false};
const original = async () => ({getAudioTracks: () => [track]});
const mediaDevices = {getUserMedia: original};
const window = {postMessage: event => events.push(event), addEventListener() {}, removeEventListener() {}};
vm.runInNewContext(await fs.readFile(new URL('extension/input-main.js', import.meta.url), 'utf8'),
  {window, navigator: {mediaDevices}, location: {origin: 'https://chatgpt.com'},
    setInterval: fn => { poll = fn; }, clearInterval() {}, setTimeout() {}, clearTimeout() {}});
assert.equal(events.at(-1).value.calls, 0);
await mediaDevices.getUserMedia({audio: true});
assert.equal(events.at(-1).value.live, 1);
track.enabled = false; poll();
assert.equal(events.at(-1).value.enabled, 0);
assert.equal(events.at(-1).value.live, 1);
track.readyState = 'ended'; poll();
assert.equal(events.at(-1).value.live, 0);
assert.equal(events.at(-1).value.tracked, 1);
console.log('通过：启用不调用 getUserMedia；能分别观察有效、静音和已结束轨道。真实 ChatGPT 是否调用包装入口仍需实测。');

let receive;
const isolatedWindow = {addEventListener: (_, fn) => { receive = fn; }, removeEventListener() {}};
vm.runInNewContext(await fs.readFile(new URL('extension/input-bridge.js', import.meta.url), 'utf8'), {window: isolatedWindow});
receive({source: isolatedWindow, data: {type: 'shenglin-input-probe', value: events.at(-1).value}});
assert.equal(isolatedWindow.__shenglinInputProbeState.events.length, 1);
assert.equal(isolatedWindow.__shenglinInputProbeState.protected, true);
// 新 service worker 不拥有这份记录；对同一文档重复启用不能清空历史。
vm.runInNewContext(await fs.readFile(new URL('extension/input-bridge.js', import.meta.url), 'utf8'), {window: isolatedWindow});
assert.equal(isolatedWindow.__shenglinInputProbeState.events.length, 1);
receive({source: isolatedWindow, data: {type: 'shenglin-input-probe', value: {stopped: true}}});
assert.equal(isolatedWindow.__shenglinInputProbeState.protected, false);
assert.equal(isolatedWindow.__shenglinInputProbeState.events.length, 1);
console.log('通过：记录属于文档，不依赖后台存活；停止保留实验历史并撤销保护标记。');
