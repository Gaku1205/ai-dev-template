#!/usr/bin/env bash
# 実装AIのあと：ブランチ claude/issue-<番号>-... から main へのPRを自動で作る。
# PRの本文は、実装AIがIssueに書いた「Create PR」リンクの中身を使う（無ければ Closes #番号 だけ）。
#
# 環境変数：ISSUE（番号）、ISSUE_TITLE、AI_OUTCOME（実装AIの結果 success/failure）
source "$(dirname "$0")/pipeline-lib.sh"
set -e

if ! has_pipeline_token; then
  # トークンが無い間は、今までどおり人間がPRを作る
  if [ "$AI_OUTCOME" = "success" ]; then
    notify "PRを作れます" "#${ISSUE} ${ISSUE_TITLE}：AIの作業が終わりました" 4
  else
    notify "AIが止まりました" "#${ISSUE} ${ISSUE_TITLE}：結果を確認してPRを作ってください" 4
  fi
  exit 0
fi

# いちばん新しいコミットがある claude/issue-<番号>- ブランチを探す
branch=""
latest=""
for b in $(gh api "repos/$REPO/branches?per_page=100" --paginate -q ".[].name | select(startswith(\"claude/issue-${ISSUE}-\"))"); do
  date=$(gh api "repos/$REPO/branches/$b" -q .commit.commit.committer.date)
  if [[ "$date" > "$latest" ]]; then
    latest="$date"
    branch="$b"
  fi
done

if [ -z "$branch" ]; then
  add_label "$ISSUE" "ai:stuck" || true
  notify "AIが止まりました" "#${ISSUE} ${ISSUE_TITLE}：変更が作られませんでした。Issueのコメントを確認してください" 4
  exit 0
fi

ahead=$(gh api "repos/$REPO/compare/main...$branch" -q .ahead_by)
if [ "${ahead:-0}" -eq 0 ]; then
  add_label "$ISSUE" "ai:stuck" || true
  notify "AIが止まりました" "#${ISSUE} ${ISSUE_TITLE}：ブランチに変更がありません" 4
  exit 0
fi

existing=$(find_open_pr "$branch" || true)
if [ -n "$existing" ]; then
  echo "PRはもうあります：$existing"
  exit 0
fi

# 実装AIの最後のコメントの「Create PR」リンクから、本文を取り出す
comment=$(all_comments "$ISSUE" | jq -r 'map(select(.user.login == "claude[bot]")) | last | .body // ""')
body=$(printf '%s' "$comment" | python3 -c '
import re, sys, urllib.parse
text = sys.stdin.read()
m = re.search(r"quick_pull=1[^)\s]*", text)
if m:
    q = urllib.parse.parse_qs(m.group(0))
    print(q.get("body", [""])[0])
')
if ! printf '%s' "$body" | grep -qiE "(close[sd]?|fix(e[sd])?|resolve[sd]?) #${ISSUE}\b"; then
  body="Closes #${ISSUE}

${body}"
fi
body="${body}

---
_実装AIの作業が終わったので、自動で作ったPRです。CIが通るとレビューAIが確認し、問題がなければ自動でマージします。_"

created=$(gh api "repos/$REPO/pulls" -f title="$ISSUE_TITLE" -f head="$branch" -f base=main -f body="$body" -q .html_url)
echo "PRを作りました：$created"

if [ "$AI_OUTCOME" != "success" ]; then
  echo "実装AIは途中で止まりましたが（作業回数の上限など）、変更があるのでPRにしました。CIで確かめます"
fi
