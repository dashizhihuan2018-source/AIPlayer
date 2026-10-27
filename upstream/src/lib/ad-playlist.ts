import { markedAdRanges, type AdRange } from './ad-skip';

type Analysis = { ranges: AdRange[]; duration: number; supported: boolean };
type ReadPlaylist = (url: string) => Promise<{ text: string; url: string }>;
const unsupported = (): Analysis => ({ ranges: [], duration: 0, supported: false });

/** All master variants must agree: mpv may select a different rendition. */
export async function analyzeAdPlaylist(url: string, read: ReadPlaylist, depth = 0): Promise<Analysis> {
  const target = new URL(url);
  if (!['http:', 'https:'].includes(target.protocol) || target.username || target.password || depth > 1) return unsupported();
  const { text, url: finalUrl } = await read(target.href);
  if (!text.trimStart().startsWith('#EXTM3U') || text.length > 1_048_576) return unsupported();
  const lines = text.split(/\r?\n/).map((v) => v.trim());
  if (lines.some((line) => line.startsWith('#EXT-X-STREAM-INF:'))) {
    const variants = lines.flatMap((line, index) => line.startsWith('#EXT-X-STREAM-INF:') && lines[index + 1] && !lines[index + 1].startsWith('#') ? [new URL(lines[index + 1], finalUrl).href] : []);
    if (!variants.length || variants.length > 4 || depth > 0) return unsupported();
    const results = await Promise.all(variants.map((variant) => analyzeAdPlaylist(variant, read, depth + 1)));
    const first = results[0];
    return results.every((v) => v.supported && Math.abs(v.duration - first.duration) < 0.1 && JSON.stringify(v.ranges) === JSON.stringify(first.ranges)) ? first : unsupported();
  }
  if (!lines.includes('#EXT-X-ENDLIST')) return unsupported();
  const durations = lines.filter((line) => line.startsWith('#EXTINF:')).map((line) => Number(line.slice(8).split(',')[0]));
  if (!durations.length || durations.some((v) => !Number.isFinite(v) || v <= 0 || v > 600)) return unsupported();
  const duration = durations.reduce((sum, v) => sum + v, 0);
  if (duration > 604_800) return unsupported();
  return { ranges: markedAdRanges(text, finalUrl), duration, supported: true };
}
