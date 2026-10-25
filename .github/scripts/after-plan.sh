#!/usr/bin/env bash
# 企画AI（ai:plan）のあと：清書の結果（plan-result.txt）を見て次へ進める。
#   READY [size:S|size:L] → サイズのラベルを付けてから ai:implement を付ける（実装AIが動く）
#   QUESTION              → ai:stuck を付けて人間に回す（質問はIssueのコメントにある）
#
# 環境変数：ISSUE、PLAN_OUTCOME、GITHUB_TOKEN_FOR_LABELS（ワークフローのトークン）
source "$(dirname "$0")/pipeline-lib.sh"

result=$(head -n 1 plan-result.txt 2> /dev/null | tr -d '\r' || true)
if [ "$PLAN_OUTCOME" != "success" ] || [ -z "$result" ]; then
  result="QUESTION"
fi
echo "清書の結果：$result"

# ここまではワークフローのトークンで十分（次のワークフローを動かさなくてよい操作）
pipeline_token="${GH_TOKEN:-}"
export GH_TOKEN="$GITHUB_TOKEN_FOR_LABELS"
remove_label "$ISSUE" "ai:plan"
title=$(issue_title "$ISSUE")

case "$result" in
  READY*)
    size=$(printf '%s' "$result" | grep -oE 'size:(S|L)' || true)
    if [ -n "$size" ]; then
      add_label "$ISSUE" "$size"
    fi
    if [ -n "$pipeline_token" ]; then
      # オーナーのトークンで付けるので、実装AIのワークフローが動く
      GH_TOKEN="$pipeline_token" add_label "$ISSUE" "ai:implement"
      echo "#$ISSUE：実装を依頼しました"
    else
      notify "Issueを清書しました" "#${ISSUE} ${title}：ai:implement を付けると実装が始まります" 3
    fi
    ;;
  *)
    add_label "$ISSUE" "ai:stuck" || true
    notify "質問があります" "#${ISSUE} ${title}：Issueのコメントを見て答えてください" 4
    ;;
esac
