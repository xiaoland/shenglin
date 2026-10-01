(() => {
  if (window.__shenglinInputBridge) return;
  window.__shenglinInputBridge = true;
  // 记录随文档存在，避免 service worker 休眠丢失；刷新自然清除旧实例。
  const state = window.__shenglinInputProbeState = {observation: 'unknown', protected: true, events: []};
  function receive(event) {
    if (event.source !== window || event.data?.type !== 'shenglin-input-probe') return;
    // 页面消息可被页面伪造，仅供该页能力实验；不据此控制其他应用。
    const value = event.data.value;
    if (!value) return;
    if (value.stopped === true) {
      state.observation = 'stopped'; state.protected = false;
      window.removeEventListener('message', receive);
      delete window.__shenglinInputBridge;
      return;
    }
    const keys = ['calls', 'failures', 'tracked', 'live', 'enabled', 'unmuted'];
    if (!keys.every(key => Number.isInteger(value[key]) && value[key] >= 0 && value[key] < 10000)) return;
    state.events.push({time: Date.now(), ...Object.fromEntries(keys.map(key => [key, value[key]]))});
    if (state.events.length > 80) state.events.shift();
    state.observation = value.tracked ? 'observed-tracks' : 'unknown';
  }
  window.addEventListener('message', receive);
})();
