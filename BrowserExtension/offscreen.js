const sessions = new Map();
async function release(id) {
  const session = sessions.get(id);
  if (!session) return;
  sessions.delete(id);
  session.stream.getTracks().forEach(track => track.stop());
  await session.context.close();
}
async function execute(message) {
  const id = message.tabId;
  if (message.command === 'release-all') {
    await Promise.all([...sessions.keys()].map(release)); return {};
  }
  if (message.command === 'release') { await release(id); return {}; }
  if (message.command === 'status') return {active: sessions.has(id)};
  if (message.command === 'targets') {
    if (!Number.isFinite(message.gain) || message.gain < 0 || message.gain > 1) throw Error('增益无效');
    for (const session of sessions.values()) {
      session.expires = Date.now() + 5000;
      session.gain.gain.setTargetAtTime(message.gain, session.context.currentTime, 0.02);
    }
    return {};
  }
  if (message.command !== 'capture' || !Number.isInteger(id) || !message.streamId) throw Error('捕获参数无效');
  await release(id);
  const stream = await navigator.mediaDevices.getUserMedia({audio: {mandatory: {
    chromeMediaSource: 'tab', chromeMediaSourceId: message.streamId}}, video: false});
  let context;
  try {
    context = new AudioContext();
    const source = context.createMediaStreamSource(stream), gain = context.createGain();
    gain.gain.value = 1;
    source.connect(gain).connect(context.destination);
    await context.resume();
    if (context.state !== 'running') throw Error('网页重放未运行');
    const session = {stream, context, gain, expires: Date.now() + 5000};
    sessions.set(id, session);
    stream.getAudioTracks().forEach(track => track.addEventListener('ended', () => release(id), {once: true}));
    context.addEventListener('statechange', () => {
      if (context.state !== 'running' && sessions.get(id) === session) release(id);
    });
    return {active: true};
  } catch (error) {
    stream.getTracks().forEach(track => track.stop());
    if (context) await context.close();
    throw error;
  }
}
setInterval(() => {
  for (const [id, session] of sessions) if (session.expires <= Date.now()) release(id);
}, 250);
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message.target !== 'audio' || sender.id !== chrome.runtime.id ||
      sender.tab || (sender.url !== undefined && sender.url !== chrome.runtime.getURL('worker.js'))) return;
  execute(message).then(reply, error => reply({error: error.message}));
  return true;
});
