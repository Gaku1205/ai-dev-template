export type BreathingPhase = "inhale" | "hold" | "exhale";

export const INHALE_SECONDS = 4;
export const HOLD_SECONDS = 4;
export const EXHALE_SECONDS = 6;
export const CYCLE_SECONDS = INHALE_SECONDS + HOLD_SECONDS + EXHALE_SECONDS;
export const TOTAL_SECONDS = 60;

export type BreathingState = {
  /** いまの段階。終了後は最後の段階（吐く）のまま */
  phase: BreathingPhase;
  /** その段階の残り秒（小数） */
  phaseRemaining: number;
  /** 全体の残り秒（小数） */
  totalRemaining: number;
  /** 光の大きさ（0〜1）。吸うで 0→1、止めるで 1、吐くで 1→0 */
  scale: number;
  /** 60秒以上たったか */
  finished: boolean;
};

export function breathingState(elapsedSeconds: number): BreathingState {
  const elapsed = Number.isFinite(elapsedSeconds) ? Math.max(0, elapsedSeconds) : 0;

  if (elapsed >= TOTAL_SECONDS) {
    return { phase: "exhale", phaseRemaining: 0, totalRemaining: 0, scale: 0, finished: true };
  }

  const t = elapsed % CYCLE_SECONDS;
  const totalRemaining = TOTAL_SECONDS - elapsed;

  if (t < INHALE_SECONDS) {
    return {
      phase: "inhale",
      phaseRemaining: INHALE_SECONDS - t,
      totalRemaining,
      scale: t / INHALE_SECONDS,
      finished: false,
    };
  }
  if (t < INHALE_SECONDS + HOLD_SECONDS) {
    return {
      phase: "hold",
      phaseRemaining: INHALE_SECONDS + HOLD_SECONDS - t,
      totalRemaining,
      scale: 1,
      finished: false,
    };
  }
  const inExhale = t - INHALE_SECONDS - HOLD_SECONDS;
  return {
    phase: "exhale",
    phaseRemaining: EXHALE_SECONDS - inExhale,
    totalRemaining,
    scale: 1 - inExhale / EXHALE_SECONDS,
    finished: false,
  };
}
