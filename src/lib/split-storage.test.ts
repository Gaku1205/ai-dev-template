import { describe, expect, it } from "vitest";
import { EMPTY_DATA, formatYen, parseSplitData } from "./split-storage";

describe("parseSplitData", () => {
  it("空や壊れた文字列は空のデータ", () => {
    expect(parseSplitData(null)).toEqual(EMPTY_DATA);
    expect(parseSplitData("{")).toEqual(EMPTY_DATA);
    expect(parseSplitData('{"people":1}')).toEqual(EMPTY_DATA);
  });

  it("保存した形を読み戻せる", () => {
    const data = {
      people: ["A", "B"],
      expenses: [
        { id: "1", payer: "A", amount: 1200, participants: ["A", "B"], memo: "昼食" },
      ],
    };
    expect(parseSplitData(JSON.stringify(data))).toEqual(data);
  });
});

describe("formatYen", () => {
  it("3桁区切りで「円」を付ける", () => {
    expect(formatYen(1200)).toBe("1,200円");
    expect(formatYen(0)).toBe("0円");
  });
});
