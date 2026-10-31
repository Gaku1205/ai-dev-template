import { describe, expect, it } from "vitest";
import { breathingState } from "./breathing";

describe("breathingState", () => {
  it("0秒は吸い始めで、光は小さい", () => {
    const s = breathingState(0);
    expect(s.phase).toBe("inhale");
    expect(s.scale).toBe(0);
    expect(s.phaseRemaining).toBe(4);
    expect(s.finished).toBe(false);
  });

  it("吸うあいだ光が広がる", () => {
    expect(breathingState(2).scale).toBeCloseTo(0.5);
    expect(breathingState(2).phaseRemaining).toBe(2);
  });

  it("4秒ちょうどで止めるに変わり、光は最大", () => {
    const s = breathingState(4);
    expect(s.phase).toBe("hold");
    expect(s.scale).toBe(1);
    expect(s.phaseRemaining).toBe(4);
  });

  it("止めるあいだ光は保たれる", () => {
    expect(breathingState(7.9).scale).toBe(1);
    expect(breathingState(7.9).phase).toBe("hold");
  });

  it("8秒ちょうどで吐くに変わり、縮み始める", () => {
    const s = breathingState(8);
    expect(s.phase).toBe("exhale");
    expect(s.scale).toBe(1);
    expect(s.phaseRemaining).toBe(6);
    expect(breathingState(11).scale).toBeCloseTo(0.5);
  });

  it("14秒ちょうどで次の周期の吸うに戻る", () => {
    const s = breathingState(14);
    expect(s.phase).toBe("inhale");
    expect(s.scale).toBe(0);
    expect(breathingState(13.99).phase).toBe("exhale");
  });

  it("全体の残り秒を返す", () => {
    expect(breathingState(10).totalRemaining).toBe(50);
  });

  it("59.99秒はまだ終わっていない", () => {
    expect(breathingState(59.99).finished).toBe(false);
  });

  it("60秒ちょうどで終わる", () => {
    const s = breathingState(60);
    expect(s.finished).toBe(true);
    expect(s.totalRemaining).toBe(0);
    expect(s.scale).toBe(0);
  });

  it("60秒を超えても終わったまま", () => {
    const s = breathingState(500);
    expect(s.finished).toBe(true);
    expect(s.totalRemaining).toBe(0);
  });

  it("負の値や不正な値は0秒として扱う", () => {
    expect(breathingState(-5).phase).toBe("inhale");
    expect(breathingState(-5).scale).toBe(0);
    expect(breathingState(Number.NaN).scale).toBe(0);
  });
});
