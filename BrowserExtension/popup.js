const state = document.querySelector('#state');
async function send(command) {
  try {
    const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
    const result = await chrome.runtime.sendMessage({target: 'worker', command, tabId: tab.id});
    const page = result.page;
    state.textContent = result.error || result.message || (page ?
      `${page.role === 'conversation' ? '通话输出受保护' : (page.controllable ? '背景网页已接入' : '背景播放已释放，请重新授权')}\n输入：${{active: '正在采集', idle: '未有效采集', unknown: '未知；如已在通话，请重启 Voice'}[page.input] || '未知'}` : '此网页尚未参与');
  } catch (error) { state.textContent = error.message; }
}
document.querySelectorAll('[data-command]').forEach(button => button.onclick = () => send(button.dataset.command));
send('status');
