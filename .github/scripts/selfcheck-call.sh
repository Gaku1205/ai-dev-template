#!/usr/bin/env bash
# agent-desk の自己点検（POST /api/selfcheck）を呼ぶ。見張り役（watchdog.yml）の定期の起動と目覚ましの時に使う（workflow_run では呼ばない）。AI は使わない。
# 入力：AGENT_DESK_URL、GH_TOKEN（App の鍵。agent-desk が GitHub に照会して確かめる）、GITHUB_REPOSITORY
# どの場合も終了コードは 0（見張り役を止めない）。
#   URL か鍵が空 → 何もしない / 404 → 黙って飛ばす（入口が本番に入る前） / 2xx → 結果を1行出す
#   401・5xx・時間切れ・つながらない → ::warning:: を1行出す
# 鍵は curl の引数に出さず、標準入力のヘッダ（-H @-）で渡す。set -x は使わない。
# 「テンプレートの時だけ呼ぶ」は、ワークフロー側の run の中で、API（repos/<リポジトリ> の is_template）で確かめて絞る。
# CPU の予算（agent-desk#698）：答えの budget が warn・over なら、スマホに知らせる（notify.sh の usage）。
#   同じ日（日本時間）に同じ段では1回だけ。記録は閉じた Issue（SELFCHECK_LOG_ISSUE、既定 212）のコメントの1行目 <!-- selfcheck-budget {…} -->
#   記録が読めないときは、30分ごとに鳴らさないよう、知らせずに ::warning:: を出す
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_ISSUE="${SELFCHECK_LOG_ISSUE:-212}"

if [ -z "${AGENT_DESK_URL:-}" ] || [ -z "${GH_TOKEN:-}" ]; then
  echo "AGENT_DESK_URL か GH_TOKEN が空なので、自己点検は呼びません"
  exit 0
fi

url="${AGENT_DESK_URL%/}/api/selfcheck"
body="$(mktemp)"
trap 'rm -f "$body"' EXIT

# 段の強さ（warn=1・over=2。それ以外は 0）
rank_of() { case "$1" in warn) echo 1 ;; over) echo 2 ;; *) echo 0 ;; esac; }

# 答えの budget を見て、今日まだ知らせていない段なら知らせる。どこで失敗しても 0 で戻る
budget_alert() {
  local file="$1" budget rank today lines prev today_ms avg_ms pct title message prio
  budget="$(jq -r '.budget // empty' "$file" 2> /dev/null)"
  rank="$(rank_of "$budget")"
  [ "$rank" -gt 0 ] || return 0
  today="${SELFCHECK_TODAY:-$(TZ=Asia/Tokyo date +%F)}"
  # shellcheck disable=SC2016  # jq の中の $ は jq の変数
  if ! lines="$(gh api --paginate "repos/${GITHUB_REPOSITORY:-}/issues/${LOG_ISSUE}/comments?per_page=100" \
    --jq '.[] | select(.user.login | endswith("[bot]")) | .body | split("\n")[0] | select(startswith("<!-- selfcheck-budget {"))' 2> /dev/null)"; then
    echo "::warning::CPU の予算が ${budget} ですが、記録用の Issue #${LOG_ISSUE} が読めないので、知らせません（30分ごとに鳴らさないため）"
    return 0
  fi
  # shellcheck disable=SC2016
  prev="$(printf '%s\n' "$lines" | sed -e '/^$/d' -e 's/^<!-- selfcheck-budget //' -e 's/ -->$//' \
    | jq -rs --arg d "$today" '[.[] | select(type == "object" and .date == $d) | (if .budget == "over" then 2 elif .budget == "warn" then 1 else 0 end)] | max // 0' 2> /dev/null)"
  [ -n "$prev" ] || prev=0
  if [ "$prev" -ge "$rank" ]; then
    echo "CPU の予算は ${budget}（今日はもう知らせました）"
    return 0
  fi
  today_ms="$(jq -r '.usage.todayMs // empty' "$file" 2> /dev/null)"
  avg_ms="$(jq -r '.usage.avg7Ms // empty' "$file" 2> /dev/null)"
  pct="$(jq -r '(.usage.ratio // empty) * 100 | round' "$file" 2> /dev/null)"
  if [ "$budget" = over ]; then
    title="agent-desk の CPU 時間が1日の予算を超えました"
    prio=5
  else
    title="agent-desk の CPU 時間が1日の予算の50%を超えました"
    prio=4
  fi
  message="今日（日本時間）${today_ms:-?}ms・予算の ${pct:-?}%。7日平均 ${avg_ms:-?}ms。Vercel（Hobby）は止まるともう解除できないので、使い方を見直すか Pro にしてください"
  # 先に記録を残す（残せないと次の回にもう一度鳴るので、警告を出す）
  gh api "repos/${GITHUB_REPOSITORY:-}/issues/${LOG_ISSUE}/comments" \
    -f body="$(printf '<!-- selfcheck-budget {"date":"%s","budget":"%s"} -->\nagent-desk の CPU の予算：%s（%s・%sms・予算の %s%%）' "$today" "$budget" "$budget" "$today" "${today_ms:-?}" "${pct:-?}")" > /dev/null 2>&1 \
    || echo "::warning::CPU の予算の記録を Issue #${LOG_ISSUE} に残せませんでした（次の回にもう一度知らせるかもしれません）"
  bash "$SCRIPT_DIR/notify.sh" usage "$title" "$message" "$prio" || true
  echo "CPU の予算が ${budget} なので、スマホに知らせました"
  return 0
}

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
      budget_alert "$body"
      ;;
    *)
      echo "::warning::agent-desk の自己点検が HTTP ${code} を返しました（見張り役には影響しません）"
      ;;
  esac
fi
exit 0
