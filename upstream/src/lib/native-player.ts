export interface MediaItem {
  id: string;
  name: string;
  url?: string;
  kind: 'local' | 'url';
}

export interface Track {
  id: number;
  type: 'audio' | 'sub' | 'video';
  title?: string;
  lang?: string;
  selected: boolean;
  external?: boolean;
}

export interface Chapter {
  time: number;
  title: string;
}

export interface NativeState {
  available: boolean;
  engine: string;
  paused: boolean;
  keepAwake?: boolean;
  displayAwake?: boolean;
  time: number;
  duration: number;
  volume: number;
  speed: number;
  muted: boolean;
  title: string;
  tracks: Track[];
  chapters: Chapter[];
  width: number;
  height: number;
  subtitleDelay: number;
  audioDelay: number;
  error?: string;
  ended?: boolean;
  recording?: boolean;
  exporting?: boolean;
  gifCapturing?: boolean;
  gifExporting?: boolean;
  gifElapsed?: number;
  gifSavedName?: string;
  gifError?: string;
  gifThumbnail?: string;
}

export interface NativeRequestMessage {
  id: string;
  command: string;
  args: Record<string, unknown>;
}

export type NativeReply = {
  id: string;
  result?: unknown;
  error?: string;
};

export type NativeStateEvent = {
  event: 'state';
  state: NativeState;
};

type DesktopMessageHandler = {
  postMessage(message: NativeRequestMessage): void;
};

type NativeWindow = Window & {
  webkit?: {
    messageHandlers?: {
      desktop?: DesktopMessageHandler;
    };
  };
};

const NATIVE_EVENT = 'aiplayer:native';
const REQUEST_TIMEOUT_MS = 10_000;
const INTERACTIVE_COMMANDS = new Set(['openFiles', 'importSubtitle', 'screenshot', 'captureGif', 'capturePoster', 'recordStart', 'recordStop', 'gifStop']);
let fallbackRequestSequence = 0;

function currentWindow(): NativeWindow | null {
  return typeof window === 'undefined' ? null : (window as NativeWindow);
}

function desktopHandler(): DesktopMessageHandler | null {
  const handler = currentWindow()?.webkit?.messageHandlers?.desktop;
  return handler && typeof handler.postMessage === 'function' ? handler : null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value);
}

function isTrack(value: unknown): value is Track {
  if (!isRecord(value)) return false;
  if (!Number.isInteger(value.id)) return false;
  if (value.type !== 'audio' && value.type !== 'sub' && value.type !== 'video') return false;
  if (typeof value.selected !== 'boolean') return false;
  if (value.title !== undefined && typeof value.title !== 'string') return false;
  if (value.lang !== undefined && typeof value.lang !== 'string') return false;
  return value.external === undefined || typeof value.external === 'boolean';
}

function isChapter(value: unknown): value is Chapter {
  return (
    isRecord(value) &&
    isFiniteNumber(value.time) &&
    value.time >= 0 &&
    typeof value.title === 'string'
  );
}

function isNativeState(value: unknown): value is NativeState {
  if (!isRecord(value)) return false;
  if (typeof value.available !== 'boolean') return false;
  if (typeof value.engine !== 'string') return false;
  if (typeof value.paused !== 'boolean') return false;
  if (value.keepAwake !== undefined && typeof value.keepAwake !== 'boolean') return false;
  if (value.displayAwake !== undefined && typeof value.displayAwake !== 'boolean') return false;
  if (!isFiniteNumber(value.time) || !isFiniteNumber(value.duration)) return false;
  if (!isFiniteNumber(value.volume) || !isFiniteNumber(value.speed)) return false;
  if (typeof value.muted !== 'boolean' || typeof value.title !== 'string') return false;
  if (!Array.isArray(value.tracks) || !value.tracks.every(isTrack)) return false;
  if (!Array.isArray(value.chapters) || !value.chapters.every(isChapter)) return false;
  if (!isFiniteNumber(value.width) || !isFiniteNumber(value.height)) return false;
  if (!isFiniteNumber(value.subtitleDelay) || !isFiniteNumber(value.audioDelay)) return false;
  if (value.error !== undefined && typeof value.error !== 'string') return false;
  if (value.recording !== undefined && typeof value.recording !== 'boolean') return false;
  if (value.exporting !== undefined && typeof value.exporting !== 'boolean') return false;
  if (value.gifCapturing !== undefined && typeof value.gifCapturing !== 'boolean') return false;
  if (value.gifExporting !== undefined && typeof value.gifExporting !== 'boolean') return false;
  if (value.gifElapsed !== undefined && (!isFiniteNumber(value.gifElapsed) || value.gifElapsed < 0)) return false;
  if (value.gifSavedName !== undefined && typeof value.gifSavedName !== 'string') return false;
  if (value.gifError !== undefined && typeof value.gifError !== 'string') return false;
  if (value.gifThumbnail !== undefined && (typeof value.gifThumbnail !== 'string' || value.gifThumbnail.length > 400_000 || !/^data:image\/(?:jpeg|png);base64,[A-Za-z0-9+/=]+$/.test(value.gifThumbnail))) return false;
  return value.ended === undefined || typeof value.ended === 'boolean';
}

function requestId(): string {
  if (typeof globalThis.crypto?.randomUUID === 'function') {
    return globalThis.crypto.randomUUID();
  }
  fallbackRequestSequence += 1;
  return `web-${Date.now().toString(36)}-${fallbackRequestSequence.toString(36)}`;
}

export function nativeAvailable(): boolean {
  return desktopHandler() !== null;
}

export function nativeRequest<T>(
  command: string,
  args: Record<string, unknown> = {},
): Promise<T> {
  const hostWindow = currentWindow();
  const handler = desktopHandler();
  if (!hostWindow || !handler) {
    return Promise.reject(new Error('Native bridge unavailable'));
  }

  const id = requestId();
  return new Promise<T>((resolve, reject) => {
    let settled = false;
    let timeout: ReturnType<typeof setTimeout> | undefined;

    const cleanup = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      hostWindow.removeEventListener(NATIVE_EVENT, onNativeEvent);
      hostWindow.removeEventListener('pagehide', onPageHide);
    };

    const onNativeEvent = (event: Event) => {
      const detail = (event as CustomEvent<unknown>).detail;
      if (!isRecord(detail) || detail.id !== id) return;
      if (detail.event !== undefined || detail.state !== undefined) return;
      if (detail.error !== undefined && detail.error !== null && typeof detail.error !== 'string') return;

      if (typeof detail.error === 'string' && detail.error.length > 0) {
        if (detail.result !== undefined && detail.result !== null) return;
        cleanup();
        reject(new Error(detail.error));
        return;
      }
      if (!Object.prototype.hasOwnProperty.call(detail, 'result')) return;

      cleanup();
      resolve(detail.result as T);
    };

    const onPageHide = () => {
      cleanup();
      reject(new Error(`Native request cancelled: page closed (${command})`));
    };

    hostWindow.addEventListener(NATIVE_EVENT, onNativeEvent);
    hostWindow.addEventListener('pagehide', onPageHide);
    if (!INTERACTIVE_COMMANDS.has(command)) {
      timeout = setTimeout(() => {
        cleanup();
        reject(new Error(`Native request timed out: ${command}`));
      }, REQUEST_TIMEOUT_MS);
    }

    try {
      handler.postMessage({ id, command, args });
    } catch (error) {
      cleanup();
      reject(error instanceof Error ? error : new Error('Native request failed'));
    }
  });
}

export function subscribeNativeState(listener: (state: NativeState) => void): () => void {
  const hostWindow = currentWindow();
  if (!hostWindow) return () => undefined;

  const onNativeEvent = (event: Event) => {
    const detail = (event as CustomEvent<unknown>).detail;
    if (!isRecord(detail) || detail.event !== 'state' || !isNativeState(detail.state)) return;
    listener(detail.state);
  };

  hostWindow.addEventListener(NATIVE_EVENT, onNativeEvent);
  let subscribed = true;
  return () => {
    if (!subscribed) return;
    subscribed = false;
    hostWindow.removeEventListener(NATIVE_EVENT, onNativeEvent);
  };
}
