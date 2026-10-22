'use client';

import Link from 'next/link';
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ChangeEvent,
  type CSSProperties,
  type ReactNode,
} from 'react';
import { HistoryPanel } from '@/components/history-panel';
import { requestShowDownloadManager } from '@/components/download-manager';
import { DesktopMediaTools } from './desktop-media-tools';
import { DesktopHome } from './desktop-home';
import { createSeekController } from '@/lib/seek-controller';
import { createTransportIntent } from '@/lib/transport-intent';
import {
  nativeAvailable,
  nativeRequest,
  subscribeNativeState,
  type Chapter,
  type MediaItem,
  type NativeState,
  type Track,
} from '@/lib/native-player';
import {
  activeSubtitle,
  formatTimecode,
  moveQueueItem,
  parseQueue,
  parseSRT,
  validateAB,
  type SubtitleCue,
} from '@/lib/desktop-player';
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
  parseWindowState,
  isCurrentLoadRequest,
  replaceSleepTimer,
  resolveLoadSelection,
  queueStepIndex,
  canRequestFullscreen,
  type DesktopCapabilities,
  type SavedBookmark,
  type WorkspaceMemory,
} from './desktop-workspace-logic';

type Panel = 'queue' | 'picture' | 'audio' | 'subtitle';
type RepeatMode = 'all' | 'one' | 'off';

const QUEUE_KEY = 'aiplayer.desktop.queue.v1';
const MEMORY_KEY = 'aiplayer.desktop.memory.v1';
const PREFS_KEY = 'aiplayer.desktop.preferences.v1';
const DEFAULT_STATE: NativeState = {
  available: false,
  engine: 'browser',
  paused: true,
  time: 0,
  duration: 0,
  volume: 100,
  speed: 1,
  muted: false,
  title: '',
  tracks: [],
  chapters: [],
  width: 0,
  height: 0,
  subtitleDelay: 0,
  audioDelay: 0,
};

const PANEL_LABELS: Array<[Panel, string]> = [
  ['picture', '视频'], ['audio', '音频'], ['subtitle', '字幕'],
];

function isTypingTarget(target: EventTarget | null) {
  const element = target instanceof HTMLElement ? target : null;
  return Boolean(element?.isContentEditable || element?.closest('input, textarea, select, [contenteditable="true"]'));
}

function parseBrowserCues(text: string): SubtitleCue[] {
  return text
    .replace(/\r/g, '')
    .split(/\n\n+/)
    .flatMap((block) => {
      const lines = block.trim().split('\n');
      const timingIndex = lines.findIndex((line) => line.includes('-->'));
      if (timingIndex < 0) return [];
      const toSeconds = (value: string) => {
        const match = value.trim().match(/(?:(\d+):)?(\d{2}):(\d{2})[,.](\d{3})/);
        return match ? Number(match[1] ?? 0) * 3600 + Number(match[2]) * 60 + Number(match[3]) + Number(match[4]) / 1000 : NaN;
      };
      const [startText, endText] = lines[timingIndex].split('-->');
      const start = toSeconds(startText);
      const end = toSeconds(endText);
      return Number.isFinite(start) && Number.isFinite(end)
        ? [{ start, end, text: lines.slice(timingIndex + 1).join('\n') }]
        : [];
    });
}

export interface ExternalPlayback {
  items: MediaItem[];
  currentIndex: number;
  onSelect: (index: number) => void;
  getRestorePosition?: () => Promise<number> | number;
  onProgress?: (time: number, duration: number) => void;
  onEnded?: () => void;
  onBack?: () => void;
  title?: string;
  sourceLabel?: string;
}

export function DesktopWorkspace({ externalPlayback }: { externalPlayback?: ExternalPlayback } = {}) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const surfaceRef = useRef<HTMLDivElement>(null);
  const mediaInputRef = useRef<HTMLInputElement>(null);
  const subtitleInputRef = useRef<HTMLInputElement>(null);
  const objectUrlsRef = useRef<string[]>([]);
  const sleepRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const endedLatchRef = useRef(false);
  const privacyQueueRef = useRef<MediaItem[]>([]);
  const queueRef = useRef<MediaItem[]>([]);
  const resumePositionRef = useRef(0);
  const loadSequenceRef = useRef(0);
  const activeLoadRef = useRef(0);
  const loadGenerationRef = useRef(0);
  const mediaReadySentRef = useRef(false);
  const loadedExternalRef = useRef<string | null>(null);
  const loadItemRef = useRef<((item: MediaItem, index: number) => Promise<void>) | null>(null);
  const [nativeHost, setNativeHost] = useState(false);
  const [capabilities, setCapabilities] = useState<DesktopCapabilities | null>(null);
  const [player, setPlayer] = useState<NativeState>(DEFAULT_STATE);
  const [localQueue, setQueue] = useState<MediaItem[]>([]);
  const [queueReady, setQueueReady] = useState(false);
  const [localCurrentIndex, setCurrentIndex] = useState(-1);
  const queue = externalPlayback?.items ?? localQueue;
  const currentIndex = externalPlayback?.currentIndex ?? localCurrentIndex;
  const [panel, setPanel] = useState<Panel>('picture');
  const [collapsed, setCollapsed] = useState(true);
  const [menuOpen, setMenuOpen] = useState(false);
  const externalRef = useRef(externalPlayback);
  externalRef.current = externalPlayback;
  const [repeatMode, setRepeatMode] = useState<RepeatMode>('off');
  const [shuffle, setShuffle] = useState(false);
  const [historyOpen, setHistoryOpen] = useState(false);
  const [overlayOpen, setOverlayOpen] = useState(false);
  const [status, setStatus] = useState('');
  const [browserSrc, setBrowserSrc] = useState('');
  const [subtitleCues, setSubtitleCues] = useState<SubtitleCue[]>([]);
  const [bookmarks, setBookmarks] = useState<SavedBookmark[]>([]);
  const [memory, setMemory] = useState<WorkspaceMemory>({ version: 1, items: {} });
  const [privacyMode, setPrivacyMode] = useState(false);
  const [queueQuery, setQueueQuery] = useState('');
  const [queueKind, setQueueKind] = useState<'all' | 'local' | 'url'>('all');
  const [queueSort, setQueueSort] = useState<'manual' | 'name-asc' | 'name-desc'>('manual');
  const [seekStep, setSeekStep] = useState(10);
  const [preferredSpeed, setPreferredSpeed] = useState(1);
  const [pauseWhenHidden, setPauseWhenHidden] = useState(false);
  const [sleepAtEnd, setSleepAtEnd] = useState(false);
  const [pipActive, setPipActive] = useState(false);
  const [windowFullscreen, setWindowFullscreen] = useState(false);
  const [fullscreenTransitioning, setFullscreenTransitioning] = useState(false);
  const [abA, setAbA] = useState<number | null>(null);
  const [abB, setAbB] = useState<number | null>(null);
  const [rotation, setRotation] = useState(0);
  const [aspect, setAspect] = useState('default');
  const [brightness, setBrightness] = useState(0);
  const [contrast, setContrast] = useState(0);
  const [saturation, setSaturation] = useState(0);
  const [gamma, setGamma] = useState(0);
  const [hue, setHue] = useState(0);
  const [hwdec, setHwdec] = useState(true);
  const [deinterlace, setDeinterlace] = useState(false);
  const [sleepMinutes, setSleepMinutes] = useState(0);
  const [seeking, setSeeking] = useState(false);
  const actualPlayerRef = useRef(player);
  const playerRef = useRef(player);
  playerRef.current = player;
  const transportRef = useRef<(name: string, value: number | boolean) => Promise<unknown>>(() => Promise.reject(new Error('播放尚未就绪')));
  const transport = useMemo(() => {
    const onError = (error: unknown) => setStatus(userFacingError(error, '播放操作失败，请重试'));
    const optimistic = <K extends 'time' | 'paused' | 'muted' | 'volume'>(key: K, value: NativeState[K] | null) => {
      const nextValue = value ?? actualPlayerRef.current[key];
      playerRef.current = { ...playerRef.current, [key]: nextValue };
      setPlayer((state) => ({ ...state, [key]: nextValue }));
    };
    return {
      seek: createSeekController({ readTime: () => actualPlayerRef.current.time, readDuration: () => actualPlayerRef.current.duration, send: (value) => transportRef.current('seek', value), onError, onIntent: (value) => { setSeeking(value !== null); optimistic('time', value); } }),
      pause: createTransportIntent({ read: () => actualPlayerRef.current.paused, send: (value) => transportRef.current('pause', value), onError, onIntent: (value) => optimistic('paused', value) }),
      mute: createTransportIntent({ read: () => actualPlayerRef.current.muted, send: (value) => transportRef.current('mute', value), onError, onIntent: (value) => optimistic('muted', value) }),
      volume: createTransportIntent({ read: () => actualPlayerRef.current.volume, send: (value) => transportRef.current('volume', value), onError, onIntent: (value) => optimistic('volume', value) }),
    };
  }, []);
  const resetTransport = useCallback(() => { transport.seek.reset(); transport.pause.reset(); transport.mute.reset(); transport.volume.reset(); }, [transport]);
  const acceptPlayerState = useCallback((state: NativeState) => {
    actualPlayerRef.current = state;
    const time = transport.seek.project(state.time);
    const projected = { ...state, time, ended: transport.seek.pending() ? false : state.ended, paused: transport.pause.project(state.paused), muted: transport.mute.project(state.muted), volume: transport.volume.project(state.volume) };
    playerRef.current = projected;
    setPlayer(projected);
  }, [transport]);

  const mode = playbackMode(nativeHost, capabilities);
  const nativeReady = mode === 'native';
  const browserMode = mode === 'browser';
  const currentItem = queue[currentIndex] ?? null;
  const duration = Number.isFinite(player.duration) ? player.duration : 0;
  const recording = 'recording' in player && player.recording === true;
  const audioTracks = player.tracks.filter((track) => track.type === 'audio');
  const subtitleTracks = player.tracks.filter((track) => track.type === 'sub');
  const subtitleText = useMemo(
    () => activeSubtitle(subtitleCues, player.time, player.subtitleDelay),
    [subtitleCues, player.subtitleDelay, player.time],
  );
  const visibleQueue = useMemo(() => queueView(queue, { query: queueQuery, kind: queueKind, sort: queueSort }), [queue, queueKind, queueQuery, queueSort]);
  const supportsCommand = useCallback((name: string) => {
    if (browserMode) return ['pause', 'seek', 'volume', 'mute', 'speed', 'subtitleDelay', 'aspect', 'rotation', 'brightness', 'contrast', 'saturation', 'abLoopA', 'abLoopB', 'stop'].includes(name);
    return supportsNativeCommand(capabilities, name);
  }, [browserMode, capabilities]);

  const supportsFeature = useCallback((feature: 'openFiles' | 'importSubtitle' | 'screenshot' | 'fullscreen') => {
    if (browserMode) return feature === 'openFiles' || feature === 'importSubtitle' || feature === 'fullscreen';
    return capabilities?.available === true && capabilities[feature];
  }, [browserMode, capabilities]);

  useEffect(() => {
    const available = nativeAvailable();
    setNativeHost(available);
    try {
      if (!externalRef.current) {
      setQueue(parseQueue(JSON.parse(localStorage.getItem(QUEUE_KEY) ?? '[]')));
      setMemory(parseWorkspaceMemory(JSON.parse(localStorage.getItem(MEMORY_KEY) ?? '{}')));
      }
      const preferences = parsePlayerPreferences(JSON.parse(localStorage.getItem(PREFS_KEY) ?? '{}'));
      setPreferredSpeed(preferences.speed);
      setSeekStep(preferences.seekStep);
      setPauseWhenHidden(preferences.pauseWhenHidden);
    } catch {
      if (!externalRef.current) localStorage.removeItem(QUEUE_KEY);
    }
    setQueueReady(true);
    if (!available) return;
    const unsubscribe = subscribeNativeState((state) => {
      if (state.available) acceptPlayerState(state);
      else {
        setCapabilities((value) => value ? { ...value, available: false } : value);
        if (state.error) setStatus(userFacingError(new Error(state.error), '原生播放发生错误'));
      }
    });
    void nativeRequest<unknown>('capabilities').then((value) => {
      const parsed = parseNativeCapabilities(value);
      if (!parsed) throw new Error('invalid capabilities');
      setCapabilities(parsed);
      if (!parsed.available) setStatus('原生引擎未就绪，已切换到浏览器播放');
    }).catch(() => {
      setCapabilities({ available: false, engine: 'unavailable', commands: [], openFiles: false, importSubtitle: false, screenshot: false, fullscreen: false });
      setStatus('无法读取原生播放能力，已切换到浏览器播放');
    });
    void nativeRequest<NativeState>('getState').then(acceptPlayerState).catch(() => setStatus('无法读取原生播放状态'));
    return unsubscribe;
  }, []);

  useEffect(() => {
    if (player.error) setStatus(userFacingError(new Error(player.error), '原生播放发生错误'));
  }, [player.error]);

  useEffect(() => {
    if (externalPlayback || !queueReady || privacyMode) return;
    const persistent = queue.filter((item) => !item.id.startsWith('browser:'));
    localStorage.setItem(QUEUE_KEY, JSON.stringify(parseQueue(persistent)));
  }, [externalPlayback, privacyMode, queue, queueReady]);

  useEffect(() => {
    queueRef.current = queue;
  }, [queue]);

  useEffect(() => {
    if (externalPlayback || !queueReady || privacyMode) return;
    localStorage.setItem(MEMORY_KEY, JSON.stringify(memory));
  }, [externalPlayback, memory, privacyMode, queueReady]);

  useEffect(() => {
    if (!queueReady) return;
    localStorage.setItem(PREFS_KEY, JSON.stringify({ speed: preferredSpeed, seekStep, pauseWhenHidden }));
  }, [pauseWhenHidden, preferredSpeed, queueReady, seekStep]);

  useEffect(() => {
    if (externalPlayback || seeking || !queueReady || privacyMode || activeLoadRef.current !== 0 || !currentItem || !isSafeMediaId(currentItem.id)) return;
    setMemory((value) => rememberMedia(value, currentItem.id, {
      position: Math.max(0, Math.min(player.time, 604_800)),
      bookmarks,
    }));
  }, [bookmarks, currentItem, externalPlayback, player.time, privacyMode, queueReady, seeking]);

  useEffect(() => {
    const active = nativeReady && Boolean(currentItem);
    document.documentElement.classList.toggle('aiplayer-native-video-active', active);
    return () => document.documentElement.classList.remove('aiplayer-native-video-active');
  }, [currentItem, nativeReady]);

  const syncVideoRect = useCallback(() => {
    if (!nativeReady || !currentItem || historyOpen || overlayOpen || !surfaceRef.current) return;
    const rect = surfaceRef.current.getBoundingClientRect();
    const clipped = clipVideoRect(rect, document.documentElement.clientWidth, document.documentElement.clientHeight);
    if (!clipped) {
      void nativeRequest('hideVideo').catch(() => setStatus('无法隐藏已移出视口的原生画面'));
      return;
    }
    void nativeRequest('setVideoRect', clipped).catch(() => setStatus('无法同步原生画面位置'));
  }, [currentItem, historyOpen, nativeReady, overlayOpen]);

  useEffect(() => {
    const updateOverlayState = () => {
      setOverlayOpen(Boolean(document.querySelector('[role="dialog"], [role="alertdialog"]')));
    };
    updateOverlayState();
    const observer = new MutationObserver(updateOverlayState);
    observer.observe(document.body, { childList: true, subtree: true });
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    if (!nativeReady || !currentItem || historyOpen || overlayOpen) {
      if (nativeHost) void nativeRequest('hideVideo').catch(() => setStatus('无法隐藏原生画面'));
      return;
    }
    syncVideoRect();
    const observer = new ResizeObserver(syncVideoRect);
    if (surfaceRef.current) observer.observe(surfaceRef.current);
    window.addEventListener('resize', syncVideoRect);
    window.addEventListener('scroll', syncVideoRect, true);
    return () => {
      observer.disconnect();
      window.removeEventListener('resize', syncVideoRect);
      window.removeEventListener('scroll', syncVideoRect, true);
      void nativeRequest('hideVideo').catch(() => {});
    };
  }, [currentItem, historyOpen, nativeHost, nativeReady, overlayOpen, syncVideoRect]);

  useEffect(() => () => {
    transport.seek.reset(); transport.pause.reset(); transport.mute.reset(); transport.volume.reset();
    objectUrlsRef.current.forEach((url) => URL.revokeObjectURL(url));
    if (sleepRef.current) clearTimeout(sleepRef.current);
  }, [transport]);

  const dispatchTransport = useCallback(async (name: string, value?: unknown) => {
      if (nativeReady) {
        await nativeRequest('command', { name, value });
        return;
      }
      const video = videoRef.current;
      if (!video) throw new Error('当前没有可播放的媒体');
      if (name === 'pause') {
        if (value === false) await video.play();
        else video.pause();
      }
      else if (name === 'seek') video.currentTime = Math.max(0, Math.min(Number(value), video.duration || Number(value)));
      else if (name === 'volume') video.volume = Math.max(0, Math.min(1, Number(value) / 100));
      else if (name === 'mute') video.muted = Boolean(value);
      else if (name === 'speed') video.playbackRate = Number(value);
      else if (name === 'stop') { video.pause(); video.currentTime = 0; }
  }, [nativeReady]);
  transportRef.current = dispatchTransport;

  const runCommand = useCallback(async (name: string, value?: unknown) => {
    if (!supportsCommand(name)) return;
    if (name === 'seek' && typeof value === 'number') { if (activeLoadRef.current === 0) transport.seek.absolute(value); return; }
    if (name === 'pause' && typeof value === 'boolean') { transport.pause.set(value); return; }
    if (name === 'mute' && typeof value === 'boolean') { transport.mute.set(value); return; }
    if (name === 'volume' && typeof value === 'number') { transport.volume.set(Math.max(0, Math.min(100, value))); return; }
    if (name === 'stop') resetTransport();
    try { await dispatchTransport(name, value); }
    catch (error) { setStatus(userFacingError(error, '播放操作失败，请重试')); }
  }, [dispatchTransport, resetTransport, supportsCommand, transport]);
  const seekBy = useCallback((delta: number) => { if (activeLoadRef.current === 0 && supportsCommand('seek')) transport.seek.relative(delta); }, [supportsCommand, transport]);
  const togglePause = useCallback(() => { if (supportsCommand('pause')) transport.pause.update((value) => !value); }, [supportsCommand, transport]);
  const toggleMute = useCallback(() => { if (supportsCommand('mute')) transport.mute.update((value) => !value); }, [supportsCommand, transport]);

  useEffect(() => {
    if (!pauseWhenHidden) return;
    const pauseIfHidden = () => { if (document.hidden) void runCommand('pause', true); };
    document.addEventListener('visibilitychange', pauseIfHidden);
    return () => document.removeEventListener('visibilitychange', pauseIfHidden);
  }, [pauseWhenHidden, runCommand]);

  const loadItem = useCallback(async (item: MediaItem, index: number) => {
    if (externalRef.current) { externalRef.current.onSelect(index); return; }
    const token = { request: ++loadSequenceRef.current, generation: loadGenerationRef.current };
    resetTransport();
    activeLoadRef.current = token.request;
    setStatus('');
    const saved = !privacyMode && isSafeMediaId(item.id) ? memory.items[item.id] : undefined;
    const resumePosition = saved?.position ?? 0;
    let nextState: NativeState | null = null;
    try {
      if (nativeReady) {
        const target = item.kind === 'local' ? { id: item.id, position: resumePosition } : { url: item.url, position: resumePosition };
        nextState = await nativeRequest<NativeState>('load', target);
      }
      else if (item.url) {
        setBrowserSrc(item.url);
      } else throw new Error('需要重新选择该文件');
      if (!isCurrentLoadRequest(token, activeLoadRef.current, loadGenerationRef.current)) return;
      activeLoadRef.current = 0;
      const selection = resolveLoadSelection({ currentIndex, endedLatched: endedLatchRef.current }, index, true, true);
      setCurrentIndex(selection.currentIndex);
      setCollapsed(true);
      endedLatchRef.current = selection.endedLatched;
      setBookmarks(saved?.bookmarks ?? []);
      resumePositionRef.current = resumePosition;
      setAbA(null);
      setAbB(null);
      acceptPlayerState({ ...(nextState ?? playerRef.current), ended: false, error: undefined });
      if (nativeReady) {
        if ((abA !== null || abB !== null) && supportsCommand('abLoopA') && supportsCommand('abLoopB')) {
          await nativeRequest('command', { name: 'abLoopA', value: null }).catch(() => setStatus('媒体已加载，但无法清除上一个 A–B 循环'));
          await nativeRequest('command', { name: 'abLoopB', value: null }).catch(() => setStatus('媒体已加载，但无法清除上一个 A–B 循环'));
        }
        if (supportsCommand('speed')) await nativeRequest('command', { name: 'speed', value: preferredSpeed }).catch(() => setStatus('媒体已加载，但无法恢复倍速'));
      } else requestAnimationFrame(() => void videoRef.current?.play().catch((error) => setStatus(userFacingError(error, '浏览器无法自动播放，请点击播放'))));
    } catch (error) {
      if (!isCurrentLoadRequest(token, activeLoadRef.current, loadGenerationRef.current)) return;
      activeLoadRef.current = 0;
      setStatus(item.kind === 'local'
        ? '文件授权已失效，请点击「打开本地媒体」重新选择'
        : userFacingError(error, '无法加载媒体'));
    }
  }, [abA, abB, acceptPlayerState, currentIndex, memory.items, nativeReady, preferredSpeed, privacyMode, resetTransport, supportsCommand]);

  useEffect(() => {
    loadItemRef.current = loadItem;
  }, [loadItem]);

  const externalId = externalPlayback ? currentItem?.id : undefined;
  const externalUrl = externalPlayback ? currentItem?.url : undefined;
  const externalKey = externalId && externalUrl ? `${externalId}:${externalUrl}` : null;
  useEffect(() => {
    if (!externalRef.current || !nativeReady || !externalUrl) return;
    resetTransport();
    loadedExternalRef.current = null;
    const token = { request: ++loadSequenceRef.current, generation: loadGenerationRef.current };
    activeLoadRef.current = token.request;
    endedLatchRef.current = false;
    let cancelled = false;
    void (async () => {
      try {
        const restore = await externalRef.current?.getRestorePosition?.();
        if (cancelled || !isCurrentLoadRequest(token, activeLoadRef.current, loadGenerationRef.current)) return;
        const position = typeof restore === 'number' && Number.isFinite(restore) ? Math.max(0, restore) : 0;
        const state = await nativeRequest<NativeState>('load', { url: externalUrl, position });
        if (cancelled || !isCurrentLoadRequest(token, activeLoadRef.current, loadGenerationRef.current)) return;
        activeLoadRef.current = 0;
        loadedExternalRef.current = externalKey;
        acceptPlayerState({ ...state, ended: false });
        setStatus('');
      } catch (error) {
        if (!cancelled && isCurrentLoadRequest(token, activeLoadRef.current, loadGenerationRef.current)) {
          activeLoadRef.current = 0;
          setStatus(userFacingError(error, '无法加载媒体'));
        }
      }
    })();
    return () => { cancelled = true; loadedExternalRef.current = null; };
  }, [acceptPlayerState, externalId, externalKey, externalUrl, nativeReady, resetTransport]);

  useEffect(() => {
    if (!seeking && externalRef.current && nativeReady && loadedExternalRef.current === externalKey && externalKey && activeLoadRef.current === 0 && player.duration > 0) {
      externalRef.current.onProgress?.(player.time, player.duration);
    }
  }, [externalKey, nativeReady, player.duration, player.time, seeking]);

  const openNativeFiles = useCallback(async () => {
    try {
      const items = await nativeRequest<MediaItem[]>('openFiles');
      if (!items.length) return;
      const start = queue.length;
      setQueue((value) => [...value, ...items]);
      await loadItem(items[0], start);
    } catch (error) {
      setStatus(userFacingError(error, '未能打开本地媒体'));
    }
  }, [loadItem, queue.length]);

  useEffect(() => {
    if (!nativeHost) return;
    let disposed = false;
    let windowEventRevision = 0;
    const onNativeEvent = (event: Event) => {
      const detail = (event as CustomEvent<unknown>).detail;
      const windowState = parseWindowState(detail);
      if (windowState) {
        windowEventRevision += 1;
        setPipActive(windowState.pictureInPicture);
        setWindowFullscreen(windowState.fullscreen);
        setFullscreenTransitioning(windowState.transitioning);
      }
      const items = parseOpenMediaEvent(detail);
      if (!items || externalRef.current) return;
      const start = queueRef.current.length;
      const nextQueue = [...queueRef.current, ...items];
      queueRef.current = nextQueue;
      setQueue(nextQueue);
      void loadItemRef.current?.(items[0], start);
    };
    const canReady = !externalRef.current && nativeReady && capabilities?.commands.includes('mediaReady') === true;
    const canNotReady = capabilities?.commands.includes('mediaNotReady') === true;
    const canGetWindowState = nativeReady && capabilities?.commands.includes('getWindowState') === true;
    window.addEventListener('aiplayer:native', onNativeEvent);
    if (canReady && !mediaReadySentRef.current) {
      mediaReadySentRef.current = true;
      void nativeRequest('mediaReady').catch(() => {
        mediaReadySentRef.current = false;
        setStatus('无法接收系统打开的媒体，请使用「打开本地媒体」');
      });
    }
    if (canGetWindowState) {
      const queryRevision = windowEventRevision;
      void nativeRequest<unknown>('getWindowState').then((value) => {
        const state = parseWindowState(value);
        if (!disposed && windowEventRevision === queryRevision && state) {
          setPipActive(state.pictureInPicture);
          setWindowFullscreen(state.fullscreen);
          setFullscreenTransitioning(state.transitioning);
        }
      }).catch(() => {});
    }
    return () => {
      disposed = true;
      window.removeEventListener('aiplayer:native', onNativeEvent);
      if (mediaReadySentRef.current && canNotReady) {
        mediaReadySentRef.current = false;
        void nativeRequest('mediaNotReady').catch(() => {});
      }
    };
  }, [capabilities, nativeHost, nativeReady]);

  const chooseMedia = useCallback(() => {
    if (externalRef.current) return;
    if (nativeReady && supportsFeature('openFiles')) void openNativeFiles();
    else if (browserMode) mediaInputRef.current?.click();
    else if (nativeHost) setStatus('正在检测原生播放能力，请稍后重试');
    else mediaInputRef.current?.click();
  }, [browserMode, nativeHost, nativeReady, openNativeFiles, supportsFeature]);

  const onBrowserFiles = useCallback((event: ChangeEvent<HTMLInputElement>) => {
    const files = Array.from(event.target.files ?? []);
    if (!files.length) return;
    const additions = files.map((file, offset): MediaItem => {
      const url = URL.createObjectURL(file);
      objectUrlsRef.current.push(url);
      return { id: `browser:${Date.now()}:${offset}:${file.name}`, name: file.name, url, kind: 'local' };
    });
    const start = queue.length;
    setQueue((value) => [...value, ...additions]);
    void loadItem(additions[0], start);
    event.target.value = '';
  }, [loadItem, queue.length]);

  const stepQueue = useCallback((direction: -1 | 1, playbackEnded = false) => {
    if (!queue.length) return;
    const target = playbackEnded && repeatMode === 'one'
      ? currentIndex
      : queueStepIndex(currentIndex, queue.length, direction, repeatMode, shuffle);
    if (target >= 0) {
      if (externalRef.current) externalRef.current.onSelect(target);
      else void loadItem(queue[target], target);
    }
  }, [currentIndex, loadItem, queue, repeatMode, shuffle]);

  useEffect(() => {
    const edge = consumeEndedEdge(endedLatchRef.current, player.ended === true, activeLoadRef.current !== 0);
    endedLatchRef.current = edge.latched;
    if (!edge.advance) return;
    if (sleepAtEnd) {
      setSleepAtEnd(false);
      void runCommand('pause', true);
      setStatus('已在当前媒体结束时暂停');
      return;
    }
    if (externalRef.current) {
      if (externalKey && loadedExternalRef.current === externalKey) externalRef.current.onEnded?.();
    }
    else stepQueue(1, true);
  }, [externalKey, player.ended, runCommand, sleepAtEnd, stepQueue]);

  const toggleFullscreen = useCallback(async () => {
    try {
      if (nativeReady) {
        if (!canRequestFullscreen(nativeReady, supportsFeature('fullscreen'), fullscreenTransitioning)) return;
        setFullscreenTransitioning(true);
        const value = await nativeRequest<unknown>('fullscreen');
        const state = parseWindowState(value);
        if (!state) throw new Error('invalid window state');
        setPipActive(state.pictureInPicture);
        setWindowFullscreen(state.fullscreen);
        setFullscreenTransitioning(state.transitioning);
      } else if (browserMode) {
        if (fullscreenTransitioning) return;
        setFullscreenTransitioning(true);
        if (document.fullscreenElement) await document.exitFullscreen();
        else if (surfaceRef.current) await surfaceRef.current.requestFullscreen();
        else setFullscreenTransitioning(false);
      }
    } catch (error) {
      setFullscreenTransitioning(false);
      setStatus(userFacingError(error, '无法切换全屏'));
    }
  }, [browserMode, fullscreenTransitioning, nativeReady, supportsFeature]);

  useEffect(() => {
    const onFullscreenChange = () => {
      if (!nativeReady) setWindowFullscreen(Boolean(document.fullscreenElement));
      setFullscreenTransitioning(false);
    };
    document.addEventListener('fullscreenchange', onFullscreenChange);
    return () => document.removeEventListener('fullscreenchange', onFullscreenChange);
  }, [nativeReady]);

  const togglePictureInPicture = useCallback(async () => {
    try {
      // AppKit emits a strictly parsed windowState after changing the real window.
      // A request/acknowledgement alone must not enable the compact layout.
      await nativeRequest('pictureInPicture', { enabled: !pipActive });
    } catch {
      setStatus(pipActive ? '无法退出画中画' : '无法开启画中画');
    }
  }, [pipActive]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (isTypingTarget(event.target)) return;
      if (!currentItem || activeLoadRef.current !== 0) return;
      const key = event.key.toLowerCase();
      if (![' ', 'arrowleft', 'arrowright', 'arrowup', 'arrowdown', 'm', 'f'].includes(key) && event.code !== 'Space') return;
      event.preventDefault();
      if (event.code === 'Space') { if (!event.repeat) togglePause(); }
      else if (event.key === 'ArrowLeft') seekBy(-seekStep);
      else if (event.key === 'ArrowRight') seekBy(seekStep);
      else if (event.key === 'ArrowUp' && supportsCommand('volume')) transport.volume.update((value) => Math.min(100, value + 5));
      else if (event.key === 'ArrowDown' && supportsCommand('volume')) transport.volume.update((value) => Math.max(0, value - 5));
      else if (key === 'm') { if (!event.repeat) toggleMute(); }
      else if (key === 'f' && !event.repeat) void toggleFullscreen();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [currentItem, seekBy, seekStep, supportsCommand, toggleFullscreen, toggleMute, togglePause, transport]);

  const onBrowserState = useCallback(() => {
    const video = videoRef.current;
    if (!video) return;
    if (resumePositionRef.current > 0 && video.readyState >= 1) {
      video.currentTime = Math.min(resumePositionRef.current, Number.isFinite(video.duration) ? video.duration : resumePositionRef.current);
      resumePositionRef.current = 0;
    }
    if (video.playbackRate !== preferredSpeed) video.playbackRate = preferredSpeed;
    if (validateAB(abA, abB) && video.currentTime >= (abB as number)) video.currentTime = abA as number;
    acceptPlayerState({ ...playerRef.current, available: true, engine: 'browser-html5', paused: video.paused,
      time: Number.isFinite(video.currentTime) ? video.currentTime : 0,
      duration: Number.isFinite(video.duration) ? video.duration : 0,
      volume: video.volume * 100, speed: video.playbackRate, muted: video.muted,
      title: currentItem?.name ?? '', width: video.videoWidth, height: video.videoHeight, ended: video.ended });
  }, [abA, abB, acceptPlayerState, currentItem?.name, preferredSpeed]);

  const importSubtitle = async () => {
    if (browserMode) { subtitleInputRef.current?.click(); return; }
    if (!nativeReady || !supportsFeature('importSubtitle')) return;
    try {
      const result = await nativeRequest<NativeState | { state?: NativeState }>('importSubtitle');
      const state = 'state' in result && result.state ? result.state : result;
      if ('tracks' in state) acceptPlayerState(state as NativeState);
    } catch (error) {
      setStatus(userFacingError(error, '字幕导入失败'));
    }
  };

  const onBrowserSubtitle = async (event: ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    if (!file) return;
    try {
      const original = await file.text();
      if (file.name.toLowerCase().endsWith('.srt')) parseSRT(original);
      setSubtitleCues(parseBrowserCues(original));
      setStatus(`已载入字幕：${file.name}`);
    } catch (error) {
      setStatus(userFacingError(error, '字幕格式无法识别'));
    }
    event.target.value = '';
  };

  const setAB = (point: 'a' | 'b') => {
    const selection = selectAB(abA, abB, point, player.time);
    if (selection.error) { setStatus(selection.error); return; }
    setAbA(selection.a);
    setAbB(selection.b);
    void runCommand(point === 'a' ? 'abLoopA' : 'abLoopB', player.time);
  };

  const resetPicture = () => {
    setRotation(0); setAspect('default'); setBrightness(0); setContrast(0); setSaturation(0); setGamma(0); setHue(0);
    if (nativeReady) void Promise.all([
      runCommand('rotation', 0), runCommand('aspect', 'default'), runCommand('brightness', 0),
      runCommand('contrast', 0), runCommand('saturation', 0), runCommand('gamma', 0), runCommand('hue', 0),
    ]);
  };

  const applySleepTimer = (choice: number) => {
    const next = replaceSleepTimer(sleepRef.current, choice, () => {
      sleepRef.current = null;
      setSleepMinutes(0);
      void runCommand('pause', true);
      setStatus('睡眠定时已暂停播放');
    });
    sleepRef.current = next.timer;
    setSleepMinutes(next.minutes);
    setSleepAtEnd(next.atEnd);
    if (next.atEnd) setStatus('将在当前媒体结束时暂停');
    else if (next.minutes > 0 && supportsCommand('pause')) setStatus(`${next.minutes} 分钟后暂停播放`);
    else if (choice === 0) setStatus('已取消睡眠定时');
    else setStatus('当前引擎不支持睡眠定时');
  };

  const moveQueue = (from: number, to: number) => {
    setQueue((value) => moveQueueItem(value, from, to));
    setCurrentIndex((selected) => adjustCurrentAfterMove(selected, from, to));
  };

  const removeQueue = (index: number) => {
    if (index === currentIndex) {
      setBrowserSrc('');
      void runCommand('stop');
    }
    setQueue((value) => value.filter((_, itemIndex) => itemIndex !== index));
    setCurrentIndex((selected) => adjustCurrentAfterRemove(selected, index));
  };

  const togglePrivacy = (enabled: boolean) => {
    loadGenerationRef.current += 1;
    loadSequenceRef.current += 1;
    activeLoadRef.current = 0;
    resumePositionRef.current = 0;
    setCurrentIndex(-1);
    setBrowserSrc('');
    setBookmarks([]);
    setAbA(null);
    setAbB(null);
    void runCommand('stop');
    if (enabled) {
      privacyQueueRef.current = queue.slice();
      setPrivacyMode(true);
      setStatus('无痕模式已开启：已停止当前播放，本次队列、进度和书签不会写入本机');
      return;
    }
    setPrivacyMode(false);
    queueRef.current = privacyQueueRef.current;
    setQueue(privacyQueueRef.current);
    setStatus('已退出无痕模式并恢复进入前队列；原有记录未删除');
  };

  const pictureStyle: CSSProperties = {
    transform: `rotate(${rotation}deg)`,
    filter: `brightness(${100 + brightness}%) contrast(${100 + contrast}%) saturate(${100 + saturation}%)`,
    objectFit: aspect === 'fill' ? 'fill' : aspect === 'cover' ? 'cover' : 'contain',
  };

  return (
    <main className={`desktop-workspace desktop-player-workspace ${externalPlayback ? 'is-external-playback' : ''} ${currentItem ? 'has-media is-playing' : ''} ${nativeReady && currentItem ? 'is-native-video' : ''} ${windowFullscreen ? 'is-window-fullscreen' : ''} ${pipActive ? 'is-picture-in-picture' : ''}`} data-testid="desktop-workspace">
      <nav className="player-menu" aria-label="播放器菜单">
        <button type="button" aria-label="打开播放器菜单" aria-expanded={menuOpen} onClick={() => setMenuOpen((open) => !open)}>•••</button>
        {menuOpen && <div className="player-menu-popover">
          {externalPlayback?.onBack && <button type="button" onClick={externalPlayback.onBack}>返回影片</button>}
          {!externalPlayback && <button type="button" onClick={chooseMedia} disabled={!supportsFeature('openFiles')}>打开本地媒体…</button>}
          <Link href="/discover">全网资源 一键搜索</Link>
          <button type="button" onClick={() => { setMenuOpen(false); setHistoryOpen(true); }}>观看历史</button>
          <button type="button" onClick={() => { setMenuOpen(false); requestShowDownloadManager(); }}>下载管理</button>
          <button type="button" onClick={() => { setMenuOpen(false); void toggleFullscreen(); }} disabled={!currentItem || !supportsFeature('fullscreen') || fullscreenTransitioning}>{windowFullscreen ? '退出全屏' : '进入全屏'}　F</button>
          <small>{nativeReady ? capabilities?.engine : mode === 'probing' ? '正在连接播放引擎' : '浏览器播放'}</small>
        </div>}
      </nav>

      <section className="desk-main">
        <header className="desk-topbar">
          <h2>{externalPlayback?.title ?? currentItem?.name ?? '万能AI播放器'}</h2>
          <input ref={mediaInputRef} data-testid="browser-media-input" type="file" accept="video/*,audio/*" multiple hidden onChange={onBrowserFiles} />
        </header>

        <section className="screening-stage" data-testid="screening-stage" aria-label="播放画面">
          <div ref={surfaceRef} className="video-surface" onDoubleClick={() => void toggleFullscreen()}>
            {browserMode && browserSrc && <video ref={videoRef} src={browserSrc} style={pictureStyle} onLoadedMetadata={onBrowserState} onTimeUpdate={onBrowserState} onSeeked={onBrowserState} onPlay={onBrowserState} onPause={onBrowserState} onVolumeChange={onBrowserState} onRateChange={onBrowserState} onEnded={onBrowserState} onError={() => setStatus('浏览器无法解码或读取该媒体文件')} playsInline />}
            {!currentItem && <DesktopHome onOpen={chooseMedia} canOpen={supportsFeature('openFiles')} connecting={mode === 'probing'} />}
            {browserMode && subtitleText && <div className="browser-subtitle">{subtitleText}</div>}
          </div>
          <DesktopMediaTools capabilities={capabilities} hasMedia={Boolean(currentItem)} mediaTitle={currentItem?.name} recording={recording} exporting={player.exporting === true} gifCapturing={player.gifCapturing} gifExporting={player.gifExporting} gifElapsed={player.gifElapsed} gifSavedName={player.gifSavedName} gifError={player.gifError} gifThumbnail={player.gifThumbnail} playbackSpeed={preferredSpeed} onPlaybackSpeed={(value) => { setPreferredSpeed(value); void runCommand('speed', value); }} fullscreenActive={windowFullscreen} fullscreenTransitioning={fullscreenTransitioning} onFullscreen={toggleFullscreen} onStatus={setStatus} />
        </section>

        {status && <div className="desk-notice" role="status"><span>!</span>{status}<button type="button" onClick={() => setStatus('')} aria-label="关闭提示">×</button></div>}

        <section className="transport" aria-label="播放控制">
          <div className="timeline-row"><input aria-label="播放进度" type="range" min="0" max={Math.max(duration, 1)} step="0.1" value={Math.min(player.time, Math.max(duration, 1))} disabled={!currentItem || !supportsCommand('seek')} onChange={(event) => void runCommand('seek', Number(event.target.value))} style={{ '--progress': `${duration ? Math.min(100, player.time / duration * 100) : 0}%` } as CSSProperties} /></div>
          <div className="transport-row">
            <div className="transport-cluster">
              <button type="button" title="上一项" onClick={() => stepQueue(-1)} disabled={!currentItem || mode === 'probing' || (currentIndex <= 0 && (externalPlayback !== undefined || (!shuffle && repeatMode !== 'all')))} aria-label="上一项"><TransportIcon kind="previous" /></button>
              <button type="button" title={`快退 ${seekStep} 秒`} aria-label={`快退 ${seekStep} 秒`} onClick={() => seekBy(-seekStep)} disabled={!currentItem || !supportsCommand('seek')}><TransportIcon kind="rewind" /></button>
              <button className="play-toggle" type="button" title={player.paused ? '播放' : '暂停'} onClick={togglePause} disabled={!currentItem || !supportsCommand('pause')} aria-label={player.paused ? '播放' : '暂停'}><TransportIcon kind={player.paused ? 'play' : 'pause'} /></button>
              <button type="button" title={`快进 ${seekStep} 秒`} aria-label={`快进 ${seekStep} 秒`} onClick={() => seekBy(seekStep)} disabled={!currentItem || !supportsCommand('seek')}><TransportIcon kind="forward" /></button>
              <button type="button" title="下一项" onClick={() => stepQueue(1)} disabled={!currentItem || mode === 'probing' || (currentIndex >= queue.length - 1 && (externalPlayback !== undefined || (!shuffle && repeatMode !== 'all')))} aria-label="下一项"><TransportIcon kind="next" /></button>
              <button type="button" title={player.muted ? '取消静音' : '静音'} className={player.muted ? 'is-on' : ''} onClick={toggleMute} disabled={!currentItem || !supportsCommand('mute')} aria-label={player.muted ? '取消静音' : '静音'}><TransportIcon kind={player.muted ? 'muted' : 'volume'} /></button>
              <input className="volume-range" aria-label="音量" type="range" min="0" max="100" value={player.volume} disabled={!currentItem || !supportsCommand('volume')} onChange={(event) => void runCommand('volume', Number(event.target.value))} />
            </div>
            <div className="transport-time" aria-live="off" aria-busy={seeking}>{formatTimecode(player.time)} / {formatTimecode(duration)}{seeking && <span className="seek-pending" role="status">正在定位…</span>}</div>
            <div className="transport-cluster transport-tools">
              <select aria-label="播放速度" title="播放速度" value={preferredSpeed} onChange={(event) => { const value = Number(event.target.value); setPreferredSpeed(value); void runCommand('speed', value); }} disabled={!currentItem || !supportsCommand('speed')}>{[0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4].map((speed) => <option key={speed} value={speed}>{speed}x</option>)}</select>
              <button type="button" aria-label="投屏（暂不支持）" title="投屏暂未实现" disabled><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 16V5h16v11h-5 M9 16H4 M9 20l3-5 3 5Z" fill="none" stroke="currentColor" strokeWidth="1.6" /></svg></button>
              <button type="button" title="播放列表" aria-label="播放列表" aria-expanded={!collapsed && panel === 'queue'} onClick={() => { setPanel('queue'); setCollapsed(panel === 'queue' && !collapsed); }}><TransportIcon kind="playlist" /></button>
              <button type="button" title="画面设置" aria-label="画面设置" aria-expanded={!collapsed && panel === 'picture'} onClick={() => { setPanel('picture'); setCollapsed(panel === 'picture' && !collapsed); }}><TransportIcon kind="settings" /></button>
              <button type="button" title={windowFullscreen ? '退出全屏' : '全屏'} aria-label={windowFullscreen ? '退出全屏' : '全屏'} className="fullscreen-control" onClick={() => void toggleFullscreen()} disabled={!currentItem || !supportsFeature('fullscreen') || fullscreenTransitioning}><TransportIcon kind="fullscreen" /></button>
              <button type="button" title={pipActive ? '退出画中画' : '画中画'} aria-label={pipActive ? '退出画中画' : '画中画'} className={pipActive ? 'is-on' : ''} onClick={() => void togglePictureInPicture()} disabled={!currentItem || !nativeReady || !capabilities?.commands.includes('pictureInPicture')}><TransportIcon kind="pip" /></button>
            </div>
          </div>
        </section>
        <section className="pip-transport" aria-label="小窗播放控制">
          <button className="play-toggle pip-control" type="button" title={player.paused ? '播放' : '暂停'} aria-label={player.paused ? '播放' : '暂停'} onClick={togglePause} disabled={!currentItem || !supportsCommand('pause')}><TransportIcon kind={player.paused ? 'play' : 'pause'} /></button>
          <button className={`pip-control ${player.muted ? 'is-on' : ''}`} type="button" title={player.muted ? '取消静音' : '静音'} aria-label={player.muted ? '取消静音' : '静音'} onClick={toggleMute} disabled={!currentItem || !supportsCommand('mute')}><TransportIcon kind={player.muted ? 'muted' : 'volume'} /></button>
          <button className={`pip-control ${pipActive ? 'is-on' : ''}`} type="button" title="退出画中画" aria-label="退出画中画" onClick={() => void togglePictureInPicture()} disabled={!nativeReady || !capabilities?.commands.includes('pictureInPicture')}><TransportIcon kind="pip" /></button>
        </section>
      </section>

      <aside className={`desk-inspector ${collapsed ? 'is-collapsed' : ''}`} aria-label="播放器工具面板" aria-hidden={collapsed}>
        <header><span>{panel === 'queue' ? '播放列表' : '播放设置'}</span><button type="button" onClick={() => setCollapsed(true)} aria-label="关闭工具面板">×</button></header>
        <>{panel !== 'queue' && <div className="inspector-tabs" role="tablist" aria-label="播放设置">{PANEL_LABELS.map(([id, label]) => <button type="button" role="tab" aria-selected={panel === id} className={panel === id ? 'is-active' : ''} key={id} onClick={() => setPanel(id)}>{label}</button>)}</div>}<div className="inspector-body">
          {panel === 'queue' && (externalPlayback ? <section className="inspector-section"><SectionHeading kicker="" title={externalPlayback.sourceLabel ?? '剧集列表'} /><ol className="queue-list">{queue.map((item, index) => <li key={item.id} className={index === currentIndex ? 'is-current' : ''}><button type="button" className="queue-main" onClick={() => externalPlayback.onSelect(index)}><span>{index + 1}</span><div><b>{item.name}</b></div></button></li>)}</ol></section> : <QueuePanel queue={queue} view={visibleQueue} currentIndex={currentIndex} repeatMode={repeatMode} shuffle={shuffle} query={queueQuery} kind={queueKind} sort={queueSort} onQuery={setQueueQuery} onKind={setQueueKind} onSort={setQueueSort} onRepeat={setRepeatMode} onShuffle={setShuffle} onLoad={loadItem} onMove={moveQueue} onRemove={removeQueue} onOpen={chooseMedia} onClear={() => { setQueue([]); setCurrentIndex(-1); setBrowserSrc(''); void runCommand('stop'); }} />)}
          {panel === 'audio' && <AudioSubtitlePanel kind="audio" tracks={audioTracks} delay={player.audioDelay} canSelect={supportsCommand('audioTrack')} canDelay={supportsCommand('audioDelay')} canImport={!externalPlayback && supportsFeature('openFiles')} onSelect={(value) => void runCommand('audioTrack', value)} onDelay={(value) => { setPlayer((state) => ({ ...state, audioDelay: value })); void runCommand('audioDelay', value); }} onImport={chooseMedia} browserMode={browserMode} />}
          {panel === 'subtitle' && <AudioSubtitlePanel kind="subtitle" tracks={subtitleTracks} delay={player.subtitleDelay} canSelect={supportsCommand('subtitleTrack')} canDelay={supportsCommand('subtitleDelay')} canImport={supportsFeature('importSubtitle')} onSelect={(value) => void runCommand('subtitleTrack', value)} onDelay={(value) => { setPlayer((state) => ({ ...state, subtitleDelay: value })); void runCommand('subtitleDelay', value); }} onImport={() => void importSubtitle()} browserMode={browserMode} />}
          {panel === 'picture' && <PicturePanel aspect={aspect} rotation={rotation} brightness={brightness} contrast={contrast} saturation={saturation} gamma={gamma} hue={hue} hwdec={hwdec} deinterlace={deinterlace} supportsCommand={supportsCommand} onAspect={(value) => { setAspect(value); void runCommand('aspect', value); }} onRotation={(value) => { setRotation(value); void runCommand('rotation', value); }} onBrightness={(value) => { setBrightness(value); void runCommand('brightness', value); }} onContrast={(value) => { setContrast(value); void runCommand('contrast', value); }} onSaturation={(value) => { setSaturation(value); void runCommand('saturation', value); }} onGamma={(value) => { setGamma(value); void runCommand('gamma', value); }} onHue={(value) => { setHue(value); void runCommand('hue', value); }} onHwdec={(value) => { setHwdec(value); void runCommand('hwdec', value); }} onDeinterlace={(value) => { setDeinterlace(value); void runCommand('deinterlace', value); }} onFrameBack={() => void runCommand('frameBackStep')} onFrame={() => void runCommand('frameStep')} onReset={resetPicture} />}
          {panel === 'picture' && <details className="settings-details"><summary>章节与书签</summary><MarkersPanel chapters={player.chapters} bookmarks={bookmarks} currentTime={player.time} hasMedia={Boolean(currentItem)} canSeek={supportsCommand('seek')} canAB={supportsCommand('abLoopA') && supportsCommand('abLoopB')} abA={abA} abB={abB} onSeek={(time) => void runCommand('seek', time)} onAdd={() => setBookmarks((value) => [...value, { id: `bm_${Date.now().toString(36)}`, label: `书签 ${value.length + 1}`, time: Math.round(player.time * 10) / 10 }].sort((a, b) => a.time - b.time))} onRename={(id, label) => setBookmarks((value) => value.map((item) => item.id === id ? { ...item, label: label.slice(0, 80) || '未命名书签' } : item))} onRemove={(id) => setBookmarks((value) => value.filter((item) => item.id !== id))} onSetAB={setAB} onClearAB={() => { setAbA(null); setAbB(null); void runCommand('abLoopA', null); void runCommand('abLoopB', null); }} /></details>}
          {panel === 'picture' && <details className="settings-details"><summary>媒体信息与播放偏好</summary><InfoPanel currentItem={currentItem} player={player} duration={duration} nativeReady={nativeReady} canSleep={supportsCommand('pause')} sleepMinutes={sleepMinutes} sleepAtEnd={sleepAtEnd} seekStep={seekStep} pauseWhenHidden={pauseWhenHidden} privacyMode={privacyMode} onSleep={applySleepTimer} onSeekStep={setSeekStep} onPauseWhenHidden={setPauseWhenHidden} onPrivacy={togglePrivacy} /></details>}
        </div></>
      </aside>
      <HistoryPanel open={historyOpen} onClose={() => setHistoryOpen(false)} />
      <input ref={subtitleInputRef} type="file" accept=".srt,.vtt,text/vtt" hidden onChange={(event) => void onBrowserSubtitle(event)} />
    </main>
  );
}

export function AudioSubtitlePanel({ kind, tracks, delay, canSelect, canDelay, canImport, onSelect, onDelay, onImport, browserMode }: {
  kind: 'audio' | 'subtitle'; tracks: Track[]; delay: number; canSelect: boolean; canDelay: boolean; canImport: boolean;
  onSelect: (value: number) => void; onDelay: (value: number) => void; onImport: () => void; browserMode: boolean;
}) {
  const label = kind === 'audio' ? '音轨' : '字幕';
  return <section className="inspector-section" aria-label={kind === 'audio' ? '音频设置' : '字幕设置'}>
    <SectionHeading kicker="" title={kind === 'audio' ? '音频' : '字幕'} />
    <Field label={label}><select disabled={!tracks.length || !canSelect} value={tracks.find((track) => track.selected)?.id ?? ''} onChange={(event) => onSelect(Number(event.target.value))}><option value="">{tracks.length ? `选择${label}` : `无可用${label}`}</option>{tracks.map((track) => <TrackOption key={track.id} track={track} />)}</select></Field>
    <RangeField label={kind === 'audio' ? '音频延迟' : '字幕延迟'} value={delay} min={-10} max={10} step={0.1} output={`${delay.toFixed(1)}s`} disabled={!canDelay} onChange={onDelay} />
    <div className="panel-actions panel-actions-stack"><button type="button" disabled={!canImport} onClick={onImport}>{kind === 'audio' ? '将音频加入队列' : '导入字幕文件'}</button></div>
    {browserMode && <p className="panel-note">{kind === 'audio' ? '浏览器模式的音轨选择取决于媒体文件与浏览器支持。' : '浏览器模式可载入 SRT/VTT 字幕文件。'}</p>}
  </section>;
}

function QueuePanel({ queue, view, currentIndex, repeatMode, shuffle, query, kind, sort, onQuery, onKind, onSort, onRepeat, onShuffle, onLoad, onMove, onRemove, onOpen, onClear }: { queue: MediaItem[]; view: Array<{ item: MediaItem; index: number }>; currentIndex: number; repeatMode: RepeatMode; shuffle: boolean; query: string; kind: 'all' | 'local' | 'url'; sort: 'manual' | 'name-asc' | 'name-desc'; onQuery: (value: string) => void; onKind: (value: 'all' | 'local' | 'url') => void; onSort: (value: 'manual' | 'name-asc' | 'name-desc') => void; onRepeat: (value: RepeatMode) => void; onShuffle: (value: boolean) => void; onLoad: (item: MediaItem, index: number) => Promise<void>; onMove: (from: number, to: number) => void; onRemove: (index: number) => void; onOpen: () => void; onClear: () => void }) {
  return <section data-testid="play-queue" className="inspector-section"><div className="section-heading"><div><span>UP NEXT</span><h2>播放队列</h2></div><b>{queue.length}</b></div><input className="queue-search" value={query} onChange={(event) => onQuery(event.target.value)} placeholder="搜索队列名称" aria-label="搜索队列" /><div className="queue-modes"><select value={kind} onChange={(event) => onKind(event.target.value as 'all' | 'local' | 'url')}><option value="all">全部类型</option><option value="local">本地</option><option value="url">网络</option></select><select value={sort} onChange={(event) => onSort(event.target.value as 'manual' | 'name-asc' | 'name-desc')}><option value="manual">队列顺序</option><option value="name-asc">名称 A–Z</option><option value="name-desc">名称 Z–A</option></select></div><div className="queue-modes"><label>循环<select value={repeatMode} onChange={(event) => onRepeat(event.target.value as RepeatMode)}><option value="off">关闭</option><option value="all">全部</option><option value="one">单曲</option></select></label><label className="check-control"><input type="checkbox" checked={shuffle} onChange={(event) => onShuffle(event.target.checked)} />随机</label></div>{view.length ? <ol className="queue-list">{view.map(({ item, index }) => <li key={item.id} className={index === currentIndex ? 'is-current' : ''}><button className="queue-main" type="button" onClick={() => void onLoad(item, index)}><span>{String(index + 1).padStart(2, '0')}</span><div><b>{item.name}</b><small>{item.kind === 'local' ? '本地媒体' : '网络媒体'}</small></div></button><div className="queue-actions"><button type="button" disabled={sort !== 'manual' || index === 0} onClick={() => onMove(index, index - 1)} aria-label="上移">↑</button><button type="button" disabled={sort !== 'manual' || index === queue.length - 1} onClick={() => onMove(index, index + 1)} aria-label="下移">↓</button><button type="button" onClick={() => onRemove(index)} aria-label="移除">×</button></div></li>)}</ol> : <EmptyPanel title={queue.length ? '没有匹配项' : '队列还是空的'} detail={queue.length ? '请调整搜索词或类型筛选。' : '打开本地媒体后，文件会按选择顺序加入这里。'} />}<div className="panel-actions"><button type="button" disabled={!view.length} onClick={() => { const first = view[0]; void onLoad(first.item, first.index); }}>首项</button><button type="button" disabled={!view.length} onClick={() => { const last = view[view.length - 1]; void onLoad(last.item, last.index); }}>末项</button><button type="button" onClick={onOpen}>+加入</button><button className="quiet-danger" type="button" disabled={!queue.length} onClick={onClear}>清空</button></div></section>;
}

function PicturePanel({ aspect, rotation, brightness, contrast, saturation, gamma, hue, hwdec, deinterlace, supportsCommand, onAspect, onRotation, onBrightness, onContrast, onSaturation, onGamma, onHue, onHwdec, onDeinterlace, onFrameBack, onFrame, onReset }: { aspect: string; rotation: number; brightness: number; contrast: number; saturation: number; gamma: number; hue: number; hwdec: boolean; deinterlace: boolean; supportsCommand: (name: string) => boolean; onAspect: (value: string) => void; onRotation: (value: number) => void; onBrightness: (value: number) => void; onContrast: (value: number) => void; onSaturation: (value: number) => void; onGamma: (value: number) => void; onHue: (value: number) => void; onHwdec: (value: boolean) => void; onDeinterlace: (value: boolean) => void; onFrameBack: () => void; onFrame: () => void; onReset: () => void }) {
  return <section className="inspector-section"><SectionHeading kicker="IMAGE" title="画面校准" /><Field label="画面比例"><select value={aspect} disabled={!supportsCommand('aspect')} onChange={(event) => onAspect(event.target.value)}><option value="default">原始比例</option><option value="cover">裁切填充</option><option value="fill">拉伸填充</option><option value="16:9">16:9</option><option value="4:3">4:3</option></select></Field><Field label="旋转"><select value={rotation} disabled={!supportsCommand('rotation')} onChange={(event) => onRotation(Number(event.target.value))}>{[0, 90, 180, 270].map((value) => <option key={value} value={value}>{value}°</option>)}</select></Field><RangeField label="亮度" value={brightness} min={-50} max={50} output={String(Math.round(brightness))} disabled={!supportsCommand('brightness')} onChange={onBrightness} /><RangeField label="对比度" value={contrast} min={-50} max={50} output={String(Math.round(contrast))} disabled={!supportsCommand('contrast')} onChange={onContrast} /><RangeField label="饱和度" value={saturation} min={-50} max={50} output={String(Math.round(saturation))} disabled={!supportsCommand('saturation')} onChange={onSaturation} /><RangeField label="Gamma" value={gamma} min={-50} max={50} output={String(Math.round(gamma))} disabled={!supportsCommand('gamma')} onChange={onGamma} /><RangeField label="色相" value={hue} min={-50} max={50} output={String(Math.round(hue))} disabled={!supportsCommand('hue')} onChange={onHue} /><label className="check-control"><input type="checkbox" checked={hwdec} disabled={!supportsCommand('hwdec')} onChange={(event) => onHwdec(event.target.checked)} />硬件解码</label><label className="check-control"><input type="checkbox" checked={deinterlace} disabled={!supportsCommand('deinterlace')} onChange={(event) => onDeinterlace(event.target.checked)} />去隔行</label><div className="panel-actions"><button type="button" disabled={!supportsCommand('frameBackStep')} onClick={onFrameBack}>退一帧</button><button type="button" disabled={!supportsCommand('frameStep')} onClick={onFrame}>进一帧</button></div><div className="panel-actions panel-actions-stack"><button type="button" disabled={!['aspect', 'rotation', 'brightness', 'contrast', 'saturation', 'gamma', 'hue'].some(supportsCommand)} onClick={onReset}>重置画面</button></div></section>;
}

function MarkersPanel({ chapters, bookmarks, currentTime, hasMedia, canSeek, canAB, abA, abB, onSeek, onAdd, onRename, onRemove, onSetAB, onClearAB }: { chapters: Chapter[]; bookmarks: SavedBookmark[]; currentTime: number; hasMedia: boolean; canSeek: boolean; canAB: boolean; abA: number | null; abB: number | null; onSeek: (time: number) => void; onAdd: () => void; onRename: (id: string, label: string) => void; onRemove: (id: string) => void; onSetAB: (point: 'a' | 'b') => void; onClearAB: () => void }) {
  return <section className="inspector-section"><SectionHeading kicker="NAVIGATION" title="章节与标记" />{chapters.length ? <ul className="marker-list chapter-list">{chapters.map((chapter, index) => <li key={`${chapter.time}-${index}`}><button type="button" disabled={!canSeek} onClick={() => onSeek(chapter.time)}><code>{formatTimecode(chapter.time)}</code><span>{chapter.title || `章节 ${index + 1}`}</span></button></li>)}</ul> : <p className="panel-note">当前媒体没有可读章节。</p>}<div className="marker-heading"><span>书签</span><button type="button" disabled={!hasMedia} onClick={onAdd}>+添加 {formatTimecode(currentTime)}</button></div>{bookmarks.length ? <ul className="marker-list">{bookmarks.map((bookmark) => <li key={bookmark.id}><button type="button" disabled={!canSeek} onClick={() => onSeek(bookmark.time)}><code>{formatTimecode(bookmark.time)}</code></button><input aria-label="书签名称" value={bookmark.label} maxLength={80} onChange={(event) => onRename(bookmark.id, event.target.value)} /><button type="button" onClick={() => onRemove(bookmark.id)}>×</button></li>)}</ul> : <p className="panel-note">书签会按媒体隔离保存，无痕模式下不写入本机。</p>}<div className="ab-block"><div><span>A–B 循环</span><b>{abA === null ? '--:--' : formatTimecode(abA)} → {abB === null ? '--:--' : formatTimecode(abB)}</b></div><div><button type="button" disabled={!hasMedia || !canAB} onClick={() => onSetAB('a')}>A 点</button><button type="button" disabled={!hasMedia || !canAB} onClick={() => onSetAB('b')}>B 点</button><button type="button" disabled={!canAB} onClick={onClearAB}>清除</button></div></div></section>;
}

function InfoPanel({ currentItem, player, duration, nativeReady, canSleep, sleepMinutes, sleepAtEnd, seekStep, pauseWhenHidden, privacyMode, onSleep, onSeekStep, onPauseWhenHidden, onPrivacy }: { currentItem: MediaItem | null; player: NativeState; duration: number; nativeReady: boolean; canSleep: boolean; sleepMinutes: number; sleepAtEnd: boolean; seekStep: number; pauseWhenHidden: boolean; privacyMode: boolean; onSleep: (minutes: number) => void; onSeekStep: (value: number) => void; onPauseWhenHidden: (value: boolean) => void; onPrivacy: (value: boolean) => void }) {
  return <section className="inspector-section"><SectionHeading kicker="MEDIA" title="媒体信息" /><dl className="media-info"><div><dt>文件</dt><dd>{currentItem?.name ?? '未加载'}</dd></div><div><dt>引擎</dt><dd>{nativeReady ? player.engine || '原生引擎' : 'HTML5 Video'}</dd></div><div><dt>分辨率</dt><dd>{player.width && player.height ? `${player.width} × ${player.height}` : '未知'}</dd></div><div><dt>时长</dt><dd>{formatTimecode(duration)}</dd></div><div><dt>轨道</dt><dd>{player.tracks.length || '未知'}</dd></div></dl><Field label="快进/快退步长"><select value={seekStep} onChange={(event) => onSeekStep(Number(event.target.value))}>{[5, 10, 15, 30, 60].map((value) => <option key={value} value={value}>{value} 秒</option>)}</select></Field><Field label="睡眠定时"><select value={sleepAtEnd ? -1 : sleepMinutes} disabled={!canSleep} onChange={(event) => onSleep(Number(event.target.value))}><option value="0">关闭</option><option value="-1">当前媒体结束时</option><option value="15">15 分钟</option><option value="30">30 分钟</option><option value="60">60 分钟</option><option value="90">90 分钟</option></select></Field><label className="check-control"><input type="checkbox" checked={pauseWhenHidden} onChange={(event) => onPauseWhenHidden(event.target.checked)} />最小化或页面隐藏时暂停</label><label className="check-control privacy-control"><input type="checkbox" checked={privacyMode} onChange={(event) => onPrivacy(event.target.checked)} />无痕模式</label><p className="panel-note">{privacyMode ? '已开启：切换模式时会停止当前播放；本次队列、进度和书签不会写入本机。退出时恢复进入前队列，不删除旧记录。' : nativeReady ? '本地文件由原生宿主保留用户选择授权，网页不会获得任意文件路径。' : '浏览器模式的文件仅在当前页面中使用，刷新后需重新选择。'}</p></section>;
}

type TransportIconKind = 'first' | 'previous' | 'rewind' | 'play' | 'pause' | 'forward' | 'next' | 'last' | 'volume' | 'muted' | 'pip' | 'playlist' | 'settings' | 'fullscreen';

function TransportIcon({ kind }: { kind: TransportIconKind }) {
  const paths: Record<TransportIconKind, string> = {
    first: 'M6 5v14 M18 6l-9 6 9 6z',
    previous: 'M16 6l-8 6 8 6z',
    rewind: 'M19 6l-7 6 7 6z M12 6l-7 6 7 6z',
    play: 'M8 5l11 7-11 7z',
    pause: 'M8 6v12 M16 6v12',
    forward: 'M5 6l7 6-7 6z M12 6l7 6-7 6z',
    next: 'M8 6l8 6-8 6z',
    last: 'M18 5v14 M6 6l9 6-9 6z',
    volume: 'M4 10v4h4l5 4V6l-5 4z M16 9c1 1 1.5 2 1.5 3S17 14 16 15 M18 7c2 2 3 3 3 5s-1 3-3 5',
    muted: 'M4 10v4h4l5 4V6l-5 4z M17 9l4 6 M21 9l-4 6',
    pip: 'M4 5h16v14H4z M12 12h6v4h-6z',
    playlist: 'M5 7h10 M5 12h10 M5 17h7 M18 15v5 M16 18l2 2 2-2',
    settings: 'M5 7h14 M9 5v4 M5 12h14 M15 10v4 M5 17h14 M11 15v4',
    fullscreen: 'M5 9V5h4 M15 5h4v4 M19 15v4h-4 M9 19H5v-4',
  };
  return <svg viewBox="0 0 24 24" aria-hidden fill="none" stroke="currentColor" strokeWidth="1.65" strokeLinecap="round" strokeLinejoin="round"><path d={paths[kind]} /></svg>;
}

function EmptyPanel({ title, detail }: { title: string; detail: string }) { return <div className="panel-empty"><span>□</span><b>{title}</b><p>{detail}</p></div>; }
function SectionHeading({ kicker, title }: { kicker: string; title: string }) { return <div className="section-heading"><div><span>{kicker}</span><h2>{title}</h2></div></div>; }
function Field({ label, children }: { label: string; children: ReactNode }) { return <label className="field"><span>{label}</span>{children}</label>; }
function RangeField({ label, value, min, max, step = 1, output, disabled, onChange }: { label: string; value: number; min: number; max: number; step?: number; output: string; disabled?: boolean; onChange: (value: number) => void }) { return <label className="range-field"><span>{label}<output>{output}</output></span><input type="range" value={value} min={min} max={max} step={step} disabled={disabled} onChange={(event) => onChange(Number(event.target.value))} /></label>; }
function TrackOption({ track }: { track: Track }) { return <option value={track.id}>{track.title || track.lang || `${track.type} ${track.id}`}{track.external ? ' · 外挂' : ''}</option>; }
