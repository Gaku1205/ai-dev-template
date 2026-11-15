#!/usr/bin/env bash
# 進捗ログ：各工程の「使ったモデル・所要時間・結果」を、Issue の「進捗ログ」コメント（1つだけ）に残す。
# 工程の開始前（--result running）と終了後（--result success / failure）に呼ぶ。形式は docs/pipeline.md の「進捗ログ」。
#
# 使い方：
#   step-log.sh (--issue N | --pr N) --step STEP --model MODEL --result RESULT [--attempt N --max-attempts N] [--started 時刻]
#     STEP   ：plan / mocks / implement / ci / review / fix / deploy
#     MODEL  ：実行時に --model へ渡した値そのまま（opus・sonnet など）。モデルを使わない工程（ci・deploy）は空か null
#     RESULT ：running / success / failure
#     --pr   ：Issue 番号が分からないとき。PR 本文の Closes #番号 から Issue を引く
#
# 記録に失敗しても、終了コードは 0（警告を1行出すだけ）。パイプラインを止めない。

STEP_LOG_MARK="<!-- pipeline-step-log -->"
STEP_ORDER='["plan","mocks","implement","ci","review","fix","deploy"]'

warn() { echo "::warning::進捗ログを残せませんでした：$*"; }

issue="" pr="" step="" model="" result="" attempt="" max_attempts="" started=""
while [ $# -gt 0 ]; do
  case "$1" in
    --issue) issue="${2:-}"; shift 2 ;;
    --pr) pr="${2:-}"; shift 2 ;;
    --step) step="${2:-}"; shift 2 ;;
    --model) model="${2:-}"; shift 2 ;;
    --result) result="${2:-}"; shift 2 ;;
    --attempt) attempt="${2:-}"; shift 2 ;;
    --max-attempts) max_attempts="${2:-}"; shift 2 ;;
    --started) started="${2:-}"; shift 2 ;;
    *) warn "知らない引数です：$1"; exit 0 ;;
  esac
done

case "$step" in plan | mocks | implement | ci | review | fix | deploy) ;; *) warn "step が正しくありません：${step}"; exit 0 ;; esac
case "$result" in running | success | failure) ;; *) warn "result が正しくありません：${result}"; exit 0 ;; esac
case "$attempt$max_attempts" in *[!0-9]*) warn "attempt は数字で指定してください"; exit 0 ;; esac
[ -n "${GITHUB_REPOSITORY:-}" ] || { warn "GITHUB_REPOSITORY がありません"; exit 0; }

# shellcheck source=pipeline-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/pipeline-lib.sh" || { warn "共通関数を読めません"; exit 0; }
# 共通関数の ERR の罠は、失敗を画面に error として出す。ここでは警告だけにしたいので外す
trap - ERR

now_utc() { printf '%s' "${STEP_LOG_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"; }

# 所要時間（秒）を「3分12秒」の形にする
fmt_duration() {
  local s="$1"
  if [ "$s" -ge 3600 ]; then printf '%s時間%s分' $((s / 3600)) $((s % 3600 / 60))
  elif [ "$s" -ge 60 ]; then printf '%s分%s秒' $((s / 60)) $((s % 60))
  else printf '%s秒' "$s"; fi
}

# 行の JSON の配列から、人が読む表を作る
render_table() {
  local rows="$1" row s m st fin res att max dur label model_text fix_text
  echo "| 工程 | モデル | 所要時間 | 結果 | 修正 |"
  echo "| --- | --- | --- | --- | --- |"
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    s=$(jq -r .step <<< "$row"); m=$(jq -r '.model // "-"' <<< "$row")
    st=$(jq -r .started <<< "$row"); fin=$(jq -r '.finished // ""' <<< "$row")
    res=$(jq -r .result <<< "$row"); att=$(jq -r '.attempt // ""' <<< "$row"); max=$(jq -r '.max_attempts // ""' <<< "$row")
    dur="-"
    if [ -n "$fin" ]; then
      dur=$(fmt_duration $(( $(date -u -d "$fin" +%s) - $(date -u -d "$st" +%s) ))) || dur="-"
    fi
    case "$res" in running) label="進行中" ;; success) label="成功" ;; *) label="失敗" ;; esac
    model_text="$m"
    fix_text="-"
    [ -n "$att" ] && fix_text="修正 ${att}回目 / ${max:-3}"
    echo "| $s | $model_text | $dur | $label | $fix_text |"
  done < <(jq -c '.[]' <<< "$rows")
}

main() {
  local n="$issue" comments existing id rows prev_started new_row now body_new
  if [ -z "$n" ] && [ -n "$pr" ]; then
    n=$(linked_issue "$pr") || return 1
  fi
  [ -n "$n" ] || { warn "Issue 番号が分かりません"; return 0; }

  comments=$(all_comments "$n") || return 1
  existing=$(jq -c --arg mark "$STEP_LOG_MARK" 'map(select(.body | contains($mark))) | first // empty' <<< "$comments")
  id="" rows="[]"
  if [ -n "$existing" ]; then
    id=$(jq -r .id <<< "$existing")
    rows=$(jq -r .body <<< "$existing" | sed -nE 's/^<!-- step-log: (.*) -->$/\1/p' | jq -sc '.' 2> /dev/null) || rows="[]"
    [ -n "$rows" ] || rows="[]"
  fi

  now=$(now_utc)
  # 終わったときは、同じ工程の「進行中」の行から開始時刻を引き継ぐ（--started があればそれを使う）
  if [ -z "$started" ]; then
    prev_started=""
    if [ "$result" != running ]; then
      prev_started=$(jq -r --arg s "$step" 'map(select(.step == $s and .result == "running")) | first | .started // empty' <<< "$rows")
    fi
    started="${prev_started:-$now}"
  fi
  [ "$model" = "null" ] && model=""
  new_row=$(jq -nc --arg step "$step" --arg model "$model" --arg started "$started" --arg now "$now" --arg result "$result" \
    --arg attempt "$attempt" --arg max "$max_attempts" '
    {step: $step, model: (if $model == "" then null else $model end), started: $started,
     finished: (if $result == "running" then null else $now end), result: $result}
    + (if $attempt == "" then {} else {attempt: ($attempt | tonumber), max_attempts: (if $max == "" then 3 else ($max | tonumber) end)} end)')

  rows=$(jq -c --argjson new "$new_row" --argjson order "$STEP_ORDER" \
    'map(select(.step != $new.step)) + [$new] | sort_by(.step as $s | $order | index($s))' <<< "$rows")

  body_new="${STEP_LOG_MARK}
### 進捗ログ

$(render_table "$rows")

$(jq -c '.[]' <<< "$rows" | sed 's/^/<!-- step-log: /; s/$/ -->/')"

  if [ -n "$id" ]; then
    gh api -X PATCH "repos/$REPO/issues/comments/$id" -f body="$body_new" > /dev/null || return 1
  else
    comment "$n" "$body_new" || return 1
  fi
}

main || warn "gh のエラーなどで記録できませんでした（工程 ${step}）"
exit 0
