#!/usr/bin/env bash
# 新しいIssueを、人間がラベルを付けなくても自動で企画AI（ai:plan）に回す。intake.yml から呼ぶ。
# ai: で始まるラベルが1つでも付いていれば何もしない（自分で ai:queue などを付けた物、ai:skip で止めている物）。
#
# 環境変数：NUMBER
source "$(dirname "$0")/pipeline-lib.sh"
has_pipeline_token || { echo "PIPELINE_TOKEN が無いので何もしません"; exit 0; }

# 作った直後にラベルを付ける人・スクリプトがいるので、少し待ってから見る
sleep "${INTAKE_WAIT_SEC:-15}"
if needs_intake "$NUMBER"; then
  # オーナーのトークンで付けるので、企画AIのワークフローが動く
  add_label "$NUMBER" "ai:plan"
  echo "#$NUMBER：ラベルが無かったので、企画に回しました"
else
  echo "#$NUMBER：すでにパイプラインのラベルがあるので何もしません"
fi
