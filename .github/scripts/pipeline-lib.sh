#!/usr/bin/env bash
# 全自動パイプラインの共通の関数。各スクリプトから `source` して使う。
#
# 必要な環境変数
#   GH_TOKEN           ：秘密の PIPELINE_TOKEN（オーナーのトークン）。これで付けたラベルや
#                        コメントは次のワークフローを動かせる（GITHUB_TOKEN だと動かない）
#   GITHUB_REPOSITORY  ：owner/repo（Actionsが自動で入れる）
#   NTFY_TOPIC         ：スマホ通知（無ければ鳴らさない）

set -uo pipefail

REPO="${GITHUB_REPOSITORY}"
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

# ブランチ名からopenのPRを1つ探す。見つかれば「番号 先頭コミット」を出す
find_open_pr() {
  local branch="$1"
  gh pr list -R "$REPO" --head "$branch" --state open --json number,headRefOid \
    -q '.[0] | select(. != null) | "\(.number) \(.headRefOid)"'
}

# PRに紐づくIssue番号（本文の Closes #N か、ブランチ名 claude/issue-N-）
linked_issue() {
  local pr="$1" body branch
  body=$(gh pr view "$pr" -R "$REPO" --json body -q .body)
  branch=$(gh pr view "$pr" -R "$REPO" --json headRefName -q .headRefName)
  local n
  n=$(printf '%s' "$body" | grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' | head -1 | grep -oE '[0-9]+')
  if [ -z "$n" ]; then
    n=$(printf '%s' "$branch" | sed -nE 's#^claude/issue-([0-9]+)-.*#\1#p')
  fi
  printf '%s' "$n"
}

pr_has_label() {
  local pr="$1" label="$2"
  gh pr view "$pr" -R "$REPO" --json labels -q '.labels[].name' | grep -qx "$label"
}

# 人間に回す：PRと紐づくIssueに ai:stuck を付けて、理由をコメントし、スマホに通知
stop_for_human() {
  local pr="$1" reason="$2"
  gh pr edit "$pr" -R "$REPO" --add-label "ai:stuck" > /dev/null || true
  gh pr comment "$pr" -R "$REPO" --body "⏸ 自動で進めるのを止めました：${reason}

確認して、続けるなら \`ai:stuck\` を外してから対応してください（直す・マージする・閉じる）。" > /dev/null || true
  local issue
  issue=$(linked_issue "$pr")
  if [ -n "$issue" ]; then
    gh issue edit "$issue" -R "$REPO" --add-label "ai:stuck" > /dev/null || true
  fi
  local title
  title=$(gh pr view "$pr" -R "$REPO" --json title -q .title)
  notify "確認が必要です" "PR #${pr} ${title}：${reason}" 4
}

# AIに直させる。上限を超えていたら人間に回す
request_fix_or_stop() {
  local pr="$1" sha="$2" message="$3"
  local count
  count=$(gh api "repos/$REPO/issues/$pr/comments" --paginate \
    -q "[.[] | select(.body | contains(\"$AUTO_FIX_MARK\"))] | length" | awk '{s+=$1} END {print s+0}')
  if [ "$count" -ge "$MAX_AUTO_FIX" ]; then
    stop_for_human "$pr" "AIが${MAX_AUTO_FIX}回直しても解決しませんでした（最後の理由：${message}）"
    return
  fi
  gh pr comment "$pr" -R "$REPO" --body "@claude ${message}

直したら、型チェック・リント・テスト・ビルドを通してから、このPRのブランチにpushしてください。（自動の依頼 $((count + 1))/${MAX_AUTO_FIX}）

${AUTO_FIX_MARK}
<!-- auto-fix-sha: ${sha} -->" > /dev/null
}

# 順番待ち（ai:queue）のIssueのうち、番号がいちばん小さい物を実装に回す。
# マージのあとに呼ぶ。止まっている物（ai:stuck）や実装中の物があれば、何もしない
start_next_in_queue() {
  local busy
  busy=$(gh issue list -R "$REPO" --state open --label "ai:implement" --json number -q 'length')
  local stuck
  stuck=$(gh issue list -R "$REPO" --state open --label "ai:stuck" --json number -q 'length')
  local prs
  prs=$(gh pr list -R "$REPO" --state open --json number -q 'length')
  if [ "$busy" -gt 0 ] || [ "$stuck" -gt 0 ] || [ "$prs" -gt 0 ]; then
    echo "進行中・停止中の物があるので、順番待ちは進めません"
    return
  fi
  local next
  next=$(gh issue list -R "$REPO" --state open --label "ai:queue" --json number -q 'map(.number) | min // empty')
  [ -z "$next" ] && return
  gh issue edit "$next" -R "$REPO" --remove-label "ai:queue" > /dev/null
  gh issue edit "$next" -R "$REPO" --add-label "ai:implement" > /dev/null
  echo "順番待ちの #$next を実装に回しました"
}
