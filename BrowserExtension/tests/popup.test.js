// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import App from '../entrypoints/popup/App.vue';

let wrapper, response, sendMessage;
async function popup(url, initial) {
  response = initial;
  sendMessage = vi.fn(async () => {
    if (response instanceof Error) throw response;
    return response;
  });
  vi.stubGlobal('chrome', {
    tabs: { query: vi.fn(async () => [{ id: 7, url }]) },
    runtime: { sendMessage },
  });
  wrapper = mount(App);
  await flushPromises();
  return wrapper;
}
function choice(command) { return wrapper.get(`[data-command="${command}"]`); }
async function poll(next) {
  response = next;
  await vi.advanceTimersByTimeAsync(1000);
  await flushPromises();
}

beforeEach(() => { vi.useFakeTimers({ toFake: ['setInterval', 'clearInterval'] }); });
afterEach(() => {
  wrapper?.unmount();
  wrapper = undefined;
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe('弹窗参与方式', () => {
  it('离线提供重试，连接恢复后可以选择通话，静音仍保留选择', async () => {
    await popup('https://chatgpt.com/', { connection: 'unavailable', nativeError: 'Native host has exited.' });
    expect(wrapper.get('#notice').text()).toContain('请启动声邻');
    expect(choice('release').attributes('aria-pressed')).toBe('true');
    expect(choice('conversation').element.disabled).toBe(true);
    expect(wrapper.get('#retry').element.disabled).toBe(false);
    response = { connection: 'connected' };
    await wrapper.get('#retry').trigger('click');
    await flushPromises();
    expect(sendMessage).toHaveBeenLastCalledWith({ target: 'worker', command: 'retry', tabId: 7 });
    expect(wrapper.find('#notice').exists()).toBe(false);
    response = { connection: 'connected', page: { role: 'conversation', input: 'unknown' } };
    await choice('conversation').trigger('click');
    await flushPromises();
    expect(sendMessage).toHaveBeenLastCalledWith({ target: 'worker', command: 'conversation', tabId: 7 });
    expect(choice('conversation').attributes('aria-pressed')).toBe('true');
    expect(wrapper.get('#notice').text()).toContain('结束后重启');
    expect(choice('release').element.disabled).toBe(false);
    await poll({ connection: 'connected', page: { role: 'conversation', input: 'idle' } });
    expect(choice('conversation').attributes('aria-pressed')).toBe('true');
    expect(wrapper.find('#notice').exists()).toBe(false);
  });

  it('正常背景无额外信息，断线后可释放，恢复后需要再次授权背景', async () => {
    await popup('https://example.com/music', { connection: 'connected', gain: 0.25, page: { role: 'background', controllable: true } });
    expect(choice('background').attributes('aria-pressed')).toBe('true');
    expect(wrapper.find('#notice').exists()).toBe(false);
    expect(choice('conversation').element.disabled).toBe(true);
    await poll({ connection: 'unavailable', page: { role: 'background', controllable: false } });
    expect(choice('release').attributes('aria-pressed')).toBe('true');
    expect(choice('release').element.disabled).toBe(false);
    expect(choice('background').element.disabled).toBe(true);
    expect(wrapper.get('#notice').text()).toContain('Mac');
    await poll({ connection: 'connected', page: { role: 'background', controllable: false } });
    expect(choice('background').element.disabled).toBe(false);
    expect(wrapper.get('#notice').text()).toContain('重新选择');
    response = { connection: 'connected', page: { role: 'background', controllable: true } };
    await choice('background').trigger('click');
    await flushPromises();
    expect(sendMessage).toHaveBeenLastCalledWith({ target: 'worker', command: 'background', tabId: 7 });
    expect(wrapper.find('#notice').exists()).toBe(false);
    response = { connection: 'connected' };
    await choice('release').trigger('click');
    await flushPromises();
    expect(sendMessage).toHaveBeenLastCalledWith({ target: 'worker', command: 'release', tabId: 7 });
    expect(choice('release').attributes('aria-pressed')).toBe('true');
  });

  it('临时查询错误在下次成功后消失，操作错误保留到下次操作', async () => {
    await popup('https://example.com/', { connection: 'connected' });
    await poll(new Error('暂时未响应'));
    expect(wrapper.get('#notice').text()).toBe('暂时未响应');
    await poll({ connection: 'connected' });
    expect(wrapper.find('#notice').exists()).toBe(false);
    response = new Error('授权失败');
    await choice('background').trigger('click');
    await flushPromises();
    await poll({ connection: 'connected' });
    expect(wrapper.get('#notice').text()).toBe('授权失败');
    response = { connection: 'connected', page: { role: 'background', controllable: true } };
    await choice('background').trigger('click');
    await flushPromises();
    expect(wrapper.find('#notice').exists()).toBe(false);
  });

  it('受限页面禁止参与', async () => {
    await popup('chrome://extensions/', { connection: 'connected' });
    expect(choice('conversation').element.disabled).toBe(true);
    expect(choice('background').element.disabled).toBe(true);
    expect(wrapper.get('#notice').text()).toContain('不支持');
  });

  it('操作期间禁止重复请求和轮询，关闭弹窗后停止轮询', async () => {
    await popup('https://example.com/', { connection: 'connected' });
    let complete;
    sendMessage.mockImplementationOnce(() => new Promise(resolve => { complete = resolve; }));
    await choice('background').trigger('click');
    expect(choice('background').element.disabled).toBe(true);
    expect(choice('release').element.disabled).toBe(true);
    const count = sendMessage.mock.calls.length;
    await vi.advanceTimersByTimeAsync(2000);
    expect(sendMessage).toHaveBeenCalledTimes(count);
    complete({ connection: 'connected', page: { role: 'background', controllable: true } });
    await flushPromises();
    expect(choice('release').element.disabled).toBe(false);
    await poll({ connection: 'connected', page: { role: 'background', controllable: true } });
    const finalCount = sendMessage.mock.calls.length;
    wrapper.unmount();
    wrapper = undefined;
    await vi.advanceTimersByTimeAsync(3000);
    expect(sendMessage).toHaveBeenCalledTimes(finalCount);
  });

  it('未读到当前页面时给出错误且不能发送操作', async () => {
    vi.stubGlobal('chrome', { tabs: { query: vi.fn(async () => []) }, runtime: { sendMessage: vi.fn() } });
    wrapper = mount(App);
    await flushPromises();
    expect(wrapper.get('#notice').text()).toBe('无法读取当前标签页。');
    expect(choice('background').element.disabled).toBe(true);
    expect(chrome.runtime.sendMessage).not.toHaveBeenCalled();
  });

  it('上次状态查询未结束时不重复轮询', async () => {
    await popup('https://example.com/', { connection: 'connected' });
    let complete;
    sendMessage.mockImplementationOnce(() => new Promise(resolve => { complete = resolve; }));
    await vi.advanceTimersByTimeAsync(1000);
    const count = sendMessage.mock.calls.length;
    await vi.advanceTimersByTimeAsync(3000);
    expect(sendMessage).toHaveBeenCalledTimes(count);
    complete({ connection: 'connected' });
    await flushPromises();
    await poll({ connection: 'connected' });
    expect(sendMessage).toHaveBeenCalledTimes(count + 1);
  });

  it('初始化期间关闭弹窗也不会留下定时器', async () => {
    let complete;
    sendMessage = vi.fn(() => new Promise(resolve => { complete = resolve; }));
    vi.stubGlobal('chrome', {
      tabs: { query: vi.fn(async () => [{ id: 7, url: 'https://example.com/' }]) },
      runtime: { sendMessage },
    });
    wrapper = mount(App);
    await flushPromises();
    expect(sendMessage).toHaveBeenCalledTimes(1);
    wrapper.unmount();
    wrapper = undefined;
    complete({ connection: 'connected' });
    await flushPromises();
    await vi.advanceTimersByTimeAsync(3000);
    expect(sendMessage).toHaveBeenCalledTimes(1);
    expect(vi.getTimerCount()).toBe(0);
  });
});
