#!/usr/bin/env bash
# 企画AIの質問に答えたあと（answer.yml）：ai:question を外して ai:plan を付け直す（企画AIが答えを読んで清書する）。
# ai:plan はパイプラインの鍵（GH_TOKEN）で付ける（ワークフローのトークンで付けると、企画AIのワークフローが動かないため）。
# 鍵が無ければ、ワークフローのトークンで付けて、人間に知らせる
# 環境変数：ISSUE、GH_TOKEN（パイプラインの鍵。無くてもよい）、GITHUB_TOKEN_FOR_LABELS（ワークフローのトークン）
source "$(dirname "$0")/pipeline-lib.sh"
pipeline_token="${GH_TOKEN:-}"
export GH_TOKEN="$GITHUB_TOKEN_FOR_LABELS"
remove_label "$ISSUE" "ai:question"
if [ -n "$pipeline_token" ]; then
  GH_TOKEN="$pipeline_token" add_label "$ISSUE" "ai:plan"
  echo "#$ISSUE：答えを受け取ったので、清書に戻しました"
else
  add_label "$ISSUE" "ai:plan"
  notify manual "答えを受け取りました" "#${ISSUE}：パイプラインの鍵が無いので、ai:plan を付け直してください" 3
fi
