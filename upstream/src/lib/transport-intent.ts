export function createTransportIntent<T extends number | boolean>(options: { read(): T; send(value: T): Promise<unknown>; onError(error: unknown): void; onIntent?(value: T | null): void }) {
  let target: T | null = null;
  let queued: { value: T; revision: number } | null = null;
  let revision = 0;
  let generation = 0;
  let busy = false;
  const drain = async () => {
    if (busy || !queued) return;
    const work = queued; queued = null; busy = true;
    const token = generation;
    try { await options.send(work.value); }
    catch (error) {
      if (token !== generation) return;
      if (work.revision === revision) { target = null; options.onIntent?.(null); }
      options.onError(error);
    }
    finally { if (token === generation) { busy = false; void drain(); } }
  };
  const set = (value: T) => {
    target = value; queued = { value, revision: ++revision };
    options.onIntent?.(value); void drain();
  };
  return {
    set,
    update(change: (value: T) => T) { set(change(target ?? options.read())); },
    project(value: T) {
      if (target === null) return value;
      if (!busy && !queued && value === target) { target = null; return value; }
      return target;
    },
    reset() { generation += 1; revision += 1; target = null; queued = null; busy = false; options.onIntent?.(null); },
  };
}
