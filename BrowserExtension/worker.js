const pages = new Map();
let port, pendingReply = false, lastReply = 0, lastSent = 0, heartbeat, error = '';
let pending = Promise.resolve();
function disconnectNative() {
  const current = port;
  port = undefined; pendingReply = false;
  current?.disconnect();
}
async function audio(message) {
  const contexts = await chrome.runtime.getContexts({contextTypes: ['OFFSCREEN_DOCUMENT']});
  if (!contexts.length) {
    if (message.command !== 'capture') return {active: false};
    await chrome.offscreen.createDocument({url: 'offscreen.html', reasons: ['USER_MEDIA'],
      justification: '在浏览器内对用户授权的背景网页施加协调增益并重放，不传送音频。'});
  }
  return chrome.runtime.sendMessage({...message, target: 'audio'});
}
function connect() {
  if (port) return;
  const current = chrome.runtime.connectNative('local.shenglin.browser');
  port = current;
  current.onMessage.addListener(message => {
    if (port !== current) return;
    pendingReply = false;
    if (!message.ok || !message.browser || message.browser.leaseSeconds !== 5) {
      error = message.message || '本机策略不可用';
      audio({command: 'release-all'}).catch(() => {}); return;
    }
    lastReply = Date.now(); error = '';
    audio({command: 'targets', gain: message.browser.gain}).catch(e => { error = e.message; });
  });
  current.onDisconnect.addListener(() => {
    if (port !== current) return;
    error = chrome.runtime.lastError?.message || '声邻连接已断开';
    port = undefined; pendingReply = false;
    audio({command: 'release-all'}).catch(() => {});
  });
}
async function update() {
  if (!pages.size) {
    if (port && !pendingReply) port.postMessage({connection: '', pages: []});
    disconnectNative(); clearInterval(heartbeat); heartbeat = undefined; return;
  }
  const snapshot = [];
  for (const [tabId, page] of pages) {
    try {
      const result = await chrome.scripting.executeScript({target: {tabId}, world: 'ISOLATED',
        func: () => ({input: window.__shenglinInputState?.input || 'unknown',
          updated: window.__shenglinInputState?.updated || 0})});
      const current = result[0];
      if (!current || current.documentId !== page.documentId) { await remove(tabId); continue; }
      if (!page.loading) page.navigationExpected = false;
      let controllable = false;
      if (page.role === 'background') controllable = !!(await audio({command: 'status', tabId})).active;
      const input = page.role === 'background' ? 'idle' :
        (Date.now() - current.result.updated <= 1500 ? current.result.input : 'unknown');
      page.input = input; page.controllable = controllable;
      snapshot.push({id: page.documentId, role: page.role, input, controllable});
    } catch (_) {
      // activeTab may hide the new URL after cross-site navigation. A loading event plus lost
      // document access ends the old instance; observation failure without navigation stays unknown.
      if (page.navigationExpected) { await remove(tabId); continue; }
      // Losing activeTab access doesn't mean input ended; retain protection until document replacement.
      page.input = 'unknown';
      snapshot.push({id: page.documentId, role: page.role, input: page.role === 'background' ? 'idle' : 'unknown', controllable: false});
      await audio({command: 'release', tabId});
    }
  }
  connect();
  if (pendingReply && Date.now() - lastSent > 5000) {
    disconnectNative(); await audio({command: 'release-all'}); return;
  }
  if (!pendingReply && port) {
    pendingReply = true; lastSent = Date.now();
    port.postMessage({connection: '', pages: snapshot});
  }
}
async function remove(tabId) {
  pages.delete(tabId);
  await audio({command: 'release', tabId});
}
async function execute(message) {
  if (!Number.isInteger(message.tabId)) throw Error('标签页无效');
  const tabId = message.tabId;
  if (message.command === 'status') return {page: pages.get(tabId), error};
  if (message.command === 'release') {
    await remove(tabId);
    try {
      await chrome.scripting.executeScript({target: {tabId}, world: 'MAIN',
        func: () => window.postMessage({type: 'shenglin-input-stop'}, location.origin)});
    } catch (_) {}
    await update(); return {message: '此网页已结束参与'};
  }
  if (!['conversation', 'background'].includes(message.command)) throw Error('操作无效');
  if (!pages.has(tabId) && pages.size >= 64) throw Error('最多接入 64 个网页，请先结束一个网页的参与');
  const tab = await chrome.tabs.get(tabId), url = new URL(tab.url);
  if (!['https:', 'http:'].includes(url.protocol)) throw Error('仅支持普通 HTTP/HTTPS 网页');
  if (message.command === 'conversation' && !(url.protocol === 'https:' && url.hostname === 'chatgpt.com') &&
      !(url.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(url.hostname)))
    throw Error('首版通话输入观察以 ChatGPT Voice 为基准');
  const result = await chrome.scripting.executeScript({target: {tabId}, world: 'ISOLATED', func: () => true});
  const documentId = result[0].documentId;
  await remove(tabId);
  if (message.command === 'conversation') {
    await chrome.scripting.executeScript({target: {tabId}, world: 'ISOLATED', files: ['input-bridge.js']});
    await chrome.scripting.executeScript({target: {tabId}, world: 'MAIN', files: ['input-main.js']});
  } else {
    await chrome.scripting.executeScript({target: {tabId}, world: 'MAIN',
      func: () => window.postMessage({type: 'shenglin-input-stop'}, location.origin)});
    const streamId = await chrome.tabCapture.getMediaStreamId({targetTabId: tabId});
    const capture = await audio({command: 'capture', tabId, streamId});
    if (!capture.active) throw Error(capture.error || '网页捕获失败');
  }
  pages.set(tabId, {documentId, origin: url.origin, role: message.command, input: message.command === 'conversation' ? 'unknown' : 'idle'});
  if (!heartbeat) heartbeat = setInterval(() => { pending = pending.then(update).catch(e => { error = e.message; }); }, 1000);
  await update();
  return {page: pages.get(tabId), message: message.command === 'conversation' ?
    '已保留此页输出。请随后开启 Voice；已有通话需结束后重新开启。' : '已接入背景网页，按 Mac 策略调音。', error};
}
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message.target !== 'worker' || sender.id !== chrome.runtime.id || sender.url !== chrome.runtime.getURL('popup.html')) return;
  pending = pending.then(() => execute(message)).then(reply, e => reply({error: e.message}));
  return true;
});
chrome.tabs.onRemoved.addListener(tabId => { pending = pending.then(() => remove(tabId)).then(update).catch(e => { error = e.message; }); });
chrome.tabs.onUpdated.addListener((tabId, change) => {
  // Loading may also happen during same-document transitions; release capture immediately, then verify documentId.
  const page = pages.get(tabId);
  if (change.url && page && new URL(change.url).origin !== page.origin) {
    pending = pending.then(() => remove(tabId)).then(update).catch(e => { error = e.message; });
    return;
  }
  if (change.status === 'loading') {
    if (page) { page.loading = true; page.navigationExpected = true; }
    pending = pending.then(() => audio({command: 'release', tabId})).then(update).catch(e => { error = e.message; });
  } else if (change.status === 'complete' && page) {
    page.loading = false;
    pending = pending.then(update).catch(e => { error = e.message; });
  }
});
