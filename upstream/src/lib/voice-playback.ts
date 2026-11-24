import type { SearchResultItem, SourceConfig, VideoDetail } from './types';
import { buildWatchUrl } from './utils';

interface VoiceSelection {
  title: string;
  episode?: string;
  index?: string;
}

type Match = { identity: string; index: number; item: SearchResultItem; source: SourceConfig };
const normalized = (text: string) => text.normalize('NFKC').toLowerCase().replace(/[\p{P}\p{Z}\s\u200B-\u200D\uFEFF]/gu, '');

function titleScore(name: string, title: string, episode: string) {
  if (episode && ['', '剧场版', '电影版', '特别篇', '终章', '最终章', '完结篇']
    .some((suffix) => name === title + suffix + episode)) return 4;
  if (name === title) return 3;
  if (episode && name.startsWith(title) && name.endsWith(episode)) return 2;
  if (episode && name.startsWith(title)) return 1;
  return 0;
}

function episodeIndex(selection: VoiceSelection, detail: VideoDetail, score: number): number {
  const count = detail.episodes.length;
  if (!count) return -1;
  const position = selection.index === 'last' ? count - 1 : selection.index ? Number(selection.index) - 1 : 0;
  if (!selection.episode) return Number.isInteger(position) && position >= 0 && position < count ? position : -1;
  if (count === 1 && (score === 4 || score === 2)) return 0;
  const episode = normalized(selection.episode);
  if (!episode || !detail.episodeLabels) return -1;
  const matches = detail.episodeLabels.flatMap((label, index) => {
    const name = normalized(label).replace(/^(?:第?[0-9一二三四五六七八九十百零]+[集话])/, '');
    return name === episode ? [index] : [];
  });
  return matches.length === 1 && (!selection.index || matches[0] === position) ? matches[0] : -1;
}

export async function voicePlaybackRoute(
  selection: VoiceSelection,
  items: SearchResultItem[],
  enabledSources: SourceConfig[],
  detail: (id: string, source: SourceConfig, signal: AbortSignal) => Promise<VideoDetail>,
  signal: AbortSignal,
): Promise<string | null> {
  const title = normalized(selection.title);
  const episode = selection.episode ? normalized(selection.episode) : '';
  if (!title || (selection.episode && !episode)) return null;
  const bySource = new Map(enabledSources.map((source) => [source.key, source]));
  const visited = new Set<string>();
  const candidates = items.flatMap((item) => {
    const source = bySource.get(item.sourceKey);
    const name = normalized(item.name);
    const score = titleScore(name, title, episode);
    if (episode && /(?:预告|花絮|片花|解说|混剪|剪辑)/u.test(item.remarks ?? '')) return [];
    const key = item.sourceKey + ':' + item.vodId;
    if (!source || !score || visited.has(key) || !item.vodId) return [];
    visited.add(key);
    return [{ item, source, score }];
  });
  // Query listings concurrently, but stop after the highest-ranked unambiguous match.
  for (const score of [4, 3, 2, 1]) {
    const group = candidates.filter((candidate) => candidate.score === score);
    if (!group.length) continue;
    // Never let other seasons or broad matches crowd out a verified full title.
    if (group.length > 32) return null;
    const matches = await Promise.all(group.map(async (candidate): Promise<Match | null> => {
      try {
        const data = await detail(candidate.item.vodId, candidate.source, signal);
        if (episode && /(?:预告|花絮|片花|解说|混剪|剪辑)/u.test(data.videoInfo.remarks ?? '')) return null;
        const index = episodeIndex(selection, data, score);
        const identity = normalized(data.videoInfo.title || candidate.item.name);
        if (index < 0 || titleScore(identity, title, episode) !== score) return null;
        return { ...candidate, identity, index };
      } catch {
        return null;
      }
    }));
    signal.throwIfAborted();
    const available = matches.filter((match) => match !== null);
    if (!available.length) continue;
    const identities = new Set(available.map((match) => match.identity));
    const years = new Set(available.map((match) => match.item.year).filter(Boolean));
    if (identities.size > 1 || years.size > 1) return null;
    // Prefer the order configured by the user, then the search result order.
    const firstSource = enabledSources.find((source) => available.some((match) => match.source === source));
    const chosen = available.find((match) => match.source === firstSource)!;
    return buildWatchUrl({
      sourceKey: chosen.source.key, vodId: chosen.item.vodId, index: chosen.index,
      title: chosen.item.name, sourceUrl: chosen.source.url, detail: chosen.source.detail,
    });
  }
  return null;
}
