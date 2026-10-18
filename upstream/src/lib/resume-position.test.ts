import { describe, expect, it } from 'vitest';
import { restorePosition } from './resume-position';

describe('metadata-ready resume', () => {
  it('restores a saved timestamp when metadata is available', async () => {
    const media = { duration: 1800, currentTime: 0 };
    expect(await restorePosition(media, async () => 122.2, () => true)).toBe(122.2);
    expect(media.currentTime).toBe(122.2);
  });
  it('ignores a stale episode after an async database read', async () => {
    const media = { duration: 1800, currentTime: 0 };
    expect(await restorePosition(media, async () => 122, () => false)).toBe(0);
    expect(media.currentTime).toBe(0);
  });
  it('does not seek beyond the end or into a live stream', async () => {
    for (const duration of [0, Infinity, 100]) {
      const media = { duration, currentTime: 0 };
      expect(await restorePosition(media, async () => 122, () => true)).toBe(0);
    }
  });
});
