import { describe, expect, it } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';

describe('desktop privacy disclosure', () => {
  const page = fs.readFileSync(path.join(process.cwd(), 'src/app/about/page.tsx'), 'utf8');
  it('does not promise IP anonymity for a loopback server', () => {
    expect(page).not.toContain('第三方数据源不会看到你的 IP 地址');
    expect(page).toContain('公网 IP');
  });
  it('discloses optional local media cache', () => {
    expect(page).toContain('本地缓存');
    expect(page).not.toContain('不存储任何视频文件');
  });
});
