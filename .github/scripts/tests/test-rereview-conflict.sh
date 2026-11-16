#!/usr/bin/env bash
# もう一度レビューに回すとき、main とコンフリクトしていれば先にAIに解消させる（request_review）
# tochi-rirekisho PR #5：PRの説明を直した後に ai:review を付け直したが、コンフリクトでレビューAIが起きず、9時間止まった
source "$(dirname "$0")/lib.sh"
setup_mock
pr_json() { printf '{"number":58,"body":"Closes #57","state":"open","mergeable_state":"%s","head":{"sha":"abc","ref":"claude/issue-57-x"},"updated_at":"2026-01-01T00:00:00Z"}' "$1"; }
setup_case() { # 1: mergeable_state 2: AIの返事 3: 依頼の印に書くPRの説明のハッシュ（空なら書かない）
  init_state '{"labels":{"58":["ai:review"]},"pulls":['"$(pr_json "$1")"'],"runs":[{"id":9,"name":"CI","conclusion":"success","created_at":"2026-01-01T00:00:00Z"}],"jobs":[{"steps":[]}]}'
  local mark=""
  [ -n "${3:-}" ] && mark="\\n<!-- auto-fix-body: $3 -->"
  state_py "
s['comments'].append({'id':50,'issue':'58','body':'@claude x\\n<!-- auto-fix -->\\n<!-- auto-fix-sha: abc -->$mark','user':{'login':'x'},'created_at':'$(ago 2)','updated_at':'$(ago 2)'})
s['comments'].append({'id':51,'issue':'58','body':'''$2''','user':{'login':'claude[bot]'},'created_at':'$(ago 1)','updated_at':'$(ago 1)'})
s['next_id']=51"
}
run_after() { RUN_STARTED=$(ago 1) CONCLUSION=success run_script after-mention.sh; }
already='指摘はPRの説明の不足だけで、前回の対応で直し済みでした。今回はコードを変えていないので、pushするコミットはありません。'

echo "== 前の対応で直し済みと返した・コンフリクト無し：もう一度レビューへ（人間に回さない）"
setup_case clean "$already"
out=$(run_after)
assert_not_contains "人間に回さない" "$(labels_of 58)" "ai:stuck"
assert_contains "ai:review を付け直す" "$(labels_of 58)" "ai:review"
assert_contains "理由" "$out" "もう一度レビューを依頼しました"

echo "== 前の対応で直し済み・main とコンフリクトしている：レビューは起きないので、先にAIに解消を頼む"
setup_case dirty "$already"
out=$(run_after)
assert_not_contains "人間に回さない" "$(labels_of 58)" "ai:stuck"
assert_contains "解消の依頼" "$(comments_of 58)" "コンフリクトを解消してください"
assert_contains "理由を出す" "$out" "先にAIに解消を依頼しました"

echo "== PRの説明だけを直した・コンフリクトしている：先にAIに解消を頼む"
setup_case dirty "PRの説明を直しました。" "0000000000"
out=$(run_after)
assert_contains "解消の依頼" "$(comments_of 58)" "コンフリクトを解消してください"
assert_not_contains "人間に回さない" "$(labels_of 58)" "ai:stuck"
finish
