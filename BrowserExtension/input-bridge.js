(() => {
  if (window.__shenglinInputState) return;
  const state = window.__shenglinInputState = {input: 'unknown', updated: 0};
  function receive(event) {
    if (event.source !== window) return;
    if (event.data?.type === 'shenglin-input-stop') {
      window.removeEventListener('message', receive);
      delete window.__shenglinInputState;
      return;
    }
    if (event.data?.type !== 'shenglin-input-state') return;
    const value = event.data.value;
    if (!value || !['calls', 'failures', 'tracked', 'live', 'active'].every(key =>
      Number.isInteger(value[key]) && value[key] >= 0 && value[key] <= 10000) ||
      value.active > value.live || value.live > value.tracked) return;
    // Page-provided metadata is untrusted and scoped to this explicitly authorized page.
    state.input = value.tracked > 0 ? (value.active > 0 ? 'active' : 'idle') : 'unknown';
    state.updated = Date.now();
  }
  window.addEventListener('message', receive);
})();
