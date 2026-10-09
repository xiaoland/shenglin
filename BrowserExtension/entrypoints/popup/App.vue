<script setup>
import { computed, onMounted, onUnmounted, ref } from 'vue';

const choices = [
  { command: 'release', label: '不参与', title: '让此网页退出协同' },
  { command: 'conversation', label: '通话', title: '保留通话原声；先选择，再开启 ChatGPT Voice' },
  { command: 'background', label: '背景', title: '允许声邻按 Mac 策略调低此页音量；音频只在浏览器内处理' },
];
const tab = ref();
const status = ref({});
const busy = ref(false);
const actionError = ref('');
const requestError = ref('');
let polling = false, timer, disposed = false;

const page = computed(() => status.value.page);
const connected = computed(() => status.value.connection === 'connected');
const unavailable = computed(() => status.value.connection === 'unavailable');
const connectionLabel = computed(() => connected.value ? 'Mac 已连接' : unavailable.value ? 'Mac 未连接，点击重试' : '正在连接 Mac');
const connectionTone = computed(() => connected.value ? 'good' : unavailable.value ? 'warning' : 'pending');
const url = computed(() => {
  try { return new URL(tab.value?.url); } catch { return undefined; }
});
const supported = computed(() => ['http:', 'https:'].includes(url.value?.protocol));
const voice = computed(() => supported.value && (
  url.value.protocol === 'https:' && url.value.hostname === 'chatgpt.com' ||
  url.value.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(url.value.hostname)
));
const role = computed(() => page.value?.role === 'background' && !page.value.controllable ? 'release' : page.value?.role || 'release');
const nativeError = computed(() => unavailable.value ? status.value.nativeError || '请打开 Mac 端声邻。' : '');
const hint = computed(() => !tab.value ? '' : !supported.value ? '此页面不支持协同。'
  : connected.value && page.value?.role === 'background' && !page.value.controllable ? '背景已释放，请重新选择“背景”。'
  : page.value?.role === 'conversation' && page.value.input === 'unknown' ? '请开启 Voice；已有通话请结束后重启。' : '');
const error = computed(() => actionError.value || requestError.value || status.value.error || nativeError.value);
const notice = computed(() => readableError(error.value || hint.value));

function readableError(message = '') {
  if (message.startsWith('无法连接声邻 App')) return '请打开 Mac 端声邻。';
  if (/native host has exited/i.test(message)) return '请启动声邻；仍无法连接时，重新设置浏览器扩展。';
  if (/specified native messaging host not found/i.test(message)) return '请在 Mac 端声邻设置中安装浏览器连接。';
  if (/access to the specified native messaging host is forbidden/i.test(message)) return '请使用声邻 App 安装的扩展，重新设置连接。';
  return message;
}

function disabled(command) {
  return !tab.value?.id || busy.value || (command === 'release' ? !page.value
    : !connected.value || !supported.value || command === 'conversation' && !voice.value || role.value === command);
}

async function send(command, quiet = false) {
  if (!tab.value?.id) return;
  if (!quiet) { busy.value = true; actionError.value = ''; }
  try {
    const result = await chrome.runtime.sendMessage({ target: 'worker', command, tabId: tab.value.id });
    if (!result) throw Error('扩展未响应，请重新加载。');
    if (disposed) return;
    requestError.value = '';
    if (!quiet) actionError.value = result.error || '';
    if (result.connection) status.value = result;
  } catch (error) {
    if (!disposed) {
      requestError.value = error.message;
      if (!quiet) actionError.value = error.message;
    }
  } finally {
    if (!quiet) busy.value = false;
  }
}

onMounted(async () => {
  try {
    const [activeTab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (disposed) return;
    if (!activeTab?.id) throw Error('无法读取当前标签页。');
    tab.value = activeTab;
    await send('status', true);
    if (disposed) return;
    timer = setInterval(async () => {
      if (busy.value || polling) return;
      polling = true;
      try { await send('status', true); } finally { polling = false; }
    }, 1000);
  } catch (error) {
    if (!disposed) requestError.value = error.message;
  }
});

onUnmounted(() => {
  disposed = true;
  clearInterval(timer);
});
</script>

<template>
  <header>
    <img src="/icons/icon128.png" width="28" height="28" alt="">
    <h1>声邻</h1>
    <button id="retry" class="connection" type="button" :data-tone="connectionTone"
      :aria-label="connectionLabel" :title="connectionLabel" :disabled="busy || !unavailable" @click="send('retry')">
      <span aria-hidden="true"></span>
    </button>
  </header>
  <main>
    <div class="roles" role="group" aria-label="当前网页的参与方式">
      <button v-for="choice in choices" :key="choice.command" :data-command="choice.command" type="button"
        :aria-pressed="role === choice.command" :title="choice.title" :disabled="disabled(choice.command)" @click="send(choice.command)">{{ choice.label }}</button>
    </div>
    <p v-if="notice" id="notice" role="status" aria-live="polite" :data-tone="error ? 'warning' : 'hint'">{{ notice }}</p>
  </main>
</template>
