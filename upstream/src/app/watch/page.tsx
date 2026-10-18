'use client';

import { Suspense, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import dynamic from 'next/dynamic';
import { useRouter, useSearchParams } from 'next/navigation';
import Link from 'next/link';
import { useQuery } from '@tanstack/react-query';
import { api } from '@/lib/client-api';
// 播放器（artplayer + hls.js）按需加载：拆出独立 chunk，不占首屏 First Load JS
const WatchPlayer = dynamic(() => import('@/components/desktop/watch-player').then((m) => m.WatchPlayer), {
  ssr: false,
  loading: () => (
    <div className="w-full h-full flex items-center justify-center">
      <Spinner size="lg" />
    </div>
  ),
});
import { Spinner } from '@/components/states';
import { SwitchSourceModal } from '@/components/switch-source';
import { enqueueDownload } from '@/components/download-manager';
import { useAuth } from '@/components/auth';
import { resolveSource, useAppStore } from '@/lib/store';
import {
  clearProgress,
  progressKeyOf,
  saveProgress,
  updateHistoryProgress,
  upsertHistory,
  db,
} from '@/lib/db';
import { isDirectVideoFile } from '@/lib/media-source';
import '../desktop.css';
import './watch-player.css';

/**
 * 播放页（唯一入口，替代旧版 watch.html → player.html 跳转链）。
 * 状态全部由 URL 驱动：/watch?source=xx&id=..&index=..&title=..
 * 集数列表由服务端详情接口获取；进度与历史走 IndexedDB。
 */
export default function WatchPage() {
  return (
    <Suspense>
      <WatchContent />
    </Suspense>
  );
}
function WatchContent() {
  const searchParams = useSearchParams();
  const router = useRouter();
  const store = useAppStore();
  const { verified } = useAuth();

  const sourceKey = searchParams.get('source') || '';
  const vodId = searchParams.get('id') || '';
  const directUrl = searchParams.get('url') || '';
  // A pure media link has no CMS identity. Do not use it to mask a deleted source.
  const directPlayback = !sourceKey && !vodId && Boolean(directUrl);
  const playbackId = vodId || directUrl;
  const titleParam = searchParams.get('title') || '';
  const indexParam = parseInt(searchParams.get('index') || '0', 10) || 0;

  const [switchOpen, setSwitchOpen] = useState(false);

  const source = resolveSource(store, sourceKey, {
    url: searchParams.get('sourceUrl') || undefined,
    detail: searchParams.get('detail') || undefined,
  });

  // 详情查询：无 id（纯直连链接分享）时跳过
  const detailQuery = useQuery({
    queryKey: ['detail', sourceKey, vodId, source?.url],
    queryFn: ({ signal }) => api.detail(vodId, source!, signal),
    enabled: Boolean(source && vodId && verified),
    staleTime: 5 * 60_000,
  });

  const episodes = useMemo(() => detailQuery.data?.episodes ?? [], [detailQuery.data]);
  const videoTitle = titleParam || detailQuery.data?.videoInfo?.title || '未知视频';

  // 当前播放地址：优先取剧集列表中的当前集，其次直连 URL 参数
  const currentUrl = useMemo(() => {
    if (episodes.length > 0) {
      const idx = Math.min(Math.max(indexParam, 0), episodes.length - 1);
      return episodes[idx] || directUrl;
    }
    return directUrl;
  }, [episodes, indexParam, directUrl]);

  const currentIndex = useMemo(() => {
    if (episodes.length > 0) return Math.min(Math.max(indexParam, 0), episodes.length - 1);
    return indexParam;
  }, [episodes, indexParam]);

  const goEpisode = useCallback(
    (index: number) => {
      const sp = new URLSearchParams(searchParams.toString());
      sp.set('index', String(index));
      sp.set('url', episodes[index] || directUrl);
      sp.delete('position');
      router.replace(`/watch?${sp.toString()}`, { scroll: false });
    },
    [router, searchParams, episodes, directUrl]
  );

  // 进度恢复优先级：URL position 参数 > IndexedDB 记录
  const getRestorePosition = useCallback(async () => {
    const urlPos = parseInt(searchParams.get('position') || '0', 10) || 0;
    if (urlPos > 0) return urlPos;
    if (!playbackId) return 0;
    const entry = await db.progress.get(progressKeyOf(sourceKey, playbackId, currentIndex));
    return entry?.position ?? 0;
  }, [searchParams, sourceKey, playbackId, currentIndex]);

  // 写入观看历史（进入页面即记录，进度后续增量更新）
  useEffect(() => {
    if (!verified || !sourceKey || !currentUrl) return;
    const timer = setTimeout(() => {
      upsertHistory({
        sourceKey,
        sourceUrl: source?.url,
        vodId: vodId || currentUrl,
        title: videoTitle,
        pic: detailQuery.data?.videoInfo?.cover,
        episodeIndex: currentIndex,
        totalEpisodes: episodes.length,
        playbackPosition: 0,
        duration: 0,
        timestamp: Date.now(),
      }).catch(() => {});
    }, 2000);
    return () => clearTimeout(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [verified, sourceKey, vodId, currentIndex, videoTitle, currentUrl]);

  // 播放中与暂停时的进度落盘逻辑一致，共用同一回调
  const handleProgress = useCallback(
    (position: number, duration: number) => {
      if (playbackId) {
        saveProgress(sourceKey, playbackId, currentIndex, position, duration).catch(() => {});
        updateHistoryProgress(sourceKey, playbackId, position, duration).catch(() => {});
      }
    },
    [sourceKey, playbackId, currentIndex]
  );

  // 自动连播的 800ms 延迟切集要在卸载时取消，避免离开页面后跳转
  const autoNextTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => () => {
    if (autoNextTimer.current) clearTimeout(autoNextTimer.current);
  }, []);

  const handleEnded = useCallback(() => {
    if (playbackId) clearProgress(sourceKey, playbackId, currentIndex).catch(() => {});
    if (store.autoplayNext && currentIndex < episodes.length - 1) {
      autoNextTimer.current = setTimeout(() => goEpisode(currentIndex + 1), 800);
    }
  }, [store.autoplayNext, currentIndex, episodes.length, goEpisode, sourceKey, playbackId]);

  // Alt+←/→ 集数切换快捷键
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (!e.altKey) return;
      if (e.key === 'ArrowLeft' && currentIndex > 0) {
        e.preventDefault();
        goEpisode(currentIndex - 1);
      } else if (e.key === 'ArrowRight' && currentIndex < episodes.length - 1) {
        e.preventDefault();
        goEpisode(currentIndex + 1);
      }
    };
    document.addEventListener('keydown', handler);
    return () => document.removeEventListener('keydown', handler);
  }, [currentIndex, episodes.length, goEpisode]);

  if (!verified) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <p className="text-faint text-sm">等待访问验证...</p>
      </div>
    );
  }

  if (directPlayback && !isHttpMediaUrl(directUrl)) {
    return (
      <div className="min-h-screen flex items-center justify-center px-4">
        <div className="text-center max-w-md">
          <h1 className="text-content font-medium mb-2">播放地址无效</h1>
          <p className="text-sm text-muted mb-4">请使用不含账号密码的完整 HTTP 或 HTTPS 视频地址。</p>
          <Link href="/" className="btn-primary">返回首页</Link>
        </div>
      </div>
    );
  }

  if (!source && !directPlayback) {
    return (
      <div className="min-h-screen flex items-center justify-center px-4">
        <div className="text-center max-w-md">
          <h1 className="text-content font-medium mb-2">点播源不存在</h1>
          <p className="text-sm text-muted mb-4">
            该视频来自点播源「{sourceKey}」，但它可能已被删除。请在设置中重新添加后重试。
          </p>
          <Link href="/" className="btn-primary">返回首页</Link>
        </div>
      </div>
    );
  }

  return (
    <div className="watch-immersive-page">
      <h1 className="sr-only">{videoTitle}</h1>
      <p className="sr-only">{source?.name || '直连播放'}</p>
      <div className="watch-context-actions" aria-label="在线资源操作">
            <button
              className="btn-ghost btn-sm"
              disabled={isDirectVideoFile(currentUrl)}
              title={isDirectVideoFile(currentUrl) ? '暂不支持 MP4/M4V 直链下载' : '下载当前 HLS 节目'}
              onClick={() => {
                if (!currentUrl || isDirectVideoFile(currentUrl)) return;
                enqueueDownload({
                  url: currentUrl,
                  // 多集才带集数后缀；单集影片（含电影）文件名就是纯标题
                  title: `${videoTitle}${episodes.length > 1 ? ` 第${currentIndex + 1}集` : ''}`,
                  format: 'MP4',
                });
                // 「已加入下载队列」由 DownloadManager 在真正入队后提示：
                // 这里先提示的话，用户随后取消保存位置会出现「已加入→已取消」的矛盾
              }}
            >
              {isDirectVideoFile(currentUrl) ? 'MP4 直链暂不支持下载' : '下载本集'}
            </button>
            {!directPlayback && (
              <button className="btn-ghost btn-sm" onClick={() => setSwitchOpen(true)}>
                切换资源
              </button>
            )}
        <button onClick={() => store.updateSettings({ autoplayNext: !store.autoplayNext })} aria-pressed={store.autoplayNext}>自动连播{store.autoplayNext ? '：开' : '：关'}</button>
      </div>
      <main aria-label="播放窗口">
              {currentUrl ? (
                <WatchPlayer
                  url={currentUrl}
                  title={videoTitle}
                  adFilter={store.adFilter}
                  autoplayNext={store.autoplayNext}
                  episodeKey={`${sourceKey}:${playbackId}:${currentIndex}`}
                  nextUrl={currentIndex + 1 < episodes.length ? episodes[currentIndex + 1] : undefined}
                  nextEpisodeKey={currentIndex + 1 < episodes.length ? `${sourceKey}:${playbackId}:${currentIndex + 1}` : undefined}
                  getRestorePosition={getRestorePosition}
                  onTimeUpdate={handleProgress}
                  onPause={handleProgress}
                  onEnded={handleEnded}
                  episodes={episodes}
                  currentIndex={currentIndex}
                  sourceLabel={source?.name || '直连播放'}
                  onSelect={goEpisode}
                  onBack={() => router.push('/discover')}
                  onRequestSwitchSource={directPlayback ? undefined : () => setSwitchOpen(true)}
                />
              ) : (
                <div className="w-full h-full flex items-center justify-center">
                  {detailQuery.isLoading ? (
                    <Spinner size="lg" />
                  ) : (
                    <p className="text-faint text-sm">
                      {detailQuery.isError ? '视频加载失败，请尝试其他资源' : '无可用播放地址'}
                    </p>
                  )}
                </div>
              )}
      </main>

      {switchOpen && (
        <SwitchSourceModal
          currentTitle={videoTitle}
          currentSourceKey={sourceKey}
          currentVodId={vodId}
          currentIndex={currentIndex}
          onClose={() => setSwitchOpen(false)}
        />
      )}
    </div>
  );
}

/** Client-side media selection only; server proxy SSRF validation remains authoritative. */
function isHttpMediaUrl(value: string): boolean {
  try {
    const url = new URL(value);
    return (url.protocol === 'https:' || url.protocol === 'http:') &&
      Boolean(url.hostname) && !url.username && !url.password;
  } catch {
    return false;
  }
}
