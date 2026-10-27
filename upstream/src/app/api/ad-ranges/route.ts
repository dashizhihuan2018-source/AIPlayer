import { NextResponse } from 'next/server';
import { guardRequest } from '@/lib/api-guard';
import { fetchWithSafeRedirects } from '@/lib/fetch-utils';
import { analyzeAdPlaylist } from '@/lib/ad-playlist';

export const runtime = 'nodejs';
export async function GET(req: Request) {
  const denied = guardRequest(req);
  if (denied) return denied;
  const url = new URL(req.url).searchParams.get('url') ?? '';
  try {
    const result = await analyzeAdPlaylist(url, async (target) => {
      const { res, finalUrl } = await fetchWithSafeRedirects(target, { signal: AbortSignal.timeout(8_000) });
      if (!res.ok || !res.body) throw new Error('playlist unavailable');
      const reader = res.body.getReader();
      const chunks: Uint8Array[] = [];
      let bytes = 0;
      try {
        for (;;) {
          const next = await reader.read();
          if (next.done) break;
          bytes += next.value.byteLength;
          if (bytes > 1_048_576) throw new Error('playlist too large');
          chunks.push(next.value);
        }
      } finally { await reader.cancel(); }
      return { text: Buffer.concat(chunks).toString('utf8'), url: finalUrl };
    });
    return NextResponse.json(result, { headers: { 'Cache-Control': 'no-store' } });
  } catch {
    // Optional detection must not interrupt playback or disclose source URLs.
    return NextResponse.json({ ranges: [], duration: 0, supported: false }, { headers: { 'Cache-Control': 'no-store' } });
  }
}
