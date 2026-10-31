import { describe, expect, it } from "vitest";
import { balances, settle, type Expense } from "./settle";

const e = (
  payer: string,
  amount: number,
  participants: string[],
  id = "x",
): Expense => ({ id, payer, amount, participants, memo: "" });

/** 送金をすべて実行したあとの全員の収支 */
function afterTransfers(expenses: Expense[]): number[] {
  const b = balances(expenses);
  for (const t of settle(expenses)) {
    b.set(t.from, (b.get(t.from) ?? 0) + t.amount);
    b.set(t.to, (b.get(t.to) ?? 0) - t.amount);
  }
  return Array.from(b.values());
}

describe("settle", () => {
  it("記録が空なら送金なし", () => {
    expect(settle([])).toEqual([]);
  });

  it("2人：割り勘の半分を返す", () => {
    expect(settle([e("A", 1200, ["A", "B"])])).toEqual([
      { from: "B", to: "A", amount: 600 },
    ]);
  });

  it("3人以上：送金回数を少なくまとめ、全員の収支が0になる", () => {
    const expenses = [
      e("A", 3000, ["A", "B", "C"], "1"),
      e("B", 900, ["A", "B", "C"], "2"),
    ];
    // 合計3900円を3人で割ると1人1300円
    const b = balances(expenses);
    expect(b.get("A")).toBe(3000 - 1300);
    expect(b.get("B")).toBe(900 - 1300);
    expect(b.get("C")).toBe(-1300);
    expect(settle(expenses)).toEqual([
      { from: "C", to: "A", amount: 1300 },
      { from: "B", to: "A", amount: 400 },
    ]);
    expect(afterTransfers(expenses).every((v) => v === 0)).toBe(true);
  });

  it("割り切れない金額：端数は先頭の人から1円ずつ、合計はずれない", () => {
    const expenses = [e("A", 100, ["A", "B", "C"])];
    const b = balances(expenses);
    expect(b.get("A")).toBe(100 - 34);
    expect(b.get("B")).toBe(-33);
    expect(b.get("C")).toBe(-33);
    expect(afterTransfers(expenses).every((v) => v === 0)).toBe(true);
  });

  it("全員貸し借りなしなら送金なし", () => {
    const expenses = [
      e("A", 1000, ["A", "B"], "1"),
      e("B", 1000, ["A", "B"], "2"),
    ];
    expect(settle(expenses)).toEqual([]);
  });

  it("対象が自分だけなら送金なし", () => {
    expect(settle([e("A", 500, ["A"])])).toEqual([]);
  });
});
