export interface FullscreenElement {
  requestFullscreen?: () => Promise<void> | void;
  webkitRequestFullscreen?: () => Promise<void> | void;
}

export interface FullscreenVideo {
  webkitDisplayingFullscreen?: boolean;
  webkitEnterFullscreen?: () => void;
  webkitExitFullscreen?: () => void;
}

export interface FullscreenDocument {
  fullscreenElement?: FullscreenElement | null;
  webkitFullscreenElement?: FullscreenElement | null;
  exitFullscreen?: () => Promise<void> | void;
  webkitExitFullscreen?: () => Promise<void> | void;
}

export type FullscreenRoute =
  | 'native'
  | 'browser-enter'
  | 'browser-exit'
  | 'webkit-enter'
  | 'webkit-exit'
  | 'webkit-video-exit'
  | 'webkit-video-enter';

export interface NativeWindowState {
  fullscreen: boolean;
  pictureInPicture: boolean;
  transitioning?: boolean;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

export function parseNativeWindowState(value: unknown): NativeWindowState | null {
  if (!isRecord(value)) return null;
  if (typeof value.fullscreen !== 'boolean' || typeof value.pictureInPicture !== 'boolean') return null;
  if (value.transitioning !== undefined && typeof value.transitioning !== 'boolean') return null;
  return {
    fullscreen: value.fullscreen,
    pictureInPicture: value.pictureInPicture,
    ...(typeof value.transitioning === 'boolean' ? { transitioning: value.transitioning } : {}),
  };
}

export function subscribeNativeWindowState(
  target: EventTarget,
  listener: (state: NativeWindowState) => void,
): () => void {
  const onNativeEvent = (event: Event) => {
    const detail = (event as CustomEvent<unknown>).detail;
    if (!isRecord(detail) || detail.event !== 'windowState') return;
    const state = parseNativeWindowState(detail);
    if (state) listener(state);
  };
  target.addEventListener('aiplayer:native', onNativeEvent);
  return () => target.removeEventListener('aiplayer:native', onNativeEvent);
}

export function createExclusiveFullscreenRequest<T>(
  request: () => Promise<T>,
): () => Promise<T> {
  let pending = false;
  return async () => {
    if (pending) throw new Error('全屏正在切换，请稍候');
    pending = true;
    try {
      return await request();
    } finally {
      pending = false;
    }
  };
}

export function watchPlayerContainerClassName(nativeFullscreen: boolean): string {
  return nativeFullscreen
    ? 'fixed inset-0 z-[2147483647] w-screen h-screen bg-black'
    : 'relative w-full h-full';
}

export function watchMediaFrameClassName(nativeFullscreen: boolean): string {
  return nativeFullscreen
    ? 'aspect-video bg-black overflow-visible'
    : 'aspect-video bg-black rounded-lg overflow-hidden';
}

export async function toggleWatchFullscreen({
  nativeAvailable,
  nativeToggle,
  document,
  element,
  video,
}: {
  nativeAvailable: boolean;
  nativeToggle?: () => Promise<unknown>;
  document: FullscreenDocument;
  element: FullscreenElement;
  video?: FullscreenVideo;
}): Promise<FullscreenRoute> {
  if (nativeAvailable) {
    if (!nativeToggle) throw new Error('原生全屏服务不可用');
    await nativeToggle();
    return 'native';
  }

  if (document.fullscreenElement) {
    if (!document.exitFullscreen) throw new Error('当前环境无法退出全屏');
    await document.exitFullscreen();
    return 'browser-exit';
  }
  if (document.webkitFullscreenElement) {
    if (!document.webkitExitFullscreen) throw new Error('当前环境无法退出全屏');
    await document.webkitExitFullscreen();
    return 'webkit-exit';
  }
  if (video?.webkitDisplayingFullscreen) {
    if (!video.webkitExitFullscreen) throw new Error('当前环境无法退出全屏');
    video.webkitExitFullscreen();
    return 'webkit-video-exit';
  }
  if (element.requestFullscreen) {
    await element.requestFullscreen();
    return 'browser-enter';
  }
  if (element.webkitRequestFullscreen) {
    await element.webkitRequestFullscreen();
    return 'webkit-enter';
  }
  if (video?.webkitEnterFullscreen) {
    video.webkitEnterFullscreen();
    return 'webkit-video-enter';
  }
  throw new Error('当前环境不支持全屏');
}

type FullscreenControl = {
  addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
  removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
};

type ArtplayerFullscreenSurface = {
  controls: Record<string, FullscreenControl | undefined>;
  on(name: string, listener: () => void): unknown;
  off(name: string, listener: () => void): unknown;
};

export function bindArtplayerFullscreen(
  art: ArtplayerFullscreenSurface,
  toggle: () => void,
): () => void {
  const onControlClick = (event: Event) => {
    event.preventDefault();
    event.stopImmediatePropagation();
    toggle();
  };
  const onDoubleClick = () => toggle();
  const control = art.controls.fullscreen;

  control?.addEventListener('click', onControlClick, true);
  art.on('dblclick', onDoubleClick);

  return () => {
    control?.removeEventListener('click', onControlClick, true);
    art.off('dblclick', onDoubleClick);
  };
}
