#!/usr/bin/env bash
# 工場の design ジョブ：デザイン担当（AI）が作った画面で、確認コマンドを AI とは別にもう一度動かす。
#   出力（GITHUB_OUTPUT）：site=true|false（src/ を作り変えたか）、ok=true|false（作り変えていて、全部通ったか）
#   失敗したときは、出力の最後（20KB）を factory-checks.log に書く（直す AI が読む）
# 環境変数（テスト用）：NPM（既定 npm）
set -uo pipefail
NPM="${NPM:-npm}"
OUT="${GITHUB_OUTPUT:-/dev/null}"
rm -f factory-checks.log

if [ -z "$(git status --porcelain -- src 2> /dev/null)" ]; then
  echo "src/ が雛形のままです（デザイン担当が画面を作れませんでした）"
  { echo "site=false"; echo "ok=false"; } >> "$OUT"
  exit 0
fi
log=$(mktemp)
trap 'rm -f "$log"' EXIT
code=0
for c in typecheck lint test build; do
  echo "== npm run $c" >> "$log"
  if ! "$NPM" run "$c" >> "$log" 2>&1; then
    echo "npm run $c が通りませんでした"
    code=1
    break
  fi
done
if [ "$code" -eq 0 ]; then
  echo "確認コマンドが全部通りました"
  { echo "site=true"; echo "ok=true"; } >> "$OUT"
else
  tail -c 20000 "$log" > factory-checks.log
  tail -n 40 factory-checks.log
  { echo "site=true"; echo "ok=false"; } >> "$OUT"
fi
exit 0
