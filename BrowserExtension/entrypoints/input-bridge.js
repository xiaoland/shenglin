export default defineUnlistedScript(() => {
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
      const input = event.data.input;
      if (!['active', 'idle', 'unknown'].includes(input)) return;
      // This page can report only its own explicitly authorized input state.
      state.input = input;
      state.updated = Date.now();
    }
    window.addEventListener('message', receive);

});
