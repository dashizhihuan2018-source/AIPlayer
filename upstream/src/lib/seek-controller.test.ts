import { afterEach, describe, expect, it, vi } from 'vitest';
import { createSeekController } from './seek-controller';

const tick = () => new Promise<void>((resolve) => queueMicrotask(resolve));
afterEach(() => vi.useRealTimers());

function fixture() {
  let time = 100;
  let duration = 600;
  const calls: number[] = [];
  const replies: Array<{ resolve(): void; reject(error: Error): void }> = [];
  const errors: string[] = [];
  const controller = createSeekController({
    readTime: () => time, readDuration: () => duration,
    send: (target) => { calls.push(target); return new Promise<void>((resolve, reject) => replies.push({ resolve, reject })); },
    onError: (error) => errors.push((error as Error).message),
  });
  return { controller, calls, replies, errors, setTime: (value: number) => { time = value; }, setDuration: (value: number) => { duration = value; } };
}

describe('serialized playback seek intent', () => {
  it('accumulates rapid forward presses before any native reply or state broadcast', async () => {
    const f = fixture();
    f.controller.relative(10); f.controller.relative(10); f.controller.relative(10);
    expect(f.calls).toEqual([110]);
    expect(f.controller.project(100)).toBe(130);
    f.replies[0].resolve(); await tick();
    expect(f.calls).toEqual([110, 130]);
  });

  it('retains the final drag position with only one native command in flight', async () => {
    const f = fixture();
    f.controller.absolute(200); f.controller.absolute(250); f.controller.absolute(240);
    expect(f.calls).toEqual([200]);
    expect(f.controller.project(101)).toBe(240);
    f.replies[0].resolve(); await tick();
    expect(f.calls).toEqual([200, 240]);
    f.replies[1].resolve(); await tick();
    expect(f.controller.project(200)).toBe(240);
    expect(f.controller.project(240.2)).toBe(240.2);
    expect(f.controller.project(241)).toBe(241);
  });

  it('combines drag and relative shortcuts using latest intent, including direction reversal', async () => {
    const f = fixture();
    f.controller.absolute(300); f.controller.relative(10); f.controller.relative(-20);
    expect(f.controller.project(100)).toBe(290);
    f.replies[0].resolve(); await tick();
    expect(f.calls).toEqual([300, 290]);
  });

  it('clamps targets, ignores non-finite input and allows unknown-duration streams', () => {
    const f = fixture();
    f.controller.absolute(NaN); expect(f.calls).toEqual([]);
    f.controller.relative(-500); expect(f.calls).toEqual([0]);
    f.controller.absolute(900); expect(f.controller.project(100)).toBe(600);
    f.setDuration(0); f.controller.absolute(900); expect(f.controller.project(100)).toBe(900);
    f.setDuration(700_000); f.controller.absolute(690_000); expect(f.controller.project(100)).toBe(604_800);
  });

  it('drops old-media queued commands and stale errors after reset', async () => {
    const f = fixture();
    f.controller.absolute(200); f.controller.absolute(250); f.controller.reset();
    f.setTime(5); f.controller.relative(10);
    expect(f.calls).toEqual([200, 15]);
    f.replies[0].reject(new Error('stale')); await tick();
    expect(f.errors).toEqual([]); expect(f.calls).toEqual([200, 15]);
  });

  it('reports a failed latest seek, releases optimism and remains usable', async () => {
    const f = fixture();
    f.controller.absolute(200); f.replies[0].reject(new Error('failed')); await tick();
    expect(f.errors).toEqual(['failed']); expect(f.controller.project(101)).toBe(101);
    f.controller.relative(10); expect(f.calls).toEqual([200, 110]);
  });

  it('accumulates another click after an immediate ack but before a new native time broadcast', async () => {
    const calls: number[] = [];
    const c = createSeekController({ readTime: () => 100, readDuration: () => 600, send: async (value) => { calls.push(value); }, onError() {} });
    c.relative(10); await tick(); expect(c.project(100)).toBe(110);
    c.relative(10); await tick(); expect(calls).toEqual([110, 120]); expect(c.project(101)).toBe(120);
    c.reset();
  });

  it('reports a seek that was accepted but never reached, instead of showing success forever', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
    const errors: unknown[] = [];
    const c = createSeekController({ readTime: () => 100, readDuration: () => 600, send: async () => {}, onError: (error) => errors.push(error), settleTimeoutMs: 100 });
    c.absolute(300); await tick(); expect(c.project(100)).toBe(300);
    vi.advanceTimersByTime(100);
    expect(errors).toHaveLength(1); expect(c.project(101)).toBe(101);
  });
});
