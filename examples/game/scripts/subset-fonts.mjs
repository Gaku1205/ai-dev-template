// 日本語の書体（M PLUS 1 の可変フォント）から、ゲームに出る文字だけを抜き出して public/fonts/ に置く。
// `npm run build`・`npm run dev` の前に自動で動く（package.json）。文言を変えても、文字が抜けないようにするため。
//   元：assets/fonts/MPLUS1-var.woff2（文字が全部入った物。assets/fonts/README.md）
//   先：public/fonts/mplus1.woff2（太さ 100〜900 を全部持つ）・OFL.txt・chars.txt（入れた文字の一覧）
// 抜き出す文字：src/ と index.html に出てくる ASCII 以外の文字と、ASCII・ひらがな・カタカナ・全角の英数字・よく使う記号。
// 大きすぎたら（既定 300KB）失敗させる。
import { copyFile, mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { dirname, extname, join } from "node:path";
import { fileURLToPath } from "node:url";
import subsetFont from "subset-font";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const SRC_DIR = join(root, "assets", "fonts");
const OUT_DIR = join(root, "public", "fonts");
const MAX_KB = Number(process.env.FONT_MAX_KB ?? 300);

async function walk(dir) {
  const out = [];
  for (const e of await readdir(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...(await walk(p)));
    else out.push(p);
  }
  return out;
}

/** いつも入れる文字：ASCII、記号・ひらがな・カタカナ（U+3000〜30FF）、全角の英数字と半角カナ（U+FF00〜FFEF）、よく使う記号 */
export function baseChars() {
  const s = new Set();
  for (let c = 0x20; c < 0x7f; c++) s.add(String.fromCodePoint(c));
  for (let c = 0x3000; c < 0x3100; c++) s.add(String.fromCodePoint(c));
  for (let c = 0xff00; c < 0xfff0; c++) s.add(String.fromCodePoint(c));
  for (const ch of "‐―—…※×÷°′″℃○●◎△▲▽▼□■◇◆★☆♪々〆") s.add(ch);
  return s;
}

/** 文章から、ASCII 以外の文字を集める（絵文字の合成に使う見えない文字は除く） */
export function collectChars(text, into = new Set()) {
  for (const ch of text) {
    const c = ch.codePointAt(0);
    if (c <= 0x7f || c === 0xfe0f || c === 0x200d) continue;
    into.add(ch);
  }
  return into;
}

async function main() {
  const chars = baseChars();
  const files = (await walk(join(root, "src"))).filter((f) => [".ts", ".tsx", ".js", ".json", ".css"].includes(extname(f)));
  files.push(join(root, "index.html"));
  for (const f of files) collectChars(await readFile(f, "utf8"), chars);
  const text = [...chars].sort().join("");
  await mkdir(OUT_DIR, { recursive: true });
  const out = await subsetFont(await readFile(join(SRC_DIR, "MPLUS1-var.woff2")), text, { targetFormat: "woff2" });
  await writeFile(join(OUT_DIR, "mplus1.woff2"), out);
  await copyFile(join(SRC_DIR, "OFL.txt"), join(OUT_DIR, "OFL.txt"));
  await writeFile(join(OUT_DIR, "chars.txt"), text, "utf8");
  console.log(`mplus1.woff2：文字 ${chars.size} 個・${Math.round(out.length / 1024)}KB（上限 ${MAX_KB}KB）`);
  if (out.length > MAX_KB * 1024) {
    console.error(`書体が上限（${MAX_KB}KB）を超えました。文字を減らすか、上限（FONT_MAX_KB）を見直してください`);
    process.exit(1);
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}
