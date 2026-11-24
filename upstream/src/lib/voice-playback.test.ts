import { describe, expect, it } from 'vitest';
import { parseDetail } from './cms-parser';
import type { SearchResultItem, SourceConfig, VideoDetail } from './types';
import { beginVoicePlayback, nextVoicePlayback, voicePlaybackRoutes } from './voice-playback';

const source: SourceConfig = { key: 'fixture', name: '测试源', url: 'https://catalog.example.org/api' };
const item = (vodId: string, name: string, year = '2026'): SearchResultItem =>
  ({ vodId, name, year, sourceKey: source.key, sourceName: source.name });
const exact = { title: '星河守望', episode: '终局之战', index: 'last' };
const video = (title: string, labels: string[], remarks = '正片'): VideoDetail => ({
  videoInfo: { title, remarks, sourceKey: source.key, sourceName: source.name },
  episodes: labels.map((_, index) => 'https://media.example.org/' + index + '.m3u8'),
  episodeLabels: labels,
});
const select = (items: SearchResultItem[], details: Record<string, VideoDetail>, selection = exact) =>
  voicePlaybackRoutes(selection, items, [source], async (id) => details[id], new AbortController().signal).then((routes) => routes[0] ?? null);
const query = (route: string | null) => new URL(route ?? '/', 'http://local.test').searchParams;

describe('voice playback', () => {
  it('prioritizes the full special over broad results and treats invisible spacing as formatting', async () => {
    const full = '星河守望剧场版 终局之战\u200B';
    const unrelated = Array.from({ length: 40 }, (_, index) => item('other-' + index, '星河守望季' + index));
    const route = await select([...unrelated, item('special', full)], { special: video(full, ['正片']) });
    expect(query(route).get('id')).toBe('special');
    expect(query(route).get('index')).toBe('0');
  });

  it('checks both the episode label and the requested position', async () => {
    const files = [item('series', '星河守望')];
    expect(query(await select(files, { series: video('星河守望', ['第1集', '第2集 终局之战']) })).get('index')).toBe('1');
    expect(await select(files, { series: video('星河守望', ['第1集 终局之战', '第2集']) })).toBeNull();
    expect(await select(files, { series: video('星河守望', ['第1集', '第2集']) })).toBeNull();
    expect(await select(files, { series: video('星河守望', ['第1集', '第2集']) }, { ...exact, index: '3', episode: '' })).toBeNull();
  });

  it('leaves competing years and preview clips for manual selection', async () => {
    const full = '星河守望剧场版 终局之战';
    expect(await select([item('first', full), item('second', full, '2025')],
      { first: video(full, ['正片']), second: video(full, ['正片']) })).toBeNull();
    expect(await select([item('teaser', full)], { teaser: video(full, ['预告'], '预告') })).toBeNull();
  });

  it('tries the other verified source after a failed load and stops after exhausting the same episode', async () => {
    const full = '星河守望剧场版 终局之战';
    const backup = { ...source, key: 'backup', url: 'https://backup.example.org/api' };
    const items = [{ ...item('backup', full), sourceKey: backup.key }, item('preferred', full)];
    const routes = await voicePlaybackRoutes(exact, items, [source, backup],
      async (id) => ({ ...video(full, ['正片']), episodes: ['https://media.example.org/' + id + '.m3u8'] }),
      new AbortController().signal);

    expect(routes.map((route) => query(route).get('source'))).toEqual([source.key, backup.key]);
    const storage = new Map<string, string>();
    const session = {
      getItem: (key: string) => storage.get(key) ?? null,
      setItem: (key: string, value: string) => { storage.set(key, value); },
    };
    const first = query(beginVoicePlayback(routes, session));
    const second = nextVoicePlayback(first, session);
    expect(query(second).get('id')).toBe('backup');
    expect(query(second).get('index')).toBe('0');
    expect(nextVoicePlayback(query(second), session)).toBeNull();

    first.set('index', '1');
    expect(nextVoicePlayback(first, session)).toBeNull();
  });

  it('keeps labels in step with the preferred playback line', () => {
    const data = { list: [{ vod_name: '剧名', vod_play_url:
      '预告$https://test.example/share$$$第1集$https://test.example/1.m3u8#无效$bad#第2集终局之战$https://test.example/2.m3u8' }] };
    const parsed = parseDetail(data, source);
    expect(parsed.episodeLabels).toEqual(['第1集', '第2集终局之战']);
    expect(parsed.episodes).toHaveLength(2);
  });
});
