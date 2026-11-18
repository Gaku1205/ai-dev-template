#!/usr/bin/env bash
# 順番待ち（ai:queue）を1つ進める。queue.yml から呼ぶ
source "$(dirname "$0")/pipeline-lib.sh"
has_pipeline_token || { echo "PIPELINE_TOKEN が無いので何もしません"; exit 0; }
# 人間がマージした『人間にお願いしたいこと』のPR：マージされた後に、Issue を待ちの状態（ai:skip）にする
if [ "${GITHUB_EVENT_NAME:-}" = pull_request_target ] && [ -f "${GITHUB_EVENT_PATH:-}" ]; then
  merged_pr=$(jq -r 'select(.action == "closed" and .pull_request.merged == true) | .pull_request.number' "$GITHUB_EVENT_PATH" 2> /dev/null || true)
  [ -z "$merged_pr" ] || park_issue_after_human_request_merge "$merged_pr" || true
fi
start_next_in_queue || { echo "::error::順番待ちを進められませんでした（トークンの権限を確認してください）"; exit 1; }
