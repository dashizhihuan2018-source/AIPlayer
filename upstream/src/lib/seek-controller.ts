export interface SeekControllerOptions {
  readTime(): number;
  readDuration(): number;
  send(target: number): Promise<unknown>;
  onError(error: unknown): void;
  onIntent?(target: number | null): void;
  settleTimeoutMs?: number;
}

/** One seek in flight, plus the newest unsent intent. Relative actions accumulate
 * immediately; intermediate slider positions may collapse, the final one cannot. */
export function createSeekController(options: SeekControllerOptions) {
  let generation = 0;
  let revision = 0;
  let inFlight = false;
  let target: number | null = null;
  let queued: { target: number; revision: number } | null = null;
  let settleTimer: ReturnType<typeof setTimeout> | undefined;
  const drain = async () => {
    if (inFlight || !queued) return;
    const work = queued;
    queued = null;
    inFlight = true;
    const token = generation;
    try {
      await options.send(work.target);
      if (token === generation && work.revision === revision && !queued) {
        clearTimeout(settleTimer);
        settleTimer = setTimeout(() => {
          if (token !== generation || work.revision !== revision || target === null) return;
          target = null; options.onIntent?.(null);
          options.onError(new Error('媒体定位超时，请重试'));
        }, options.settleTimeoutMs ?? 15_000);
      }
    }
    catch (error) {
      if (token !== generation) return;
      if (work.revision === revision) { target = null; options.onIntent?.(null); }
      options.onError(error);
    }
    finally {
      if (token === generation) { inFlight = false; void drain(); }
    }
  };
  const absolute = (value: number) => {
    if (!Number.isFinite(value)) return;
    clearTimeout(settleTimer);
    const duration = options.readDuration();
    target = Math.max(0, Math.min(value, 604_800, Number.isFinite(duration) && duration > 0 ? duration : 604_800));
    queued = { target, revision: ++revision };
    options.onIntent?.(target);
    void drain();
  };
  return {
    absolute,
    relative(delta: number) { if (Number.isFinite(delta)) absolute((target ?? options.readTime()) + delta); },
    pending() { return target !== null; },
    project(time: number) {
      if (target === null) return time;
      if (!inFlight && !queued && Math.abs(time - target) <= 1.5) { clearTimeout(settleTimer); target = null; options.onIntent?.(null); return time; }
      return target;
    },
    reset() { clearTimeout(settleTimer); generation += 1; revision += 1; inFlight = false; queued = null; target = null; options.onIntent?.(null); },
  };
}
