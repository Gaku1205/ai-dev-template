#!/usr/bin/env bash
# スマホ通知（ntfy）。使い方：notify.sh "タイトル" "本文" [優先度 1〜5]
# 秘密の NTFY_TOPIC（ntfyアプリで購読するトピック名）が無ければ何もしない。
# 通知に失敗しても、ワークフロー自体は失敗にしない。
set -uo pipefail
if [ -z "${NTFY_TOPIC:-}" ]; then
  echo "NTFY_TOPIC が設定されていないので通知しません"
  exit 0
fi
if [ -n "${AGENT_DESK_URL:-}" ]; then
  click="${AGENT_DESK_URL}/repos/${GITHUB_REPOSITORY}"
else
  click="https://github.com/${GITHUB_REPOSITORY}"
fi
jq -n \
  --arg topic "$NTFY_TOPIC" \
  --arg title "$1" \
  --arg message "$2" \
  --arg click "$click" \
  --argjson priority "${3:-3}" \
  '{topic: $topic, title: $title, message: $message, click: $click, priority: $priority}' \
  | curl -fsS -X POST -H "Content-Type: application/json" --data-binary @- https://ntfy.sh > /dev/null \
  || echo "通知の送信に失敗しました（作業には影響しません）"
exit 0
