#!/usr/bin/env bash
# 作業中に Issue が閉じられたら、企画・実装の続きを進めない（ai-dev-template #71・#84：閉じた Issue の企画の結果で実装が始まり、同じ作業のPRがもう1つできた）
source "$(dirname "$0")/lib.sh"
setup_mock
work="$MOCK_DIR/work"; mkdir -p "$work"

echo "== 企画のあと：Issue が閉じていたら、清書の結果を使わない（ラベルを付けない・分けた Issue を作らない）"
init_state '{"labels":{"3":["ai:plan"]},"issues_meta":{"3":{"title":"t","state":"closed"}}}'
out=$(cd "$work" && printf 'READY\n' > plan-result.txt && ISSUE=3 PLAN_OUTCOME=success GH_TOKEN=pipe GITHUB_TOKEN_FOR_LABELS=x bash "$SCRIPTS_DIR/after-plan.sh" 2>&1)
assert_eq "ラベルが残らない" "" "$(labels_of 3)"
assert_contains "理由を出す" "$out" "閉じられているので"
assert_eq "Issue を作らない" "1" "$(python3 -c "import json,os;print(len(json.load(open(os.environ['MOCK_STATE'])).get('issues_meta',{})))")"

echo "== 開いていれば、今までどおり進む"
init_state '{"labels":{"3":["ai:plan"]},"issues_meta":{"3":{"title":"t","state":"open"}}}'
(cd "$work" && printf 'READY\n' > plan-result.txt && ISSUE=3 PLAN_OUTCOME=success GH_TOKEN=pipe GITHUB_TOKEN_FOR_LABELS=x bash "$SCRIPTS_DIR/after-plan.sh" > /dev/null 2>&1)
assert_not_contains "ai:plan は外れる" "$(labels_of 3)" "ai:plan"
assert_contains "実装か順番待ちへ" "$(labels_of 3)" "ai:"

echo "== 実装のあと：Issue が閉じていたら、PRを作らない"
init_state '{"labels":{"7":["ai:implement"]},"issues_meta":{"7":{"title":"t","state":"closed"}},"branches":[{"name":"claude/issue-7-20260101-0000","commit":{"sha":"a"}}]}'
out=$(ISSUE=7 ISSUE_TITLE="題" AI_OUTCOME=success GITHUB_RUN_ID=99 run_script open-pr.sh 2>&1)
assert_contains "理由を出す" "$out" "PRは作りません"
assert_eq "PRを作らない" "0" "$(python3 -c "import json,os;print(len(json.load(open(os.environ['MOCK_STATE'])).get('pulls',[])))")"
assert_eq "ai:implement を外す" "" "$(labels_of 7)"

echo "== ワークフロー：閉じた Issue では企画・実装・画面案を始めない"
WF="$SCRIPTS_DIR/../workflows"
for f in claude-plan.yml claude-implement.yml claude-mocks.yml; do
  assert_contains "$f" "$(cat "$WF/$f")" "github.event.issue.state == 'open'"
done
finish
