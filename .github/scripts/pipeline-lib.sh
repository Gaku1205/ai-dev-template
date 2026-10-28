#!/usr/bin/env bash
# 全自動パイプラインの共通の関数。各スクリプトから `source` して使う。
# GitHubとのやり取りは全部 REST API（gh api）で行う。`gh issue edit` などのGraphQL経由の
# コマンドは、Fine-grained トークンだと権限の都合で黙って失敗することがあるため使わない。
#
# 必要な環境変数
#   GH_TOKEN           ：秘密の PIPELINE_TOKEN（オーナーのトークン）。これで付けたラベルや
#                        コメントは次のワークフローを動かせる（GITHUB_TOKEN だと動かない）
#   GITHUB_REPOSITORY  ：owner/repo（Actionsが自動で入れる）
#   NTFY_TOPIC         ：スマホ通知（無ければ鳴らさない）

set -Euo pipefail
# 失敗したら、どの行のどのコマンドかをActionsの画面に出す
trap 'echo "::error file=${BASH_SOURCE[0]},line=${LINENO}::失敗したコマンド: ${BASH_COMMAND}"' ERR

REPO="${GITHUB_REPOSITORY}"
OWNER="${REPO%%/*}"
# AIに自動で直させる回数の上限（CIの失敗とレビューの指摘を合わせて数える）。超えたら人間に回す
MAX_AUTO_FIX="${MAX_AUTO_FIX:-2}"
AUTO_FIX_MARK="<!-- auto-fix -->"
RESUME_MARK="<!-- auto-resume -->"
# shellcheck disable=SC2034  # after-ci.sh など、この下を読み込む側のスクリプトで使う
VISUAL_MARK="<!-- auto-visual-update -->"
# 自動でやり直す回数の上限と、失敗してからやり直すまでの待ち時間（分）。
# 使用量の上限で止まったときは、リセットされるまで何度かやり直しながら待つ
RETRY_MARK="<!-- auto-retry -->"
MAX_RETRY="${MAX_RETRY:-10}"
RETRY_COOLDOWN_MIN="${RETRY_COOLDOWN_MIN:-30}"
# 使用量の上限で止まったときは、回数を減らさずに待つ。リセット時刻が分からないときの待ち時間（分）と、待つのをあきらめる上限（時間）
LIMIT_UNKNOWN_WAIT_MIN="${LIMIT_UNKNOWN_WAIT_MIN:-60}"
LIMIT_MAX_WAIT_HOURS="${LIMIT_MAX_WAIT_HOURS:-24}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

notify() {
  "$SCRIPT_DIR/notify.sh" "$@" || true
}

has_pipeline_token() {
  [ -n "${GH_TOKEN:-}" ]
}

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# ---- Issue・PR の操作（PRもIssueと同じ番号でラベル・コメントを扱える） ----

add_label() {
  gh api "repos/$REPO/issues/$1/labels" -f "labels[]=$2" > /dev/null
}

# 付いていなくてもエラーにしない
remove_label() {
  gh api -X DELETE "repos/$REPO/issues/$1/labels/$(urlencode "$2")" > /dev/null 2>&1 || true
}

has_label() {
  gh api "repos/$REPO/issues/$1/labels" -q '.[].name' | grep -qx "$2"
}

comment() {
  gh api "repos/$REPO/issues/$1/comments" -f body="$2" > /dev/null
}

# コメントを全部（ページをまたいで）1つの配列で出す
all_comments() {
  gh api "repos/$REPO/issues/$1/comments?per_page=100" --paginate --slurp | jq 'add // []'
}

issue_title() {
  gh api "repos/$REPO/issues/$1" -q .title
}

# ラベルが付いたopenのIssue（PRを除く）の数
count_open_issues_with_label() {
  gh api "repos/$REPO/issues?state=open&per_page=100&labels=$(urlencode "$1")" \
    -q '[.[] | select(.pull_request | not)] | length'
}

count_open_prs() {
  gh api "repos/$REPO/pulls?state=open&per_page=100" -q 'length'
}

# ブランチ名からopenのPRを1つ探す。見つかれば「番号 先頭コミット」を出す
find_open_pr() {
  gh api "repos/$REPO/pulls?state=open&head=$OWNER:$1" \
    -q '.[0] | select(. != null) | "\(.number) \(.head.sha)"'
}

# PRに紐づくIssue番号（本文の Closes #N か、ブランチ名 claude/issue-N-）
linked_issue() {
  local pr_json body branch n
  pr_json=$(gh api "repos/$REPO/pulls/$1")
  body=$(printf '%s' "$pr_json" | jq -r '.body // ""')
  branch=$(printf '%s' "$pr_json" | jq -r .head.ref)
  n=$(printf '%s' "$body" | grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  if [ -z "$n" ]; then
    n=$(printf '%s' "$branch" | sed -nE 's#^claude/issue-([0-9]+)-.*#\1#p')
  fi
  printf '%s' "$n"
}

# まだパイプラインに乗っていないIssueか（ai: で始まるラベルが1つも無い。ai:skip も ai: なので「まだ動かさない」になる）
needs_intake() {
  local labels
  labels=$(gh api "repos/$REPO/issues/$1/labels" -q '.[].name') || return 1
  ! printf '%s\n' "$labels" | grep -q '^ai:'
}

# ---- 判断 ----

# 人間に回す：PRと紐づくIssueに ai:stuck を付けて、理由をコメントし、スマホに通知
stop_for_human() {
  local pr="$1" reason="$2"
  add_label "$pr" "ai:stuck" || true
  remove_label "$pr" "ai:retry"
  comment "$pr" "⏸ 自動で進めるのを止めました：${reason}

自分で直す・マージする・閉じるときは、そのまま対応してください。AIに続きを任せるなら \`ai:stuck\` を外してください（外すと、止まった所から自動で続けます）。" || true
  local issue
  issue=$(linked_issue "$pr")
  if [ -n "$issue" ]; then
    add_label "$issue" "ai:stuck" || true
  fi
  notify stuck "確認が必要です" "PR #${pr} $(issue_title "$pr")：${reason}" 4
}

# Issue（PRではない）を人間に回す
stop_issue_for_human() {
  local n="$1" reason="$2"
  add_label "$n" "ai:stuck" || true
  remove_label "$n" "ai:retry"
  comment "$n" "⏸ 自動で進めるのを止めました：${reason}

確認して、続けるなら \`ai:stuck\` を外してください（外すと、止まった所から自動で続けます）。" || true
  notify stuck "確認が必要です" "#${n} $(issue_title "$n")：${reason}" 4
}

# 「再開」の記録（人間が ai:stuck を外したとき resume.sh が書く）より後に、AIに自動で直させた回数
count_auto_fix() {
  all_comments "$1" | jq --arg mark "$AUTO_FIX_MARK" --arg resume "$RESUME_MARK" '
    (map(select(.body | contains($resume)) | .created_at) | max // "") as $since
    | [.[] | select((.body | contains($mark)) and .created_at > $since)] | length'
}

# PRの説明の中身の目印。AIがコミットを入れず、PRの説明だけを直したかを見分けるのに使う
pr_body_hash() {
  gh api "repos/$REPO/pulls/$1" -q '.body // ""' | sha1sum | cut -c1-12
}

# AIに直させる。上限を超えていたら人間に回す
request_fix_or_stop() {
  local pr="$1" sha="$2" message="$3"
  local count total model_mark="" note=""
  count=$(count_auto_fix "$pr")
  # 普通のモデルで MAX_AUTO_FIX 回直しても駄目なら、最後に1回だけ、いちばん強いモデル（opus）で直す
  total=$((MAX_AUTO_FIX + 1))
  if [ "$count" -ge "$total" ]; then
    stop_for_human "$pr" "AIが${total}回（最後の1回は強いモデル）直しても解決しませんでした（最後の理由：${message}）"
    return
  fi
  if [ "$count" -ge "$MAX_AUTO_FIX" ]; then
    model_mark="
<!-- auto-fix-model: opus -->"
    note="（これまでの修正で直らなかったので、最後の1回は、いちばん強いモデルが直します。前の修正の内容とPRのコメントをよく読んでください）
"
  fi
  comment "$pr" "@claude ${message}
${note}
直したら、型チェック・リント・テスト・ビルドを通してから、このPRのブランチにpushしてください。（自動の依頼 $((count + 1))/${total}）

${AUTO_FIX_MARK}
<!-- auto-fix-sha: ${sha} -->
<!-- auto-fix-body: $(pr_body_hash "$pr") -->${model_mark}"
}

# 順番待ち（ai:queue）のIssueのうち、番号がいちばん小さい物を実装に回す。
# 止まっている物（ai:stuck）や実装中の物、openのPRがあれば何もしない
start_next_in_queue() {
  local busy stuck prs next
  busy=$(count_open_issues_with_label "ai:implement") || return 1
  stuck=$(count_open_issues_with_label "ai:stuck") || return 1
  prs=$(count_open_prs) || return 1
  # 停止中（ai:stuck）の数は表示だけにする。実装まで進んだ物は ai:implement か open のPRが残っていて、それで止まる。
  # 企画の段階で止まった物（人間の作業待ち・質問）はコードに触れていないので、後ろの作業をぶつからずに進められる。
  # （これを数えると、人間の作業待ちのIssueが1つあるだけで、ほかの作業が永久に始まらない）
  echo "実装中 ${busy} / 停止中 ${stuck}（数えない） / openのPR ${prs}"
  if [ "$busy" -gt 0 ] || [ "$prs" -gt 0 ]; then
    echo "進行中の物があるので、順番待ちは進めません"
    return 0
  fi
  next=$(gh api "repos/$REPO/issues?state=open&per_page=100&labels=ai%3Aqueue" \
    -q '[.[] | select(.pull_request | not) | .number] | min // empty') || return 1
  if [ -z "$next" ]; then
    echo "順番待ちはありません"
    return 0
  fi
  remove_label "$next" "ai:queue"
  # 企画AIの「待ち」のコメントを読んだ実装AIが、前の作業が終わったか確かめられずに止まらないよう、先に伝えておく
  comment "$next" "▶ 順番が来たので実装を始めます。この作業の前に待っていた作業は、すべて終わっています（進行中の作業・openのPRはありません）。上の「待ち」のコメントは気にせず、このIssueの内容を実装してください。" || true
  add_label "$next" "ai:implement" || return 1
  echo "順番待ちの #$next を実装に回しました"
}

# ---- 自動のやり直し ----
# 止まったとき、すぐ人間に回さず「あとでやり直す」印（ai:retry）と記録のコメントを付ける。
# やり直しは watchdog.sh（定期・ほかのワークフロー完了のたび）が、待ち時間（RETRY_COOLDOWN_MIN）が過ぎてから行う。
# 上限（MAX_RETRY）を超えたら人間に回す。kind：plan / implement（Issue）、review / mention（PR）

retry_comment() {
  all_comments "$1" | jq -c --arg mark "$RETRY_MARK" 'map(select(.body | contains($mark))) | last // empty'
}

retry_count() {
  local c n
  c=$(retry_comment "$1")
  if [ -z "$c" ]; then
    echo 0
    return
  fi
  n=$(printf '%s' "$c" | jq -r .body | sed -nE 's/.*count=([0-9]+) kind=.*/\1/p' | tail -1)
  echo "${n:-0}"
}

# 記録のコメントは1つだけ作り、あとは書き換える（コメントが増えないように）。
#   num 回数 kind 理由 [上限のリセット時刻（UNIX秒 か unknown）] [上限の待ちを最初に始めた時刻（UNIX秒）]
write_retry_record() {
  local num="$1" count="$2" kind="$3" reason="$4" until_at="${5:-}" first="${6:-}" c id body marks=""
  [ -n "$until_at" ] && marks="${marks}
<!-- limit-until=${until_at} -->"
  [ -n "$first" ] && marks="${marks}
<!-- limit-first=${first} -->"
  body=$(printf '🔁 AIが止まったので、時間をおいて自動でやり直します（やり直し %s/%s回）。\n理由：%s\n\n%s\n<!-- count=%s kind=%s -->%s' \
    "$count" "$MAX_RETRY" "$reason" "$RETRY_MARK" "$count" "$kind" "$marks")
  c=$(retry_comment "$num")
  if [ -n "$c" ]; then
    id=$(printf '%s' "$c" | jq -r .id)
    gh api -X PATCH "repos/$REPO/issues/comments/$id" -f body="$body" > /dev/null
  else
    comment "$num" "$body"
  fi
}


# AIの実行記録から、使用量の上限かどうかと、リセット時刻を見分ける。出力：
#   （空）    上限ではない／分からない
#   unknown   上限だが、リセット時刻は読み取れない
#   <数字>    上限で、リセットされる時刻（UNIX秒）。「…limit reached|1761000000」の形で書かれているとき
limit_signal() {
  local f="${1:-}" result epoch
  { [ -n "$f" ] && [ -s "$f" ]; } || return 0
  result=$(jq -r 'if type == "array" then . else [.] end | map(select(.type == "result")) | last // {} | .result // "" | tostring' "$f" 2> /dev/null) || return 0
  printf '%s' "$result" | grep -qiE 'usage limit|rate limit|limit reached|hit your limit' || return 0
  epoch=$(printf '%s' "$result" | sed -nE 's/.*[Ll]imit reached\|([0-9]{10}).*/\1/p' | head -1)
  echo "${epoch:-unknown}"
}

# AIの実行記録（claude-code-action の execution_file）から、失敗の原因を一言に分類する
#   使用量の上限 / 許可不足 / 作業回数の上限 / その他 / 不明（記録なし）
classify_failure() {
  local f="${1:-}" info subtype denials result
  if [ -z "$f" ] || [ ! -s "$f" ]; then
    echo "不明（AIの実行記録がありません）"
    return
  fi
  info=$(jq -r 'if type == "array" then . else [.] end | map(select(.type == "result")) | last // {}
    | "\(.subtype // "")|\(.permission_denials // [] | length)|\(.result // "" | tostring | .[0:300] | gsub("\n"; " "))"' "$f" 2> /dev/null) || info=""
  # 区切りは | （空白の区切りだと、先頭の項目が空のときに詰められてずれる）。result は最後なので、中に | があってもよい
  IFS='|' read -r subtype denials result <<< "$info"
  if printf '%s' "$result" | grep -qiE 'usage limit|rate limit|limit reached|overloaded|429'; then
    echo "使用量の上限"
  elif [ "${denials:-0}" -gt 0 ]; then
    echo "許可不足（AIが許可されていない操作を試した：${denials}件）"
  elif [ "$subtype" = "error_max_turns" ]; then
    echo "作業回数の上限（--max-turns）"
  elif [ -n "$subtype" ]; then
    echo "その他（${subtype}）"
  else
    echo "その他（結果が読み取れません）"
  fi
}

# 失敗コメントの理由に、分類（classify_failure）と、見に行けるログのURLを足す
#   使い方：failure_reason "企画AIがエラーで止まりました" [実行記録のファイル]
failure_reason() {
  echo "$1（原因：$(classify_failure "${2:-}")。ログ：${GITHUB_SERVER_URL:-https://github.com}/${REPO}/actions/runs/${GITHUB_RUN_ID:-0}）"
}

# AIが作ったブランチ（claude/ で始まる物）だけを消す。人間のブランチやmainには触らない（無ければ何もしない）
delete_branch_if_ai() {
  local b="${1:-}"
  case "$b" in
    claude/*) gh api -X DELETE "repos/$REPO/git/refs/heads/$b" > /dev/null 2>&1 && echo "ブランチ $b を消しました" || true ;;
  esac
}

# 記録のコメントの本文から、印の値を取り出す（無ければ空）。使い方：retry_mark_value "$body" limit-until
retry_mark_value() {
  printf '%s' "$1" | sed -nE "s/.*<!-- $2=([0-9a-z]+) -->.*/\\1/p" | tail -1
}

# ---- AIの許可（--allowedTools）の不足 ----
# AIが「許可されていない操作」で止まったとき、何を足せばいいかを通知・コメントに書き、同じ不足が2回起きたらIssueにする。
# 許可の一覧は docs/pipeline.md の「AIの許可」の表（tests/test-permissions.sh が、ワークフローと食い違っていないか確かめる）

PERM_LEDGER_TITLE="AIの許可の不足（自動の記録）"

# コマンドを、許可の書き方（--allowedTools に足す形）にする。git は2語、gh・npm は3語（npm は完全一致）、ほかは1語
permission_key_for_command() {
  local cmd="$1" a b c
  read -r a b c _ <<< "$cmd"
  case "$a" in
    git) echo "Bash(${a} ${b:-}:*)" ;;
    gh) echo "Bash(${a} ${b:-} ${c:-}:*)" ;;
    npm) echo "Bash(${a} ${b:-} ${c:-})" ;;
    "") return 0 ;;
    *) echo "Bash(${a}:*)" ;;
  esac | sed -E 's/ +:\*\)/:*)/; s/ +\)/)/'
}

# AIの実行記録から、許可が無くて拒否された操作を、許可の書き方で1行ずつ出す（無ければ何も出さない）
denied_tools() {
  local f="${1:-}" name cmd
  { [ -n "$f" ] && [ -s "$f" ]; } || return 0
  jq -r 'if type == "array" then . else [.] end | map(select(.type == "result")) | last // {} | .permission_denials // []
    | .[] | "\(.tool_name)\t\(.tool_input.command // "")"' "$f" 2> /dev/null \
    | while IFS=$'\t' read -r name cmd; do
      if [ "$name" = "Bash" ]; then permission_key_for_command "$cmd"; else echo "$name"; fi
    done | sort -u
}

# AIのコメントの文章から、「許可されていない」と書いてある行と、そこに出てくるコマンド（`...`）の許可の書き方を出す
#   1行目以降：許可の不足を言っている行（最大3行）。最後に「KEY: …」の行で、許可の書き方
permission_hints_from_text() {
  local text lines key
  text=$(cat)
  lines=$(printf '%s\n' "$text" | grep -iE '許可されて|許可が無|許可が足り|権限が無|権限がありません|not allowed|permission denied|requires approval|was blocked' | head -3 || true)
  [ -z "$lines" ] && return 0
  printf '%s\n' "$lines"
  printf '%s\n' "$lines" | grep -oE '`[^`]+`' | tr -d '`' | grep -E '^(git|gh|npm|npx|node|curl|python3?) ' \
    | while IFS= read -r c; do permission_key_for_command "$c"; done | sort -u | sed 's/^/KEY: /'
}

# 許可の不足を、記録用のIssue（閉じたまま）にコメントで残し、同じ不足が2回目なら、直すためのIssueを自動で作る
#   使い方：report_permission_gap 番号 "許可の書き方（改行区切り）"
report_permission_gap() {
  local from="$1" keys="$2" key ledger n title existing created
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    ledger=$(gh api "repos/$REPO/issues?state=all&per_page=100" -q ".[] | select(.title == \"$PERM_LEDGER_TITLE\") | .number" | head -1) || return 0
    if [ -z "$ledger" ]; then
      ledger=$(gh api -X POST "repos/$REPO/issues" -f title="$PERM_LEDGER_TITLE" \
        -f body="AIが「許可されていない操作」で止まったときの記録です（自動）。同じ不足が2回起きたら、直すためのIssueを自動で作ります。このIssueは閉じたままにしてください。" -q .number) || return 0
      gh api -X PATCH "repos/$REPO/issues/$ledger" -f state=closed > /dev/null || true
    fi
    comment "$ledger" "<!-- perm-gap: ${key} -->
#${from} で、AIが許可されていない操作を試して止まりました：\`${key}\`" || true
    n=$(all_comments "$ledger" | jq --arg k "<!-- perm-gap: ${key} -->" '[.[] | select(.body | contains($k))] | length')
    if [ "${n:-0}" -ge 2 ]; then
      title="AIの許可が足りない：${key}"
      existing=$(gh api "repos/$REPO/issues?state=open&per_page=100" -q ".[] | select(.title == \"$title\") | .number" | head -1)
      if [ -z "$existing" ]; then
        created=$(gh api -X POST "repos/$REPO/issues" -f title="$title" -f 'labels[]=ai:skip' \
          -f body="### 背景
AIが \`${key}\` を許可されておらず、${n}回止まりました（記録：#${ledger}）。

### やること（マネージャーが行う。\`.github/\` を触るのでAIには回さない）
- docs/pipeline.md の「AIの許可」の表を見て、どのAIにこの操作が要るかを決める
- 要るなら、そのワークフローの \`--allowedTools\` に足し、表にも書く（tests/test-permissions.sh が食い違いを見つける）
- 要らない操作なら、AIへの指示の方を直す" -q .number) || return 0
        notify stuck "AIの許可が足りません" "同じ不足（${key}）が${n}回起きたので、Issue #${created} を作りました" 4
      fi
    fi
  done <<< "$keys"
}

# AIがエラーで終わったときの処理：許可の不足なら、足りない物を書いて人間に回す（やり直しても直らない）。
# それ以外は、やり直す（使用量の上限なら待つ）。使い方：handle_ai_failure 番号 kind(plan|implement|review|mention) 説明 [実行記録のファイル]
handle_ai_failure() {
  local num="$1" kind="$2" label="$3" file="${4:-}" denied reason
  denied=$(denied_tools "$file")
  if [ -n "$denied" ]; then
    report_permission_gap "$num" "$denied"
    reason="$(failure_reason "$label" "$file")。足りない許可：$(printf '%s' "$denied" | paste -sd, - | sed 's/,/、/g')（docs/pipeline.md の「AIの許可」の表と、ワークフローの --allowedTools を見てください）"
    case "$kind" in
      plan) remove_label "$num" "ai:plan"; stop_issue_for_human "$num" "$reason" ;;
      implement) stop_issue_for_human "$num" "$reason" ;;
      *) stop_for_human "$num" "$reason" ;;
    esac
    return 0
  fi
  mark_for_retry "$num" "$kind" "$(failure_reason "$label" "$file")" "$(limit_signal "$file")"
}

# 止まったことを記録して、あとで自動でやり直す。使い方：mark_for_retry 番号 kind 理由 [limit]
#   limit：使用量の上限のとき、リセット時刻（UNIX秒）か unknown（limit_signal の出力）。上限で待つあいだは、やり直しの回数を使わない
mark_for_retry() {
  local num="$1" kind="$2" reason="$3" limit="${4:-}" count now record body updated first
  now=$(date +%s)
  count=$(retry_count "$num")
  if [ -n "$limit" ]; then
    record=$(retry_comment "$num")
    body=$(printf '%s' "$record" | jq -r '.body // ""')
    first=$(retry_mark_value "$body" limit-first)
    # 前の上限の待ちから時間があいているなら、別の出来事として数え直す
    if [ -n "$record" ] && [ -n "$first" ]; then
      updated=$(date -d "$(printf '%s' "$record" | jq -r .updated_at)" +%s)
      [ $(( now - updated )) -gt $(( LIMIT_MAX_WAIT_HOURS * 3600 )) ] && first=""
    fi
    if [ -n "$first" ] && [ $(( now - first )) -gt $(( LIMIT_MAX_WAIT_HOURS * 3600 )) ]; then
      reason="${reason}（使用量の上限が${LIMIT_MAX_WAIT_HOURS}時間以上続いています）"
      limit=""
    fi
  fi
  if [ -z "$limit" ] && [ "$count" -ge "$MAX_RETRY" ]; then
    if [ "$kind" = "plan" ]; then
      remove_label "$num" "ai:plan"
    fi
    case "$kind" in
      plan | implement) stop_issue_for_human "$num" "${reason}。自動でやり直しても${MAX_RETRY}回解決しませんでした" ;;
      *) stop_for_human "$num" "${reason}。自動でやり直しても${MAX_RETRY}回解決しませんでした" ;;
    esac
    return
  fi
  if [ -n "$limit" ]; then
    first="${first:-$now}"
    write_retry_record "$num" "$count" "$kind" "$reason" "$limit" "$first"
    add_label "$num" "ai:retry"
    # 待ちに入った最初の1回だけ通知する
    if [ -z "$(retry_mark_value "$body" limit-first)" ] || [ "$(retry_mark_value "$body" limit-first)" != "$first" ]; then
      notify limit "使用量の上限で待っています" "#${num}：$(limit_until_text "$limit")に自動で再開します。回数は減りません" 2
    fi
    echo "#$num：使用量の上限なので、$(limit_until_text "$limit")まで待ちます（やり直しの回数は使いません）"
    return
  fi
  write_retry_record "$num" "$count" "$kind" "$reason"
  add_label "$num" "ai:retry"
  echo "#$num：${reason}。あとで自動でやり直します（${count}/${MAX_RETRY}回やり直し済み）"
}


# 上限の待ちの表示用（日本時間）
limit_until_text() {
  if [ "$1" = "unknown" ]; then
    echo "${LIMIT_UNKNOWN_WAIT_MIN}分後"
  else
    TZ=Asia/Tokyo date -d "@$1" +"%H:%M ごろ"
  fi
}

# 記録のコメントが最後に書き換えられてから、待ち時間が過ぎたか
#   上限で待っているとき：リセット時刻（の1分後）か、時刻が分からないときは LIMIT_UNKNOWN_WAIT_MIN 分
retry_due() {
  local c updated until_at now
  c=$(retry_comment "$1")
  [ -z "$c" ] && return 0
  now=$(date +%s)
  until_at=$(retry_mark_value "$(printf '%s' "$c" | jq -r .body)" limit-until)
  if [ -n "$until_at" ] && [ "$until_at" != "unknown" ]; then
    [ "$now" -ge $(( until_at + 60 )) ]
    return
  fi
  updated=$(date -d "$(printf '%s' "$c" | jq -r .updated_at)" +%s)
  if [ "$until_at" = "unknown" ]; then
    [ $(( now - updated )) -ge $(( LIMIT_UNKNOWN_WAIT_MIN * 60 )) ]
  else
    [ $(( now - updated )) -ge $(( RETRY_COOLDOWN_MIN * 60 )) ]
  fi
}


# AI（claude[bot]）がpushしたコミットのCIは、GitHubが「承認待ち（action_required）」で止めることがある。
# そうなっていたら、オーナーのトークンで空のコミットを1つ足して、CIを動かし直す（オーナーのpushなら承認は要らない）。
# READ_TOKEN（ワークフローのトークン、actions: read）でCIの実行を読む
rerun_ci_if_waiting_approval() {
  local pr="$1" sha="$2" branch="$3" runs="[]"
  for _ in 1 2 3 4; do
    runs=$(GH_TOKEN="$READ_TOKEN" gh api "repos/$REPO/actions/runs?head_sha=$sha&event=pull_request&per_page=50" \
      -q '[.workflow_runs[] | select(.name == "CI")]')
    [ "$(printf '%s' "$runs" | jq 'length')" -gt 0 ] && break
    sleep 15
  done
  local running waiting
  running=$(printf '%s' "$runs" | jq '[.[] | select(.conclusion != "action_required")] | length')
  waiting=$(printf '%s' "$runs" | jq '[.[] | select(.conclusion == "action_required")] | length')
  if [ "$running" -gt 0 ]; then
    echo "PR #$pr：CIはふつうに動いています"
    return 0
  fi
  echo "PR #$pr：CIが承認待ち（${waiting} 件）か、始まっていないので、空のコミットで動かし直します"
  local tree new
  tree=$(gh api "repos/$REPO/git/commits/$sha" -q .tree.sha)
  new=$(gh api "repos/$REPO/git/commits" -f message="CIを動かし直す（AIのpushでCIが承認待ちになったため）" \
    -f tree="$tree" -f "parents[]=$sha" -q .sha)
  gh api -X PATCH "repos/$REPO/git/refs/heads/$branch" -f sha="$new" > /dev/null
  echo "PR #$pr：$new を足しました"
}
