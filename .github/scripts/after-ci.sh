#!/usr/bin/env bash
# CIが終わったあと（PRのとき）：
#   通った → レビューAIを動かす（ai:review を付け直す）
#   落ちた → AIに直させる（上限を超えたら人間に回す）
#
# 環境変数：CONCLUSION、HEAD_SHA、HEAD_BRANCH
source "$(dirname "$0")/pipeline-lib.sh"

has_pipeline_token || { echo "PIPELINE_TOKEN が無いので何もしません"; exit 0; }

read -r pr head < <(find_open_pr "$HEAD_BRANCH")
if [ -z "${pr:-}" ]; then
  echo "openのPRがありません"
  exit 0
fi
if [ "$head" != "$HEAD_SHA" ]; then
  echo "このCIのあとに新しいコミットが来ているので、何もしません"
  exit 0
fi
if pr_has_label "$pr" "ai:stuck"; then
  echo "人間の確認待ち（ai:stuck）なので、何もしません"
  exit 0
fi

case "$CONCLUSION" in
  success)
    # 付け直すと labeled イベントが起きて、レビューAIが動く
    gh pr edit "$pr" -R "$REPO" --remove-label "ai:review" > /dev/null 2>&1 || true
    gh pr edit "$pr" -R "$REPO" --add-label "ai:review" > /dev/null
    echo "PR #$pr：CIが通ったのでレビューを依頼しました"
    ;;
  failure)
    request_fix_or_stop "$pr" "$HEAD_SHA" "CIが失敗しました。失敗したチェックのログを確認して、原因を直してください。"
    echo "PR #$pr：CIが落ちたので直すよう依頼しました"
    ;;
esac
