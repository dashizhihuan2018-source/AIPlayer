'use client';

import Link from 'next/link';

export function DesktopHome({ onOpen, canOpen, connecting }: { onOpen: () => void; canOpen: boolean; connecting: boolean }) {
  return <div className="stage-empty cosmic-home">
    <div className="cosmic-content">
      <div className="cosmic-brand">
        {/* The approved logo remains local; decorative stars need no network. */}
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img className="empty-brand-logo" src="/icons/aiplayer-master.png" width="120" height="120" alt="AIPlayer" draggable={false} />
        <h1>万能AI播放器</h1>
      </div>
      <span className="cosmic-title-divider" aria-hidden="true"><i />✦<i /></span>
      <Link className="discover-entry" href="/discover" aria-label="全网资源 一键搜索">
        <span className="cosmic-search-icon" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="10.5" cy="10.5" r="6.5" /><path d="m16 16 5 5" /></svg></span>
        <span className="discover-entry-copy"><strong>全网资源 一键搜索</strong><span>电影 · 剧集 · 更多精彩</span></span>
        <span className="cosmic-entry-line" aria-hidden="true" />
      </Link>
      <div className="cosmic-local">
        <span className="cosmic-divider" aria-hidden="true"><i />本地放映<i /></span>
        <button data-testid="open-local-media" type="button" onClick={onOpen} disabled={!canOpen}><svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M3 7h7l2 2h9v11H3z M3 7V4h7l2 3" /></svg>打开文件…</button>
        <p>{connecting ? '正在连接播放引擎…' : '选择视频或音频文件，也可直接拖入窗口'}</p>
      </div>
    </div>
    <span className="cosmic-footer" aria-hidden="true"><i />AIPlayer<i /></span>
  </div>;
}
