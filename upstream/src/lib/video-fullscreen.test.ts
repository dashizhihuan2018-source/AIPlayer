import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, test } from 'vitest';

import {
  bindArtplayerFullscreen,
  createExclusiveFullscreenRequest,
  parseNativeWindowState,
  subscribeNativeWindowState,
  toggleWatchFullscreen,
  watchPlayerContainerClassName,
  watchMediaFrameClassName,
  type FullscreenDocument,
  type FullscreenElement,
  type FullscreenVideo,
} from './video-fullscreen';

function nativeWindowEvent(detail: unknown): Event {
  const event = new Event('aiplayer:native');
  Object.defineProperty(event, 'detail', { value: detail });
  return event;
}

class ClickTarget {
  private listeners = new Set<(event: Event) => void>();

  addEventListener(_type: string, listener: EventListenerOrEventListenerObject) {
    this.listeners.add(listener as (event: Event) => void);
  }

  removeEventListener(_type: string, listener: EventListenerOrEventListenerObject) {
    this.listeners.delete(listener as (event: Event) => void);
  }

  click(event: Event) {
    for (const listener of [...this.listeners]) listener(event);
  }
}

describe('watch player fullscreen routing', () => {
  test('uses the macOS native bridge when it is available', async () => {
    let nativeCalls = 0;
    let domCalls = 0;

    await expect(toggleWatchFullscreen({
      nativeAvailable: true,
      nativeToggle: async () => { nativeCalls += 1; },
      document: {} as FullscreenDocument,
      element: { requestFullscreen: async () => { domCalls += 1; } },
    })).resolves.toBe('native');

    expect(nativeCalls).toBe(1);
    expect(domCalls).toBe(0);
  });

  test('keeps standard DOM enter and exit fullscreen in a browser', async () => {
    let entered = 0;
    let exited = 0;
    const element: FullscreenElement = { requestFullscreen: async () => { entered += 1; } };
    const document = {
      fullscreenElement: null,
      exitFullscreen: async () => { exited += 1; },
    } as FullscreenDocument;

    await expect(toggleWatchFullscreen({ nativeAvailable: false, document, element })).resolves.toBe('browser-enter');
    document.fullscreenElement = element;
    await expect(toggleWatchFullscreen({ nativeAvailable: false, document, element })).resolves.toBe('browser-exit');

    expect(entered).toBe(1);
    expect(exited).toBe(1);
  });

  test('falls back to prefixed WebKit fullscreen APIs', async () => {
    let entered = 0;
    let exited = 0;
    const element: FullscreenElement = { webkitRequestFullscreen: () => { entered += 1; } };
    const document = {
      webkitFullscreenElement: null,
      webkitExitFullscreen: () => { exited += 1; },
    } as FullscreenDocument;

    await expect(toggleWatchFullscreen({ nativeAvailable: false, document, element })).resolves.toBe('webkit-enter');
    document.webkitFullscreenElement = element;
    await expect(toggleWatchFullscreen({ nativeAvailable: false, document, element })).resolves.toBe('webkit-exit');

    expect(entered).toBe(1);
    expect(exited).toBe(1);
  });

  test('uses the video WebKit fullscreen API only as the last browser fallback', async () => {
    let entered = 0;
    const video = { webkitEnterFullscreen: () => { entered += 1; } };

    await expect(toggleWatchFullscreen({
      nativeAvailable: false,
      document: {} as FullscreenDocument,
      element: {},
      video,
    })).resolves.toBe('webkit-video-enter');

    expect(entered).toBe(1);
  });

  test('exits prefixed video fullscreen when WebKit exposes only video-level state', async () => {
    let exited = 0;
    const video: FullscreenVideo = {
      webkitDisplayingFullscreen: true,
      webkitExitFullscreen: () => { exited += 1; },
    };

    await expect(toggleWatchFullscreen({
      nativeAvailable: false,
      document: {} as FullscreenDocument,
      element: {},
      video,
    })).resolves.toBe('webkit-video-exit');

    expect(exited).toBe(1);
  });

  test('rejects visibly when no real fullscreen implementation exists', async () => {
    await expect(toggleWatchFullscreen({
      nativeAvailable: false,
      document: {} as FullscreenDocument,
      element: {},
    })).rejects.toThrow('当前环境不支持全屏');
  });
});

describe('Artplayer fullscreen entry points', () => {
  test('routes toolbar clicks and Artplayer double-clicks through one handler and cleans up', () => {
    const target = new ClickTarget();
    const handlers = new Map<string, () => void>();
    const art = {
      controls: { fullscreen: target },
      on: (name: string, listener: () => void) => { handlers.set(name, listener); },
      off: (name: string, listener: () => void) => {
        if (handlers.get(name) === listener) handlers.delete(name);
      },
    };
    let toggles = 0;
    let prevented = 0;
    let stopped = 0;
    const event = {
      preventDefault: () => { prevented += 1; },
      stopImmediatePropagation: () => { stopped += 1; },
    } as unknown as Event;

    const unbind = bindArtplayerFullscreen(art, () => { toggles += 1; });
    target.click(event);
    handlers.get('dblclick')?.();

    expect(toggles).toBe(2);
    expect(prevented).toBe(1);
    expect(stopped).toBe(1);

    unbind();
    target.click(event);
    expect(handlers.has('dblclick')).toBe(false);
    expect(toggles).toBe(2);
  });

  test('applies native window enter and exit events, rejects malformed payloads, and cleans up', () => {
    const target = new EventTarget();
    const states: boolean[] = [];
    const unsubscribe = subscribeNativeWindowState(target, (state) => {
      states.push(state.fullscreen);
    });

    target.dispatchEvent(nativeWindowEvent({
      event: 'windowState', fullscreen: true, pictureInPicture: false,
    }));
    target.dispatchEvent(nativeWindowEvent({
      event: 'windowState', fullscreen: 'yes', pictureInPicture: false,
    }));
    target.dispatchEvent(nativeWindowEvent({
      event: 'state', fullscreen: false, pictureInPicture: false,
    }));
    target.dispatchEvent(nativeWindowEvent({
      event: 'windowState', fullscreen: false, pictureInPicture: false,
    }));

    expect(states).toEqual([true, false]);
    unsubscribe();
    target.dispatchEvent(nativeWindowEvent({
      event: 'windowState', fullscreen: true, pictureInPicture: false,
    }));
    expect(states).toEqual([true, false]);
  });

  test('strictly parses the initial native window-state response', () => {
    expect(parseNativeWindowState({ fullscreen: true, pictureInPicture: false })).toEqual({
      fullscreen: true,
      pictureInPicture: false,
    });
    expect(parseNativeWindowState({ fullscreen: true })).toBeNull();
    expect(parseNativeWindowState({ fullscreen: 1, pictureInPicture: false })).toBeNull();
  });

  test('rejects a duplicate fullscreen request while the first request is unresolved', async () => {
    let release: (() => void) | undefined;
    let calls = 0;
    const request = createExclusiveFullscreenRequest(() => {
      calls += 1;
      if (calls > 1) return Promise.resolve();
      return new Promise<void>((resolve) => { release = resolve; });
    });

    const first = request();
    await expect(request()).rejects.toThrow('全屏正在切换');
    expect(calls).toBe(1);
    release?.();
    await first;
    await request();
    expect(calls).toBe(2);
  });

  test('only the confirmed native window state expands the video over the full window', () => {
    expect(watchPlayerContainerClassName(false)).toBe('relative w-full h-full');
    expect(watchPlayerContainerClassName(true)).toContain('fixed inset-0');
    expect(watchPlayerContainerClassName(true)).toContain('bg-black');
  });

  test('removes the rounded clipping ancestor only while the native video is fullscreen', () => {
    expect(watchMediaFrameClassName(false)).toContain('overflow-hidden');
    expect(watchMediaFrameClassName(false)).toContain('aspect-video');
    expect(watchMediaFrameClassName(true)).not.toContain('overflow-hidden');
    expect(watchMediaFrameClassName(true)).not.toContain('rounded-lg');
    expect(watchMediaFrameClassName(true)).toContain('overflow-visible');
  });

  test('the watch player wires toolbar, keyboard, and double-click to the shared native-aware toggle', () => {
    const source = readFileSync(resolve(process.cwd(), 'src/components/player-shell.tsx'), 'utf8');

    expect(source).toContain("import { nativeAvailable, nativeRequest } from '@/lib/native-player'");
    expect(source).toContain('const useNativeFullscreen = nativeAvailable();');
    expect(source).toContain('toggleWatchFullscreen({');
    expect(source).toContain('nativeAvailable: useNativeFullscreen');
    expect(source).toContain("() => nativeRequest('fullscreen')");
    expect(source).toContain('nativeToggle: requestNativeFullscreen');
    expect(source).toContain('fullscreenWeb: !useNativeFullscreen');
    expect(source).toContain("nativeRequest('getWindowState')");
    expect(source).toContain('subscribeNativeWindowState(window');
    expect(source).toContain('watchPlayerContainerClassName(nativeWindowFullscreen)');
    expect(source).toContain('bindArtplayerFullscreen(art, requestFullscreen)');
    expect(source).toContain('Artplayer.DBCLICK_FULLSCREEN = false');
    expect(source).toContain("case 'f': case 'F':");
    expect(source).toContain('void requestFullscreen();');
    expect(source).not.toContain('current.fullscreen = !current.fullscreen');
  });
});
