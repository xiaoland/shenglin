const element = id => document.getElementById(id);
const choices = [...document.querySelectorAll('[data-command]')];
let tab, busy = false, polling = false, latest, actionError = '';
function readableError(message = '') {
  if (message.startsWith('无法连接声邻 App')) return '请打开 Mac 端声邻。';
  if (/native host has exited/i.test(message)) return '请启动声邻；仍无法连接时，重新设置浏览器扩展。';
  if (/specified native messaging host not found/i.test(message)) return '请在 Mac 端声邻设置中安装浏览器连接。';
  if (/access to the specified native messaging host is forbidden/i.test(message)) return '请使用声邻 App 安装的扩展，重新设置连接。';
  return message;
}
function notice(message, warning = false) {
  element('notice').hidden = !message;
  element('notice').textContent = readableError(message);
  element('notice').dataset.tone = warning ? 'warning' : 'hint';
}
function render(result) {
  latest = result;
  const page = result.page, connected = result.connection === 'connected';
  const connection = element('retry');
  const label = connected ? 'Mac 已连接' : result.connection === 'unavailable' ? 'Mac 未连接，点击重试' : '正在连接 Mac';
  connection.setAttribute('aria-label', label);
  connection.title = label;
  connection.dataset.tone = connected ? 'good' : result.connection === 'unavailable' ? 'warning' : 'pending';
  connection.disabled = busy || result.connection !== 'unavailable';
  let url;
  try { url = new URL(tab?.url); } catch (_) {}
  const supported = ['http:', 'https:'].includes(url?.protocol);
  const voice = supported && (url.hostname === 'chatgpt.com' && url.protocol === 'https:' || url.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(url.hostname));
  const role = page?.role === 'background' && !page.controllable ? 'release' : page?.role || 'release';
  for (const button of choices) {
    const command = button.dataset.command, selected = role === command;
    button.setAttribute('aria-pressed', String(selected));
    button.disabled = busy || (command === 'release' ? !page : !connected || !supported || command === 'conversation' && !voice || selected);
  }
  const nativeError = result.connection === 'unavailable' ? result.nativeError || '请打开 Mac 端声邻。' : '';
  const hint = !supported ? '此页面不支持协同。' : connected && page?.role === 'background' && !page.controllable ? '背景已释放，请重新选择“背景”。' : page?.role === 'conversation' && page.input === 'unknown' ? '请开启 Voice；已有通话请结束后重启。' : '';
  notice(actionError || result.error || nativeError || hint, !!(actionError || result.error || nativeError));
}
async function send(command, quiet = false) {
  if (!tab?.id) return;
  if (!quiet) { busy = true; actionError = ''; if (latest) render(latest); }
  try {
    const result = await chrome.runtime.sendMessage({target: 'worker', command, tabId: tab.id});
    if (!result) throw Error('扩展未响应，请重新加载。');
    if (!quiet) actionError = result.error || '';
    if (result.connection) render(result);
  } catch (error) { if (!quiet) actionError = error.message; notice(error.message, true); }
  finally { if (!quiet) { busy = false; if (latest) render(latest); } }
}
choices.forEach(button => button.addEventListener('click', () => send(button.dataset.command)));
element('retry').addEventListener('click', () => send('retry'));
async function initialize() {
  try {
    [tab] = await chrome.tabs.query({active: true, currentWindow: true});
    if (!tab?.id) throw Error('无法读取当前标签页。');
    await send('status', true);
    setInterval(async () => {
      if (busy || polling) return;
      polling = true;
      try { await send('status', true); } finally { polling = false; }
    }, 1000);
  } catch (error) { notice(error.message, true); choices.forEach(button => { button.disabled = true; }); }
}
initialize();
