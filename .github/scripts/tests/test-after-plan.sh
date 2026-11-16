#!/usr/bin/env bash
# 企画AIのあと（after-plan.sh）：清書の結果のサイズを付けて実装へ。先に決まっているサイズ（工場の size:L など）は残す
source "$(dirname "$0")/lib.sh"
setup_mock
work="$MOCK_DIR/work"; mkdir -p "$work"
run_plan() { (cd "$work" && if [ -n "$1" ]; then printf '%s\n%s\n' "$1" PARALLEL > plan-result.txt; else rm -f plan-result.txt; fi && ISSUE=3 PLAN_OUTCOME=success GITHUB_TOKEN_FOR_LABELS=x bash "$SCRIPTS_DIR/after-plan.sh" 2>&1); }

echo "== サイズが無ければ、企画AIの決めたサイズを付けて実装へ"
init_state '{"labels":{"3":["ai:plan"]}}'
run_plan "READY size:S" > /dev/null
assert_eq "size:S と ai:implement" "ai:implement,size:S" "$(labels_of 3)"

echo "== 工場が size:L を付けていれば、企画AIが size:S と言っても size:L のまま"
init_state '{"labels":{"3":["ai:plan","size:L"]}}'
run_plan "READY size:S" > /dev/null
assert_eq "size:L のまま" "ai:implement,size:L" "$(labels_of 3)"

echo "== 結果を書かずに終わった（質問も無い）：黙って止めず、2回までは自動でやり直す"
init_state '{"labels":{"3":["ai:plan"]}}'
run_plan "" > /dev/null
assert_contains "やり直し待ち" "$(labels_of 3)" "ai:retry"
assert_not_contains "人間に回さない" "$(labels_of 3)" "ai:stuck"
state_py "
import re
for c in s['comments']:
    if 'auto-retry' in c['body']: c['body']=re.sub(r'count=[0-9]+ kind=','count=2 kind=',c['body'])
s['labels']['3']=['ai:plan']"
run_plan "" > /dev/null
assert_contains "やり直しのあとも書かなければ人間に回す" "$(labels_of 3)" "ai:stuck"
assert_contains "理由を書く" "$(comments_of 3)" "清書の結果を書きませんでした"

echo "== 迷いがあれば選択式で質問して待つ（ai:question。止まった扱いにはしない）"
init_state '{"labels":{"3":["ai:plan"]}}'
run_plan "ASK" > /dev/null
assert_eq "質問の印だけ" "ai:question" "$(labels_of 3)"

echo "== 答えたら清書に戻す（after-answer.sh）"
init_state '{"labels":{"3":["ai:question"]}}'
(ISSUE=3 GH_TOKEN=pipe GITHUB_TOKEN_FOR_LABELS=x bash "$SCRIPTS_DIR/after-answer.sh" > /dev/null 2>&1)
assert_eq "質問の印を外して ai:plan" "ai:plan" "$(labels_of 3)"

echo "== 見た目の大きい作り直しは、作る前に画面案（ai:mocks。パイプラインの鍵で付けて画面案のワークフローを動かす）"
init_state '{"labels":{"3":["ai:plan"]}}'
(cd "$work" && printf 'MOCKS\nPARALLEL\n' > plan-result.txt && ISSUE=3 PLAN_OUTCOME=success GH_TOKEN=pipe GITHUB_TOKEN_FOR_LABELS=x bash "$SCRIPTS_DIR/after-plan.sh" > /dev/null 2>&1)
assert_eq "画面案の印" "ai:mocks" "$(labels_of 3)"


echo "== ai:skip が付いた Issue（オーナー以外が作った物）は、失敗してもやり直しに回さず、結果も使わない"
init_state '{"labels":{"3":["ai:plan","ai:skip"]}}'
(cd "$work" && rm -f plan-result.txt && ISSUE=3 PLAN_OUTCOME=failure GITHUB_TOKEN_FOR_LABELS=x bash "$SCRIPTS_DIR/after-plan.sh" > /dev/null 2>&1)
assert_eq "ai:retry を付けず、ai:plan を外す" "ai:skip" "$(labels_of 3)"
init_state '{"labels":{"3":["ai:plan","ai:skip"]}}'
run_plan "READY" > /dev/null
assert_eq "清書できていても、実装に回さない" "ai:skip" "$(labels_of 3)"

echo "== 企画AIが PARALLEL と言っても、企画の間に始まった作業と触るファイルが重なるなら、順番待ちにする"
touch_state() { # この Issue の印 進行中の Issue の印
  init_state '{"labels":{"3":["ai:plan"],"8":["ai:implement"]},"issues_meta":{"3":{"body":"本文\n<!-- ai-touches: '"$1"' -->"},"8":{"body":"本文\n<!-- ai-touches: '"$2"' -->"}}}'
}
touch_state "src/lib/a.ts, docs/spec.md" "src/lib/a.ts"
out=$(run_plan "READY")
assert_eq "重なるので順番待ち" "ai:queue" "$(labels_of 3)"
assert_contains "理由をログに出す" "$out" "触るファイルが重なるので、待ちます"
touch_state "src/lib/a.ts" "src/lib/b.ts"
run_plan "READY" > /dev/null
assert_eq "重ならなければ、今までどおり並列で実装へ" "ai:implement" "$(labels_of 3)"
init_state '{"labels":{"3":["ai:plan"],"8":["ai:implement"]},"issues_meta":{"3":{"body":"本文\n<!-- ai-touches: src/lib/a.ts -->"}}}'
run_plan "READY" > /dev/null
assert_eq "進行中の物に印が無ければ、今までどおり企画AIの判断" "ai:implement" "$(labels_of 3)"

echo "== 作業回数の上限に届いた企画：ワークフローが上限を増やしてやり直しても、また届いたら、やり直さず人間に回す"
turns_file="$MOCK_DIR/turns.json"; printf '%s' '[{"type":"result","subtype":"error_max_turns","result":""}]' > "$turns_file"
other_file="$MOCK_DIR/other.json"; printf '%s' '[{"type":"result","subtype":"error_during_execution","result":""}]' > "$other_file"
limit_file="$MOCK_DIR/limit.json"; printf '%s' '[{"type":"result","subtype":"error_max_turns","result":"Claude usage limit reached|1900000000"}]' > "$limit_file"
run_failed() { # 上限を増やしてやり直したか（true／false／空） 実行記録
  (cd "$work" && rm -f plan-result.txt && ISSUE=3 PLAN_OUTCOME=failure PLAN_TURNS_RAISED="$1" EXECUTION_FILE="$2" GITHUB_TOKEN_FOR_LABELS=x bash "$SCRIPTS_DIR/after-plan.sh" 2>&1)
}
init_state '{"labels":{"3":["ai:plan"]}}'
run_failed true "$turns_file" > /dev/null
assert_eq "人間に回す（ai:plan は外す。やり直し待ちにしない）" "ai:stuck" "$(labels_of 3)"
assert_contains "理由を書く" "$(comments_of 3)" "作業回数の上限を増やしてやり直しても、また上限に届きました"
assert_contains "次にすることを書く" "$(comments_of 3)" "Issue を小さく分けるか"
assert_not_contains "やり直しの記録は作らない" "$(comments_of 3)" "auto-retry"

echo "== 上限を増やしたやり直しをしていない（古いワークフロー・結果ファイルがあった）ときは、今までどおり1回やり直す"
for raised in false ""; do
  init_state '{"labels":{"3":["ai:plan"]}}'
  run_failed "$raised" "$turns_file" > /dev/null
  assert_eq "やり直し待ち（raised=${raised:-空}）" "ai:plan,ai:retry" "$(labels_of 3)"
done

echo "== 上限を増やしたやり直しが、別の理由（エラー・使用量の上限）で終わったときは、今までどおりやり直す"
init_state '{"labels":{"3":["ai:plan"]}}'
run_failed true "$other_file" > /dev/null
assert_eq "エラー：やり直し待ち" "ai:plan,ai:retry" "$(labels_of 3)"
init_state '{"labels":{"3":["ai:plan"]}}'
run_failed true "$limit_file" > /dev/null
assert_eq "使用量の上限：待つ（人間に回さない）" "ai:plan,ai:retry" "$(labels_of 3)"
assert_contains "上限の待ちとして記録する" "$(comments_of 3)" "limit-until=1900000000"

echo "== 上限を増やしたやり直しで清書できたら、いつもどおり実装へ"
init_state '{"labels":{"3":["ai:plan"]}}'
(cd "$work" && printf '%s\n%s\n' "READY" PARALLEL > plan-result.txt && ISSUE=3 PLAN_OUTCOME=success PLAN_TURNS_RAISED=true EXECUTION_FILE="$turns_file" GITHUB_TOKEN_FOR_LABELS=x bash "$SCRIPTS_DIR/after-plan.sh" > /dev/null 2>&1)
assert_eq "ai:implement" "ai:implement" "$(labels_of 3)"

finish
