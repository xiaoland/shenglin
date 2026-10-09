// Exercise the shipped popup's visible contracts without browser or microphone access.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const root = path.join(__dirname, '..', 'BrowserExtension');
async function popup(url, response) {
  const elements = new Map();
  function node(id) {
    if (!elements.has(id)) elements.set(id, {textContent: '', hidden: false, disabled: false, dataset: {},
      attributes: {}, listeners: {}, setAttribute(key, value) { this.attributes[key] = value; },
      addEventListener(key, fn) { this.listeners[key] = fn; }});
    return elements.get(id);
  }
  const conversation = node('conversation'), background = node('background'), release = node('release');
  conversation.dataset.command = 'conversation'; background.dataset.command = 'background'; release.dataset.command = 'release';
  const document = {getElementById: node, querySelectorAll: selector => selector === '.choice' ? [conversation, background] : [conversation, background, release]};
  let next = response;
  const chrome = {tabs: {query: async () => [{id: 7, title: '<unsafe page title>', url}]},
    runtime: {sendMessage: async () => { if (next instanceof Error) throw next; return next; }}};
  const context = vm.createContext({document, chrome, URL, Number, Error, setInterval() {}});
  vm.runInContext(fs.readFileSync(path.join(root, 'popup.js'), 'utf8'), context);
  async function drain() { for (let i = 0; i < 20; i++) await Promise.resolve(); }
  await drain();
  return {node, async respond(value) { next = value; await vm.runInContext("send('status', true)", context); await drain(); }};
}
(async () => {
  const offline = await popup('https://chatgpt.com/', {connection: 'unavailable', nativeError: 'Native host has exited.'});
  assert.ok(offline.node('notice').textContent.includes('请启动声邻'));
  assert.equal(offline.node('retry').disabled, false);
  assert.equal(offline.node('release').attributes['aria-pressed'], 'true');
  assert.equal(offline.node('conversation').disabled, true);
  await offline.respond({connection: 'connected', page: {role: 'conversation', input: 'unknown'}});
  assert.equal(offline.node('conversation').attributes['aria-pressed'], 'true');
  assert.ok(offline.node('notice').textContent.includes('结束后重启'));
  assert.equal(offline.node('release').disabled, false);
  await offline.respond({connection: 'connected', page: {role: 'conversation', input: 'idle'}});
  assert.equal(offline.node('conversation').attributes['aria-pressed'], 'true');
  assert.equal(offline.node('notice').hidden, true);
  const music = await popup('https://example.com/music', {connection: 'connected', gain: 0.25,
    page: {role: 'background', controllable: true}});
  assert.equal(music.node('background').attributes['aria-pressed'], 'true');
  assert.equal(music.node('notice').hidden, true);
  assert.equal(music.node('conversation').disabled, true);
  await music.respond(new Error('暂时未响应'));
  assert.equal(music.node('notice').textContent, '暂时未响应');
  await music.respond({connection: 'connected', page: {role: 'background', controllable: true}});
  assert.equal(music.node('notice').hidden, true);
  await music.respond({connection: 'unavailable', page: {role: 'background', controllable: false}});
  assert.equal(music.node('release').attributes['aria-pressed'], 'true');
  assert.equal(music.node('background').disabled, true);
  assert.equal(music.node('release').disabled, false);
  assert.ok(music.node('notice').textContent.includes('Mac'));
  await music.respond({connection: 'connected', page: {role: 'background', controllable: false}});
  assert.equal(music.node('background').disabled, false);
  assert.ok(music.node('notice').textContent.includes('重新选择'));
  await music.respond({connection: 'connected', page: {role: 'background', controllable: true}});
  assert.equal(music.node('notice').hidden, true);
  const internal = await popup('chrome://extensions/', {connection: 'connected'});
  assert.equal(internal.node('conversation').disabled, true);
  assert.equal(internal.node('background').disabled, true);
  assert.ok(internal.node('notice').textContent.includes('不支持'));
  console.log('通过：三态选择、静音保留通话、正常状态无提示、离线重试、释放与重新授权、受限页面。');
})().catch(error => { console.error(error); process.exitCode = 1; });
