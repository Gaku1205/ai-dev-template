import { describe, expect, it } from "vitest";
import { clamp } from "./clamp";

describe("clamp", () => {
  it("範囲の中ならそのまま", () => expect(clamp(5, 0, 10)).toBe(5));
  it("下限より小さければ下限", () => expect(clamp(-3, 0, 10)).toBe(0));
  it("上限より大きければ上限", () => expect(clamp(42, 0, 10)).toBe(10));
});
