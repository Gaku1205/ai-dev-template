import { describe, expect, it } from "vitest";
import { baseChars, collectChars } from "./subset-fonts.mjs";

describe("書体に入れる文字を集める", () => {
  it("いつも入れる文字：ASCII・ひらがな・カタカナ・全角の英数字", () => {
    const base = baseChars();
    for (const ch of ["A", "z", "0", " ", "あ", "ん", "ア", "ー", "。", "「", "Ａ", "９", "！"]) {
      expect(base.has(ch)).toBe(true);
    }
  });
  it("文章から、ASCII 以外の文字を集める（漢字も）", () => {
    const got = collectChars("Score: 得点は 3 倍！");
    expect([...got].sort()).toEqual(["は", "倍", "得", "点", "！"].sort());
  });
  it("ASCII と、絵文字の合成に使う見えない文字は集めない", () => {
    const got = collectChars("abc 123 ️‍");
    expect(got.size).toBe(0);
  });
  it("渡した入れ物に足していく", () => {
    const into = new Set(["既"]);
    collectChars("新", into);
    expect([...into].sort()).toEqual(["既", "新"].sort());
  });
});
