// @vitest-environment jsdom
import { act, createElement } from 'react';
import { createRoot } from 'react-dom/client';
import { describe, expect, it, vi } from 'vitest';
import { DesktopHome } from './desktop-home';

describe('cosmic desktop home', () => {
  it('centres the approved local logo and routes the renamed resource entry to discovery', async () => {
    const host = document.createElement('div'), root = createRoot(host), onOpen = vi.fn();
    vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true);
    try {
      await act(async () => root.render(createElement(DesktopHome, { onOpen, canOpen: true, connecting: false })));
      expect(host.querySelector('h1')?.textContent).toBe('万能AI播放器');
      expect(host.querySelector('img')?.getAttribute('src')).toBe('/icons/aiplayer-master.png');
      expect(host.querySelector('a[aria-label="全网资源 一键搜索"]')?.getAttribute('href')).toBe('/discover');
      expect(host.textContent).not.toContain('在线发现');
      expect(host.textContent).not.toContain('直播');
      await act(async () => host.querySelector('button')!.click());
      expect(onOpen).toHaveBeenCalledOnce();
      await act(async () => root.render(createElement(DesktopHome, { onOpen, canOpen: false, connecting: true })));
      expect(host.querySelector('button')?.disabled).toBe(true);
      expect(host.textContent).toContain('正在连接播放引擎');
      expect(host.querySelector('.cosmic-title-divider')?.getAttribute('aria-hidden')).toBe('true');
    } finally { await act(async () => root.unmount()); vi.unstubAllGlobals(); }
  });
});
