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

STEP_LOG_MARK="<!-- ai-step-log -->"
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

# コメントの本文から、機械が読む行（<!-- ai-step {JSON} -->）を配列にして出す
rows_of_body() {
  local rows
  rows=$(sed -nE 's/^<!-- ai-step (.*) -->$/\1/p' <<< "$1" | jq -sc '.' 2> /dev/null) || rows="[]"
  printf '%s' "${rows:-[]}"
}

# 行の配列に、今回の行を入れる（同じ工程の行は置き換え、工程の順に並べる）
merge_row() { # 行の配列 今回の行
  jq -c --argjson new "$2" --argjson order "$STEP_ORDER" \
    'map(select(.step != $new.step)) + [$new] | sort_by(.step as $s | $order | index($s))' <<< "$1"
}

# 行の配列から、コメントの本文を作る
build_body() {
  printf '%s\n### 進捗ログ\n\n%s\n\n%s' "$STEP_LOG_MARK" "$(render_table "$1")" "$(jq -c '.[]' <<< "$1" | sed 's/^/<!-- ai-step /; s/$/ -->/')"
}

# 書いた後の確かめ：2つの工程（CI の終わりとレビューの終わり、など）がほぼ同時に書くと、どちらも「相手の行が無い古い表」に
# 自分の行を足して書くので、後から書いた方が、先に書いた方の行を消す。少し待ってから読み直し、自分の行が消えていたら、
# 今の表に足して書き直す（最大 STEP_LOG_VERIFY_MAX 回）。API は、ふつうは読み直しの1回だけ増える
#   - 自分の工程の行が、自分の書いた物 → そのまま
#   - 無い・自分が置き換える前の行に戻っている → 消された。今の表に足して書き直す
#   - それ以外（同じ工程の、もっと新しい記録）→ 触らない（古い記録で上書きしない）
verify_written() { # コメントの id　今回の行　置き換える前の行（無ければ空）
  local id="$1" new_row="$2" prev_row="$3" try body rows state
  for try in $(seq 1 "${STEP_LOG_VERIFY_MAX:-2}"); do
    sleep "${STEP_LOG_VERIFY_WAIT:-2}"
    body=$(gh api "repos/$REPO/issues/comments/$id" --jq '.body // ""' 2> /dev/null) || return 0
    rows=$(rows_of_body "$body")
    state=$(jq -r --argjson new "$new_row" --argjson prev "${prev_row:-null}" '
      (map(select(.step == $new.step)) | first) as $cur
      | if $cur == $new then "ok" elif $cur == null or $cur == $prev then "lost" else "newer" end' <<< "$rows" 2> /dev/null) || return 0
    [ "$state" = lost ] || return 0
    echo "進捗ログ：ほかの工程の書き込みで、この工程（${step}）の行が消えていたので、足して書き直します（${try}回目）"
    gh api -X PATCH "repos/$REPO/issues/comments/$id" -f body="$(build_body "$(merge_row "$rows" "$new_row")")" > /dev/null || return 1
  done
}

main() {
  local n="$issue" comments existing id rows prev_started prev_row new_row now first_id first_body
  if [ -z "$n" ] && [ -n "$pr" ]; then
    n=$(linked_issue "$pr") || return 1
  fi
  [ -n "$n" ] || { warn "Issue 番号が分かりません"; return 0; }

  comments=$(all_comments "$n") || return 1
  existing=$(jq -c --arg mark "$STEP_LOG_MARK" 'map(select(.body | contains($mark))) | first // empty' <<< "$comments")
  id="" rows="[]"
  if [ -n "$existing" ]; then
    id=$(jq -r .id <<< "$existing")
    rows=$(rows_of_body "$(jq -r .body <<< "$existing")")
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
  prev_row=$(jq -c --arg s "$step" 'map(select(.step == $s)) | first // empty' <<< "$rows")

  if [ -n "$id" ]; then
    gh api -X PATCH "repos/$REPO/issues/comments/$id" -f body="$(build_body "$(merge_row "$rows" "$new_row")")" > /dev/null || return 1
    verify_written "$id" "$new_row" "$prev_row" || return 1
    return 0
  fi

  # コメントがまだ無い：作る。2つの工程が同時に作ると、進捗ログが2つになる（読む側は先の1つしか見ない）。
  # 作った後に一覧を読み直し、自分より先のコメントがあれば、そちらに自分の行を足して、自分のコメントを消す（今作ったばかりの、自分の物だけ）
  id=$(gh api "repos/$REPO/issues/$n/comments" -f body="$(build_body "$(merge_row "$rows" "$new_row")")" --jq '.id // empty') || return 1
  [ -n "$id" ] || return 0
  sleep "${STEP_LOG_VERIFY_WAIT:-2}"
  comments=$(all_comments "$n") || return 0
  existing=$(jq -c --arg mark "$STEP_LOG_MARK" 'map(select(.body | contains($mark))) | first // empty' <<< "$comments")
  first_id=$(jq -r '.id // empty' <<< "${existing:-null}")
  if [ -n "$first_id" ] && [ "$first_id" != "$id" ]; then
    echo "進捗ログ：ほかの工程が先に進捗ログを作っていたので、そちらに足して、今作った方を消します"
    first_body=$(jq -r .body <<< "$existing")
    gh api -X PATCH "repos/$REPO/issues/comments/$first_id" -f body="$(build_body "$(merge_row "$(rows_of_body "$first_body")" "$new_row")")" > /dev/null || return 1
    gh api -X DELETE "repos/$REPO/issues/comments/$id" > /dev/null || true
    verify_written "$first_id" "$new_row" "" || return 1
  fi
}

main || warn "gh のエラーなどで記録できませんでした（工程 ${step}）"
exit 0
