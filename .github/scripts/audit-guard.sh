#!/usr/bin/env bash
# 仕様書の監査（週1回）を「いま動かしてよいか」調べる。audit.yml から呼ぶ
# 進行中の作業（実装中・企画中・openのPR・前回の監査のIssue）が1つでもあれば run=false、全部無ければ run=true
# 結果は GITHUB_OUTPUT があればそこに、無ければ標準出力にだけ出す
source "$(dirname "$0")/pipeline-lib.sh"

# 監査のIssueの本文の最後に付ける印（prompts/audit.md と同じ）
AUDIT_MARK='<!-- spec-audit -->'

impl=$(count_open_issues_with_label "ai:implement") || { echo "::error::ai:implement のIssueを数えられませんでした"; exit 1; }
plan=$(count_open_issues_with_label "ai:plan") || { echo "::error::ai:plan のIssueを数えられませんでした"; exit 1; }
prs=$(count_open_prs) || { echo "::error::openのPRを数えられませんでした"; exit 1; }
audits=$(gh api "repos/$REPO/issues?state=open&per_page=100" \
  -q "[.[] | select(.pull_request | not) | select((.body // \"\") | contains(\"$AUDIT_MARK\"))] | length") \
  || { echo "::error::前回の監査のIssueを調べられませんでした"; exit 1; }

echo "実装中 ${impl} / 企画中 ${plan} / openのPR ${prs} / 前回の監査のIssue ${audits}"

run=true
if [ "$impl" -gt 0 ]; then
  echo "実装中のIssueがあるので、監査は動かしません"; run=false
elif [ "$plan" -gt 0 ]; then
  echo "企画中のIssueがあるので、監査は動かしません"; run=false
elif [ "$prs" -gt 0 ]; then
  echo "openのPRがあるので、監査は動かしません"; run=false
elif [ "$audits" -gt 0 ]; then
  echo "前回の監査のIssueがまだ開いているので、監査は動かしません"; run=false
else
  echo "進行中の作業が無いので、監査を動かします"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "run=$run" >> "$GITHUB_OUTPUT"
else
  echo "run=$run"
fi
