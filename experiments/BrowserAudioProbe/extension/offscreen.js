const sessions = new Map();
async function release(tabId) {
  const session = sessions.get(tabId);
  if (!session) return;
  sessions.delete(tabId);
  clearTimeout(session.timer);
  session.stream.getTracks().forEach(track => track.stop());
  await session.context.close();
}
function rms(analyser) {
  const samples = new Float32Array(analyser.fftSize);
  analyser.getFloatTimeDomainData(samples);
  return Math.sqrt(samples.reduce((sum, x) => sum + x * x, 0) / samples.length);
}
async function execute(message) {
  const id = message.tabId;
  let session = sessions.get(id);
  if (message.command === 'status') return {active: !!session};
  if (message.command === 'release') { await release(id); return {released: true}; }
  if (message.command !== 'gain' || ![1, 0.2].includes(message.gain)) throw new Error('无效操作');
  if (!session) {
    if (!message.streamId) throw new Error('缺少捕获授权');
    const stream = await navigator.mediaDevices.getUserMedia({audio: {mandatory: {
      chromeMediaSource: 'tab', chromeMediaSourceId: message.streamId}}, video: false});
    let context;
    try {
      context = new AudioContext();
      const source = context.createMediaStreamSource(stream), gain = context.createGain();
      const before = context.createAnalyser(), after = context.createAnalyser();
      gain.gain.value = message.gain;
      source.connect(before).connect(gain).connect(after).connect(context.destination);
      await context.resume();
      session = {stream, context, gain, before, after, timer: setTimeout(() => release(id), 90000)};
      sessions.set(id, session);
      stream.getAudioTracks().forEach(track => track.addEventListener('ended', () => release(id), {once: true}));
    } catch (error) {
      stream.getTracks().forEach(track => track.stop());
      if (context) await context.close();
      throw error;
    }
  }
  session.gain.gain.setTargetAtTime(message.gain, session.context.currentTime, 0.02);
  await new Promise(resolve => setTimeout(resolve, 150));
  const inputRMS = rms(session.before), outputRMS = rms(session.after);
  return {active: true, targetGain: message.gain, inputRMS, outputRMS,
    measuredRatio: inputRMS > 0.00001 ? outputRMS / inputRMS : null};
}
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message.target !== 'audio' || sender.id !== chrome.runtime.id) return;
  execute(message).then(reply, error => reply({error: error.message}));
  return true;
});
