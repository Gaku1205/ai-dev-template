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

echo "== CIが通った・レビューの「直して」が先に出ている・main が進んでいる → 取り込まず、二重に頼まない"
state "{\"comments\":[$fixed_by_review],\"checks\":$ci_ok,\"ahead_by\":2}"
out=$(ci success)
assert_contains "直した push を待つ" "$out" "直した push を待ちます"
assert_not_contains "取り込まない" "$out" "取り込みました"
assert_eq "直す依頼は1つのまま" "1" "$(comments_of 58 | grep -c 'auto-fix-sha: abc')"
assert_eq "マージしない" "[]" "$(mstate merged)"

fix_done='{"id":4,"issue":"58","user":{"login":"claude[bot]"},"body":"**Claude finished** 指摘は誤りと返しました","created_at":"2026-01-02T00:01:00Z","updated_at":"2026-01-02T00:01:00Z"}'
review_ng2='{"id":5,"issue":"58","user":{"login":"claude[bot]"},"body":"## Code review\n\n1 issue found.","created_at":"2026-01-02T00:02:00Z","updated_at":"2026-01-02T00:02:00Z"}'
review_ok2='{"id":6,"issue":"58","user":{"login":"claude[bot]"},"body":"## Code review\n\nNo issues found.","created_at":"2026-01-02T00:02:00Z","updated_at":"2026-01-02T00:02:00Z"}'

echo "== 前の依頼は修正AIが push せず終わった・同じコミットの2回目のレビューにも指摘 → 直すよう頼み直す"
state "{\"comments\":[$fixed_by_review,$fix_done,$review_ng2]}"
out=$(CONCLUSION=success HEAD_SHA=abc HEAD_BRANCH=claude/issue-1-x READ_TOKEN=x run_script after-review.sh)
assert_not_contains "止まらない" "$out" "重ねて頼みません"
assert_eq "直す依頼が2つになる" "2" "$(comments_of 58 | grep -c 'auto-fix-sha: abc')"

echo "== 前の依頼は終わった・2回目のレビューは指摘なしで先に終わった・そのあとCIが通る → マージへ進める"
state "{\"comments\":[$fixed_by_review,$fix_done,$review_ok2],\"checks\":$ci_ok}"
out=$(ci success)
assert_contains "マージへ進める" "$out" "レビューの結果も出ているので、マージへ進めます"
assert_eq "マージした" "[58]" "$(mstate merged)"

echo "== 前の回の結果（指摘あり）が残っている・同じコミットの2回目のレビューが動いている・CIが通る → 前の結果で頼み直さず、待つ"
state "{\"comments\":[$fixed_by_review,$fix_done,$review_ng2],\"checks\":$ci_ok,\"wf_runs\":{\"claude-review.yml\":[{\"id\":8,\"status\":\"in_progress\"}]}}"
out=$(ci success)
assert_contains "待つ" "$out" "レビューAIが動いているので"
assert_not_contains "前の結果でマージへ進めない" "$out" "レビューの結果も出ているので"
assert_eq "直す依頼は1つのまま" "1" "$(comments_of 58 | grep -c 'auto-fix-sha: abc')"
assert_eq "マージしない" "[]" "$(mstate merged)"

finish
