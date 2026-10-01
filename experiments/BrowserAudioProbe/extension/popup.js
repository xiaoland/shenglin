const state = document.querySelector('#state');
async function send(command, gain) {
  try {
    const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
    const result = await chrome.runtime.sendMessage({target: 'worker', command, tabId: tab.id, gain});
    state.textContent = JSON.stringify(result, null, 2);
  } catch (error) { state.textContent = error.message; }
}
document.querySelectorAll('[data-gain]').forEach(button => {
  button.onclick = () => send('gain', Number(button.dataset.gain));
});
document.querySelector('#release').onclick = () => send('release');
document.querySelector('#observe').onclick = () => send('observe');
document.querySelector('#inspect').onclick = () => send('inspect');
document.querySelector('#unobserve').onclick = () => send('unobserve');
