#!/usr/bin/env bash
# 2つのPRにほぼ同時に直す依頼が出たとき：終わった修正AIの結果は、対応したPR（PR_NUMBER または pr.txt）だけに使う。
# まだ作業中のもう一方のPRを「変更が入りませんでした」で ai:stuck にしない
source "$(dirname "$0")/lib.sh"
setup_mock
pr_json() { printf '{"number":%s,"body":"Closes #1","state":"open","head":{"sha":"abc","ref":"claude/issue-%s-x"},"updated_at":"2026-01-01T00:00:00Z"}' "$1" "$1"; }
setup_two() {
  init_state '{"labels":{"58":[],"59":[]},"pulls":['"$(pr_json 58)"','"$(pr_json 59)"'],"runs":[{"id":9,"name":"CI","conclusion":"failure","created_at":"2026-01-01T00:00:00Z"}],"jobs":[{"steps":[]}]}'
  state_py "
s['comments'].append({'id':50,'issue':'58','body':'@claude x\\n<!-- auto-fix -->\\n<!-- auto-fix-sha: abc -->','user':{'login':'x'},'created_at':'$(ago 2)','updated_at':'$(ago 2)'})
s['comments'].append({'id':51,'issue':'59','body':'@claude y\\n<!-- auto-fix -->\\n<!-- auto-fix-sha: abc -->','user':{'login':'x'},'created_at':'$(ago 2)','updated_at':'$(ago 2)'})
s['next_id']=51"
}
run_after() { RUN_STARTED=$(ago 1) CONCLUSION=success run_script after-mention.sh; }

echo "== PR_NUMBER が無い（古いワークフロー）：今までどおり、180秒以内の依頼がある全PRを見る"
setup_two
run_after > /dev/null
assert_contains "58 は ai:stuck" "$(labels_of 58)" "ai:stuck"
assert_contains "59 も ai:stuck（今までの動き）" "$(labels_of 59)" "ai:stuck"

echo "== PR_NUMBER=58：58 だけを処理し、作業中の 59 は何も変わらない"
setup_two
RUN_STARTED=$(ago 1) CONCLUSION=success PR_NUMBER=58 run_script after-mention.sh > /dev/null
assert_contains "58 は ai:stuck" "$(labels_of 58)" "ai:stuck"
assert_eq "59 のラベルは変わらない" "" "$(labels_of 59)"
assert_eq "59 にコメントが増えない" "$(printf '@claude y\n<!-- auto-fix -->\n<!-- auto-fix-sha: abc -->')" "$(comments_of 59)"

echo "== pr.txt（EXECUTION_FILE と同じフォルダ）に 59：59 だけを処理する"
setup_two
mkdir -p "$MOCK_DIR/ai-result"
printf '[]' > "$MOCK_DIR/ai-result/execution.json"
printf '59\n' > "$MOCK_DIR/ai-result/pr.txt"
RUN_STARTED=$(ago 1) CONCLUSION=success EXECUTION_FILE="$MOCK_DIR/ai-result/execution.json" run_script after-mention.sh > /dev/null
assert_contains "59 は ai:stuck" "$(labels_of 59)" "ai:stuck"
assert_eq "58 のラベルは変わらない" "" "$(labels_of 58)"

echo "== PR_NUMBER が pr.txt より優先される"
setup_two
RUN_STARTED=$(ago 1) CONCLUSION=success PR_NUMBER=58 EXECUTION_FILE="$MOCK_DIR/ai-result/execution.json" run_script after-mention.sh > /dev/null
assert_contains "58 は ai:stuck" "$(labels_of 58)" "ai:stuck"
assert_eq "59 のラベルは変わらない" "" "$(labels_of 59)"

echo "== 数字だけでない値は無視する：今までどおり全PRを見る"
setup_two
printf 'abc\n' > "$MOCK_DIR/ai-result/pr.txt"
RUN_STARTED=$(ago 1) CONCLUSION=success PR_NUMBER='58 59' EXECUTION_FILE="$MOCK_DIR/ai-result/execution.json" run_script after-mention.sh > /dev/null
assert_contains "58 は ai:stuck" "$(labels_of 58)" "ai:stuck"
assert_contains "59 も ai:stuck" "$(labels_of 59)" "ai:stuck"

finish
