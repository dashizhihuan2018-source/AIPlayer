// @vitest-environment jsdom
import { act, createElement } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { DesktopWorkspace, type ExternalPlayback } from './desktop-workspace';
import type { NativeRequestMessage, NativeState } from '@/lib/native-player';
vi.mock('@/components/history-panel', () => ({ HistoryPanel: () => null }));
vi.mock('@/components/download-manager', () => ({ requestShowDownloadManager() {} }));

describe('actual workspace playback feature integration', () => {
  let root: Root | null = null;
  afterEach(async () => {
    if (root) await act(async () => root?.unmount());
    root = null;
    document.body.innerHTML = '';
    localStorage.clear();
    Reflect.deleteProperty(window, 'webkit');
    vi.unstubAllGlobals();
  });
  it('automatically seeks once, preserves rewind, and routes both menu settings', async () => {
    vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true);
    vi.stubGlobal('ResizeObserver', class { observe() {} disconnect() {} });
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: true, json: async () => ({ supported: true, duration: 40, ranges: [{ start: 10, end: 20 }, { start: 25, end: 30 }] }) })));
    let state: NativeState = { available: true, engine: 'libmpv', paused: false, time: 0, duration: 40,
      volume: 100, speed: 1, muted: false, title: 'Owned test', tracks: [], chapters: [], width: 960, height: 540, subtitleDelay: 0, audioDelay: 0, keepAwake: true };
    const messages: NativeRequestMessage[] = [];
    const emitState = () => window.dispatchEvent(new CustomEvent('aiplayer:native', { detail: { event: 'state', state } }));
    Object.defineProperty(window, 'webkit', { configurable: true, value: { messageHandlers: { desktop: {
      postMessage: (message: NativeRequestMessage) => {
        messages.push(message);
        let result: unknown = state;
        if (message.command === 'capabilities') result = { available: true, engine: 'libmpv', commands: ['pause', 'seek'], openFiles: true, importSubtitle: false, screenshot: false, fullscreen: true };
        if (message.command === 'keepAwake') state = { ...state, keepAwake: Boolean(message.args.enabled) };
        if (message.command === 'command' && message.args.name === 'seek') state = { ...state, time: Number(message.args.value) };
        if (message.command !== 'capabilities') result = state;
        queueMicrotask(() => window.dispatchEvent(new CustomEvent('aiplayer:native', { detail: { id: message.id, result } })));
      },
    } } } });
    const container = document.createElement('div'); document.body.appendChild(container); root = createRoot(container);
    await act(async () => {
      root!.render(createElement<{ externalPlayback?: ExternalPlayback }>(DesktopWorkspace, { externalPlayback: { items: [{ id: 'owned-online', kind: 'url', name: 'Owned test', url: 'https://media.example/owned.m3u8' }], currentIndex: 0, onSelect() {} } }));
    });
    const seeks = () => messages.filter((m) => m.command === 'command' && m.args.name === 'seek').map((m) => m.args.value);
    await act(async () => { state = { ...state, time: 11 }; emitState(); });
    expect(seeks()).toEqual([20]);
    await act(async () => { state = { ...state, time: 11 }; emitState(); });
    expect(seeks()).toEqual([20]);
    await act(async () => (container.querySelector('[aria-label="打开播放器菜单"]') as HTMLButtonElement).click());
    const checks = Array.from(container.querySelectorAll<HTMLInputElement>('.player-menu-popover input'));
    expect(checks).toHaveLength(2);
    await act(async () => checks[0].click());
    expect(messages.some((m) => m.command === 'keepAwake' && m.args.enabled === false)).toBe(true);
    await act(async () => checks[1].click());
    expect(localStorage.getItem('aiplayer.autoSkipAds')).toBe('false');
    await act(async () => { state = { ...state, time: 26 }; emitState(); });
    expect(seeks()).toEqual([20]);
  });
});
