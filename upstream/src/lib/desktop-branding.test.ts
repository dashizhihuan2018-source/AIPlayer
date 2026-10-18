import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { expect, it } from 'vitest';

const read = (path: string) => readFileSync(resolve(process.cwd(), path), 'utf8');

it('uses the requested application name without migrating existing user storage', () => {
  const plist = read('../desktop/Info.plist');
  expect(plist).toContain('<key>CFBundleDisplayName</key><string>万能AI播放器</string>');
  expect(plist).toContain('<key>CFBundleName</key><string>万能AI播放器</string>');
  expect(plist).toContain('<key>CFBundleIconFile</key><string>AIplayer</string>');
  expect(plist).toContain('<key>CFBundleIdentifier</key><string>cn.nankong.libretv.desktop</string>');
  expect(read('../desktop/build.sh')).toContain('dist/万能AI播放器.app');
  const main = read('../desktop/main.swift');
  expect(main).toContain('window.title = "万能AI播放器"');
  expect(main).toContain('Library/Application Support/LibreTV Desktop');
  expect(main).toContain('Library/Logs/LibreTV Desktop');
  expect(main).toContain('setFrameAutosaveName("LibreTV.MainWindow")');
});

it('shows the requested brand and accurate automatic source guidance', () => {
  expect(read('src/app/layout.tsx')).toContain("default: '万能AI播放器'");
  expect(read('src/app/manifest.ts')).toContain("short_name: '万能AI播放器'");
  expect(read('src/components/header.tsx')).toContain('aria-label="万能AI播放器 首页"');
  expect(read('src/app/page.tsx')).toContain('>万能AI播放器</h1>');
  expect(read('src/app/page.tsx')).not.toContain('LibreTV 不内置任何采集站');
  expect(read('src/app/about/page.tsx')).toContain('22 个');
  expect(read('src/app/about/page.tsx')).not.toContain('默认不附带第三方点播源');
});

it('ships the new AIplayer artwork at native and web icon sizes', () => {
  const master = resolve(process.cwd(), 'public/icons/aiplayer-master.png');
  expect(existsSync(master)).toBe(true);
  const image = readFileSync(master);
  expect(image.subarray(1, 4).toString()).toBe('PNG');
  expect(image.readUInt32BE(16)).toBeGreaterThanOrEqual(1024);
  expect(image.readUInt32BE(16)).toBe(image.readUInt32BE(20));
  // Both VOD and live players use this startup poster; it must not retain the old L artwork.
  expect(readFileSync(resolve(process.cwd(), 'public/player-poster.png')).equals(image)).toBe(true);
  for (const size of [48, 96, 144, 192, 512]) {
    const icon = readFileSync(resolve(process.cwd(), `public/icons/icon-${size}.png`));
    expect(icon.readUInt32BE(16)).toBe(size);
    expect(icon.readUInt32BE(20)).toBe(size);
  }
  expect(read('../desktop/build.sh')).toContain('public/icons/aiplayer-master.png');
});
