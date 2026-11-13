import type { MediaItem } from '@/lib/native-player';
import { nextQueueIndex } from '@/lib/desktop-player';

export interface DesktopCapabilities {
  available: boolean;
  engine: string;
  commands: string[];
  openFiles: boolean;
  importSubtitle: boolean;
  screenshot: boolean;
  fullscreen: boolean;
}

export type PlaybackMode = 'browser' | 'probing' | 'native';
export type VideoRectangle = { x: number; y: number; width: number; height: number; visible: true };
export type ABSelection = { a: number | null; b: number | null; error?: string };
export type SavedBookmark = { id: string; label: string; time: number };
export type MediaMemory = { position: number; bookmarks: SavedBookmark[] };
export type WorkspaceMemory = { version: 1; items: Record<string, MediaMemory> };
export type QueueViewOptions = { query: string; kind: 'all' | 'local' | 'url'; sort: 'manual' | 'name-asc' | 'name-desc' };
export type PlayerPreferences = { speed: number; seekStep: number; pauseWhenHidden: boolean };
export type LoadSelection = { currentIndex: number; endedLatched: boolean };
export type LoadRequestToken = { request: number; generation: number };
export type DesktopWindowState = { fullscreen: boolean; pictureInPicture: boolean; transitioning: boolean; alwaysOnTop?: boolean };
export type SleepTimerState = { timer: ReturnType<typeof setTimeout> | null; minutes: number; atEnd: boolean };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

export function parseNativeCapabilities(value: unknown): DesktopCapabilities | null {
  if (!isRecord(value)) return null;
  if (typeof value.available !== 'boolean' || typeof value.engine !== 'string' || !value.engine.trim()) return null;
  if (!Array.isArray(value.commands) || !value.commands.every((command) => typeof command === 'string')) return null;
  const { openFiles, importSubtitle, screenshot, fullscreen } = value;
  if (typeof openFiles !== 'boolean' || typeof importSubtitle !== 'boolean' || typeof screenshot !== 'boolean' || typeof fullscreen !== 'boolean') return null;
  return {
    available: value.available,
    engine: value.engine,
    commands: [...new Set(value.commands)],
    openFiles,
    importSubtitle,
    screenshot,
    fullscreen,
  };
}

export function playbackMode(host: boolean, capabilities: DesktopCapabilities | null): PlaybackMode {
  if (!host) return 'browser';
  if (!capabilities) return 'probing';
  return capabilities.available ? 'native' : 'browser';
}

export function supportsNativeCommand(capabilities: DesktopCapabilities | null, name: string): boolean {
  return capabilities?.available === true && capabilities.commands.includes(name);
}

export function supportsMediaTool(capabilities: DesktopCapabilities | null, name: string): boolean {
  if (capabilities?.available !== true) return false;
  return name === 'screenshot' ? capabilities.screenshot : capabilities.commands.includes(name);
}

export function clipVideoRect(
  rect: { left: number; top: number; right: number; bottom: number },
  viewportWidth: number,
  viewportHeight: number,
): VideoRectangle | null {
  const values = [rect.left, rect.top, rect.right, rect.bottom, viewportWidth, viewportHeight];
  if (!values.every(Number.isFinite) || viewportWidth <= 0 || viewportHeight <= 0) return null;
  const x = Math.max(0, Math.min(viewportWidth, rect.left));
  const y = Math.max(0, Math.min(viewportHeight, rect.top));
  const right = Math.max(0, Math.min(viewportWidth, rect.right));
  const bottom = Math.max(0, Math.min(viewportHeight, rect.bottom));
  const width = right - x;
  const height = bottom - y;
  return width >= 1 && height >= 1 ? { x, y, width, height, visible: true } : null;
}

export function consumeEndedEdge(latched: boolean, ended: boolean, loadPending = false): { latched: boolean; advance: boolean } {
  if (loadPending) return { latched, advance: false };
  if (!ended) return { latched: false, advance: false };
  return { latched: true, advance: !latched };
}

export function selectAB(a: number | null, b: number | null, point: 'a' | 'b', time: number): ABSelection {
  if (!Number.isFinite(time) || time < 0) return { a, b, error: '当前时间无效' };
  if (point === 'a') {
    if (b !== null && time >= b) return { a, b, error: 'A 点必须早于 B 点' };
    return { a: time, b };
  }
  if (a === null || time <= a) return { a, b, error: 'B 点必须晚于 A 点' };
  return { a, b: time };
}

export function adjustCurrentAfterMove(selected: number, from: number, to: number): number {
  if (selected < 0 || from === to) return selected;
  if (selected === from) return to;
  if (from < selected && to >= selected) return selected - 1;
  if (from > selected && to <= selected) return selected + 1;
  return selected;
}

export function adjustCurrentAfterRemove(selected: number, removed: number): number {
  if (selected === removed) return -1;
  return selected > removed ? selected - 1 : selected;
}

export function userFacingError(error: unknown, fallback: string): string {
  const message = error instanceof Error ? error.message.trim() : '';
  return /[\u3400-\u9fff]/.test(message) ? message : fallback;
}

export function isSafeMediaId(id: string): boolean {
  return /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/.test(id);
}

function parseMediaMemory(value: unknown): MediaMemory | null {
  if (!isRecord(value) || typeof value.position !== 'number' || !Number.isFinite(value.position) || value.position < 0 || value.position > 604_800 || !Array.isArray(value.bookmarks) || value.bookmarks.length > 200) return null;
  const bookmarks: SavedBookmark[] = [];
  for (const bookmark of value.bookmarks) {
    if (!isRecord(bookmark) || typeof bookmark.id !== 'string' || !/^bm_[A-Za-z0-9_-]{1,64}$/.test(bookmark.id) || typeof bookmark.label !== 'string' || !bookmark.label.trim() || bookmark.label.length > 80 || typeof bookmark.time !== 'number' || !Number.isFinite(bookmark.time) || bookmark.time < 0 || bookmark.time > 604_800) return null;
    bookmarks.push({ id: bookmark.id, label: bookmark.label.trim(), time: bookmark.time });
  }
  return { position: value.position, bookmarks };
}

export function parseWorkspaceMemory(value: unknown): WorkspaceMemory {
  if (!isRecord(value) || value.version !== 1 || !isRecord(value.items)) return { version: 1, items: {} };
  const items: Record<string, MediaMemory> = {};
  for (const [id, entry] of Object.entries(value.items).slice(0, 500)) {
    const parsed = isSafeMediaId(id) ? parseMediaMemory(entry) : null;
    if (parsed) items[id] = parsed;
  }
  return { version: 1, items };
}

export function rememberMedia(memory: WorkspaceMemory, mediaId: string, entry: MediaMemory): WorkspaceMemory {
  if (!isSafeMediaId(mediaId)) return memory;
  const parsed = parseMediaMemory(entry);
  if (!parsed) return memory;
  return { version: 1, items: { ...memory.items, [mediaId]: parsed } };
}

export function queueView<T extends { id: string; name: string; kind: 'local' | 'url' }>(items: T[], options: QueueViewOptions): Array<{ item: T; index: number }> {
  const query = options.query.trim().toLocaleLowerCase();
  const view = items.map((item, index) => ({ item, index })).filter(({ item }) =>
    (options.kind === 'all' || item.kind === options.kind) && (!query || item.name.toLocaleLowerCase().includes(query))
  );
  if (options.sort !== 'manual') view.sort((a, b) => {
    const order = a.item.name.localeCompare(b.item.name, undefined, { sensitivity: 'base', numeric: true });
    return options.sort === 'name-asc' ? order : -order;
  });
  return view;
}

export function parsePlayerPreferences(value: unknown): PlayerPreferences {
  if (!isRecord(value)) return { speed: 1, seekStep: 10, pauseWhenHidden: false };
  const speed = typeof value.speed === 'number' && Number.isFinite(value.speed) && value.speed >= 0.25 && value.speed <= 4 ? value.speed : 1;
  const seekStep = typeof value.seekStep === 'number' && Number.isInteger(value.seekStep) && value.seekStep >= 1 && value.seekStep <= 300 ? value.seekStep : 10;
  const pauseWhenHidden = typeof value.pauseWhenHidden === 'boolean' ? value.pauseWhenHidden : false;
  return { speed, seekStep, pauseWhenHidden };
}

export function resolveLoadSelection(previous: LoadSelection, requestedIndex: number, succeeded: boolean, isLatest: boolean): LoadSelection {
  if (!succeeded || !isLatest) return previous;
  return { currentIndex: requestedIndex, endedLatched: false };
}

export function isCurrentLoadRequest(token: LoadRequestToken, activeRequest: number, currentGeneration: number): boolean {
  return token.request === activeRequest && token.generation === currentGeneration;
}

export function parseWindowState(value: unknown): DesktopWindowState | null {
  if (!isRecord(value) || (value.event !== undefined && value.event !== 'windowState')) return null;
  if (typeof value.fullscreen !== 'boolean' || typeof value.pictureInPicture !== 'boolean') return null;
  if (value.transitioning !== undefined && typeof value.transitioning !== 'boolean') return null;
  if (value.alwaysOnTop !== undefined && typeof value.alwaysOnTop !== 'boolean') return null;
  return { fullscreen: value.fullscreen, pictureInPicture: value.pictureInPicture, transitioning: value.transitioning ?? false, alwaysOnTop: value.alwaysOnTop ?? false };
}

export function canRequestFullscreen(nativeReady: boolean, supported: boolean, transitioning: boolean): boolean {
  return nativeReady && supported && !transitioning;
}

export function queueStepIndex(
  index: number,
  length: number,
  direction: -1 | 1,
  mode: 'all' | 'one' | 'off',
  shuffle: boolean,
  random: number = Math.random(),
): number {
  const manualMode = mode === 'one' ? 'off' : mode;
  if (direction === 1) return nextQueueIndex(index, length, manualMode, shuffle, random);
  if (!Number.isInteger(length) || length <= 0 || !Number.isInteger(index) || index < 0 || index >= length) return -1;
  if (mode !== 'all' && mode !== 'one' && mode !== 'off') return -1;
  if (index > 0) return index - 1;
  return mode === 'all' ? length - 1 : -1;
}

export function recordingResultMessage(command: 'recordStart' | 'recordStop', value: unknown): string {
  if (!isRecord(value) || typeof value.recording !== 'boolean') return '录制操作未完成';
  if (value.cancelled === true) return '已取消片段导出，原视频未修改';
  if (value.recording && value.exporting === true) return '正在导出选定片段，播放不受影响；完成后自动保存到“影片/AIPlayer/Clips”';
  if (value.recording) return '已开始录制当前媒体，请勿跳转；这不是屏幕录制，也不包含画面滤镜';
  if (value.panelOpened === true) return '请选择录制范围，再点击开始';
  if (value.saved === true) return '录制已保存';
  if (value.previewOpened === true) return '片段预览已生成，但未自动保存；请检查目录写入权限或磁盘空间';
  if (command === 'recordStart' && value.saved === false) return '已取消录制保存';
  return '录制已停止，尚未保存';
}

export function captureResultMessage(kind: 'screenshot' | 'gif' | 'poster', value: unknown): string {
  if (!isRecord(value) || value.cancelled === true) return '';
  const label = { screenshot: '截图', gif: 'GIF', poster: '海报' }[kind];
  const folder = { screenshot: 'Screenshots', gif: 'GIF', poster: 'Posters' }[kind];
  if (value.saved === true) return `${label}已自动保存到“图片/AIPlayer/${folder}”，可从预览打开文件或所在文件夹`;
  if (value.previewOpened === true) return `${label}预览已生成，但尚未保存`;
  return '';
}

export function replaceSleepTimer(
  current: ReturnType<typeof setTimeout> | null,
  choice: number,
  onPause: () => void,
): SleepTimerState {
  if (current) clearTimeout(current);
  if (Number.isFinite(choice) && choice > 0 && choice <= 1_440) {
    return { timer: setTimeout(onPause, choice * 60_000), minutes: choice, atEnd: false };
  }
  return { timer: null, minutes: 0, atEnd: choice === -1 };
}

export function parseOpenMediaEvent(value: unknown): MediaItem[] | null {
  if (!isRecord(value) || value.event !== 'openMedia' || !Array.isArray(value.items) || value.items.length < 1 || value.items.length > 100) return null;
  const items: MediaItem[] = [];
  for (const item of value.items) {
    if (!isRecord(item) || typeof item.id !== 'string' || !isSafeMediaId(item.id) || typeof item.name !== 'string' || !item.name.trim() || item.name.length > 500) return null;
    if (item.kind === 'local' && item.url === undefined) {
      items.push({ id: item.id, name: item.name.trim(), kind: 'local' });
      continue;
    }
    if (item.kind !== 'url' || typeof item.url !== 'string') return null;
    try {
      const url = new URL(item.url);
      if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
      items.push({ id: item.id, name: item.name.trim(), kind: 'url', url: url.toString() });
    } catch {
      return null;
    }
  }
  return items;
}

/** 原生命单播放快捷键（⌘. 停止、⌘W 关闭当前、⌘←/→ 上/下一项、⌘L 播放列表、⌘S 截图等；
 * V1.1.8 起对齐 OmniPlayer 全量可配置动作：定位/章节/帧步进、A/B 循环、倍速、音/字幕轨道与延迟、
 * GIF/录制片段/海报、书签、播放列表首/末项、字幕加载与面板、窗口置顶；未覆盖项（新建窗口、在线字幕搜索）无真实能力）
 * 由 AppKit 菜单消费按键后经 aiplayer:native 事件路由到 Web 层执行；队列与面板状态都在 Web 侧。 */
const MENU_SHORTCUT_ACTIONS = [
  'stop', 'closeFile', 'prevItem', 'nextItem', 'togglePlaylist', 'screenshot', 'showMediaInfo', 'pip', 'showHistory', 'showMenu',
  'jumpToBegin', 'nextChapter', 'prevChapter', 'frameStep', 'frameBackStep',
  'abLoopA', 'abLoopB', 'clearABLoop', 'addBookmark', 'editBookmark',
  'speedUp', 'speedDown', 'speedReset',
  'toggleGif', 'toggleRecord', 'capturePoster', 'openGifFolder',
  'cycleAudioTrack', 'cycleSubtitleTrack', 'toggleSubtitle', 'loadSubtitle',
  'audioDelayPlus', 'audioDelayMinus', 'audioDelayReset',
  'subtitleDelayPlus', 'subtitleDelayMinus', 'subtitleDelayReset',
  'firstItem', 'lastItem', 'showAudioSettings', 'showSubtitleSettings',
  'alwaysOnTop',
  'mute', 'aspectCycle', 'showVideoSettings',
] as const;
export type MenuShortcutAction = (typeof MENU_SHORTCUT_ACTIONS)[number];

export function parseMenuShortcutEvent(value: unknown): MenuShortcutAction | null {
  if (!isRecord(value) || value.event !== 'menuShortcut' || typeof value.action !== 'string') return null;
  return (MENU_SHORTCUT_ACTIONS as readonly string[]).includes(value.action) ? value.action as MenuShortcutAction : null;
}

/** 倍速步进（对齐 OmniPlayer Increase/Reset Playback Speed）：沿固定档位阶梯上下各移一档。 */
export const PLAYBACK_RATE_LADDER = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4] as const;

export function stepSpeedValue(current: number, direction: 1 | -1): number {
  const ladder = [...PLAYBACK_RATE_LADDER];
  let index = ladder.findIndex((rate) => Math.abs(rate - current) < 0.01);
  if (index === -1) {
    // 不在档位上（如手动改过倍速）时先吸附到最近档，再按方向步进，避免回落到 1x
    index = ladder.reduce((best, rate, i) => (Math.abs(rate - current) < Math.abs(ladder[best] - current) ? i : best), 0);
  }
  const next = Math.min(ladder.length - 1, Math.max(0, index + direction));
  return ladder[next];
}

/** 章节跳转（对齐 OmniPlayer Next/Previous Chapter）：后一章取第一个时间点晚于当前 +0.25s 的章节；
 * 前一章取最后一个早于当前 -0.5s 的章节；越界返回 null（不循环、不动作）。 */
export function chapterJumpIndex(chapters: Array<{ time: number }>, time: number, direction: 1 | -1): number | null {
  if (!chapters.length || !Number.isFinite(time)) return null;
  if (direction === 1) {
    const next = chapters.findIndex((chapter) => chapter.time > time + 0.25);
    return next === -1 ? null : next;
  }
  for (let index = chapters.length - 1; index >= 0; index -= 1) {
    if (chapters[index].time < time - 0.5) return index;
  }
  return null;
}

/** 轨道循环切换（对齐 OmniPlayer 轨道切换语义）：沿轨道表上下移动；
 * allowNone 时末尾追加“无”（-1），允许切到无字幕。仅一条轨道且不允许“无”时不动作。 */
export function cycleTrackId(tracks: Array<{ id: number; selected: boolean }>, direction: 1 | -1, allowNone = false): number | null {
  const list: number[] = allowNone ? [...tracks.map((track) => track.id), -1] : [...tracks.map((track) => track.id)];
  if (list.length < 2) return null;
  const selected = tracks.find((track) => track.selected)?.id;
  // 没有轨道被选中时：无论方向都先选第一条实际轨道（"无字幕" -1 只能作为显式终点，不作为起步）
  if (selected === undefined) return list[0];
  const currentIndex = selected === -1 && allowNone ? list.length - 1 : list.indexOf(selected);
  const step = direction === 1 ? 1 : list.length - 1;
  return list[(((currentIndex % list.length) + list.length) % list.length + step) % list.length];
}

/** 音/字幕延迟步进（对齐 OmniPlayer Audio/Subtitle Delay +/-）：±0.5s 步进、±10s 上限（与设置面板 RangeField 一致）。 */
export function stepDelayValue(current: number, delta: number, limit = 10): number {
  const next = current + delta;
  return Math.round(Math.max(-limit, Math.min(limit, next)) * 10) / 10;
}
