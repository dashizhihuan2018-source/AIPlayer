import type { MediaItem } from './native-player';

export type { MediaItem } from './native-player';

export interface SubtitleCue {
  start: number;
  end: number;
  text: string;
}

const MAX_QUEUE_ITEMS = 1_000;
const MAX_ID_LENGTH = 128;
const MAX_NAME_LENGTH = 512;
const OPAQUE_ID = /^[A-Za-z0-9][A-Za-z0-9_-]*$/;
const MEDIA_ITEM_KEYS = new Set(['id', 'name', 'kind', 'url']);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function validIdentity(value: Record<string, unknown>): boolean {
  return (
    typeof value.id === 'string' &&
    value.id.length <= MAX_ID_LENGTH &&
    OPAQUE_ID.test(value.id) &&
    typeof value.name === 'string' &&
    value.name.trim().length > 0 &&
    value.name.length <= MAX_NAME_LENGTH
  );
}

function validRemoteUrl(value: unknown): value is string {
  if (typeof value !== 'string' || value.length > 8192 || value !== value.trim()) return false;
  try {
    const parsed = new URL(value);
    return (
      (parsed.protocol === 'http:' || parsed.protocol === 'https:') &&
      parsed.username === '' &&
      parsed.password === ''
    );
  } catch {
    return false;
  }
}

function parseMediaItem(value: unknown): MediaItem | null {
  if (!isRecord(value) || !Object.keys(value).every((key) => MEDIA_ITEM_KEYS.has(key))) return null;
  if (!validIdentity(value)) return null;

  if (value.kind === 'local') {
    if (Object.prototype.hasOwnProperty.call(value, 'url')) return null;
    return { id: value.id as string, name: value.name as string, kind: 'local' };
  }
  if (value.kind === 'url' && validRemoteUrl(value.url)) {
    return {
      id: value.id as string,
      name: value.name as string,
      kind: 'url',
      url: value.url,
    };
  }
  return null;
}

export function parseQueue(value: unknown): MediaItem[] {
  if (!Array.isArray(value) || value.length > MAX_QUEUE_ITEMS) return [];
  return value.flatMap((item) => {
    const parsed = parseMediaItem(item);
    return parsed ? [parsed] : [];
  });
}

export function nextQueueIndex(
  index: number,
  length: number,
  mode: 'all' | 'one' | 'off',
  shuffle: boolean,
  random: number = Math.random(),
): number {
  if (!Number.isInteger(length) || length <= 0) return -1;
  if (!Number.isInteger(index) || index < 0 || index >= length) return -1;
  if (mode !== 'all' && mode !== 'one' && mode !== 'off') return -1;
  if (mode === 'one') return index;
  if (index === length - 1 && mode === 'off') return -1;

  if (shuffle) {
    if (length === 1) return 0;
    const sample = Number.isFinite(random) ? Math.min(Math.max(random, 0), 1 - Number.EPSILON) : 0;
    const offset = 1 + Math.floor(sample * (length - 1));
    return (index + offset) % length;
  }

  if (index + 1 < length) return index + 1;
  return mode === 'all' ? 0 : -1;
}

export function moveQueueItem(items: MediaItem[], from: number, to: number): MediaItem[] {
  const moved = items.slice();
  if (
    !Number.isInteger(from) ||
    !Number.isInteger(to) ||
    from < 0 ||
    to < 0 ||
    from >= moved.length ||
    to >= moved.length ||
    from === to
  ) {
    return moved;
  }
  const [item] = moved.splice(from, 1);
  moved.splice(to, 0, item);
  return moved;
}

export function parseTimecode(text: string): number | null {
  const value = text.trim();
  if (/^\d+(?:\.\d{1,3})?$/.test(value)) {
    const seconds = Number(value);
    return Number.isFinite(seconds) ? seconds : null;
  }

  const segments = value.split(':');
  let hours = 0;
  let minutesText: string;
  let secondsText: string;
  if (segments.length === 2) {
    [minutesText, secondsText] = segments;
  } else if (segments.length === 3) {
    const [hoursText, minutes, seconds] = segments;
    if (!/^\d+$/.test(hoursText)) return null;
    hours = Number(hoursText);
    minutesText = minutes;
    secondsText = seconds;
  } else {
    return null;
  }

  if (!/^\d{2}$/.test(minutesText) || !/^\d{2}(?:\.\d{1,3})?$/.test(secondsText)) {
    return null;
  }
  const minutes = Number(minutesText);
  const seconds = Number(secondsText);
  if (minutes >= 60 || seconds >= 60) return null;
  const result = hours * 3600 + minutes * 60 + seconds;
  return Number.isFinite(result) ? result : null;
}

export function formatTimecode(seconds: number): string {
  const whole = Number.isFinite(seconds) && seconds > 0 ? Math.floor(seconds) : 0;
  const hours = Math.floor(whole / 3600);
  const minutes = Math.floor((whole % 3600) / 60);
  const remainder = whole % 60;
  return [hours, minutes, remainder].map((part) => String(part).padStart(2, '0')).join(':');
}

type ParsedSrtTimestamp = {
  seconds: number;
  vtt: string;
};

function parseSrtTimestamp(value: string): ParsedSrtTimestamp | null {
  const match = value.match(/^(\d{2,}):([0-5]\d):([0-5]\d)[,.](\d{3})$/);
  if (!match) return null;
  const [, hours, minutes, seconds, milliseconds] = match;
  const total = Number(hours) * 3600 + Number(minutes) * 60 + Number(seconds) + Number(milliseconds) / 1000;
  if (!Number.isFinite(total)) return null;
  return { seconds: total, vtt: `${hours}:${minutes}:${seconds}.${milliseconds}` };
}

export function parseSRT(text: string): string {
  const normalized = text.replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n').trim();
  if (!normalized) throw new Error('Subtitle file is empty');

  const cues = normalized.split(/\n[\t ]*\n/).map((block, blockIndex) => {
    const lines = block.split('\n');
    if (/^\d+$/.test(lines[0]?.trim() ?? '')) lines.shift();
    const timing = lines.shift()?.trim() ?? '';
    const timingMatch = timing.match(/^(\S+)\s+-->\s+(\S+)$/);
    if (!timingMatch) throw new Error(`Invalid SRT timing in cue ${blockIndex + 1}`);
    const start = parseSrtTimestamp(timingMatch[1]);
    const end = parseSrtTimestamp(timingMatch[2]);
    if (!start || !end || end.seconds <= start.seconds) {
      throw new Error(`Invalid SRT range in cue ${blockIndex + 1}`);
    }
    if (lines.length === 0) throw new Error(`Missing SRT text in cue ${blockIndex + 1}`);
    return `${start.vtt} --> ${end.vtt}\n${lines.join('\n')}`;
  });

  return `WEBVTT\n\n${cues.join('\n\n')}\n`;
}

export function activeSubtitle(cues: SubtitleCue[], time: number, delay: number): string {
  if (!Number.isFinite(time)) return '';
  const adjustedTime = time - (Number.isFinite(delay) ? delay : 0);
  return cues
    .filter(
      (cue) =>
        Number.isFinite(cue.start) &&
        Number.isFinite(cue.end) &&
        cue.end > cue.start &&
        adjustedTime >= cue.start &&
        adjustedTime < cue.end &&
        typeof cue.text === 'string',
    )
    .map((cue) => cue.text)
    .join('\n');
}

export function validateAB(a: number | null, b: number | null): boolean {
  return a !== null && b !== null && Number.isFinite(a) && Number.isFinite(b) && a >= 0 && b > a;
}
