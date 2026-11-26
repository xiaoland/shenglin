import { CaptureSessions } from '../../lib/capture-sessions.js';

const sessions = new CaptureSessions({
  getUserMedia: constraints => navigator.mediaDevices.getUserMedia(constraints),
  createContext: () => new AudioContext(),
});
async function execute(message) {
  switch (message.command) {
    case 'release-all': await sessions.releaseAll(); return {};
    case 'release': await sessions.release(message.tabId); return {};
    case 'status': return {active: sessions.active(message.tabId)};
    case 'targets': sessions.targets(message.gain); return {};
    case 'capture': return sessions.capture(message.tabId, message.streamId);
    default: throw Error('捕获参数无效');
  }
}
setInterval(() => { sessions.expire().catch(() => {}); }, 250);
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message.target !== 'audio' || sender.id !== chrome.runtime.id ||
      sender.tab || (sender.url !== undefined && sender.url !== chrome.runtime.getURL('background.js'))) return;
  execute(message).then(reply, error => reply({error: error.message}));
  return true;
});
