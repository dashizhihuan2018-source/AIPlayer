import { describe, expect, test } from 'vitest';

import {
  activeSubtitle,
  formatTimecode,
  moveQueueItem,
  nextQueueIndex,
  parseQueue,
  parseSRT,
  parseTimecode,
  validateAB,
  type MediaItem,
} from './desktop-player';

describe('parseQueue', () => {
  const local: MediaItem = { id: 'bookmark_A1-2', name: '影片.mkv', kind: 'local' };
  const remote: MediaItem = {
    id: 'remote_1',
    name: '公开流',
    kind: 'url',
    url: 'https://media.example.test/movie.mp4?quality=high',
  };

  test('restores valid opaque local IDs and HTTP(S) URLs without changing identity fields', () => {
    expect(parseQueue([local, remote])).toEqual([local, remote]);
    expect(
      parseQueue([
        { ...remote, id: 'remote_2', url: 'http://127.0.0.1/video.mp4' },
      ]),
    ).toHaveLength(1);
  });

  test.each([
    null,
    {},
    'queue',
    [{ id: 'one', name: '影片', kind: 'missing' }],
    [{ id: 'one', name: '', kind: 'local' }],
    [{ id: '../movie', name: '影片', kind: 'local' }],
    [{ id: 'one', name: '影片', kind: 'local', path: '/tmp/movie.mkv' }],
    [{ id: 'one', name: '影片', kind: 'local', localpath: '/tmp/movie.mkv' }],
    [{ id: 'one', name: '影片', kind: 'local', url: 'file:///tmp/movie.mkv' }],
    [{ id: 'one', name: '影片', kind: 'url', url: 'file:///tmp/movie.mkv' }],
    [{ id: 'one', name: '影片', kind: 'url', url: 'javascript:alert(1)' }],
    [{ id: 'one', name: '影片', kind: 'url', url: 'https://user:secret@example.test/a' }],
  ])('rejects malformed, path-bearing, non-network, or credential-bearing persistence: %j', (value) => {
    expect(parseQueue(value)).toEqual([]);
  });

  test('rejects the entire persistence value when its queue is unreasonably large', () => {
    expect(parseQueue(Array.from({ length: 1001 }, () => local))).toEqual([]);
  });

  test('bounds remote URLs to the native bridge limit', () => {
    const prefix = 'https://media.example.test/';
    expect(parseQueue([{ ...remote, url: prefix + 'a'.repeat(8192 - prefix.length) }])).toHaveLength(1);
    expect(parseQueue([{ ...remote, url: prefix + 'a'.repeat(8193 - prefix.length) }])).toEqual([]);
  });

  test('drops an unsafe entry while preserving independently valid entries', () => {
    expect(parseQueue([local, { id: 'bad', name: '坏', kind: 'url', url: 'ftp://bad' }, remote])).toEqual([
      local,
      remote,
    ]);
  });
});

describe('queue navigation and reorder', () => {
  test('handles queue end for repeat off, all, and one', () => {
    expect(nextQueueIndex(2, 3, 'off', false)).toBe(-1);
    expect(nextQueueIndex(2, 3, 'all', false)).toBe(0);
    expect(nextQueueIndex(2, 3, 'one', false)).toBe(2);
  });

  test('uses deterministic shuffle input and never selects the current item', () => {
    expect(nextQueueIndex(1, 4, 'all', true, 0)).toBe(2);
    expect(nextQueueIndex(1, 4, 'all', true, 0.999999)).toBe(0);
    expect(nextQueueIndex(0, 1, 'all', true, 0.5)).toBe(0);
  });

  test('returns a bounds sentinel for invalid queue state', () => {
    expect(nextQueueIndex(-1, 3, 'all', false)).toBe(-1);
    expect(nextQueueIndex(3, 3, 'all', false)).toBe(-1);
    expect(nextQueueIndex(0, 0, 'all', false)).toBe(-1);
  });

  test('reorders without mutating the source and preserves object identities', () => {
    const a: MediaItem = { id: 'a', name: 'A', kind: 'local' };
    const b: MediaItem = { id: 'b', name: 'B', kind: 'local' };
    const c: MediaItem = { id: 'c', name: 'C', kind: 'local' };
    const source = [a, b, c];

    const moved = moveQueueItem(source, 0, 2);

    expect(source).toEqual([a, b, c]);
    expect(moved).toEqual([b, c, a]);
    expect(moved[0]).toBe(b);
    expect(moved[2]).toBe(a);
    expect(moveQueueItem(source, -1, 2)).toEqual(source);
  });
});

describe('timecodes and subtitle text', () => {
  test('parses hours, minutes, seconds, and milliseconds while rejecting invalid fields', () => {
    expect(parseTimecode('01:02:03.500')).toBe(3723.5);
    expect(parseTimecode('02:03')).toBe(123);
    expect(parseTimecode('75.25')).toBe(75.25);
    expect(parseTimecode('1:60:00')).toBeNull();
    expect(parseTimecode('00:00:60')).toBeNull();
    expect(parseTimecode('-1')).toBeNull();
    expect(parseTimecode('not a time')).toBeNull();
  });

  test('formats stable hour timecodes and safely clamps invalid values', () => {
    expect(formatTimecode(3723.9)).toBe('01:02:03');
    expect(formatTimecode(62)).toBe('00:01:02');
    expect(formatTimecode(Number.NaN)).toBe('00:00:00');
    expect(formatTimecode(-1)).toBe('00:00:00');
  });

  test('converts UTF-8 multiline SRT with CRLF and a BOM into valid WebVTT', () => {
    const srt = '\uFEFF1\r\n00:00:01,250 --> 00:00:03,500\r\n你好，世界\r\n第二行\r\n\r\n2\r\n01:02:03,004 --> 01:02:04,120\r\nFin';

    expect(parseSRT(srt)).toBe(
      'WEBVTT\n\n00:00:01.250 --> 00:00:03.500\n你好，世界\n第二行\n\n01:02:03.004 --> 01:02:04.120\nFin\n',
    );
  });

  test.each([
    '',
    '1\ninvalid timestamp\ntext',
    '1\n00:00:05,000 --> 00:00:04,000\nbackwards',
    '1\n00:99:00,000 --> 00:99:01,000\ninvalid minute',
  ])('throws for malformed SRT instead of emitting invalid WebVTT: %j', (srt) => {
    expect(() => parseSRT(srt)).toThrow();
  });

  test('applies positive subtitle delay and uses inclusive-start/exclusive-end boundaries', () => {
    const cues = [
      { start: 10, end: 12, text: '第一句' },
      { start: 12, end: 14, text: '第二句' },
    ];

    expect(activeSubtitle(cues, 10.999, 1)).toBe('');
    expect(activeSubtitle(cues, 11, 1)).toBe('第一句');
    expect(activeSubtitle(cues, 13, 1)).toBe('第二句');
    expect(activeSubtitle(cues, 15, 1)).toBe('');
  });
});

describe('validateAB', () => {
  test('accepts an ordered positive span including a zero A point', () => {
    expect(validateAB(0, 1)).toBe(true);
    expect(validateAB(10.5, 12)).toBe(true);
  });

  test.each([
    [null, 1],
    [0, null],
    [2, 1],
    [1, 1],
    [-1, 1],
    [Number.NaN, 1],
    [1, Number.POSITIVE_INFINITY],
  ])('rejects missing, reversed, zero-span, negative, or non-finite points: %j', (a, b) => {
    expect(validateAB(a, b)).toBe(false);
  });
});
