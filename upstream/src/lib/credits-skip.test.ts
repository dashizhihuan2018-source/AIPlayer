import { describe, expect, it } from 'vitest';
import { ENDING_SKIP_WINDOW_SECONDS, MIN_DURATION_FOR_ENDING_SKIP, MIN_DURATION_FOR_OPENING_SKIP, OPENING_SKIP_SECONDS, endingSkipTarget, openingSkipTarget } from './credits-skip';

describe('openingSkipTarget', () => {
  it('skips a fresh long episode to 02:00', () => {
    expect(openingSkipTarget(0, 2700)).toBe(OPENING_SKIP_SECONDS);
    expect(openingSkipTarget(30, 2700)).toBe(OPENING_SKIP_SECONDS);
    expect(openingSkipTarget(119, 2700)).toBe(OPENING_SKIP_SECONDS);
  });
  it('never pulls a viewer who already moved past the opening backward/forward', () => {
    expect(openingSkipTarget(120, 2700)).toBeNull();
    expect(openingSkipTarget(500, 2700)).toBeNull();
  });
  it('ignores short media (movies/shorts have no reliable opening)', () => {
    expect(openingSkipTarget(0, MIN_DURATION_FOR_OPENING_SKIP - 1)).toBeNull();
    expect(openingSkipTarget(0, 40)).toBeNull();
  });
  it('rejects unknown duration or time', () => {
    expect(openingSkipTarget(0, 0)).toBeNull();
    expect(openingSkipTarget(NaN, 2700)).toBeNull();
    expect(openingSkipTarget(0, NaN)).toBeNull();
  });
});

describe('endingSkipTarget', () => {
  it('jumps to the tail inside the 90s window of a long episode', () => {
    expect(endingSkipTarget(2700 - 90, 2700)).toBe(2700 - 0.5);
    expect(endingSkipTarget(2700 - 10, 2700)).toBe(2700 - 0.5);
  });
  it('stays quiet before the window', () => {
    expect(endingSkipTarget(2700 - ENDING_SKIP_WINDOW_SECONDS - 1, 2700)).toBeNull();
  });
  it('does nothing when already at the very end', () => {
    expect(endingSkipTarget(2700 - 0.5, 2700)).toBeNull();
    expect(endingSkipTarget(2700, 2700)).toBeNull();
  });
  it('ignores short media and unknown durations', () => {
    expect(endingSkipTarget(10, MIN_DURATION_FOR_ENDING_SKIP - 1)).toBeNull();
    expect(endingSkipTarget(0, 0)).toBeNull();
    expect(endingSkipTarget(NaN, 2700)).toBeNull();
  });
});
