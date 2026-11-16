#!/usr/bin/env bash
# 「使ってみる役」「監査役」のAIが書いた見つけた問題（JSON）を、Issue にする。
#   found-report.sh try|audit 結果のファイル
# 結果のファイル：{"findings":[{"title":"…","body":"…"}]}（AIが書く。無い・壊れている・空なら何もしない）
# - 1回に最大 FOUND_MAX（既定 3）件
# - 同じ題名の Issue が開いていれば作らない（ai:found のもの。空白の違いは無視）
# - ラベル ai:found と ai:plan を付ける（企画AIが清書して、いつもの流れに乗る）
# 環境変数：GITHUB_REPOSITORY、GH_TOKEN、RUN_URL（ログの場所。本文に書く）、GITHUB_STEP_SUMMARY
# docs/pipeline.md「使ってみる役・監査役」
set -uo pipefail
kind="${1:-}" file="${2:-}"
REPO="${GITHUB_REPOSITORY:?}"
max="${FOUND_MAX:-3}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
case "$kind" in
  try) who="使ってみる役（公開後に、AIが本番のサイトを利用者として試した）" ;;
  audit) who="監査役（AIが仕様書どうし・仕様書とコードの食い違いを探した）" ;;
  *) echo "使い方：found-report.sh try|audit 結果のファイル" >&2; exit 2 ;;
esac

norm() { tr -d ' 　\t\n' <<< "$1"; }

if [ ! -s "$file" ] || ! jq -e '.findings | type == "array"' "$file" > /dev/null 2>&1; then
  echo "見つけた問題はありません（結果のファイルが無いか、形が違う）" | tee -a "$summary"
  exit 0
fi

existing=$(gh api "repos/$REPO/issues?state=open&labels=ai%3Afound&per_page=100" --jq '.[].title' 2> /dev/null || true)
made=0 skipped=0
n=$(jq '.findings | length' "$file")
for ((i = 0; i < n && made < max; i++)); do
  title=$(jq -r ".findings[$i].title // empty | tostring | split(\"\n\")[0] | .[0:60]" "$file")
  body=$(jq -r ".findings[$i].body // empty" "$file")
  [ -z "$title" ] || [ -z "$body" ] && continue
  dup=0
  while IFS= read -r t; do
    [ -n "$t" ] && [ "$(norm "$t")" = "$(norm "$title")" ] && dup=1
  done <<< "$existing"
  if [ "$dup" = 1 ]; then
    skipped=$((skipped + 1))
    echo "- 同じ題名の Issue が開いているので作りません：$title" >> "$summary"
    continue
  fi
  full="$body

---
見つけた役：$who${RUN_URL:+（ログと画面の画像：$RUN_URL）}
<!-- ai-found: $kind -->"
  if num=$(jq -n --arg t "$title" --arg b "$full" '{title:$t, body:$b, labels:["ai:found","ai:plan"]}' |
    gh api "repos/$REPO/issues" --input - --jq '.number' 2> /dev/null); then
    made=$((made + 1))
    existing="$existing
$title"
    echo "- Issue #$num を作りました：$title" | tee -a "$summary"
  fi
done
echo "作った Issue：${made}件（重複で見送り：${skipped}件）" | tee -a "$summary"
exit 0
