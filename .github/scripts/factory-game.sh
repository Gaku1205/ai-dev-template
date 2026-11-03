#!/usr/bin/env bash
# 工場：テンプレートから作ったリポジトリを、ゲームの雛形に切り替える。使い方：factory-game.sh <リポジトリのフォルダ> [exe|web]
# ゲームはブラウザの技術（TypeScript・Canvas／WebGL・Vite）で作る。
#   exe（既定。examples/game）：Electron で Windows の exe（1ファイル）にして GitHub Releases に置く
#   web（examples/webgame）：Vercel で公開して、ブラウザ（スマホも）で遊ぶ
# 工場の design ジョブ（デザイン担当が作る前）と build ジョブ（factory.sh）の両方から呼ぶ。
set -euo pipefail
cd "${1:?フォルダを指定}"
mode="${2:-exe}"
case "$mode" in exe) ex=examples/game ;; web) ex=examples/webgame ;; *) echo "種類「$mode」は exe か web"; exit 1 ;; esac
[ -d "$ex" ] || { echo "$ex がありません"; exit 1; }

# 1. Next.js の物を消す（Web のゲームは Vercel で公開するので vercel.json は残す）
rm -rf src package.json package-lock.json next.config.ts tsconfig.json eslint.config.mjs vitest.config.ts next-env.d.ts public
[ "$mode" = exe ] && rm -f vercel.json
# 2. 雛形をルートへ（.gitignore は足す。node_modules・dist は持ち込まない）
for f in src electron scripts index.html vite.config.ts tsconfig.json package.json package-lock.json pipeline.json; do
  if [ -e "$ex/$f" ]; then cp -r "$ex/$f" .; fi
done
cat "$ex/.gitignore" >> .gitignore
rm -rf examples
# 3. AGENTS.md はゲーム向けの注意にする
if [ "$mode" = web ]; then
  cat > AGENTS.md <<'MD'
# このリポジトリの注意（Web のゲーム）

- ゲームの本体は `src/`（`src/main.ts` が入口）。`index.html` は canvas を1枚置くだけ。Vercel が `npm run build` の `dist/` を公開する
- スマホ（縦の画面・タッチ）と PC（キーボード・マウス）の両方で遊べるようにする。画面の大きさが変わっても崩れない
- 画面を撮る：`npm run build` のあと `node .github/scripts/shot.mjs --serve --widths 390,1440 /`。遊んでいる途中の場面は、`/?scene=play` のように URL で直接開けるようにしておくと撮れる（`--steps` でキーを押してもよい）
- 音は Web Audio API で作る（外の音のファイルを読み込まない）。ブラウザは最初に触るまで音を出せないので、最初のタップ・キーで鳴らし始める
MD
else
  cat > AGENTS.md <<'MD'
# このリポジトリの注意（ゲーム）

- ゲームの本体は `src/`（`src/main.ts` が入口）。`index.html` は canvas を1枚置くだけ。`vite.config.ts` の `base: "./"` は exe（file://）で開くために要るので変えない
- exe は `electron/main.cjs` が `dist/index.html` を開く。`npm run dist` が Windows の exe（`release/*.exe`）を作る（GitHub の Windows のランナーで動く）
- 画面を撮る：`npm run build` のあと `node .github/scripts/shot.mjs --serve /`。遊んでいる途中の場面は、`/?scene=play` のように URL で直接開けるようにしておくと撮れる（`--steps` でキーを押してもよい）
- 音は Web Audio API で作る（外の音のファイルを読み込まない）
MD
fi
# 4. CLAUDE.md・仕様書をゲーム向けに
MODE="$mode" python3 - <<'PY'
import os, re
web = os.environ["MODE"] == "web"
s = open("CLAUDE.md", encoding="utf-8").read()
what = "Vercel で公開して、スマホでも PC でもブラウザで遊ぶ Web のゲーム。" if web else "Electron で Windows の exe にして配るゲーム。"
s = s.replace("Next.js（App Router）＋TypeScript。", "ブラウザの技術（TypeScript・Canvas／WebGL・Vite）で作り、" + what, 1)
s = re.sub(r"（Next\.js 以外で作るなら[^\n]*?）", "", s, count=1)
s = "\n".join(l for l in s.split("\n") if not l.startswith("- Next.js固有の注意は AGENTS.md を読む"))
code = """## コードの書き方

- TypeScriptの型をちゃんと付ける。`any` は使わない
- ゲームの本体は `src/`、入力から出力が決まるロジック（当たり判定・得点・敵の出し方など）は `src/lib/` に置いて `*.test.ts` でテストを書く
- 注意は AGENTS.md（""" + ("公開のしかた" if web else "exe の作り方") + """・画面の撮り方）
- 画面の文言は日本語
"""
s = re.sub(r"## コードの書き方\n.*?(?=\n## )", code, s, count=1, flags=re.S)
open("CLAUDE.md", "w", encoding="utf-8").write(s)
s = open("docs/spec.md", encoding="utf-8").read()
how = "Vercel で公開する（スマホ・PC のブラウザで遊ぶ）" if web else "Electron で Windows の exe にして GitHub Releases で配る"
s = s.replace("- 技術：Next.js（App Router）＋TypeScript、テストはVitest", "- 技術：TypeScript・Vite（Canvas／WebGL）、テストはVitest。" + how, 1)
open("docs/spec.md", "w", encoding="utf-8").write(s)
PY
[ "$mode" = web ] && echo "Web のゲーム（TypeScript・Vite、Vercel で公開）に切り替えた" || echo "ゲーム（TypeScript・Vite・Electron の exe）に切り替えた"
