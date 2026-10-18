'use client';

import { useMemo, useState } from 'react';
import { PlayerShell } from '@/components/player-shell';
import { nativeAvailable, type MediaItem } from '@/lib/native-player';
import { DesktopWorkspace } from './desktop-workspace';

type BrowserPlayerProps = Parameters<typeof PlayerShell>[0];
export type WatchPlayerProps = BrowserPlayerProps & {
  episodes?: string[];
  currentIndex?: number;
  sourceLabel?: string;
  onSelect?: (index: number) => void;
  onBack?: () => void;
};

/** Ephemeral online identities do not contain credentials or machine paths. */
export function onlinePlaylist(urls: string[], title: string): MediaItem[] {
  const items = urls.flatMap((value, index) => {
    try {
      const url = new URL(value);
      if (!['http:', 'https:'].includes(url.protocol) || !url.hostname || url.username || url.password) return [];
      let hash = 2166136261;
      for (let i = 0; i < value.length; i += 1) hash = Math.imul(hash ^ value.charCodeAt(i), 16777619);
      return [{
        id: `online-${(hash >>> 0).toString(36)}-${index.toString(36)}`,
        name: (urls.length > 1 ? `${title} · 第 ${index + 1} 集` : title).slice(0, 500),
        kind: 'url' as const,
        url: value,
      }];
    } catch { return []; }
  });
  // Do not silently renumber the source's episodes after rejecting an entry.
  return items.length === urls.length ? items : [];
}

/** Loaded client-only: the desktop app never mounts an offscreen Artplayer. */
export function WatchPlayer(props: WatchPlayerProps) {
  const [nativeHost] = useState(nativeAvailable);
  const items = useMemo(
    () => onlinePlaylist(props.episodes?.length ? props.episodes : [props.url], props.title),
    [props.episodes, props.title, props.url],
  );
  const externalPlayback = useMemo(() => ({
    items,
    currentIndex: Math.min(Math.max(props.currentIndex ?? 0, 0), Math.max(0, items.length - 1)),
    title: props.title,
    sourceLabel: props.sourceLabel,
    onSelect: props.onSelect ?? (() => undefined),
    onBack: props.onBack,
    getRestorePosition: props.getRestorePosition,
    onProgress: props.onTimeUpdate,
    onEnded: props.onEnded,
  }), [items, props.currentIndex, props.title, props.sourceLabel, props.onSelect, props.onBack,
    props.getRestorePosition, props.onTimeUpdate, props.onEnded]);

  if (nativeHost) return <DesktopWorkspace externalPlayback={externalPlayback} />;
  return <div className="watch-browser-stage"><PlayerShell {...props} /></div>;
}
