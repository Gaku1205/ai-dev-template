#!/usr/bin/env bash
# レビューAIが終わったあと：
#   指摘なし → CIも全部通っていれば自動でマージ（ai:hold が付いていたら、マージは人間に任せて通知）
#   指摘あり → AIに直させる（上限を超えたら人間に回す）
#
# 環境変数：CONCLUSION、HEAD_SHA、HEAD_BRANCH、READ_TOKEN（ワークフローのトークン）
source "$(dirname "$0")/pipeline-lib.sh"
set -e

has_pipeline_token || { echo "PIPELINE_TOKEN が無いので何もしません"; exit 0; }

read -r pr head < <(find_open_pr "$HEAD_BRANCH") || true
if [ -z "${pr:-}" ]; then
  echo "openのPRがありません"
  exit 0
fi
if [ "$head" != "$HEAD_SHA" ]; then
  echo "レビューのあとに新しいコミットが来ているので、何もしません"
  exit 0
fi
if has_label "$pr" "ai:stuck"; then
  echo "人間の確認待ち（ai:stuck）なので、何もしません"
  exit 0
fi

if [ "$CONCLUSION" != "success" ]; then
  stop_for_human "$pr" "レビューAIがエラーで止まりました"
  exit 0
fi

# いまの先頭コミットのあとに書かれた、最新のレビュー結果（「## Code review」で始まる）を探す。
# 同じコミットをもう一度レビューすると、レビューAIは新しいコメントを書かないことがあるので、
# 「この実行で書かれた物」ではなく「先頭コミットより新しい物」を見る
head_date=$(gh api "repos/$REPO/commits/$HEAD_SHA" -q .commit.committer.date)
review=$(all_comments "$pr" | jq -r --arg since "$head_date" \
  'map(select(.user.login == "claude[bot]" and (.body | startswith("## Code review")) and .created_at >= $since)) | last | .body // ""')

# 指摘があるとき、レビューAIはまとめのコメントを書かず、コードの行への指摘（インラインコメント）だけを残すことがある
inline=$(gh api "repos/$REPO/pulls/$pr/comments?per_page=100" --paginate --slurp \
  | jq --arg sha "$HEAD_SHA" 'add // [] | map(select(.user.login == "claude[bot]" and .original_commit_id == $sha)) | length')

if [ "$inline" -gt 0 ] || { [ -n "$review" ] && ! printf '%s' "$review" | grep -q "No issues found"; }; then
  request_fix_or_stop "$pr" "$HEAD_SHA" "レビューで指摘がありました。このPRの「Code review」のコメントと、コードの行に付いた指摘を読んで直してください。指摘が間違っていると判断した場合は、直さずにその理由をこのPRにコメントしてください。"
  echo "PR #$pr：指摘があったので直すよう依頼しました（行への指摘 ${inline} 件）"
  exit 0
fi

if [ -z "$review" ]; then
  stop_for_human "$pr" "レビューAIの結果のコメントが見つかりませんでした"
  exit 0
fi

# CI（レビュー以外のチェック）が全部通っているか、もう一度確かめる
# チェックの読み取りはワークフロー自身のトークン（checks: read）で行う（PIPELINE_TOKEN に Checks の権限は付けていない）
checks=$(GH_TOKEN="$READ_TOKEN" gh api "repos/$REPO/commits/$HEAD_SHA/check-runs?per_page=100" \
  -q '[.check_runs[] | select(.name != "review")]')
actions_count=$(printf '%s' "$checks" | jq '[.[] | select(.app.slug == "github-actions")] | length')
not_ok=$(printf '%s' "$checks" | jq '[.[] | select(.status != "completed" or (.conclusion | IN("success", "neutral", "skipped") | not))] | length')
if [ "$actions_count" -eq 0 ] || [ "$not_ok" -gt 0 ]; then
  echo "CIがまだ全部通っていないので、マージしません（CIが終わればもう一度レビューから進みます）"
  exit 0
fi

title=$(issue_title "$pr")
if has_label "$pr" "ai:hold"; then
  notify "マージできます" "PR #${pr} ${title}：CIもレビューもOK。ai:hold なのでマージはあなたが押してください" 4
  exit 0
fi

gh api -X PUT "repos/$REPO/pulls/$pr/merge" -f merge_method=merge -f sha="$HEAD_SHA" > /dev/null
echo "PR #$pr：自動でマージしました（次の順番待ちは、Issueが閉じたときに queue.yml が始める）"
