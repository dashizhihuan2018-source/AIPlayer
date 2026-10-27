import { describe, expect, it } from 'vitest';
import { markedAdRanges, adSkipTarget } from './ad-skip';

const vod = (segments: string) => `#EXTM3U\n#EXT-X-TARGETDURATION:10\n${segments}\n#EXT-X-ENDLIST`;
describe('conservative native advertising fast-forward', () => {
  it('skips explicit advertising paths on the original unmodified timeline', () => {
    expect(markedAdRanges(vod('#EXTINF:10,\nmain0.ts\n#EXT-X-DISCONTINUITY\n#EXTINF:5,\n/ads/a.ts\n#EXTINF:5,\n/ads/b.ts\n#EXT-X-DISCONTINUITY\n#EXTINF:10,\nmain1.ts'), 'https://media.example/movie/list.m3u8'))
      .toEqual([{ start: 10, end: 20 }]);
  });
  it('accepts a closed cue-out/in block, not an unterminated cue', () => {
    expect(markedAdRanges(vod('#EXT-X-CUE-OUT:5\n#EXTINF:5,\na.ts\n#EXT-X-CUE-IN\n#EXTINF:10,\nb.ts'), 'https://media.example/list.m3u8')).toEqual([{ start: 0, end: 5 }]);
    expect(markedAdRanges(vod('#EXT-X-CUE-OUT:5\n#EXTINF:5,\na.ts'), 'https://media.example/list.m3u8')).toEqual([]);
  });
  it('does not guess using duration, discontinuities, query text or the parent URL', () => {
    expect(markedAdRanges(vod('#EXT-X-DISCONTINUITY\n#EXTINF:5,\na.ts?title=advert\n#EXT-X-DISCONTINUITY\n#EXTINF:10,\nb.ts'), 'https://media.example/ads/list.m3u8')).toEqual([]);
  });
  it('rejects live, malformed and excessive advertising ranges', () => {
    expect(markedAdRanges('#EXTM3U\n#EXTINF:5,\n/ads/a.ts', 'https://media.example/a')).toEqual([]);
    expect(markedAdRanges(vod('#EXTINF:NaN,\n/ads/a.ts'), 'https://media.example/a')).toEqual([]);
    expect(markedAdRanges(vod('#EXTINF:200,\n/ads/a.ts'), 'https://media.example/a')).toEqual([]);
  });
  it('seeks to the ad end only during active playback and within valid duration', () => {
    const ranges = [{ start: 10, end: 20 }];
    expect(adSkipTarget(ranges, 12, 30, true)).toBe(20);
    expect(adSkipTarget(ranges, 12, 30, false)).toBeNull();
    expect(adSkipTarget(ranges, 20, 30, true)).toBeNull();
    expect(adSkipTarget(ranges, 12, 15, true)).toBeNull();
    expect(adSkipTarget(ranges, NaN, 30, true)).toBeNull();
  });
});
