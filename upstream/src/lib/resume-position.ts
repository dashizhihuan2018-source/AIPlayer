/** Call only once metadata is ready; a manifest alone has no reliable duration. */
export async function restorePosition(
  media: { duration: number; currentTime: number },
  readSaved: () => number | Promise<number>,
  isCurrent: () => boolean
): Promise<number> {
  const saved = await readSaved();
  const duration = media.duration;
  if (!isCurrent() || !Number.isFinite(duration) || duration <= 0 ||
      !Number.isFinite(saved) || saved <= 10 || saved >= duration - 2) return 0;
  media.currentTime = saved;
  return saved;
}
