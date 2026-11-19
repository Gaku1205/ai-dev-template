#!/usr/bin/env bash
# Vercel（Hobby）の30日の使用量を見て、上限に近づいたら、止まる前に知らせる。1日1回、watchdog か夜の点検から呼ぶ。
# 使い方：vercel-usage.sh
#   VERCEL_TOKEN     Vercel の鍵（環境変数だけで渡す。--token では渡さず、ログにも出さない）。無ければ警告して終わる
#   VERCEL_TEAM_ID   チーム（あれば CLI の --scope に渡す）
#   VERCEL_PLAN      pro なら何もしない（Hobby と上限が違うため）
#   VERCEL_REPO_MAP  プロジェクト名とリポジトリの対応。例：agent-desk=Gaku1205/agent-desk,foo=o/foo（無い・対応が無ければ GITHUB_REPOSITORY）
#   VERCEL_LOG_ISSUE 前の日の記録を、コメントで1日1回残す閉じた Issue の番号（既定 212）
# 知らせ方（項目ごと。上限は下の LIMITS の表）
#   50% を超えた    スマホに1回（notify.sh の usage。前の記録が50%未満のときだけ）
#   75% を超えた    いちばん使っているプロジェクトのリポジトリに Issue（priority:high。同じ題の開いた Issue があれば作らない）
#   90% を超えた    その Issue にコメントを足し、もう一度スマホに知らせる（前の記録が90%未満のときだけ）
#   1日で上限の15%以上増えた   50%未満でも、スマホに知らせる（急に増えたのは、何かが壊れている合図）
# 取れなかったとき（CLI のエラー・鍵が無い・形が変わった）は、::warning:: を1行出して 0 で終わる（見張りを止めない）
# CLI の出力は、JSON の配列（または data・usage・rows・items の中の配列）で、1行が「プロジェクト・項目名・量」と読む。
# 量の単位は表の単位（時間・GB・回・GB-Hrs）と読む。行に unit があれば bytes→GB、seconds・ms→時間に直す
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${GITHUB_REPOSITORY:-}"
LOG_ISSUE="${VERCEL_LOG_ISSUE:-212}"
TODAY="${VERCEL_TODAY:-$(date -u +%F)}"

warn() { echo "::warning::Vercel の使用量を確かめられませんでした：$1"; exit 0; }

# Hobby の上限（30日）。項目名は、CLI の項目名に（大文字小文字を無視して）含まれるかで合わせる
LIMITS='[
  {"name":"Fluid Active CPU","limit":4,"unit":"時間"},
  {"name":"Fast Origin Transfer","limit":10,"unit":"GB"},
  {"name":"Function Invocations","limit":1000000,"unit":"回"},
  {"name":"CDN Requests","limit":1000000,"unit":"回"},
  {"name":"Fluid Provisioned Memory","limit":360,"unit":"GB-Hrs"}
]'

if [ "${VERCEL_PLAN:-}" = "pro" ]; then
  echo "VERCEL_PLAN=pro なので、Vercel の使用量は見ません（Hobby と上限が違うため）"
  exit 0
fi
[ -n "${VERCEL_TOKEN:-}" ] || warn "VERCEL_TOKEN が設定されていません"

# 鍵が万一出力に混ざっても、伏せる
scrub() { local s="$1"; printf '%s' "${s//"$VERCEL_TOKEN"/***}"; }

# CLI（鍵は環境変数の VERCEL_TOKEN で渡る）。まず JSON で、だめなら形の指定なしで
scope=()
[ -z "${VERCEL_TEAM_ID:-}" ] || scope=(--scope "$VERCEL_TEAM_ID")
raw=""
for fmt in "--format json" ""; do
  # shellcheck disable=SC2086  # $fmt は、空か「--format json」（2語に分ける）
  if raw=$(timeout 120 npx --yes vercel@latest billing usage --since 30d --group-by project $fmt "${scope[@]}" 2> /dev/null); then
    cli_ok=1
    break
  fi
  cli_ok=0
done
[ "${cli_ok:-0}" = 1 ] || warn "Vercel の CLI が失敗しました（$(scrub "$(printf '%s' "$raw" | head -c 200)")）"

# 項目ごとに集計する（形が違えば失敗にする）
# shellcheck disable=SC2016  # jq の中の $ は jq の変数
items=$(printf '%s' "$raw" | jq -c --argjson table "$LIMITS" '
  def rows: if type == "array" then . else (.data // .usage // .rows // .items // []) end;
  def proj: (.project // .projectName // .project_name // .group // "(不明)") | if type == "object" then (.name // .id // "(不明)") else tostring end;
  def svc: (.service // .serviceName // .name // .metric // .sku // "") | tostring | ascii_downcase;
  def qty: (.quantity // .usage // .value // 0) | if type == "string" then (tonumber? // 0) else . end;
  def conv: ((.unit // "") | ascii_downcase) as $u | qty as $q
    | if $u == "bytes" or $u == "b" then $q / 1e9
      elif $u == "seconds" or $u == "s" or $u == "sec" then $q / 3600
      elif $u == "milliseconds" or $u == "ms" then $q / 3600000
      else $q end;
  [rows[] | select(type == "object") | {p: proj, s: svc, q: conv}] as $r
  | if ($r | length) == 0 then error("no rows") else . end
  | [$table[] | . as $t
      | ($r | map(select(.s | contains($t.name | ascii_downcase)))) as $m
      | {name: $t.name, unit: $t.unit, limit: $t.limit,
         used: ($m | map(.q) | add // 0),
         byp: ($m | group_by(.p) | map({p: .[0].p, q: (map(.q) | add)}) | sort_by(-.q))}
      | .pct = (.used / .limit * 100) | .top = (.byp[0].p // "")]
' 2> /dev/null) || warn "CLI の出力の形が読めません（行の配列ではありません）"

# 前の記録（記録用の Issue のコメントの1行目：<!-- vercel-usage {...} -->）
recs='[]'
if lines=$(gh api --paginate "repos/$REPO/issues/$LOG_ISSUE/comments?per_page=100" \
  --jq '.[].body | split("\n")[0] | select(startswith("<!-- vercel-usage {"))' 2> /dev/null); then
  parsed=$(printf '%s\n' "$lines" | sed -e '/^$/d' -e 's/^<!-- vercel-usage //' -e 's/ -->$//' | jq -cs 'map(select(type == "object"))' 2> /dev/null) && recs="$parsed"
else
  echo "::warning::記録用の Issue #${LOG_ISSUE} のコメントが読めないので、前の日との比べはしません"
fi
# shellcheck disable=SC2016
prev_all=$(jq -c 'last // {}' <<< "$recs")
# shellcheck disable=SC2016
prev_old=$(jq -c --arg d "$TODAY" 'map(select(.date != $d)) | last // {}' <<< "$recs")
# shellcheck disable=SC2016
today_done=$(jq -r --arg d "$TODAY" 'any(.[]; .date == $d)' <<< "$recs")

# 前の記録と比べて、段・増え方を付ける（今日の記録がもうあれば、増え方は見ない＝同じ日に何度動かしても、知らせが増えない）
# shellcheck disable=SC2016
items=$(jq -c --argjson pa "$prev_all" --argjson po "$prev_old" --arg tdone "$today_done" '
  map(.level = (if .pct > 90 then 90 elif .pct > 75 then 75 elif .pct > 50 then 50 else 0 end)
    | .plevel = ($pa.level[.name] // 0)
    | .growth = (if $tdone == "true" or ($po.pct[.name] == null) then 0 else (.pct - $po.pct[.name]) end))
' <<< "$items")

# 記録用の Issue の番号・リポジトリを決める
repo_for() { # プロジェクト名 → リポジトリ
  local pair
  while IFS= read -r pair; do
    [ "${pair%%=*}" = "$1" ] && [ -n "${pair#*=}" ] && { echo "${pair#*=}"; return; }
  done < <(printf '%s' "${VERCEL_REPO_MAP:-}" | tr ',' '\n' | tr -d ' ')
  echo "$REPO"
}

# 題が同じ開いた Issue の番号（無ければ空。検索が失敗したら return 1）
find_issue() { # リポジトリ 題
  local q res n t
  q=$(jq -rn --arg t "\"$2\" in:title repo:$1 type:issue is:open" '$t | @uri')
  res=$(gh api "search/issues?q=$q" -q '.items[] | "\(.number)\t\(.title)"' 2> /dev/null) || return 1
  while IFS=$'\t' read -r n t; do
    [ "$t" = "$2" ] && { echo "$n"; return 0; }
  done <<< "$res"
  return 0
}

notify() { bash "$SCRIPT_DIR/notify.sh" usage "$1" "$2" "$3" || true; }

while IFS= read -r item; do
  IFS=$'\t' read -r name unit limit used pct top level plevel growth < <(jq -r '[.name, .unit, .limit, (.used * 100 | round / 100), (.pct * 10 | round / 10), .top, .level, .plevel, (.growth * 10 | round / 10)] | @tsv' <<< "$item")
  echo "${name}：${used}${unit} / ${limit}${unit}（${pct}%）いちばん使っているプロジェクト：${top:-なし}"
  grown=$(jq -r '.growth >= 15' <<< "$item")
  summary="${name}：30日で ${used}${unit} / 上限 ${limit}${unit}（${pct}%）。いちばん使っているのは ${top:-不明}"

  issue=""
  if [ "$level" -ge 75 ]; then
    tr_repo=$(repo_for "$top")
    title="Vercel の使用量が上限の75%：${name}"
    if ! issue=$(find_issue "$tr_repo" "$title"); then
      echo "::warning::同じ題の Issue を探せなかったので、${tr_repo} に Issue は作りません（${name}）"
    elif [ -z "$issue" ]; then
      # shellcheck disable=SC2016  # jq の中の $ は jq の変数
      breakdown=$(jq -r --argjson used "$used" '.byp[] | "| \(.p) | \(.q * 100 | round / 100) | \(if $used > 0 then (.q / $used * 1000 | round / 10) else 0 end)% |"' <<< "$item")
      body=$(printf '%s\n' \
        "Vercel（Hobby）の30日の使用量が、上限の ${pct}% になりました。上限に達するとアカウントが止まります。" \
        "" \
        "- 項目：${name}" \
        "- 使った量：${used}${unit}（上限 ${limit}${unit}）" \
        "- 割合：${pct}%" \
        "- いちばん使っているプロジェクト：${top:-不明}" \
        "" \
        "### プロジェクトごとの内訳（30日）" \
        "" \
        "| プロジェクト | 使った量（${unit}） | 項目の中の割合 |" \
        "| --- | --- | --- |" \
        "$breakdown" \
        "" \
        "（毎日の見張り \`vercel-usage.sh\` が作りました。90%を超えると、この Issue にコメントします）")
      if issue=$(gh api "repos/$tr_repo/issues" -f title="$title" -f body="$body" -f "labels[]=priority:high" -q .number 2> /dev/null); then
        echo "Issue #${issue} を ${tr_repo} に作りました（${name}）"
      else
        issue=""
        echo "::warning::${tr_repo} に Issue を作れませんでした（${name}）"
      fi
    fi
  fi

  if [ "$level" -ge 90 ] && [ "$plevel" -lt 90 ]; then
    if [ -n "$issue" ]; then
      gh api "repos/$tr_repo/issues/$issue/comments" -f body="上限の90%を超えました（${pct}%）。${summary}。止まる前に、使い方を見直してください。" > /dev/null 2>&1 \
        || echo "::warning::Issue #${issue} にコメントできませんでした（${name}）"
    fi
    notify "Vercel の使用量が上限の90%を超えました" "$summary" 5
  elif [ "$grown" = true ]; then
    notify "Vercel の使用量が、1日で急に増えました" "${summary}。前の日より ${growth}%（上限に対して）増えています。何かが壊れているかもしれません" 4
  elif [ "$level" -ge 50 ] && [ "$plevel" -lt 50 ]; then
    notify "Vercel の使用量が上限の50%を超えました" "$summary" 3
  fi
done < <(jq -c '.[]' <<< "$items")

# 今日の記録を残す（1日1回。コメントの1行目が機械用の記録）
if [ "$today_done" != true ]; then
  # shellcheck disable=SC2016
  rec=$(jq -c --arg d "$TODAY" '{date: $d, pct: (map({(.name): (.pct * 10 | round / 10)}) | add), level: (map({(.name): .level}) | add)}' <<< "$items")
  # shellcheck disable=SC2016
  lines=$(jq -r '.[] | "- \(.name)：\(.pct * 10 | round / 10)%"' <<< "$items")
  gh api "repos/$REPO/issues/$LOG_ISSUE/comments" -f body="$(printf '<!-- vercel-usage %s -->\nVercel の使用量（%s・30日、上限に対する割合）\n%s' "$rec" "$TODAY" "$lines")" > /dev/null 2>&1 \
    || echo "::warning::今日の記録を Issue #${LOG_ISSUE} に残せませんでした（前の日との比べができなくなります）"
fi
exit 0
