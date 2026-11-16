#!/usr/bin/env bash
# 監査の入口（audit-guard.sh）：動かしてよいとき・いけないとき
source "$(dirname "$0")/lib.sh"
setup_mock
unset GITHUB_OUTPUT  # Actions の中で動かしても、標準出力で確かめられるように

pr='{"number":5,"state":"open","body":"","head":{"sha":"abc","ref":"claude/issue-5-x"},"updated_at":"2026-01-01T00:00:00Z"}'

echo "== 何も進行中でなければ動かす"
init_state '{"labels":{"1":["ai:stuck"]}}'
out=$(run_script audit-guard.sh)
assert_contains "run=true" "$out" "run=true"

echo "== 実装中があれば動かさない"
init_state '{"labels":{"1":["ai:implement"]}}'
out=$(run_script audit-guard.sh)
assert_contains "run=false" "$out" "run=false"
assert_contains "理由が出る" "$out" "実装中のIssueがある"

echo "== 企画中があれば動かさない"
init_state '{"labels":{"1":["ai:plan"]}}'
out=$(run_script audit-guard.sh)
assert_contains "run=false" "$out" "run=false"
assert_contains "理由が出る" "$out" "企画中のIssueがある"

echo "== openのPRがあれば動かさない"
init_state '{"pulls":['"$pr"']}'
out=$(run_script audit-guard.sh)
assert_contains "run=false" "$out" "run=false"
assert_contains "理由が出る" "$out" "openのPRがある"

echo "== 前回の監査のIssueがopenなら動かさない"
init_state '{"labels":{"9":[]},"issues_meta":{"9":{"title":"食い違い","state":"open","body":"違う\n<!-- spec-audit -->"}}}'
out=$(run_script audit-guard.sh)
assert_contains "run=false" "$out" "run=false"
assert_contains "理由が出る" "$out" "前回の監査のIssue"

echo "== 前回の監査のIssueが閉じていれば動かす"
init_state '{"labels":{"9":[]},"issues_meta":{"9":{"title":"食い違い","state":"closed","body":"違う\n<!-- spec-audit -->"}}}'
out=$(run_script audit-guard.sh)
assert_contains "run=true" "$out" "run=true"

echo "== GITHUB_OUTPUT があればそこに書く"
init_state '{}'
export GITHUB_OUTPUT="$MOCK_DIR/gh-output"
: > "$GITHUB_OUTPUT"
run_script audit-guard.sh > /dev/null
assert_eq "出力ファイルに run=true" "run=true" "$(cat "$GITHUB_OUTPUT")"
unset GITHUB_OUTPUT

finish
