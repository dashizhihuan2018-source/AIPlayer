import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { beforeEach, describe, expect, test, vi } from 'vitest';

const state = vi.hoisted(() => ({
  params: new URLSearchParams(),
  source: undefined as undefined | { key: string; name: string; url: string },
  verified: true,
  queries: [] as { enabled: boolean }[],
}));

// Keep the actual page and its React rendering; isolate browser/router and I/O boundaries.
vi.mock('next/navigation', () => ({
  useSearchParams: () => state.params,
  useRouter: () => ({ back() {}, push() {}, replace() {} }),
}));
vi.mock('next/dynamic', () => ({
  default: () => ({ url, episodeKey }: { url: string; episodeKey: string }) =>
    createElement('video', { 'data-test-url': url, 'data-test-episode': episodeKey }),
}));
vi.mock('@/components/auth', () => ({ useAuth: () => ({ verified: state.verified }) }));
vi.mock('@/lib/store', () => ({
  useAppStore: () => ({ adFilter: false, autoplayNext: false, updateSettings() {} }),
  resolveSource: () => state.source,
}));
vi.mock('@tanstack/react-query', () => ({
  useQuery: (query: { enabled: boolean }) => {
    state.queries.push(query);
    return { data: undefined, isLoading: false, isError: false };
  },
}));
vi.mock('@/components/download-manager', () => ({ enqueueDownload: vi.fn() }));
vi.mock('@/components/switch-source', () => ({ SwitchSourceModal: () => null }));

import WatchPage from './page';

function renderWatch(query: Record<string, string>) {
  state.params = new URLSearchParams(query);
  return renderToStaticMarkup(createElement(WatchPage));
}

describe('watch direct URL entry', () => {
  beforeEach(() => {
    state.source = undefined;
    state.verified = true;
    state.queries = [];
  });

  test('plays an HTTPS direct link without requiring a CMS source', () => {
    const url = 'https://example.test/video/master.m3u8';
    const html = renderWatch({ url, title: '直连测试' });
    expect(html).not.toContain('点播源不存在');
    expect(html).toContain('data-test-url="' + url + '"');
    expect(html).toContain('直连播放');
    expect(html).not.toContain('切换资源');
    expect(state.queries.at(-1)?.enabled).toBe(false);
  });

  test('accepts an explicit HTTP direct link', () => {
    const url = 'http://example.test/video.mp4';
    expect(renderWatch({ url })).toContain('data-test-url="' + url + '"');
  });

  test('uses a viewport playback stage instead of the old catalogue grid', () => {
    const html = renderWatch({ url: 'https://example.test/video.m3u8', title: '沉浸播放' });
    expect(html).toContain('watch-immersive-page');
    expect(html).not.toContain('lg:grid-cols-[1fr_300px]');
    expect(html).not.toContain('max-w-7xl');
    expect(html).not.toContain('暂无剧集信息');
  });

  test('keeps direct media cache identities separate between URLs', () => {
    const first = 'https://example.test/first.m3u8';
    const second = 'https://example.test/second.m3u8';
    expect(renderWatch({ url: first })).toContain('data-test-episode=":' + first + ':0"');
    expect(renderWatch({ url: second })).toContain('data-test-episode=":' + second + ':0"');
  });

  test.each([
    'javascript:alert(1)',
    'data:video/mp4;base64,AAAA',
    'file:///tmp/video.mp4',
    'ftp://example.test/video.mp4',
    '//example.test/video.mp4',
    '/api/video.mp4',
    'not-a-url',
    'https://user:password@example.test/video.mp4',
  ])('does not hand invalid or non-web direct links to the player: %s', (url) => {
    const html = renderWatch({ url });
    expect(html).toContain('播放地址无效');
    expect(html).not.toContain('data-test-url');
  });

  test('does not disguise a deleted CMS source as direct playback', () => {
    const html = renderWatch({ source: 'deleted', id: '123', url: 'https://example.test/video.m3u8' });
    expect(html).toContain('点播源不存在');
    expect(html).not.toContain('data-test-url');
  });

  test('keeps missing source errors for incomplete CMS links', () => {
    expect(renderWatch({ id: '123' })).toContain('点播源不存在');
    expect(renderWatch({})).toContain('点播源不存在');
  });

  test('keeps CMS display, source switching, and detail loading', () => {
    state.source = { key: 'cms', name: '测试点播源', url: 'https://example.test/api.php' };
    const html = renderWatch({ source: 'cms', id: '123' });
    expect(html).toContain('测试点播源');
    expect(html).toContain('切换资源');
    expect(state.queries.at(-1)?.enabled).toBe(true);
  });

  test('does not bypass authentication for direct links', () => {
    state.verified = false;
    const html = renderWatch({ url: 'https://example.test/video.m3u8' });
    expect(html).toContain('等待访问验证');
    expect(html).not.toContain('data-test-url');
  });
});
