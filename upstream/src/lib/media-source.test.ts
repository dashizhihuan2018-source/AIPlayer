import { describe, expect, it, vi } from 'vitest';
import { isDirectVideoFile, loadMediaSource } from './media-source';

describe('media source switching', () => {
  it('recognizes native files with query strings without treating HLS as MP4', () => {
    expect(isDirectVideoFile('https://example.test/movie.MP4?token=test')).toBe(true);
    expect(isDirectVideoFile('https://example.test/movie.m4v#t=10')).toBe(true);
    expect(isDirectVideoFile('https://example.test/movie.m3u8')).toBe(false);
  });
  it('detaches an existing HLS session before loading a native MP4 episode', () => {
    const events: string[] = [];
    const media = { src: '', removeAttribute: (name: string) => events.push(`clear:${name}`), load: () => events.push('load'), play: async () => { events.push('play'); } };
    const attachHls = vi.fn();
    loadMediaSource(media, 'https://example.test/next.mp4', () => events.push('detach'), attachHls);
    expect(events).toEqual(['detach', 'clear:crossorigin', 'load', 'play']);
    expect(media.src).toBe('https://example.test/next.mp4');
    expect(attachHls).not.toHaveBeenCalled();
  });
  it('routes switching back to HLS through the HLS setup callback', () => {
    const media = { src: '', removeAttribute: vi.fn(), load: vi.fn(), play: vi.fn(async () => {}) };
    const detach = vi.fn();
    const attach = vi.fn();
    loadMediaSource(media, 'https://example.test/next.m3u8', detach, attach);
    expect(attach).toHaveBeenCalledWith('https://example.test/next.m3u8');
    expect(detach).not.toHaveBeenCalled();
    expect(media.load).not.toHaveBeenCalled();
  });
  it('does not surface an unhandled autoplay rejection for a native file', async () => {
    const media = { src: '', removeAttribute: vi.fn(), load: vi.fn(), play: vi.fn(async () => { throw new Error('autoplay denied'); }) };
    loadMediaSource(media, 'https://example.test/next.mp4', vi.fn(), vi.fn());
    await Promise.resolve();
    expect(media.play).toHaveBeenCalledOnce();
  });
});
