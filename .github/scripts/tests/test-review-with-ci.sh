#!/usr/bin/env bash
# レビューAIを CI と同時に動かす（#119）：どちらが後に終わっても、後の方がマージへ進める。CIが落ちたらレビューを取り消す。
# 同じコミットに CI とレビューの両方から「直して」を二重に頼まない
source "$(dirname "$0")/lib.sh"
setup_mock

state() { # 追加の状態（JSON）
  python3 - "$1" <<'PY'
import json, os, sys
pr = {'number': 58, 'body': 'Closes #1', 'state': 'open', 'head': {'sha': 'abc', 'ref': 'claude/issue-1-x', 'repo': {'full_name': 'o/r'}}, 'updated_at': '2026-01-01T00:00:00Z', 'mergeable_state': 'clean', 'user': {'login': 'claude[bot]'}}
s = {'next_id': 0, 'comments': [], 'labels': {'58': ['ai:review']}, 'issue_updated': {}, 'pulls': [pr], 'jobs': [], 'checks': [], 'runs': [], 'branches': [], 'authors': {}, 'files': ['src/app/page.tsx']}
s.update(json.loads(sys.argv[1]))
json.dump(s, open(os.environ['MOCK_STATE'], 'w'))
PY
}
review_ok='{"id":1,"issue":"58","user":{"login":"github-actions[bot]"},"body":"## Code review\n\nNo issues found.","created_at":"2026-01-02T00:00:00Z","updated_at":"2026-01-02T00:00:00Z"}'
fixed_by_review='{"id":2,"issue":"58","user":{"login":"github-actions[bot]"},"body":"@claude レビューで指摘がありました\n<!-- auto-fix -->\n<!-- auto-fix-sha: abc -->","created_at":"2026-01-02T00:00:00Z","updated_at":"2026-01-02T00:00:00Z"}'
ci_ok='[{"name":"check","status":"completed","conclusion":"success","app":{"slug":"github-actions"}}]'
mstate() { python3 -c "import json,os;print(json.load(open(os.environ['MOCK_STATE'])).get('$1',[]))"; }
ci() { CONCLUSION="$1" HEAD_SHA=abc HEAD_BRANCH=claude/issue-1-x RUN_ID=9 READ_TOKEN=x run_script after-ci.sh; }

echo "== CIが通った・レビューの結果（指摘なし）がもう出ている → レビューを頼み直さず、マージへ進める"
state "{\"comments\":[$review_ok],\"checks\":$ci_ok}"
out=$(ci success)
assert_contains "マージへ進める" "$out" "レビューの結果も出ているので、マージへ進めます"
assert_eq "マージした" "[58]" "$(mstate merged)"

echo "== CIが通った・レビューAIが動いている → 待つ（終わったら after-review.sh が進める）"
state '{"wf_runs":{"claude-review.yml":[{"id":7,"status":"in_progress"}]}}'
out=$(ci success)
assert_contains "待つ" "$out" "レビューAIが動いているので"
assert_eq "マージしない" "[]" "$(mstate merged)"

echo "== CIが通った・レビューがまだ無い → 今までどおりレビューを頼む"
state '{"labels":{"58":[]}}'
out=$(ci success)
assert_contains "頼む" "$out" "レビューを依頼しました"
assert_contains "ai:review を付ける" "$(labels_of 58)" "ai:review"

echo "== CIが落ちた・レビューAIが動いている → 取り消して、直すよう頼む"
state '{"wf_runs":{"claude-review.yml":[{"id":7,"status":"in_progress"},{"id":6,"status":"completed"}]}}'
out=$(ci failure)
assert_eq "動いている物だけ取り消す" "[7]" "$(mstate cancels)"
assert_not_contains "結果を待つ印を外す" "$(labels_of 58)" "ai:review"
assert_contains "直すよう頼む" "$(comments_of 58)" "auto-fix-sha: abc"

echo "== CIが落ちた・レビューの指摘でもう直すよう頼んである → 二重に頼まない"
state "{\"comments\":[$fixed_by_review]}"
out=$(ci failure)
assert_contains "重ねて頼まない" "$out" "重ねて頼みません"
assert_eq "直す依頼は1つのまま" "1" "$(comments_of 58 | grep -c 'auto-fix-sha: abc')"

echo "== レビューに指摘・CIが落ちてもう直すよう頼んである → 二重に頼まない"
review_ng='{"id":3,"issue":"58","user":{"login":"github-actions[bot]"},"body":"## Code review\n\n1 issue found.","created_at":"2026-01-02T00:00:00Z","updated_at":"2026-01-02T00:00:00Z"}'
state "{\"comments\":[$fixed_by_review,$review_ng]}"
out=$(CONCLUSION=success HEAD_SHA=abc HEAD_BRANCH=claude/issue-1-x READ_TOKEN=x run_script after-review.sh)
assert_contains "重ねて頼まない" "$out" "重ねて頼みません"
assert_eq "直す依頼は1つのまま" "1" "$(comments_of 58 | grep -c 'auto-fix-sha: abc')"

echo "== レビューが指摘なしで先に終わった・CIはまだ → マージせず、CIを待つ"
state "{\"comments\":[$review_ok],\"checks\":[{\"name\":\"check\",\"status\":\"in_progress\",\"conclusion\":null,\"app\":{\"slug\":\"github-actions\"}}]}"
out=$(CONCLUSION=success HEAD_SHA=abc HEAD_BRANCH=claude/issue-1-x READ_TOKEN=x run_script after-review.sh)
assert_contains "CIを待つ" "$out" "after-ci.sh が、このレビューの結果でマージへ進めます"
assert_eq "マージしない" "[]" "$(mstate merged)"

finish
