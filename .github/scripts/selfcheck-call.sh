#!/usr/bin/env bash
# agent-desk の自己点検（POST /api/selfcheck）を呼ぶ。見張り役（watchdog.yml）の定期の起動と目覚ましの時に使う（workflow_run では呼ばない）。AI は使わない。
# 入力：AGENT_DESK_URL、GH_TOKEN（App の鍵。agent-desk が GitHub に照会して確かめる）、GITHUB_REPOSITORY
# どの場合も終了コードは 0（見張り役を止めない）。
#   URL か鍵が空 → 何もしない / 404 → 黙って飛ばす（入口が本番に入る前） / 2xx → 結果を1行出す
#   401・5xx・時間切れ・つながらない → ::warning:: を1行出す
# 鍵は curl の引数に出さず、標準入力のヘッダ（-H @-）で渡す。set -x は使わない。
# 「テンプレートの時だけ呼ぶ」は、ワークフロー側の run の中で、API（repos/<リポジトリ> の is_template）で確かめて絞る。
set -uo pipefail

if [ -z "${AGENT_DESK_URL:-}" ] || [ -z "${GH_TOKEN:-}" ]; then
  echo "AGENT_DESK_URL か GH_TOKEN が空なので、自己点検は呼びません"
  exit 0
fi

url="${AGENT_DESK_URL%/}/api/selfcheck"
body="$(mktemp)"
trap 'rm -f "$body"' EXIT

code="$(printf 'Authorization: Bearer %s\n' "$GH_TOKEN" \
  | curl -sS --max-time 30 -X POST -H @- -o "$body" -w '%{http_code}' "$url" 2> /dev/null)"
rc=$?

if [ "$rc" -eq 28 ]; then
  echo "::warning::agent-desk の自己点検が30秒で時間切れになりました（見張り役には影響しません）"
elif [ "$rc" -ne 0 ]; then
  echo "::warning::agent-desk の自己点検につながりませんでした（curl の終了コード ${rc}。見張り役には影響しません）"
else
  case "$code" in
    404) ;;
    2??)
      summary="$(head -c 300 "$body" | tr '\r\n' '  ')"
      echo "agent-desk の自己点検：HTTP ${code} ${summary}"
      ;;
    *)
      echo "::warning::agent-desk の自己点検が HTTP ${code} を返しました（見張り役には影響しません）"
      ;;
  esac
fi
exit 0
