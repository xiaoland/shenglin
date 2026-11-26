import { describe, it, expect } from 'vitest';
import { CaptureSessions } from '../lib/capture-sessions.js';

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return {promise, resolve, reject};
}
function fixture() {
  const requests = [], contexts = [];
  let now = 0, resume;
  const sessions = new CaptureSessions({
    now: () => now,
    getUserMedia: () => { const request = deferred(); requests.push(request); return request.promise; },
    createContext: () => {
      const listeners = {};
      const context = {
        state: 'running', closed: 0, currentTime: 0, destination: {},
        createMediaStreamSource: () => ({connect: () => ({connect() {}})}),
        createGain: () => ({gain: {value: 1, setTargetAtTime() {}}}),
        resume: () => resume?.promise ?? Promise.resolve(),
        close: async () => { context.closed++; context.state = 'closed'; },
        addEventListener: (event, listener) => { listeners[event] = listener; },
        emit: event => listeners[event]?.(),
      };
      contexts.push(context); return context;
    },
  });
  const stream = () => {
    const listeners = {};
    const track = {stopped: 0, stop() { this.stopped++; },
      addEventListener: (event, listener) => { listeners[event] = listener; }};
    return {getTracks: () => [track], getAudioTracks: () => [track], track,
      end: () => listeners.ended?.()};
  };
  return {sessions, requests, contexts, stream, advance: n => { now += n; },
    delayResume: () => { resume = deferred(); return resume; }};
}
describe('capture lifecycle', () => {
  it.each(['release', 'releaseAll', 'expire'])('invalidates a pending permission request through %s', async command => {
    const f = fixture(), stream = f.stream();
    const capture = f.sessions.capture(7, 'token');
    f.advance(5000);
    await f.sessions[command](7);
    f.requests[0].resolve(stream);
    expect(await capture).toEqual({active: false});
    expect(f.sessions.active(7)).toBe(false);
    expect(stream.track.stopped).toBe(1);
    expect(f.contexts).toHaveLength(0);
  });
  it('keeps a replacement when an older request completes last', async () => {
    const f = fixture(), old = f.stream(), next = f.stream();
    const first = f.sessions.capture(7, 'old');
    const second = f.sessions.capture(7, 'new');
    await Promise.resolve();
    f.requests[1].resolve(next);
    expect(await second).toEqual({active: true});
    f.requests[0].resolve(old);
    expect(await first).toEqual({active: false});
    expect(old.track.stopped).toBe(1);
    expect(next.track.stopped).toBe(0);
    expect(f.sessions.active(7)).toBe(true);
  });
  it('ignores old track and context events after a replacement', async () => {
    const f = fixture(), old = f.stream(), next = f.stream();
    const first = f.sessions.capture(7, 'old'); f.requests[0].resolve(old); await first;
    const second = f.sessions.capture(7, 'new'); await Promise.resolve(); await Promise.resolve();
    f.requests[1].resolve(next); await second;
    old.end(); f.contexts[0].emit('statechange');
    expect(f.sessions.active(7)).toBe(true);
    expect(next.track.stopped).toBe(0);
    expect(f.contexts[0].closed).toBe(1);
  });
  it('cancels while AudioContext.resume is pending', async () => {
    const f = fixture(), stream = f.stream(), resume = f.delayResume();
    const capture = f.sessions.capture(7, 'token'); f.requests[0].resolve(stream);
    await Promise.resolve(); await f.sessions.releaseAll(); resume.resolve();
    expect(await capture).toEqual({active: false});
    expect(stream.track.stopped).toBe(1);
    expect(f.contexts[0].closed).toBe(1);
  });
  it('cleans failed replay and permits a fresh request', async () => {
    const f = fixture(), stream = f.stream(), resume = f.delayResume();
    const capture = f.sessions.capture(7, 'token'); f.requests[0].resolve(stream);
    resume.reject(Error('resume failed'));
    await expect(capture).rejects.toThrow('resume failed');
    expect(stream.track.stopped).toBe(1);
    expect(f.contexts[0].closed).toBe(1);
    expect(f.sessions.active(7)).toBe(false);
  });
  it('renews a running lease and releases only expired sessions', async () => {
    const f = fixture(), stream = f.stream();
    const capture = f.sessions.capture(7, 'token'); f.requests[0].resolve(stream); await capture;
    f.advance(4000); f.sessions.targets(0.25); f.advance(4000); await f.sessions.expire();
    expect(f.sessions.active(7)).toBe(true);
    f.advance(1000); await f.sessions.expire();
    expect(f.sessions.active(7)).toBe(false);
    expect(stream.track.stopped).toBe(1);
  });
});
