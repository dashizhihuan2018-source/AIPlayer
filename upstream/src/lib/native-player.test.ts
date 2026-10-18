import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest';

import {
  nativeAvailable,
  nativeRequest,
  subscribeNativeState,
  type NativeState,
} from './native-player';

type Listener = (event: Event) => void;

class NativeWindowHarness {
  readonly messages: unknown[] = [];
  readonly listeners = new Map<string, Set<Listener>>();
  postError: Error | null = null;

  readonly webkit = {
    messageHandlers: {
      desktop: {
        postMessage: (message: unknown) => {
          if (this.postError) throw this.postError;
          this.messages.push(message);
        },
      },
    },
  };

  addEventListener(type: string, listener: EventListenerOrEventListenerObject) {
    const callback = listener as Listener;
    const listeners = this.listeners.get(type) ?? new Set<Listener>();
    listeners.add(callback);
    this.listeners.set(type, listeners);
  }

  removeEventListener(type: string, listener: EventListenerOrEventListenerObject) {
    this.listeners.get(type)?.delete(listener as Listener);
  }

  emit(detail: unknown) {
    const event = { type: 'aiplayer:native', detail } as unknown as Event;
    for (const listener of [...(this.listeners.get('aiplayer:native') ?? [])]) listener(event);
  }

  listenerCount() {
    return this.listeners.get('aiplayer:native')?.size ?? 0;
  }
}

const validState: NativeState = {
  available: true,
  engine: 'libmpv',
  paused: false,
  time: 12,
  duration: 120,
  volume: 80,
  speed: 1,
  muted: false,
  title: '测试影片',
  tracks: [{ id: 1, type: 'video', selected: true }],
  chapters: [{ time: 0, title: '开始' }],
  width: 1920,
  height: 1080,
  subtitleDelay: 0,
  audioDelay: 0,
};

describe('native player bridge', () => {
  let harness: NativeWindowHarness;

  beforeEach(() => {
    harness = new NativeWindowHarness();
    vi.stubGlobal('window', harness as unknown as Window);
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  test('detects only a callable desktop WebKit message handler', () => {
    expect(nativeAvailable()).toBe(true);
    vi.stubGlobal('window', { webkit: { messageHandlers: {} } } as unknown as Window);
    expect(nativeAvailable()).toBe(false);
    vi.stubGlobal('window', undefined);
    expect(nativeAvailable()).toBe(false);
  });

  test('correlates replies, ignores unrelated and malformed events, and cleans up', async () => {
    const request = nativeRequest<{ accepted: boolean }>('load', { id: 'local_1' });
    const sent = harness.messages[0] as {
      id: string;
      command: string;
      args: Record<string, unknown>;
    };
    let settled = false;
    void request.finally(() => {
      settled = true;
    });

    expect(sent.command).toBe('load');
    expect(sent.args).toEqual({ id: 'local_1' });
    expect(sent.id).toEqual(expect.any(String));
    expect(harness.listenerCount()).toBe(1);

    harness.emit({ id: 'another-request', result: { accepted: false } });
    harness.emit({ event: 'state', state: validState });
    harness.emit({ id: sent.id });
    harness.emit('bad detail');
    await Promise.resolve();
    expect(settled).toBe(false);

    harness.emit({ id: sent.id, result: { accepted: true } });
    await expect(request).resolves.toEqual({ accepted: true });
    expect(harness.listenerCount()).toBe(0);
  });

  test('rejects native errors and removes its reply listener', async () => {
    const request = nativeRequest('screenshot');
    const { id } = harness.messages[0] as { id: string };

    harness.emit({ id, error: 'Save was cancelled' });

    await expect(request).rejects.toThrow('Save was cancelled');
    expect(harness.listenerCount()).toBe(0);
  });

  test.each(['openFiles', 'importSubtitle', 'screenshot', 'captureGif', 'capturePoster', 'recordStart', 'recordStop', 'gifStop'])('keeps %s alive while a user chooses a file or a bounded capture runs', async (command) => {
    vi.useFakeTimers();
    const request = nativeRequest(command);
    const { id } = harness.messages[0] as { id: string };
    let settled = false;
    void request.then(() => { settled = true; }, () => { settled = true; });
    await vi.advanceTimersByTimeAsync(60_000);
    expect(settled).toBe(false);
    harness.emit({ id, result: [], error: null });
    await expect(request).resolves.toEqual([]);
    expect(harness.listenerCount()).toBe(0);
  });

  test('ignores mixed state/reply payloads and invalid error shapes', async () => {
    const request = nativeRequest('getState');
    const { id } = harness.messages[0] as { id: string };
    let settled = false;
    void request.then(() => { settled = true; }, () => { settled = true; });
    harness.emit({ id, event: 'state', state: validState, result: validState });
    harness.emit({ id, result: validState, error: 42 });
    harness.emit({ id, result: validState, error: 'conflicting result' });
    await Promise.resolve();
    expect(settled).toBe(false);
    harness.emit({ id, result: validState, error: null });
    await expect(request).resolves.toEqual(validState);
  });

  test('cancels a modal request and removes listeners when its page closes', async () => {
    const request = nativeRequest('importSubtitle');
    const rejection = expect(request).rejects.toThrow(/closed|cancel/i);
    for (const listener of [...(harness.listeners.get('pagehide') ?? [])]) {
      listener({ type: 'pagehide' } as Event);
    }
    await rejection;
    expect(harness.listenerCount()).toBe(0);
    expect(harness.listeners.get('pagehide')?.size ?? 0).toBe(0);
  });

  test('times out an unanswered request and removes its listener', async () => {
    vi.useFakeTimers();
    const request = nativeRequest('getState');
    const rejection = expect(request).rejects.toThrow(/timed out/i);
    expect(harness.listenerCount()).toBe(1);

    await vi.advanceTimersByTimeAsync(10_000);

    await rejection;
    expect(harness.listenerCount()).toBe(0);
  });

  test('fails safely and leaves no listener when the native host is missing or postMessage throws', async () => {
    vi.stubGlobal('window', {} as Window);
    await expect(nativeRequest('getState')).rejects.toThrow(/unavailable/i);

    vi.stubGlobal('window', harness as unknown as Window);
    harness.postError = new Error('host closed');
    await expect(nativeRequest('getState')).rejects.toThrow('host closed');
    expect(harness.listenerCount()).toBe(0);
  });

  test('subscribes only to valid state events, isolates replies, and unsubscribes cleanly', () => {
    const observed: NativeState[] = [];
    const unsubscribe = subscribeNativeState((state) => observed.push(state));

    harness.emit({ id: 'reply', result: validState });
    harness.emit({ event: 'state', state: { ...validState, duration: '120' } });
    harness.emit({ event: 'state', state: { ...validState, recording: 42 } });
    harness.emit({ event: 'state', state: { ...validState, exporting: 'yes' } });
    harness.emit({ event: 'state', state: validState });
    expect(observed).toEqual([validState]);
    expect(harness.listenerCount()).toBe(1);

    unsubscribe();
    unsubscribe();
    harness.emit({ event: 'state', state: { ...validState, time: 13 } });
    expect(observed).toEqual([validState]);
    expect(harness.listenerCount()).toBe(0);
  });

  test('validates the native GIF lifecycle and rejects malformed elapsed time or flags', () => {
    const observed: NativeState[] = [];
    const unsubscribe = subscribeNativeState((state) => observed.push(state));
    for (const patch of [{ gifCapturing: 'yes' }, { gifExporting: 1 }, { gifElapsed: -1 }, { gifElapsed: Infinity }, { gifSavedName: 5 }, { gifError: 0 }]) {
      harness.emit({ event: 'state', state: { ...validState, ...patch } });
    }
    expect(observed).toHaveLength(0);
    harness.emit({ event: 'state', state: { ...validState, gifCapturing: true, gifExporting: false, gifElapsed: 12.4 } });
    expect(observed).toHaveLength(1);
    unsubscribe();
  });
});
