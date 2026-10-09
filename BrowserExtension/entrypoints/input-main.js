export default defineUnlistedScript(() => {
    if (window.__shenglinInputObserver) return;
    const media = navigator.mediaDevices;
    if (!media?.getUserMedia) return;
    const original = media.getUserMedia, tracks = new Set();
    let calls = 0, failures = 0;
    function report() {
      const live = [...tracks].filter(track => track.readyState === 'live');
      window.postMessage({type: 'shenglin-input-state', value: {
        calls, failures, tracked: tracks.size, live: live.length,
        active: live.filter(track => track.enabled && !track.muted).length
      }}, location.origin);
    }
    function observed(...args) {
      calls++; report();
      return original.apply(this, args).then(stream => {
        stream.getAudioTracks().forEach(track => tracks.add(track));
        report(); return stream;
      }, error => { failures++; report(); throw error; });
    }
    media.getUserMedia = observed;
    const timer = setInterval(report, 250);
    function stop(event) {
      if (event.source !== window || event.data?.type !== 'shenglin-input-stop') return;
      clearInterval(timer);
      if (media.getUserMedia === observed) media.getUserMedia = original;
      window.removeEventListener('message', stop);
      delete window.__shenglinInputObserver;
    }
    window.addEventListener('message', stop);
    window.__shenglinInputObserver = true;
    report();

});
