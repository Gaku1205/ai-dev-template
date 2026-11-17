#!/usr/bin/env bash
# 企画AI・実装AIが動く前に、Issue の本文に貼られた画像を取ってきて（fetch-issue-images.sh）、AIへの一言を作る。
# 使い方: issue-images-prompt.sh <置き場所> <plan|implement>
#   BODY（Issue の本文）・GH_TOKEN・GITHUB_REPOSITORY を読む。GITHUB_OUTPUT に prompt=（AIへの一言。画像が無ければ空）を書く。
#   置き場所はコミットしない（.git/info/exclude に足す）。取れなくても止めない（取れなかった枚数を一言に書く）。
#   一言には URL も本文も入れない（AIへの指示に、Issue の文字をそのまま混ぜない）。
set -uo pipefail
dir="${1:?置き場所}"
role="${2:?plan か implement}"
dir="${dir%/}"
out=$(OUT_DIR="$dir" bash "$(dirname "$0")/fetch-issue-images.sh" 2>&1)
printf '%s\n' "$out"
got=$(find "$dir" -maxdepth 1 -type f \( -name '*.png' -o -name '*.jpg' -o -name '*.webp' -o -name '*.gif' \) 2> /dev/null | wc -l | tr -d ' ')
failed=$(printf '%s\n' "$out" | grep -cE '^(取れませんでした|大きさが合いません|画像ではありません)：' || true)
if [ -d .git/info ]; then
  grep -qxF "/$dir/" .git/info/exclude 2> /dev/null || echo "/$dir/" >> .git/info/exclude
fi
note=""
if [ "$got" -gt 0 ]; then
  note="Issue の本文に貼られた画像（${got}枚）を ${dir}/ に置いた（01.png のように本文の順。${dir}/INDEX.md に元の場所）。Read で全部開いて、メモの意図（何を直したいか・どう見せたいか）を読むのに使う。${dir}/ はコミットしない。"
  if [ "$role" = plan ]; then
    note="${note}清書した本文にも、貼られた画像の行（![..](..)）を消さずに残す（実装AIもその画像を見るため）。"
  fi
fi
if [ "$failed" -gt 0 ]; then
  note="${note}Issue の本文の画像のうち ${failed}枚は取れなかった（中身は見られない。本文の文字から意図を読む）。"
fi
echo "prompt=$note" >> "${GITHUB_OUTPUT:-/dev/null}"
