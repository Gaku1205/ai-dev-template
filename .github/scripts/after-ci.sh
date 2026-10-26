#!/usr/bin/env bash
# CIが終わったあと（PRのとき）：
#   通った → main が先に進んでいれば取り込む（CIがもう一度走る）。最新なら、レビューAIを動かす（ai:review を付け直す）
#   落ちた → AIに直させる（上限を超えたら人間に回す）
#
# 環境変数：CONCLUSION、HEAD_SHA、HEAD_BRANCH
source "$(dirname "$0")/pipeline-lib.sh"
set -e

has_pipeline_token || { echo "PIPELINE_TOKEN が無いので何もしません"; exit 0; }

read -r pr head < <(find_open_pr "$HEAD_BRANCH") || true
if [ -z "${pr:-}" ]; then
  echo "openのPRがありません"
  exit 0
fi
if [ "$head" != "$HEAD_SHA" ]; then
  echo "このCIのあとに新しいコミットが来ているので、何もしません"
  exit 0
fi
if has_label "$pr" "ai:stuck"; then
  echo "人間の確認待ち（ai:stuck）なので、何もしません"
  exit 0
fi

case "$CONCLUSION" in
  success)
    # main が先に進んでいたら、先にPRのブランチへ取り込む（取り込むとCIがもう一度走り、通ったらここに戻ってくる）。
    # レビューAIのワークフローは、PRのブランチの版が main と同じでないと動かないので、これが要る
    behind=$(gh api "repos/$REPO/compare/$HEAD_SHA...main" -q .ahead_by)
    if [ "${behind:-0}" -gt 0 ]; then
      if gh api -X PUT "repos/$REPO/pulls/$pr/update-branch" -f expected_head_sha="$HEAD_SHA" > /dev/null 2>&1; then
        echo "PR #$pr：main の変更（${behind} コミット）を取り込みました。CIが終わったらレビューに進みます"
      else
        stop_for_human "$pr" "main の変更を取り込めませんでした（コンフリクトの可能性があります）"
      fi
      exit 0
    fi
    # 付け直すと labeled イベントが起きて、レビューAIが動く
    remove_label "$pr" "ai:review"
    add_label "$pr" "ai:review"
    echo "PR #$pr：CIが通ったのでレビューを依頼しました"
    ;;
  failure)
    notify ci_failed "CIが失敗しました" "PR #${pr} $(issue_title "$pr")：AIに直してもらいます" 3
    request_fix_or_stop "$pr" "$HEAD_SHA" "CIが失敗しました。失敗したチェックのログを確認して、原因を直してください。"
    echo "PR #$pr：CIが落ちたので直すよう依頼しました"
    ;;
esac
