import type { Expense } from "./settle";

export type SplitData = {
  people: string[];
  expenses: Expense[];
};

export const STORAGE_KEY = "split-data";

export const EMPTY_DATA: SplitData = { people: [], expenses: [] };

/** localStorage の文字列を読み取る。壊れていたら空のデータを返す。 */
export function parseSplitData(raw: string | null): SplitData {
  if (!raw) return EMPTY_DATA;
  try {
    const value: unknown = JSON.parse(raw);
    if (typeof value !== "object" || value === null) return EMPTY_DATA;
    const { people, expenses } = value as Record<string, unknown>;
    if (!Array.isArray(people) || !Array.isArray(expenses)) return EMPTY_DATA;
    const names = people.filter((p): p is string => typeof p === "string");
    const list = expenses.filter(
      (x): x is Expense =>
        typeof x === "object" &&
        x !== null &&
        typeof (x as Expense).id === "string" &&
        typeof (x as Expense).payer === "string" &&
        typeof (x as Expense).amount === "number" &&
        typeof (x as Expense).memo === "string" &&
        Array.isArray((x as Expense).participants),
    );
    return { people: names, expenses: list };
  } catch {
    return EMPTY_DATA;
  }
}

/** 金額を「1,200円」の形にする */
export function formatYen(amount: number): string {
  return `${amount.toLocaleString("ja-JP")}円`;
}
