# 日本語の書体の元（M PLUS 1）

- `MPLUS1-var.woff2`：M PLUS 1 の可変フォント（太さ 100〜900 を1つで持つ。文字は全部入っている。約1.6MB）。ゲームには、このまま入れない
- `OFL.txt`：ライセンス（SIL Open Font License 1.1）。Copyright 2021 The M+ FONTS Project Authors（https://github.com/coz-m/MPLUS_FONTS）
- 元のファイル：https://github.com/google/fonts/tree/main/ofl/mplus1

ゲームに入れるのは、`npm run fonts`（`scripts/subset-fonts.mjs`）が作る `public/fonts/mplus1.woff2`。
`src/` と `index.html` に出てくる文字と、かな・記号・英数字だけを抜き出した物で（太さは全部残る）、`npm run build` と `npm run dev` の前に自動で作り直す
（文言を変えても、文字が抜けない。人間やAIが書体を作り直す必要は無い）。`public/fonts/` は作られる物なので、git には入れない。
M PLUS 1 に無い文字（矢印 ← → など）は、予備の書体で出る。
