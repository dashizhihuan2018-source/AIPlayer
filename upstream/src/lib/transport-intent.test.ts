import { describe, expect, it } from 'vitest';
import { createTransportIntent } from './transport-intent';

const tick = () => new Promise<void>((resolve) => queueMicrotask(resolve));

describe('pause/mute/volume input intent', () => {
  it('alternates rapid toggles before React renders or native state arrives', async () => {
    const sent: boolean[] = []; const replies: Array<() => void> = [];
    const lane = createTransportIntent({ read: () => true, send: (value: boolean) => { sent.push(value); return new Promise<void>((resolve) => replies.push(resolve)); }, onError() {} });
    lane.update((value) => !value); lane.update((value) => !value);
    expect(sent).toEqual([false]); expect(lane.project(true)).toBe(true);
    replies[0](); await tick(); expect(sent).toEqual([false, true]);
  });

  it('accumulates volume steps using latest intent and retains the final slider value', async () => {
    const sent: number[] = []; const replies: Array<() => void> = [];
    const lane = createTransportIntent({ read: () => 50, send: (value: number) => { sent.push(value); return new Promise<void>((resolve) => replies.push(resolve)); }, onError() {} });
    lane.update((value) => value + 5); lane.update((value) => value + 5); lane.set(35);
    expect(sent).toEqual([55]); expect(lane.project(50)).toBe(35);
    replies[0](); await tick(); expect(sent).toEqual([55, 35]);
    replies[1](); await tick(); expect(lane.project(50)).toBe(35); expect(lane.project(35)).toBe(35); expect(lane.project(36)).toBe(36);
  });

  it('does not block future actions after a rejected command', async () => {
    const errors: unknown[] = []; let sends = 0;
    const lane = createTransportIntent({ read: () => false, send: async (_value: boolean) => { sends += 1; throw Error('failed'); }, onError: (error) => errors.push(error) });
    lane.set(true); await tick(); expect(lane.project(false)).toBe(false); expect(errors).toHaveLength(1);
    lane.set(true); await tick(); expect(sends).toBe(2);
  });
});
