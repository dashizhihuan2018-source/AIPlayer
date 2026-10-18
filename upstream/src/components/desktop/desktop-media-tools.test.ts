// @vitest-environment jsdom
import { act, createElement } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { DesktopMediaTools } from './desktop-media-tools';

type Props = Parameters<typeof DesktopMediaTools>[0];
type Request = { id: string; command: string; args: Record<string, unknown> };

describe('inline GIF capture controls', () => {
  let container: HTMLDivElement;
  let root: Root;
  let props: Props;
  let messages: Request[];
  let reply: (message: Request) => void;

  beforeEach(async () => {
    vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true);
    container = document.createElement('div');
    document.body.append(container);
    root = createRoot(container);
    messages = [];
    localStorage.clear();
    reply = (message) => window.dispatchEvent(new CustomEvent('aiplayer:native', { detail: {
      id: message.id, result: message.command === 'gifStart' ? { capturing: true } : message.command === 'gifCancel' ? { cancelled: true } : { saved: true, previewOpened: false, name: 'capture.gif', frames: 80, duration: 8 },
    } }));
    Object.defineProperty(window, 'webkit', { configurable: true, value: { messageHandlers: { desktop: { postMessage(message: Request) { messages.push(message); reply(message); } } } } });
    props = { capabilities: { available: true, engine: 'libmpv', commands: ['gifStart', 'gifStop', 'gifCancel', 'openGifFolder', 'captureGif', 'capturePoster', 'recordStart', 'recordStop', 'ocr'], openFiles: true, importSubtitle: true, screenshot: true, fullscreen: true }, hasMedia: true, recording: false, fullscreenActive: false, fullscreenTransitioning: false, onFullscreen: async () => {}, onStatus: vi.fn() };
    await render();
  });

  afterEach(async () => {
    await act(async () => root.unmount());
    container.remove();
    delete (window as Window & { webkit?: unknown }).webkit;
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  async function render(update: Record<string, unknown> = {}) {
    props = { ...props, ...update };
    await act(async () => root.render(createElement(DesktopMediaTools, props)));
  }

  async function click(label: string) {
    const button = container.querySelector<HTMLButtonElement>(`button[aria-label="${label}"]`);
    expect(button, label).not.toBeNull();
    expect(button!.disabled, label).toBe(false);
    await act(async () => button!.click());
  }

  it('starts immediately and stops on the second GIF click, saving without a dialog or preview', async () => {
    await click('制作 GIF');
    expect(messages.map((message) => message.command)).toEqual(['gifStart']);
    expect(messages[0].args).toEqual({ fps: 20, maximumWidth: 640 });
    expect(messages[0].args).not.toHaveProperty('duration');
    await render({ gifCapturing: true, gifElapsed: 8.2 });
    expect(container.textContent).toContain('00:08');
    expect(container.textContent).toContain('点击GIF图标停止');
    expect(container.querySelector('button[aria-label="截图"]')?.hasAttribute('disabled')).toBe(true);
    expect(container.querySelector('[role="dialog"]')).toBeNull();
    await click('停止 GIF 录制');
    expect(messages.map((message) => message.command)).toEqual(['gifStart', 'gifStop']);
    expect(props.onStatus).toHaveBeenLastCalledWith('GIF已自动保存，悬停 GIF 图标并选择“打开 GIF 文件夹”查看');
    expect(container.textContent).not.toContain('预览');
  });

  it('keeps recording beyond the old three-second limit and follows native elapsed time', async () => {
    vi.useFakeTimers();
    await click('制作 GIF');
    await act(async () => vi.advanceTimersByTimeAsync(12_000));
    await render({ gifCapturing: true, gifElapsed: 12.4 });
    expect(container.textContent).toContain('00:12');
    expect(messages.map((message) => message.command)).toEqual(['gifStart']);
    expect(container.querySelector('button[aria-label="停止 GIF 录制"]')?.hasAttribute('disabled')).toBe(false);
  });

  it('cancels a recording without saving, opening a window or sending a stop', async () => {
    await click('制作 GIF');
    await render({ gifCapturing: true, gifElapsed: 4 });
    await click('取消 GIF 录制');
    await render({ gifCapturing: false });
    expect(messages.map((message) => message.command)).toEqual(['gifStart', 'gifCancel']);
    expect(props.onStatus).toHaveBeenLastCalledWith('已取消 GIF 录制，未保存文件');
    expect(container.querySelector('[role="dialog"]')).toBeNull();
  });

  it('recovers the GIF button after start failure and reports a useful error', async () => {
    reply = (message) => window.dispatchEvent(new CustomEvent('aiplayer:native', { detail: { id: message.id, error: '磁盘空间不足' } }));
    await click('制作 GIF');
    expect(props.onStatus).toHaveBeenCalledWith('磁盘空间不足');
    expect(container.querySelector('button[aria-label="制作 GIF"]')?.hasAttribute('disabled')).toBe(false);
  });

  it('reports an unsuccessful start response instead of silently returning to idle', async () => {
    reply = (message) => window.dispatchEvent(new CustomEvent('aiplayer:native', { detail: { id: message.id, result: { capturing: false } } }));
    await click('制作 GIF');
    expect(props.onStatus).toHaveBeenCalledWith('GIF 未开始录制，请重试');
  });

  it('keeps encoding inline and disabled until the native save completes', async () => {
    await render({ gifCapturing: true, gifElapsed: 8 });
    await render({ gifCapturing: false, gifExporting: true });
    expect(container.textContent).toContain('正在保存 GIF');
    expect(container.querySelector('button[aria-label="正在处理 GIF"]')?.hasAttribute('disabled')).toBe(true);
    expect(container.querySelector('[role="dialog"]')).toBeNull();
    await render({ gifExporting: false, gifSavedName: 'encoded.gif' });
    expect(container.querySelector('button[aria-label="制作 GIF"]')?.hasAttribute('disabled')).toBe(false);
  });

  it('ignores an overlapping click while the native start acknowledgement is pending', async () => {
    reply = () => {};
    await click('制作 GIF');
    const button = container.querySelector<HTMLButtonElement>('button[aria-label="正在处理 GIF"]');
    await act(async () => button!.click());
    expect(messages).toHaveLength(1);
    await act(async () => window.dispatchEvent(new CustomEvent('aiplayer:native', { detail: { id: messages[0].id, result: { capturing: true } } })));
    expect(container.querySelector('button[aria-label="停止 GIF 录制"]')?.hasAttribute('disabled')).toBe(false);
  });

  it('shows only small inline recording text without any thumbnail card or dialog', async () => {
    const thumbnail = 'data:image/png;base64,aGVsbG8=';
    await render({ gifCapturing: true, gifElapsed: 5, gifThumbnail: thumbnail });
    expect(container.querySelector('.gif-inline-image')).toBeNull();
    expect(container.querySelector('img')).toBeNull();
    expect(container.querySelector('.gif-inline-capture')?.textContent).toContain('点击GIF图标停止');
    expect(container.querySelector('[role="dialog"]')).toBeNull();
  });

  it('announces EOF auto-save once and never opens a result preview', async () => {
    await render({ gifCapturing: true, gifElapsed: 6 });
    await render({ gifCapturing: false, gifSavedName: 'eof.gif' });
    expect(props.onStatus).toHaveBeenCalledTimes(1);
    expect(props.onStatus).toHaveBeenCalledWith('GIF已自动保存，悬停 GIF 图标并选择“打开 GIF 文件夹”查看');
    await render({ gifCapturing: false, gifSavedName: 'eof.gif', gifElapsed: 6.1 });
    expect(props.onStatus).toHaveBeenCalledTimes(1);
    expect(container.querySelector('[role="dialog"]')).toBeNull();
    expect(messages).toHaveLength(0);
  });

  it('keeps the frame rate choice within the existing toolbar settings', async () => {
    const select = container.querySelector<HTMLSelectElement>('select[aria-label="GIF 帧率"]');
    expect(select).not.toBeNull();
    await act(async () => { select!.value = '15'; select!.dispatchEvent(new Event('change', { bubbles: true })); });
    await click('制作 GIF');
    expect(messages[0].args).toEqual({ fps: 15, maximumWidth: 640 });
  });

  it('persists the user-selected 4K setting across a remount', async () => {
    const select = container.querySelector<HTMLSelectElement>('select[aria-label="GIF 分辨率"]');
    expect(select).not.toBeNull();
    expect(select!.value).toBe('640');
    await act(async () => { select!.value = '3840'; select!.dispatchEvent(new Event('change', { bubbles: true })); });
    await act(async () => root.unmount());
    root = createRoot(container);
    await render();
    expect(container.querySelector<HTMLSelectElement>('select[aria-label="GIF 分辨率"]')?.value).toBe('3840');
    await click('制作 GIF');
    expect(messages[0].args).toEqual({ fps: 20, maximumWidth: 3840 });
    expect(container.textContent).not.toContain('预览');
  });

  it('keeps an obvious folder button available even without media and routes it to native openGifFolder', async () => {
    await render({ hasMedia: false });
    await click('打开 GIF 文件夹');
    expect(messages).toHaveLength(1);
    expect(messages[0]).toMatchObject({ command: 'openGifFolder', args: {} });
  });

  it('reveals settings and folder only in the GIF hover submenu and hides it after leaving', async () => {
    const tool = container.querySelector('.gif-tool')!;
    const panel = () => container.querySelector<HTMLElement>('[aria-label="GIF 子菜单"]');
    expect(panel()).not.toBeNull();
    expect(panel()!.hidden).toBe(true);
    expect(tool.contains(container.querySelector('button[aria-label="打开 GIF 文件夹"]'))).toBe(true);
    expect(container.querySelector('summary')).toBeNull();
    await act(async () => tool.dispatchEvent(new MouseEvent('mouseover', { bubbles: true })));
    expect(panel()!.hidden).toBe(false);
    await act(async () => tool.dispatchEvent(new MouseEvent('mouseout', { bubbles: true, relatedTarget: document.body })));
    expect(panel()!.hidden).toBe(true);
  });

  it('offers keyboard focus and Escape access to the same submenu without starting capture', async () => {
    const button = container.querySelector<HTMLButtonElement>('button[aria-label="制作 GIF"]')!;
    await act(async () => button.focus());
    expect(container.querySelector<HTMLElement>('[aria-label="GIF 子菜单"]')!.hidden).toBe(false);
    await act(async () => button.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })));
    expect(container.querySelector<HTMLElement>('[aria-label="GIF 子菜单"]')!.hidden).toBe(true);
    expect(messages).toHaveLength(0);
  });

  it('routes the submenu recording speed through the shared playback speed control', async () => {
    const onPlaybackSpeed = vi.fn();
    await render({ playbackSpeed: 1.5, onPlaybackSpeed });
    const select = container.querySelector<HTMLSelectElement>('select[aria-label="GIF 播放速度"]');
    expect(select).not.toBeNull();
    expect(select!.value).toBe('1.5');
    await act(async () => { select!.value = '2'; select!.dispatchEvent(new Event('change', { bubbles: true })); });
    expect(onPlaybackSpeed).toHaveBeenCalledWith(2);
    expect(messages).toHaveLength(0);
  });
});
