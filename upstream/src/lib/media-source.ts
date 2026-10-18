export function isDirectVideoFile(url: string): boolean {
  return /\.(mp4|m4v)(?:$|[?#])/i.test(url);
}

export function loadMediaSource(
  video: Pick<HTMLVideoElement, 'src' | 'load' | 'play' | 'removeAttribute'>,
  url: string,
  detachHls: () => void,
  attachHls: (url: string) => void
): void {
  if (isDirectVideoFile(url)) {
    detachHls();
    // Native video playback does not require a CORS-enabled media host.
    // Canvas screenshots of a cross-origin file may remain unavailable.
    video.removeAttribute('crossorigin');
    video.src = url;
    video.load();
    void video.play().catch(() => {});
  } else {
    attachHls(url);
  }
}
