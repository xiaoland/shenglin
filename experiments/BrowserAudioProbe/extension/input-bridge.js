(() => {
  if (window.__shenglinInputBridge) return;
  window.__shenglinInputBridge = true;
  function receive(event) {
    if (event.source !== window || event.data?.type !== 'shenglin-input-probe') return;
    // 页面消息可被页面伪造，仅供该页能力实验；不据此控制其他应用。
    chrome.runtime.sendMessage({target: 'input-probe', value: event.data.value}).catch(() => {});
    if (event.data.value?.stopped) {
      window.removeEventListener('message', receive);
      delete window.__shenglinInputBridge;
    }
  }
  window.addEventListener('message', receive);
})();
