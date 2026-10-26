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
  comment "$pr" "⏸ 自動で進めるのを止めました：${reason}

確認して、続けるなら \`ai:stuck\` を外してから対応してください（直す・マージする・閉じる）。" || true
  local issue
  issue=$(linked_issue "$pr")
  if [ -n "$issue" ]; then
    add_label "$issue" "ai:stuck" || true
  fi
  notify stuck "確認が必要です" "PR #${pr} $(issue_title "$pr")：${reason}" 4
}

# AIに直させる。上限を超えていたら人間に回す
request_fix_or_stop() {
  local pr="$1" sha="$2" message="$3"
  local count
  count=$(all_comments "$pr" | jq --arg mark "$AUTO_FIX_MARK" '[.[] | select(.body | contains($mark))] | length')
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
