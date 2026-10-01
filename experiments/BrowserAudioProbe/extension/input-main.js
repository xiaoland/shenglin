(() => {
  if (window.__shenglinInputProbe) return;
  const media = navigator.mediaDevices, original = media.getUserMedia;
  const tracks = new Set();
  let calls = 0, failures = 0, last = '';
  function report() {
    const live = [...tracks].filter(track => track.readyState === 'live');
    const value = {calls, failures, tracked: tracks.size, live: live.length,
      enabled: live.filter(track => track.enabled).length,
      unmuted: live.filter(track => !track.muted).length};
    const serialized = JSON.stringify(value);
    if (serialized !== last) {
      last = serialized;
      window.postMessage({type: 'shenglin-input-probe', value}, location.origin);
    }
  }
  function observed(...args) {
    calls++;
    report();
    return original.apply(this, args).then(stream => {
      stream.getAudioTracks().forEach(track => tracks.add(track));
      report();
      return stream;
    }, error => { failures++; report(); throw error; });
  }
  media.getUserMedia = observed;
  const timer = setInterval(report, 250);
  const timeout = setTimeout(stop, 600000);
  function stop() {
    clearInterval(timer); clearTimeout(timeout);
    if (media.getUserMedia === observed) media.getUserMedia = original;
    window.removeEventListener('message', onMessage);
    delete window.__shenglinInputProbe;
    window.postMessage({type: 'shenglin-input-probe', value: {stopped: true}}, location.origin);
  }
  function onMessage(event) {
    if (event.source === window && event.data?.type === 'shenglin-input-probe-stop') stop();
  }
  window.addEventListener('message', onMessage);
  window.__shenglinInputProbe = true;
  report();
})();
