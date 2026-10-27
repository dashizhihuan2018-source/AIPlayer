import { describe, expect, it } from 'vitest';
import { analyzeAdPlaylist } from './ad-playlist';
const content = '#EXTM3U\n#EXTINF:5,\n/ads/a.ts\n#EXTINF:10,\nmain.ts\n#EXT-X-ENDLIST';
describe('ad playlist boundary validation', () => {
  it('accepts VOD and resolves all renditions only when timelines agree', async () => {
    const master = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=10\na.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=20\nb.m3u8';
    const read = async (url: string) => ({ url, text: url.endsWith('master.m3u8') ? master : content });
    expect(await analyzeAdPlaylist('https://media.example/master.m3u8', read)).toEqual({ ranges: [{ start: 0, end: 5 }], duration: 15, supported: true });
    const different = async (url: string) => ({ url, text: url.endsWith('master.m3u8') ? master : url.endsWith('a.m3u8') ? content : content.replace('/ads/a.ts', 'main0.ts') });
    expect((await analyzeAdPlaylist('https://media.example/master.m3u8', different)).supported).toBe(false);
  });
  it('refuses local schemes, credentials, live, deeply nested and oversized manifests', async () => {
    let reads = 0;
    const read = async (url: string) => { reads += 1; return { url, text: content }; };
    expect((await analyzeAdPlaylist('file:///etc/passwd', read)).supported).toBe(false);
    expect((await analyzeAdPlaylist('https://user:secret@media.example/a', read)).supported).toBe(false);
    expect(reads).toBe(0);
    expect((await analyzeAdPlaylist('https://media.example/a', async (url) => ({ url, text: content.replace('#EXT-X-ENDLIST', '') }))).supported).toBe(false);
    expect((await analyzeAdPlaylist('https://media.example/a', async (url) => ({ url, text: '#EXTM3U\n' + 'x'.repeat(1_048_576) }))).supported).toBe(false);
    expect((await analyzeAdPlaylist('https://media.example/a', read, 2)).supported).toBe(false);
  });
});
