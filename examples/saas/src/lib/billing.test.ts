import { describe, expect, it } from "vitest";
import { isPaidStatus, isPro, planLabel, safeNext, stripeTime } from "./billing";

const now = new Date("2026-11-04T00:00:00Z");

describe("isPro", () => {
  it("契約が無ければ無料", () => {
    expect(isPro(null, now)).toBe(false);
  });
  it("active と trialing は有料", () => {
    expect(isPro({ status: "active", current_period_end: null }, now)).toBe(true);
    expect(isPro({ status: "trialing", current_period_end: null }, now)).toBe(true);
  });
  it("支払いが遅れていても、期間内なら有料のまま", () => {
    expect(isPro({ status: "past_due", current_period_end: "2026-11-10T00:00:00Z" }, now)).toBe(true);
    expect(isPro({ status: "past_due", current_period_end: "2026-11-01T00:00:00Z" }, now)).toBe(false);
  });
  it("解約済み・未完了は無料", () => {
    for (const status of ["canceled", "incomplete", "incomplete_expired", "unpaid", "paused"]) {
      expect(isPro({ status, current_period_end: "2027-01-01T00:00:00Z" }, now)).toBe(false);
    }
    expect(isPaidStatus(undefined)).toBe(false);
  });
});

describe("safeNext", () => {
  it("サイトの中のパスだけ通す", () => {
    expect(safeNext("/notes")).toBe("/notes");
    expect(safeNext("https://evil.example")).toBe("/account");
    expect(safeNext("//evil.example")).toBe("/account");
    expect(safeNext("/\\evil.example")).toBe("/account");
    expect(safeNext(null)).toBe("/account");
  });
});

describe("stripeTime と planLabel", () => {
  it("秒を ISO にする", () => {
    expect(stripeTime(1_700_000_000)).toBe("2023-11-14T22:13:20.000Z");
    expect(stripeTime(undefined)).toBeNull();
  });
  it("状態を日本語にする", () => {
    expect(planLabel(null, now)).toBe("無料プラン");
    expect(planLabel({ status: "active", current_period_end: "2026-12-04T00:00:00Z" }, now)).toContain("有料プラン（次の更新");
    expect(planLabel({ status: "active", current_period_end: "2026-12-04T00:00:00Z", cancel_at_period_end: true }, now)).toContain("で終わります");
  });
});
