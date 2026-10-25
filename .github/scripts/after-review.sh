#!/usr/bin/env bash
# レビューAIが終わったあと：
#   指摘なし → CIも全部通っていれば自動でマージ（ai:hold が付いていたら、マージは人間に任せて通知）
#   指摘あり → AIに直させる（上限を超えたら人間に回す）
#
# 環境変数：CONCLUSION、HEAD_SHA、HEAD_BRANCH、RUN_STARTED（レビューが始まった時刻）
source "$(dirname "$0")/pipeline-lib.sh"

has_pipeline_token || { echo "PIPELINE_TOKEN が無いので何もしません"; exit 0; }

read -r pr head < <(find_open_pr "$HEAD_BRANCH")
if [ -z "${pr:-}" ]; then
  echo "openのPRがありません"
  exit 0
fi
if [ "$head" != "$HEAD_SHA" ]; then
  echo "レビューのあとに新しいコミットが来ているので、何もしません"
  exit 0
fi
if pr_has_label "$pr" "ai:stuck"; then
  echo "人間の確認待ち（ai:stuck）なので、何もしません"
  exit 0
fi

if [ "$CONCLUSION" != "success" ]; then
  stop_for_human "$pr" "レビューAIがエラーで止まりました"
  exit 0
fi

# このレビューで書かれた結果のコメント（「## Code review」で始まる）を探す
review=$(gh api "repos/$REPO/issues/$pr/comments" --paginate --slurp \
  | jq -r --arg since "$RUN_STARTED" \
    'add | map(select(.user.login == "claude[bot]" and (.body | startswith("## Code review")) and .created_at >= $since)) | last | .body // ""')

if [ -z "$review" ]; then
  stop_for_human "$pr" "レビューAIの結果のコメントが見つかりませんでした"
  exit 0
fi

if ! printf '%s' "$review" | grep -q "No issues found"; then
  request_fix_or_stop "$pr" "$HEAD_SHA" "レビューで指摘がありました。上の「Code review」のコメントを読んで直してください。指摘が間違っていると判断した場合は、直さずにその理由をこのPRにコメントしてください。"
  echo "PR #$pr：指摘があったので直すよう依頼しました"
  exit 0
fi

# CI（レビュー以外のチェック）が全部通っているか、もう一度確かめる
checks=$(gh api "repos/$REPO/commits/$HEAD_SHA/check-runs?per_page=100" \
  -q '[.check_runs[] | select(.name != "review")]')
actions_count=$(printf '%s' "$checks" | jq '[.[] | select(.app.slug == "github-actions")] | length')
not_ok=$(printf '%s' "$checks" | jq '[.[] | select(.status != "completed" or (.conclusion | IN("success", "neutral", "skipped") | not))] | length')
if [ "$actions_count" -eq 0 ] || [ "$not_ok" -gt 0 ]; then
  echo "CIがまだ全部通っていないので、マージしません（CIが終わればもう一度レビューから進みます）"
  exit 0
fi

title=$(gh pr view "$pr" -R "$REPO" --json title -q .title)
if pr_has_label "$pr" "ai:hold"; then
  notify "マージできます" "PR #${pr} ${title}：CIもレビューもOK。ai:hold なのでマージはあなたが押してください" 4
  exit 0
fi

gh pr merge "$pr" -R "$REPO" --merge --match-head-commit "$HEAD_SHA"
echo "PR #$pr：自動でマージしました"

# 次の順番待ちは、Issueが閉じたときに queue.yml が始める
