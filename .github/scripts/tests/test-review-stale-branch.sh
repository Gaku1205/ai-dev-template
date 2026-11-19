#!/usr/bin/env bash
# レビューAIが結果を書かずに終わったとき：枝が古くて claude-review.yml が main と違うだけなら、やり直しに数えず main を取り込む
source "$(dirname "$0")/lib.sh"
setup_mock
printf '%s\n' '# 普通のリポジトリ' > "$MOCK_DIR/CLAUDE_default.md"
export CLAUDE_MD="$MOCK_DIR/CLAUDE_default.md"

WF=".github/workflows/claude-review.yml"
case_run() { # ファイルのJSON配列 先頭のsha mainのsha [追加の状態(JSONの断片。, で始める)]
  init_state '{"labels":{"58":[]},"files":'"$1"',"contents_sha":{"abc":{"'"$WF"'":"'"$2"'"},"main":{"'"$WF"'":"'"$3"'"}},"pulls":[{"number":58,"state":"open","body":"Closes #54","head":{"sha":"abc","ref":"claude/issue-54-x"},"updated_at":"2026-01-01T00:00:00Z"}],"checks":[{"name":"check","status":"completed","conclusion":"success","app":{"slug":"github-actions"}}],"branches":[{"name":"claude/issue-54-x","date":"2026-01-01T00:00:00Z"}]'"${4:-}"'}'
  CONCLUSION=success HEAD_SHA=abc HEAD_BRANCH=claude/issue-54-x run_script after-review.sh > /dev/null
}
field() { python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print(','.join(map(str,s.get('$1',[]))))"; }

echo "== 枝が古いだけ（PRは変えていない・版が違う）：main を取り込む。やり直しに数えない"
case_run '["src/a.ts"]' f5c0faf 41d0f38
assert_eq "update-branch を呼ぶ" "58" "$(field update_branches)"
assert_not_contains "やり直し（ai:retry）にしない" "$(labels_of 58)" "ai:retry"
assert_not_contains "止めない" "$(labels_of 58)" "ai:stuck"
assert_not_contains "retry を数えない" "$(comments_of 58)" "count="

echo "== 取り込みがコンフリクト：AIにコンフリクトの解消を頼む"
case_run '["src/a.ts"]' f5c0faf 41d0f38 ',"update_branch_fail":true'
assert_eq "取り込めていない" "" "$(field update_branches)"
assert_contains "コンフリクトの解消を頼む" "$(comments_of 58)" "コンフリクト"
assert_contains "直す依頼の印が付く" "$(comments_of 58)" "auto-fix-sha: abc"
assert_not_contains "やり直し（ai:retry）にしない" "$(labels_of 58)" "ai:retry"

echo "== 直す依頼がもう出ているコミット：取り込まない"
case_run '["src/a.ts"]' f5c0faf 41d0f38 ',"comments":[{"id":900,"issue":"58","user":{"login":"gaku-ai-pipeline[bot]"},"created_at":"'"$(ago 1)"'","updated_at":"'"$(ago 1)"'","body":"@claude 直してください\n\n<!-- auto-fix -->\n<!-- auto-fix-sha: abc -->"}]'
assert_eq "update-branch を呼ばない" "" "$(field update_branches)"

echo "== 撮り直し（visual:update）が動いている：取り込まない"
case_run '["src/a.ts"]' f5c0faf 41d0f38 ',"labels":{"58":["visual:update"]}'
assert_eq "update-branch を呼ばない" "" "$(field update_branches)"

echo "== PR自身が claude-review.yml を変えている：ai:hold（取り込まない）"
case_run '["'"$WF"'"]' f5c0faf 41d0f38
assert_eq "update-branch を呼ばない" "" "$(field update_branches)"
assert_contains "ai:hold が付く" "$(labels_of 58)" "ai:hold"

echo "== 版が同じ：今までどおりやり直す"
case_run '["src/a.ts"]' 41d0f38 41d0f38
assert_eq "update-branch を呼ばない" "" "$(field update_branches)"
assert_contains "ai:retry が付く" "$(labels_of 58)" "ai:retry"
assert_contains "retry を数える" "$(comments_of 58)" "count="

finish
