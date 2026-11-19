#!/usr/bin/env bash
# 企画AIの質問に答えたあと（answer.yml）：ai:question を外して ai:plan を付け直す（企画AIが答えを読んで清書する）。
# ai:plan はパイプラインの鍵（GH_TOKEN）で付ける（ワークフローのトークンで付けると、企画AIのワークフローが動かないため）。
# 鍵が無ければ、ワークフローのトークンで付けて、人間に知らせる
# 環境変数：ISSUE、GH_TOKEN（パイプラインの鍵。無くてもよい）、GITHUB_TOKEN_FOR_LABELS（ワークフローのトークン）
source "$(dirname "$0")/pipeline-lib.sh"
pipeline_token="${GH_TOKEN:-}"
export GH_TOKEN="$GITHUB_TOKEN_FOR_LABELS"
remove_label "$ISSUE" "ai:question"
# 答えを書いたあとに、オーナーが Issue を閉じていることがある（コメントの時点では open なので、ワークフローの条件では弾けない）。
# 閉じた Issue に ai:plan を付けると、閉じたまま清書に戻ってラベルが矛盾する（agent-desk #555）。読めなかったときは今まで通り
state=$(gh api "repos/$REPO/issues/$ISSUE" -q .state 2> /dev/null) || state=""
if [ "$state" = closed ]; then
  echo "#$ISSUE：閉じているので、清書には戻しません（ai:question を外すだけ）"
  exit 0
fi
if [ -n "$pipeline_token" ]; then
  GH_TOKEN="$pipeline_token" add_label "$ISSUE" "ai:plan"
  echo "#$ISSUE：答えを受け取ったので、清書に戻しました"
else
  add_label "$ISSUE" "ai:plan"
  notify manual "答えを受け取りました" "#${ISSUE}：パイプラインの鍵が無いので、ai:plan を付け直してください" 3
fi
