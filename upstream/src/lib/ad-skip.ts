export type AdRange = { start: number; end: number };
/** Original media timeline: no playlist edits, timestamp rebasing or duration guesses. */
export function markedAdRanges(text: string, base: string): AdRange[] {
  if (!text.trimStart().startsWith('#EXTM3U') || !/^#EXT-X-ENDLIST\s*$/m.test(text)) return [];
  const ranges: AdRange[] = [];
  let time = 0, duration: number | null = null, cueStart: number | null = null;
  for (const line of text.split(/\r?\n/).map((v) => v.trim())) {
    if (line.startsWith('#EXTINF:')) {
      duration = Number(line.slice(8).split(',')[0]);
      if (!Number.isFinite(duration) || duration <= 0 || duration > 600) return [];
    } else if (/^#EXT-X-CUE-OUT(?::|$)/.test(line)) {
      if (cueStart !== null) return []; // ambiguous nested markers
      cueStart = time;
    } else if (line === '#EXT-X-CUE-IN') {
      if (cueStart !== null && time > cueStart && time - cueStart <= 180) ranges.push({ start: cueStart, end: time });
      cueStart = null;
    } else if (line && !line.startsWith('#')) {
      if (duration === null) return []; // master/malformed playlist
      // Do not inherit an /ads/ directory from the manifest URL or inspect query values.
      let path: string;
      try { path = new URL(line, base).pathname; } catch { return []; }
      const explicitPath = line.split('?')[0];
      if (/(?:^|\/)(?:ads?|adjump|advert(?:isement)?)(?:\/|[._-])/i.test(explicitPath)
          && /(?:^|\/)(?:ads?|adjump|advert(?:isement)?)(?:\/|[._-])/i.test(path)) {
        ranges.push({ start: time, end: time + duration });
      }
      time += duration;
      duration = null;
      if (time > 604_800) return [];
    }
  }
  if (duration !== null) return [];
  const merged: AdRange[] = [];
  for (const range of ranges.sort((a, b) => a.start - b.start)) {
    const last = merged[merged.length - 1];
    if (last && range.start <= last.end) last.end = Math.max(last.end, range.end);
    else merged.push({ ...range });
  }
  return merged.filter((r) => r.end - r.start <= 180 && r.end < time);
}
export function adSkipTarget(ranges: AdRange[], time: number, duration: number, playing: boolean): number | null {
  if (!playing || !Number.isFinite(time) || !Number.isFinite(duration) || duration <= 0) return null;
  return ranges.find((r) => Number.isFinite(r.start) && Number.isFinite(r.end)
    && r.start >= 0 && r.end > r.start && r.end - r.start <= 180 && r.end < duration
    && time >= r.start && time < r.end)?.end ?? null;
}
