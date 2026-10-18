import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  adjustCurrentAfterMove,
  adjustCurrentAfterRemove,
  clipVideoRect,
  consumeEndedEdge,
  parseNativeCapabilities,
  playbackMode,
  selectAB,
  supportsNativeCommand,
  userFacingError,
  isSafeMediaId,
  parseWorkspaceMemory,
  rememberMedia,
  queueView,
  parsePlayerPreferences,
  parseOpenMediaEvent,
  resolveLoadSelection,
  supportsMediaTool,
  isCurrentLoadRequest,
  parseWindowState,
  recordingResultMessage,
  captureResultMessage,
  replaceSleepTimer,
  queueStepIndex,
  canRequestFullscreen,
} from '@/components/desktop/desktop-workspace-logic';

afterEach(() => vi.useRealTimers());

const source = (path: string) => {
  try {
    return readFileSync(resolve(process.cwd(), path), 'utf8');
  } catch {
    return '';
  }
};

describe('desktop workspace shell', () => {
  const page = source('src/app/page.tsx');
  const discover = source('src/app/discover/page.tsx');
  const workspace = source('src/components/desktop/desktop-workspace.tsx');
  const css = source('src/app/desktop.css');

  it('makes the player workstation the default route and keeps discover reachable without live entry', () => {
    expect(page).toContain("import { DesktopWorkspace }");
    expect(page).toContain('<DesktopWorkspace />');
    expect(workspace).toContain('href="/discover"');
    expect(workspace).not.toContain('href="/live"');
    expect(workspace).not.toContain('href="/history"');
    expect(workspace).not.toContain('href="/downloads"');
    expect(discover).toContain('router.push(`/discover?s=${encodeURIComponent(query)}`');
    expect(discover).not.toContain('router.push(`/?s=');
  });

  it('places the brand logo to the left of the large discover title and removes the live header entry', () => {
    expect(discover).toContain('data-testid="discover-brand"');
    const brand = discover.slice(discover.indexOf('data-testid="discover-brand"'), discover.indexOf('{urlQuery && <h1'));
    expect(brand.indexOf('/icons/aiplayer-master.png')).toBeGreaterThan(0);
    expect(brand.indexOf('/icons/aiplayer-master.png')).toBeLessThan(brand.indexOf('<h1'));
    expect(source('src/components/header.tsx')).not.toContain('href="/live"');
  });

  it('exposes honest local open, queue, and browser fallback surfaces', () => {
    expect(workspace).toContain('data-testid="desktop-workspace"');
    expect(workspace).toContain('<DesktopHome onOpen={chooseMedia}');
    expect(source('src/components/desktop/desktop-home.tsx')).toContain('data-testid="open-local-media"');
    expect(workspace).toContain('data-testid="browser-media-input"');
    expect(workspace).toContain('data-testid="play-queue"');
    expect(workspace).toContain("nativeRequest<MediaItem[]>('openFiles'");
    expect(workspace).toContain("nativeRequest<NativeState>('load'");
    expect(workspace).toContain('parseQueue(');
  });

  it('keeps native video geometry synchronized and hides it when the surface leaves', () => {
    expect(workspace).toContain('ResizeObserver');
    expect(workspace).toContain('MutationObserver');
    expect(workspace).toContain("document.querySelector('[role=\"dialog\"], [role=\"alertdialog\"]')");
    expect(workspace).toContain("nativeRequest('setVideoRect'");
    expect(workspace).toContain("nativeRequest('hideVideo'");
    expect(workspace).toContain("window.addEventListener('scroll'");
  });

  it('keeps the selected item stable while queue rows move or are removed', () => {
    expect(adjustCurrentAfterMove(2, 2, 0)).toBe(0);
    expect(adjustCurrentAfterMove(2, 0, 3)).toBe(1);
    expect(adjustCurrentAfterMove(2, 4, 1)).toBe(3);
    expect(adjustCurrentAfterRemove(2, 0)).toBe(1);
    expect(adjustCurrentAfterRemove(2, 2)).toBe(-1);
  });

  it('renders a focused screening stage rather than the old search homepage', () => {
    expect(workspace).toContain('data-testid="screening-stage"');
    expect(workspace).toContain('aria-label="播放控制"');
    expect(workspace).toContain("['audio', '音频'], ['subtitle', '字幕']");
    expect(workspace).toContain('A–B 循环');
    expect(css).toContain('--desk-signal: #ffcb39');
    expect(css).toContain('.screening-stage');
    expect(css).toContain('.desk-inspector.is-collapsed { display: none; }');
    expect(workspace).not.toContain('RecommendSection');
  });

  it('validates the native capability payload and distinguishes host from a ready engine', () => {
    const valid = parseNativeCapabilities({
      available: true,
      engine: 'libmpv 0.40',
      commands: ['pause', 'seek'],
      openFiles: true,
      importSubtitle: true,
      screenshot: true,
      fullscreen: true,
    });
    expect(valid).not.toBeNull();
    expect(playbackMode(false, null)).toBe('browser');
    expect(playbackMode(true, null)).toBe('probing');
    expect(playbackMode(true, { ...valid!, available: false })).toBe('browser');
    expect(playbackMode(true, valid)).toBe('native');
    expect(supportsNativeCommand(valid, 'pause')).toBe(true);
    expect(supportsNativeCommand(valid, 'volume')).toBe(false);
    expect(parseNativeCapabilities({ ...valid, commands: ['pause', 4] })).toBeNull();
    expect(parseNativeCapabilities({ ...valid, screenshot: 'yes' })).toBeNull();
  });

  it('clips partially visible video rectangles and hides fully offscreen surfaces', () => {
    expect(clipVideoRect({ left: -30, top: 10, right: 170, bottom: 110 }, 300, 200)).toEqual({
      x: 0, y: 10, width: 170, height: 100, visible: true,
    });
    expect(clipVideoRect({ left: 250, top: 150, right: 350, bottom: 250 }, 300, 200)).toEqual({
      x: 250, y: 150, width: 50, height: 50, visible: true,
    });
    expect(clipVideoRect({ left: -200, top: 10, right: -10, bottom: 100 }, 300, 200)).toBeNull();
    expect(clipVideoRect({ left: NaN, top: 0, right: 10, bottom: 10 }, 300, 200)).toBeNull();
  });

  it('consumes each EOF rising edge once and rearms after a new load state', () => {
    expect(consumeEndedEdge(false, false)).toEqual({ latched: false, advance: false });
    expect(consumeEndedEdge(false, true)).toEqual({ latched: true, advance: true });
    expect(consumeEndedEdge(true, true)).toEqual({ latched: true, advance: false });
    expect(consumeEndedEdge(true, false)).toEqual({ latched: false, advance: false });
    expect(consumeEndedEdge(false, true)).toEqual({ latched: true, advance: true });
    expect(consumeEndedEdge(true, true, true)).toEqual({ latched: true, advance: false });
    expect(consumeEndedEdge(false, true, true)).toEqual({ latched: false, advance: false });
  });

  it('rejects either A or B point when the resulting interval is invalid', () => {
    expect(selectAB(null, null, 'a', 12)).toEqual({ a: 12, b: null });
    expect(selectAB(12, null, 'b', 20)).toEqual({ a: 12, b: 20 });
    expect(selectAB(12, 20, 'a', 21)).toEqual({ a: 12, b: 20, error: 'A 点必须早于 B 点' });
    expect(selectAB(12, 20, 'b', 8)).toEqual({ a: 12, b: 20, error: 'B 点必须晚于 A 点' });
  });

  it('keeps native English/internal failures out of user-facing status text', () => {
    expect(userFacingError(new Error('字幕文件无效'), '操作失败')).toBe('字幕文件无效');
    expect(userFacingError(new Error('Native request timed out'), '操作失败')).toBe('操作失败');
    expect(userFacingError(null, '操作失败')).toBe('操作失败');
  });

  it('persists progress and named bookmarks only under safe opaque media ids', () => {
    expect(isSafeMediaId('media_Ab-12')).toBe(true);
    expect(isSafeMediaId('browser:file.mov')).toBe(false);
    const saved = rememberMedia({ version: 1, items: {} }, 'media_Ab-12', {
      position: 42.5,
      bookmarks: [{ id: 'bm_1', label: '开场', time: 12 }],
    });
    expect(parseWorkspaceMemory(saved)).toEqual(saved);
    expect(rememberMedia(saved, '../private.mov', { position: 99, bookmarks: [] })).toBe(saved);
    expect(parseWorkspaceMemory({ version: 1, items: { bad: { position: -1, bookmarks: [] } } })).toEqual({ version: 1, items: {} });
  });

  it('builds searchable filtered sorted queue views without losing original identity', () => {
    const items = [
      { id: 'c', name: 'Zulu.mp4', kind: 'local' as const },
      { id: 'a', name: 'alpha.m3u8', kind: 'url' as const },
      { id: 'b', name: 'Beta.mp4', kind: 'local' as const },
    ];
    expect(queueView(items, { query: '', kind: 'all', sort: 'name-asc' }).map(({ item, index }) => [item.id, index])).toEqual([['a', 1], ['b', 2], ['c', 0]]);
    expect(queueView(items, { query: 'a', kind: 'all', sort: 'name-asc' }).map(({ item }) => item.id)).toEqual(['a', 'b']);
    expect(queueView(items, { query: '', kind: 'local', sort: 'manual' }).map(({ item, index }) => [item.id, index])).toEqual([['c', 0], ['b', 2]]);
  });

  it('restores bounded player preferences and rejects malformed values', () => {
    expect(parsePlayerPreferences({ speed: 1.5, seekStep: 30, pauseWhenHidden: true })).toEqual({ speed: 1.5, seekStep: 30, pauseWhenHidden: true });
    expect(parsePlayerPreferences({ speed: 99, seekStep: -4, pauseWhenHidden: 'yes' })).toEqual({ speed: 1, seekStep: 10, pauseWhenHidden: false });
  });

  it('commits load selection only after the latest request succeeds', () => {
    const previous = { currentIndex: 2, endedLatched: true };
    expect(resolveLoadSelection(previous, 4, false, true)).toBe(previous);
    expect(resolveLoadSelection(previous, 4, true, false)).toBe(previous);
    expect(resolveLoadSelection(previous, 4, true, true)).toEqual({ currentIndex: 4, endedLatched: false });
  });

  it('accepts only safe native open-media events before adding them to the queue', () => {
    expect(parseOpenMediaEvent({
      event: 'openMedia',
      items: [
        { id: 'media_1', name: 'Film.mkv', kind: 'local' },
        { id: 'stream_1', name: 'Live', kind: 'url', url: 'https://example.com/live.m3u8' },
      ],
    })).toEqual([
      { id: 'media_1', name: 'Film.mkv', kind: 'local' },
      { id: 'stream_1', name: 'Live', kind: 'url', url: 'https://example.com/live.m3u8' },
    ]);
    expect(parseOpenMediaEvent({ event: 'openMedia', items: [{ id: '../movie', name: 'Bad', kind: 'local' }] })).toBeNull();
    expect(parseOpenMediaEvent({ event: 'openMedia', items: [{ id: 'url_1', name: 'Bad', kind: 'url', url: 'file:///tmp/a' }] })).toBeNull();
    expect(parseOpenMediaEvent({ event: 'state', items: [] })).toBeNull();
  });

  it('gates native media tools against the exact advertised capability', () => {
    const capabilities = parseNativeCapabilities({
      available: true,
      engine: 'libmpv',
      commands: ['ocr', 'captureGif', 'recordStart', 'recordStop'],
      openFiles: true,
      importSubtitle: true,
      screenshot: true,
      fullscreen: true,
    });
    expect(supportsMediaTool(capabilities, 'screenshot')).toBe(true);
    expect(supportsMediaTool(capabilities, 'captureGif')).toBe(true);
    expect(supportsMediaTool(capabilities, 'pictureInPicture')).toBe(false);
    expect(supportsMediaTool(capabilities && { ...capabilities, available: false }, 'ocr')).toBe(false);
  });

  it('invalidates a pending load when the privacy generation changes', () => {
    expect(isCurrentLoadRequest({ request: 4, generation: 2 }, 4, 2)).toBe(true);
    expect(isCurrentLoadRequest({ request: 4, generation: 2 }, 5, 2)).toBe(false);
    expect(isCurrentLoadRequest({ request: 4, generation: 2 }, 4, 3)).toBe(false);
  });

  it('validates native window state events and recording outcomes', () => {
    expect(parseWindowState({ event: 'windowState', fullscreen: false, pictureInPicture: true })).toEqual({ fullscreen: false, pictureInPicture: true, transitioning: false });
    expect(parseWindowState({ fullscreen: true, pictureInPicture: false, transitioning: true })).toEqual({ fullscreen: true, pictureInPicture: false, transitioning: true });
    expect(parseWindowState({ event: 'windowState', pictureInPicture: 'yes' })).toBeNull();
    expect(parseWindowState({ fullscreen: true, pictureInPicture: false, transitioning: 'yes' })).toBeNull();
    expect(recordingResultMessage('recordStart', { recording: false, saved: false })).toBe('已取消录制保存');
    expect(recordingResultMessage('recordStart', { recording: true, saved: true })).toContain('已开始录制');
    expect(recordingResultMessage('recordStop', { recording: false })).toBe('录制已停止，尚未保存');
    expect(recordingResultMessage('recordStart', { recording: false, panelOpened: true, saved: false })).toContain('选择录制范围');
    expect(recordingResultMessage('recordStop', { recording: false, previewOpened: true, saved: false })).toContain('预览');
    expect(recordingResultMessage('recordStop', { recording: false, saved: true })).toBe('录制已保存');
    expect(recordingResultMessage('recordStop', { recording: false, saved: true, previewOpened: true })).toBe('录制已保存');
    expect(recordingResultMessage('recordStart', { recording: true, exporting: true, saved: false })).toContain('自动保存');
    expect(recordingResultMessage('recordStop', { recording: false, saved: false, previewOpened: true })).not.toContain('另存');
    expect(recordingResultMessage('recordStart', { recording: true, saved: false })).toContain('已开始录制');
    expect(recordingResultMessage('recordStop', { recording: false, saved: false, cancelled: true })).toBe('已取消片段导出，原视频未修改');
    expect(recordingResultMessage('recordStart', { recording: true, exporting: true, saved: false })).toContain('正在导出选定片段');
  });

  it('clears a minute timer when switching to end-of-media sleep', () => {
    vi.useFakeTimers();
    let pauses = 0;
    const first = replaceSleepTimer(null, 15, () => { pauses += 1; });
    const atEnd = replaceSleepTimer(first.timer, -1, () => { pauses += 1; });
    vi.advanceTimersByTime(15 * 60_000);
    expect(pauses).toBe(0);
    expect(atEnd).toEqual({ timer: null, minutes: 0, atEnd: true });
  });

  it('reports automatic tool saves only after the native result confirms persistence', () => {
    expect(captureResultMessage('screenshot', { saved: true, previewOpened: true })).toContain('自动保存');
    expect(captureResultMessage('gif', { saved: true })).toContain('GIF');
    expect(captureResultMessage('poster', { saved: true })).toContain('Posters');
    expect(captureResultMessage('screenshot', { saved: false, previewOpened: true })).toContain('尚未保存');
    expect(captureResultMessage('gif', { saved: false, cancelled: true })).toBe('');
    expect(captureResultMessage('poster', null)).toBe('');
  });

  it('gates repeated native fullscreen requests while AppKit is transitioning', () => {
    expect(canRequestFullscreen(true, true, false)).toBe(true);
    expect(canRequestFullscreen(true, true, true)).toBe(false);
    expect(canRequestFullscreen(false, true, false)).toBe(false);
    expect(canRequestFullscreen(true, false, false)).toBe(false);
  });

  it('resolves real previous and next queue steps without confusing first and last', () => {
    expect(queueStepIndex(2, 5, -1, 'off', false)).toBe(1);
    expect(queueStepIndex(2, 5, 1, 'off', false)).toBe(3);
    expect(queueStepIndex(2, 5, -1, 'one', false)).toBe(1);
    expect(queueStepIndex(2, 5, 1, 'one', false)).toBe(3);
    expect(queueStepIndex(0, 5, -1, 'off', false)).toBe(-1);
    expect(queueStepIndex(0, 5, -1, 'all', false)).toBe(4);
    expect(queueStepIndex(4, 5, 1, 'off', false)).toBe(-1);
    expect(queueStepIndex(4, 5, 1, 'all', false)).toBe(0);
  });

  it('switches the workspace into a safe native fullscreen layout and cleans browser listeners', () => {
    expect(workspace).toContain("document.addEventListener('fullscreenchange'");
    expect(workspace).toContain("document.removeEventListener('fullscreenchange'");
    expect(workspace).toContain('windowEventRevision === queryRevision');
    expect(workspace).toContain("windowFullscreen ? 'is-window-fullscreen' : ''");
    expect(workspace).toContain('title="上一项"');
    expect(workspace).toContain('onClick={() => stepQueue(-1)}');
    expect(workspace).toContain('title="下一项"');
    expect(workspace).toContain('onClick={() => stepQueue(1)}');
    expect(css).toContain('.desk-main, .screening-stage, .video-surface');
    expect(css).toContain('position: absolute; inset: 0; width: 100%; height: 100%');
    expect(css).toContain('html.aiplayer-native-video-active .video-surface');
    expect(css).not.toContain('height: calc(100vh - 152px)');
  });

  it('floats on-demand inspectors above the video instead of shrinking the stage', () => {
    expect(workspace).toContain("setPanel('queue'); setCollapsed(panel === 'queue' && !collapsed)");
    expect(workspace).toContain("setPanel('picture'); setCollapsed(panel === 'picture' && !collapsed)");
    expect(css).toContain('.desk-inspector.is-collapsed { display: none; }');
    expect(css).toContain('inset: 40px 16px 75px auto');
    expect(css).not.toContain('--fullscreen-panel-width');
    expect(css).toContain('html.aiplayer-native-video-active body');
  });

  it('uses confirmed window events rather than optimistic PiP requests for the compact layout', () => {
    expect(workspace).toContain("pipActive ? 'is-picture-in-picture' : ''");
    expect(workspace).toContain('setPipActive(windowState.pictureInPicture)');
    expect(workspace).toContain('setPipActive(state.pictureInPicture)');
    expect(workspace).not.toContain('setPipActive(result.active)');
    expect(workspace).not.toContain('setPipActive(!pipActive)');
  });

  it('fits PiP video above a minimal 56px control row after all mobile overrides', () => {
    const pipStyles = css.slice(css.indexOf('/* Native picture-in-picture'));
    expect(css.indexOf('/* Native picture-in-picture')).toBeGreaterThan(css.lastIndexOf('@media (max-width: 520px)'));
    expect(pipStyles).toContain('.desktop-workspace.is-picture-in-picture');
    expect(pipStyles).toContain('grid-template-rows: minmax(0, 1fr) 56px');
    expect(pipStyles).toContain('min-height: 0');
    expect(pipStyles).toContain('aspect-ratio: auto');
    expect(pipStyles).toContain('position: static');
    expect(pipStyles).toContain('.is-picture-in-picture .player-menu');
    expect(pipStyles).toContain('.is-picture-in-picture .desk-topbar');
    expect(pipStyles).toContain('.is-picture-in-picture .desk-inspector');
    expect(pipStyles).toContain('.is-picture-in-picture .stage-toolstrip');
    expect(pipStyles).toContain('.is-picture-in-picture .transport');
    expect(pipStyles).toContain('.is-picture-in-picture .pip-transport');
    expect(workspace).toContain('aria-label="小窗播放控制"');
    expect(workspace).toContain('className="play-toggle pip-control"');
    expect(workspace.match(/className=\{`pip-control \$\{player\.muted/g)).toHaveLength(1);
    expect(workspace.match(/className=\{`pip-control \$\{pipActive/g)).toHaveLength(1);
  });
});
