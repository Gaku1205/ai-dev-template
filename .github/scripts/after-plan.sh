#!/usr/bin/env bash
# 企画AI（ai:plan）のあと：清書の結果（plan-result.txt）を見て次へ進める。
#   READY [size:S|size:L] → サイズのラベルを付けてから ai:implement を付ける（実装AIが動く）
#   QUESTION              → ai:stuck を付けて人間に回す（質問はIssueのコメントにある）
#
# 環境変数：ISSUE、ISSUE_TITLE、PLAN_OUTCOME、GITHUB_TOKEN_FOR_LABELS（ワークフローのトークン）
source "$(dirname "$0")/pipeline-lib.sh"

result=$(head -n 1 plan-result.txt 2> /dev/null | tr -d '\r' || true)
if [ "$PLAN_OUTCOME" != "success" ] || [ -z "$result" ]; then
  result="QUESTION"
fi
echo "清書の結果：$result"

# ai:plan を外す（次に付け直せば、もう一度清書できる）
GH_TOKEN="$GITHUB_TOKEN_FOR_LABELS" gh issue edit "$ISSUE" -R "$REPO" --remove-label "ai:plan" > /dev/null || true
title=$(GH_TOKEN="$GITHUB_TOKEN_FOR_LABELS" gh issue view "$ISSUE" -R "$REPO" --json title -q .title)

case "$result" in
  READY*)
    size=$(printf '%s' "$result" | grep -oE 'size:(S|L)' || true)
    if [ -n "$size" ]; then
      GH_TOKEN="$GITHUB_TOKEN_FOR_LABELS" gh issue edit "$ISSUE" -R "$REPO" --add-label "$size" > /dev/null
    fi
    if has_pipeline_token; then
      # オーナーのトークンで付けるので、実装AIのワークフローが動く
      gh issue edit "$ISSUE" -R "$REPO" --add-label "ai:implement" > /dev/null
      echo "#$ISSUE：実装を依頼しました"
    else
      notify "Issueを清書しました" "#${ISSUE} ${title}：ai:implement を付けると実装が始まります" 3
    fi
    ;;
  *)
    GH_TOKEN="$GITHUB_TOKEN_FOR_LABELS" gh issue edit "$ISSUE" -R "$REPO" --add-label "ai:stuck" > /dev/null || true
    notify "質問があります" "#${ISSUE} ${title}：Issueのコメントを見て答えてください" 4
    ;;
esac
