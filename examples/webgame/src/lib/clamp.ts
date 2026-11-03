/** 値を下限と上限の間に収める */
export function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}
