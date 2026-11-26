export default defineUnlistedScript(() => {
    if (window.__shenglinInputObserver) return;
    const media = navigator.mediaDevices;
    if (!media?.getUserMedia) return;
    const original = media.getUserMedia, tracks = new Set();
    let observedAudio = false;
    function report() {
      let input = observedAudio ? 'idle' : 'unknown';
      for (const track of tracks) {
        if (track.readyState === 'ended') tracks.delete(track);
        else if (track.enabled && !track.muted) input = 'active';
      }
      window.postMessage({type: 'shenglin-input-state', input}, location.origin);
    }
    async function observed(...args) {
      const stream = await original.apply(this, args);
      if (window.__shenglinInputObserver === observed) {
        for (const track of stream.getAudioTracks()) {
          observedAudio = true;
          tracks.add(track);
        }
        report();
      }
      return stream;
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
    window.__shenglinInputObserver = observed;
    report();

});
