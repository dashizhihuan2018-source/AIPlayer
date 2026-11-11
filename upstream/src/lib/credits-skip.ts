/**
 * 自动跳过片头片尾（剧集）：基于时间的保守启发式，不做内容识别。
 * - 片头：一集从头开播（位置仍停留在片头区）时定位到 02:00；
 * - 片尾：播放进入最后 90 秒时定位到结尾（触发自然结束 → 自动连播切下一集）。
 * 短于阈值的媒体（多为短片/单集电影）一律不触发，避免跳过正片。
 */
export const OPENING_SKIP_SECONDS = 120;
export const ENDING_SKIP_WINDOW_SECONDS = 90;
export const MIN_DURATION_FOR_OPENING_SKIP = 150;
export const MIN_DURATION_FOR_ENDING_SKIP = 300;

/** 新集停留在片头区（时长足够、进度未过 02:00）时，定位到 02:00。否则返回 null。 */
export function openingSkipTarget(time: number, duration: number): number | null {
  if (!Number.isFinite(time) || !Number.isFinite(duration) || duration <= 0) return null;
  if (duration < MIN_DURATION_FOR_OPENING_SKIP) return null;
  if (time >= OPENING_SKIP_SECONDS) return null;
  return OPENING_SKIP_SECONDS;
}

/** 进入片尾 90 秒窗口（且未已贴底）时，定位到结尾前一帧。否则返回 null。 */
export function endingSkipTarget(time: number, duration: number): number | null {
  if (!Number.isFinite(time) || !Number.isFinite(duration) || duration <= 0) return null;
  if (duration < MIN_DURATION_FOR_ENDING_SKIP) return null;
  if (time >= duration - 0.5) return null;
  if (duration - time > ENDING_SKIP_WINDOW_SECONDS) return null;
  return duration - 0.5;
}
