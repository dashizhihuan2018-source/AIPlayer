import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, test, vi } from 'vitest';

const host = vi.hoisted(() => ({ native: true, external: null as unknown }));
vi.mock('@/lib/native-player', () => ({ nativeAvailable: () => host.native }));
vi.mock('./desktop-workspace', () => ({
  DesktopWorkspace: ({ externalPlayback }: { externalPlayback: { title: string; items: unknown[] } }) => {
    host.external = externalPlayback;
    return createElement('section', { 'data-player': 'native', 'data-count': externalPlayback.items.length }, externalPlayback.title);
  },
}));
vi.mock('@/components/player-shell', () => ({
  PlayerShell: ({ url }: { url: string }) => createElement('video', { 'data-web-url': url }),
}));

import { WatchPlayer, onlinePlaylist } from './watch-player';

describe('one immersive playback surface for online and local media', () => {
  test('uses the native workspace for online streams inside the desktop app', () => {
    host.native = true;
    const props = { url: 'https://example.test/a.m3u8', title: '测试影片', adFilter: false, autoplayNext: false };
    const html = renderToStaticMarkup(createElement(WatchPlayer, props));
    expect(html).toContain('data-player="native"');
    expect(html).not.toContain('data-web-url');
    expect(host.external).toMatchObject({ title: '测试影片', currentIndex: 0, items: [{ kind: 'url', url: props.url }] });
  });

  test('retains the actual HLS browser fallback outside the desktop host', () => {
    host.native = false;
    const html = renderToStaticMarkup(createElement(WatchPlayer, { url: 'https://example.test/a.m3u8', title: '测试', adFilter: true, autoplayNext: false }));
    expect(html).toContain('data-web-url="https://example.test/a.m3u8"');
    expect(html).not.toContain('data-player="native"');
  });

  test('gives online episodes stable URL-sensitive IDs without paths or credentials', () => {
    const first = onlinePlaylist(['https://example.test/a.m3u8', 'https://example.test/b.m3u8'], '影片');
    expect(first).toHaveLength(2);
    expect(first[0].name).toBe('影片 · 第 1 集');
    expect(first[0].id).toMatch(/^online-[a-z0-9-]+$/);
    expect(first[0].id).not.toBe(first[1].id);
    expect(onlinePlaylist(['https://example.test/a.m3u8'], '影片')[0].id).toBe(first[0].id);
    expect(onlinePlaylist(['https://example.test/c.m3u8'], '影片')[0].id).not.toBe(first[0].id);
  });

  test('rejects unsafe URL schemes and embedded credentials instead of loading them', () => {
    expect(onlinePlaylist(['file:///tmp/private.mp4', 'https://user:secret@example.test/a', 'javascript:alert(1)'], '影片')).toEqual([]);
  });

  test('never shifts episode indexes when one source URL is invalid', () => {
    expect(onlinePlaylist(['file:///tmp/private.mp4', 'https://example.test/second.m3u8'], '影片')).toEqual([]);
  });

  test('clamps a direct-link episode index to the only available item', () => {
    host.native = true;
    renderToStaticMarkup(createElement(WatchPlayer, { url: 'https://example.test/a.m3u8', title: '测试', adFilter: false, autoplayNext: false, currentIndex: 99 }));
    expect(host.external).toMatchObject({ currentIndex: 0 });
  });
});
