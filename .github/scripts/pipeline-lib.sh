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
VISUAL_MARK="<!-- auto-visual-update -->"
# 自動でやり直す回数の上限と、失敗してからやり直すまでの待ち時間（分）。
# 使用量の上限で止まったときは、リセットされるまで何度かやり直しながら待つ
RETRY_MARK="<!-- auto-retry -->"
MAX_RETRY="${MAX_RETRY:-10}"
RETRY_COOLDOWN_MIN="${RETRY_COOLDOWN_MIN:-30}"
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

# AIに直させる。上限を超えていたら人間に回す
request_fix_or_stop() {
  local pr="$1" sha="$2" message="$3"
  local count
  count=$(count_auto_fix "$pr")
  if [ "$count" -ge "$MAX_AUTO_FIX" ]; then
    stop_for_human "$pr" "AIが${MAX_AUTO_FIX}回直しても解決しませんでした（最後の理由：${message}）"
    return
  fi
  comment "$pr" "@claude ${message}

直したら、型チェック・リント・テスト・ビルドを通してから、このPRのブランチにpushしてください。（自動の依頼 $((count + 1))/${MAX_AUTO_FIX}）

${AUTO_FIX_MARK}
<!-- auto-fix-sha: ${sha} -->"
}

# 順番待ち（ai:queue）のIssueのうち、番号がいちばん小さい物を実装に回す。
# 止まっている物（ai:stuck）や実装中の物、openのPRがあれば何もしない
start_next_in_queue() {
  local busy stuck prs next
  busy=$(count_open_issues_with_label "ai:implement") || return 1
  stuck=$(count_open_issues_with_label "ai:stuck") || return 1
  prs=$(count_open_prs) || return 1
  echo "実装中 ${busy} / 停止中 ${stuck} / openのPR ${prs}"
  if [ "$busy" -gt 0 ] || [ "$stuck" -gt 0 ] || [ "$prs" -gt 0 ]; then
    echo "進行中・停止中の物があるので、順番待ちは進めません"
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
# やり直しは watchdog.sh（30分ごと）が、待ち時間（RETRY_COOLDOWN_MIN）が過ぎてから行う。
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

# 記録のコメントは1つだけ作り、あとは書き換える（コメントが増えないように）。num 回数 kind 理由
write_retry_record() {
  local num="$1" count="$2" kind="$3" reason="$4" c id body
  body=$(printf '🔁 AIが止まったので、時間をおいて自動でやり直します（やり直し %s/%s回）。\n理由：%s\n\n%s\n<!-- count=%s kind=%s -->' \
    "$count" "$MAX_RETRY" "$reason" "$RETRY_MARK" "$count" "$kind")
  c=$(retry_comment "$num")
  if [ -n "$c" ]; then
    id=$(printf '%s' "$c" | jq -r .id)
    gh api -X PATCH "repos/$REPO/issues/comments/$id" -f body="$body" > /dev/null
  else
    comment "$num" "$body"
  fi
}

mark_for_retry() {
  local num="$1" kind="$2" reason="$3" count
  count=$(retry_count "$num")
  if [ "$count" -ge "$MAX_RETRY" ]; then
    if [ "$kind" = "plan" ]; then
      remove_label "$num" "ai:plan"
    fi
    case "$kind" in
      plan | implement) stop_issue_for_human "$num" "${reason}。自動でやり直しても${MAX_RETRY}回解決しませんでした" ;;
      *) stop_for_human "$num" "${reason}。自動でやり直しても${MAX_RETRY}回解決しませんでした" ;;
    esac
    return
  fi
  write_retry_record "$num" "$count" "$kind" "$reason"
  add_label "$num" "ai:retry"
  echo "#$num：${reason}。あとで自動でやり直します（${count}/${MAX_RETRY}回やり直し済み）"
}

# 記録のコメントが最後に書き換えられてから、待ち時間が過ぎたか
retry_due() {
  local c updated
  c=$(retry_comment "$1")
  [ -z "$c" ] && return 0
  updated=$(date -d "$(printf '%s' "$c" | jq -r .updated_at)" +%s)
  [ $(( $(date +%s) - updated )) -ge $(( RETRY_COOLDOWN_MIN * 60 )) ]
}

# AI（claude[bot]）がpushしたコミットのCIは、GitHubが「承認待ち（action_required）」で止めることがある。
# そうなっていたら、オーナーのトークンで空のコミットを1つ足して、CIを動かし直す（オーナーのpushなら承認は要らない）。
# READ_TOKEN（ワークフローのトークン、actions: read）でCIの実行を読む
rerun_ci_if_waiting_approval() {
  local pr="$1" sha="$2" branch="$3" runs="[]" attempt
  for attempt in 1 2 3 4; do
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
