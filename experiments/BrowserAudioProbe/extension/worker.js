function observationURL(value) {
  const url = new URL(value);
  return (url.protocol === 'https:' && url.hostname === 'chatgpt.com') ||
    (url.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(url.hostname) && url.port === '18763');
}
async function execute(message) {
  if (!Number.isInteger(message.tabId)) throw new Error('无效标签页');
  if (['observe', 'inspect', 'unobserve'].includes(message.command)) {
    const tab = await chrome.tabs.get(message.tabId);
    if (!observationURL(tab.url)) throw new Error('仅允许 ChatGPT 或本地实验页的输入观察');
    if (message.command === 'unobserve') {
      await chrome.scripting.executeScript({target: {tabId: tab.id}, world: 'MAIN',
        func: () => window.postMessage({type: 'shenglin-input-probe-stop'}, location.origin)});
      return {observation: 'stopped', protected: false};
    }
    if (message.command === 'observe') {
      await chrome.scripting.executeScript({target: {tabId: tab.id}, world: 'ISOLATED', files: ['input-bridge.js']});
      await chrome.scripting.executeScript({target: {tabId: tab.id}, world: 'MAIN', files: ['input-main.js']});
    }
    const results = await chrome.scripting.executeScript({target: {tabId: tab.id}, world: 'ISOLATED',
      func: () => window.__shenglinInputProbeState || {observation: 'unknown', protected: false}});
    return {...results[0].result, documentId: results[0].documentId};
  }
  if (message.command !== 'gain' && message.command !== 'release') throw new Error('无效操作');
  const tab = await chrome.tabs.get(message.tabId);
  const url = new URL(tab.url);
  if (url.protocol !== 'http:' || !['localhost', '127.0.0.1'].includes(url.hostname) || url.port !== '18763')
    throw new Error('仅允许本地实验页');
  if (message.command === 'gain' && ![1, 0.2].includes(message.gain)) throw new Error('无效增益');
  const contexts = await chrome.runtime.getContexts({contextTypes: ['OFFSCREEN_DOCUMENT']});
  if (!contexts.length) {
    if (message.command === 'release') return {released: true};
    await chrome.offscreen.createDocument({url: 'offscreen.html', reasons: ['USER_MEDIA'],
      justification: '在浏览器内重放指定实验标签页的音频，并测量增益。'});
  }
  const current = await chrome.runtime.sendMessage({target: 'audio', command: 'status', tabId: tab.id});
  let streamId;
  if (message.command === 'gain' && !current.active)
    streamId = await chrome.tabCapture.getMediaStreamId({targetTabId: tab.id});
  return chrome.runtime.sendMessage({...message, target: 'audio', streamId});
}
// 顺序处理按钮操作，避免同时创建离屏文档或对同一页重复捕获。
let pending = Promise.resolve();
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message.target !== 'worker') return;
  if (sender.id !== chrome.runtime.id || sender.url !== chrome.runtime.getURL('popup.html')) return;
  pending = pending.then(() => execute(message)).then(reply, error => reply({error: error.message}));
  return true;
});
function release(tabId) {
  chrome.runtime.sendMessage({target: 'audio', command: 'release', tabId}).catch(() => {});
}
chrome.tabs.onRemoved.addListener(release);
chrome.tabs.onUpdated.addListener((tabId, change) => { if (change.status === 'loading') release(tabId); });
