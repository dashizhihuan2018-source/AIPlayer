import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';

// Browser storage and native I/O start in effects; keep the actual player UI.
vi.mock('@/components/history-panel', () => ({ HistoryPanel: () => null }));
vi.mock('@/components/download-manager', () => ({ requestShowDownloadManager() {} }));

import { AudioSubtitlePanel, DesktopWorkspace, type ExternalPlayback } from './desktop-workspace';

describe('immersive desktop player UI', () => {
  const render = () => renderToStaticMarkup(createElement(DesktopWorkspace));

  it('uses the full-window player instead of a permanent website navigation rail', () => {
    const html = render();
    expect(html).toContain('desktop-player-workspace');
    expect(html).toContain('aria-label="播放器菜单"');
    expect(html).not.toContain('aria-label="主导航"');
    expect(html).not.toContain('SCREENING STATION');
    expect(html).not.toContain('stage-ruler');
    expect(html).not.toContain('stage-corners');
  });

  it('starts with the settings and queue dismissed, leaving only player controls', () => {
    const html = render();
    expect(html).toContain('aria-label="播放列表"');
    expect(html).toContain('aria-label="画面设置"');
    expect(html).toContain('aria-label="播放器工具面板" aria-hidden="true"');
    expect(html).not.toContain('data-testid="play-queue"');
    expect(html).toContain('class="transport-time"');
    expect(html).toContain('aria-label="播放控制"');
  });

  it('offers only video, audio and subtitle settings tabs, separate from the queue', () => {
    const html = render();
    expect(html.match(/role="tab"/g)).toHaveLength(3);
    expect(html).toMatch(/role="tab"[^>]*>视频<\/button>/);
    expect(html).toMatch(/role="tab"[^>]*>音频<\/button>/);
    expect(html).toMatch(/role="tab"[^>]*>字幕<\/button>/);
    expect(html).toContain('<summary>章节与书签</summary>');
    expect(html).toContain('<summary>媒体信息与播放偏好</summary>');
  });

  it('keeps actual local open and transport controls accessible without fake playback', () => {
    const html = render();
    expect(html).toContain('data-testid="open-local-media"');
    expect(html).toContain('aria-label="播放进度"');
    expect(html).toContain('aria-label="音量"');
    expect(html).toContain('aria-label="全屏"');
    expect(html).toContain('aria-label="打开播放器菜单"');
    expect(html).toMatch(/aria-label="播放"[^>]*disabled/);
    expect(html).not.toContain('拖放你的观影时间');
  });

  it('gates the poster tool on real native capability instead of substituting fullscreen', () => {
    const html = render();
    expect(html).toContain('aria-label="生成竖版电影海报"');
    expect(html).toMatch(/aria-label="生成竖版电影海报"[^>]*disabled/);
  });

  it('labels GIF as a capture flow, not a hard-coded immediate three-second save', () => {
    const html = render();
    expect(html).toContain('aria-label="制作 GIF"');
    expect(html).not.toContain('生成 3 秒 GIF');
  });

  it('centers the approved logo and offers a large illustrated discover entry without live links', () => {
    const html = render();
    expect(html).toMatch(/<img[^>]*class="empty-brand-logo"[^>]*src="\/icons\/aiplayer-master.png"/);
    expect(html).toContain('class="discover-entry"');
    expect(html).toContain('cosmic-home');
    expect(html).toContain('aria-label="全网资源 一键搜索"');
    const css = readFileSync(new URL('../../app/desktop.css', import.meta.url), 'utf8');
    expect(css).toContain("url('/cosmic-home-background.jpg')");
    expect(css).toContain('align-items: center');
    expect(html).not.toContain('href="/live"');
    const source = readFileSync(new URL('./desktop-workspace.tsx', import.meta.url), 'utf8');
    expect(source).not.toContain('href="/live"');
  });

  it('renders external selections without exposing local file import', () => {
    const html = renderToStaticMarkup(createElement<{ externalPlayback?: ExternalPlayback }>(DesktopWorkspace, { externalPlayback: {
      items: [{ id: 'stream_test', kind: 'url', name: '第二集', url: 'https://example.test/2.m3u8' }],
      currentIndex: 0, onSelect() {}, title: '影片标题',
    } }));
    expect(html).toContain('影片标题');
    expect(html).toContain('has-media is-playing');
    expect(html).not.toContain('data-testid="open-local-media"');
    expect(html).not.toContain('打开本地媒体…');
    expect(html).toMatch(/title="上一项"[^>]*disabled/);
    expect(html).toMatch(/title="下一项"[^>]*disabled/);
  });

  it('keeps OCR results non-modal so overlay detection does not hide the video', () => {
    const source = readFileSync(new URL('./desktop-media-tools.tsx', import.meta.url), 'utf8');
    expect(source).toContain('className="ocr-result" role="region"');
  });

  it('resamples paused browser seeks after completion, and routes transport actions through intent lanes', () => {
    const source = readFileSync(new URL('./desktop-workspace.tsx', import.meta.url), 'utf8');
    expect(source).toContain('onSeeked={onBrowserState}');
    expect(source).toContain("transport.seek.relative(delta)");
    expect(source).toContain('onClick={togglePause}');
    expect(source).toContain('onClick={toggleMute}');
    expect(source).not.toMatch(/runCommand\('seek',\s*player\.time\s*[+-]/);
    expect(source).not.toContain("runCommand('pause', !player.paused)");
  });

  it('gives the seek slider a 24px transparent hit target above the transport buttons while retaining a 3px track', () => {
    const css = readFileSync(new URL('../../app/desktop.css', import.meta.url), 'utf8');
    const rule = (selector: string) => css.slice(css.indexOf(`${selector} {`)).split('}')[0];
    const timeline = rule('.timeline-row');
    const input = rule('.timeline-row input');
    const controls = rule('.transport-row');
    expect(timeline).toContain('height: 24px');
    expect(timeline).toContain('inset: -12px 0 auto');
    expect(Number(timeline.match(/z-index:\s*(\d+)/)?.[1])).toBeGreaterThan(Number(controls.match(/z-index:\s*(\d+)/)?.[1]));
    expect(input).toContain('height: 24px');
    expect(input).toContain('background-size: 100% 3px');
    expect(input).toContain('background-position: center');
    expect(input).toContain('background-repeat: no-repeat');
    expect(input).toContain('background-color: transparent');
    expect(rule('.timeline-row input::-webkit-slider-thumb')).toContain('height: 14px');
    expect(rule('.timeline-row input::-moz-range-thumb')).toContain('height: 14px');
  });

  it.each(['audio', 'subtitle'] as const)('separates the actual %s track controls', (kind) => {
    const html = renderToStaticMarkup(createElement(AudioSubtitlePanel, {
      kind, tracks: [{ id: 2, type: kind === 'audio' ? 'audio' : 'sub', selected: true, title: '测试轨道' }],
      delay: .5, canSelect: true, canDelay: true, canImport: false,
      onSelect() {}, onDelay() {}, onImport() {}, browserMode: false,
    }));
    expect(html).toContain(kind === 'audio' ? '音频延迟' : '字幕延迟');
    expect(html).not.toContain(kind === 'audio' ? '字幕延迟' : '音频延迟');
    expect(html).toContain('测试轨道');
    expect(html).toMatch(/<button[^>]*disabled/);
  });
});
