#!/usr/bin/env bash
# AIがエラーで終わったときの分け方（handle_ai_failure・retry_ai_failure）：
#   使用量の上限は、途中に拒否された操作があっても、待ってやり直す（許可の不足として人間に回さない）
#   作業回数の上限（--max-turns）が続くときは、10回やり直さずに人間に回す
#   修正AI・レビューAIも、実行記録があれば同じように見分ける
source "$(dirname "$0")/lib.sh"
setup_mock
export GITHUB_SERVER_URL=https://github.com GITHUB_RUN_ID=1
cd "$SCRIPTS_DIR/../.." || exit 1
write() { printf '%s' "$2" > "$MOCK_DIR/$1.json"; }
write limit_denied '[{"type":"result","subtype":"success","result":"Claude AI usage limit reached|1761000000","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"git rebase main"}}]}]'
write denied '[{"type":"result","subtype":"error_during_execution","result":"","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"git rebase main"}}]}]'
write turns '[{"type":"result","subtype":"error_max_turns","result":""}]'
write turns_denied '[{"type":"result","subtype":"error_max_turns","result":"","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"cat >> src/a.test.ts <<EOF"}}]}]'
write limit '[{"type":"result","subtype":"success","result":"Claude AI usage limit reached|1761000000"}]'
set_count() { state_py "
import re
for c in s['comments']:
    if 'auto-retry' in c['body']: c['body']=re.sub(r'count=[0-9]+ kind=','count=$1 kind=',c['body'])"; }

echo "== 使用量の上限＋拒否された操作：上限として待つ（人間に回さない）"
init_state '{"labels":{"7":["ai:implement"]}}'
run_lib "handle_ai_failure 7 implement '実装AIが止まりました' '$MOCK_DIR/limit_denied.json'" > /dev/null
assert_eq "ai:retry で待つ" "ai:implement,ai:retry" "$(labels_of 7)"
assert_contains "リセット時刻を記録" "$(comments_of 7)" "limit-until=1761000000"

echo "== 拒否された操作だけ（上限ではない）：今までどおり、足りない許可を書いて人間に回す"
init_state '{"labels":{"7":["ai:implement"]}}'
run_lib "handle_ai_failure 7 implement '実装AIが止まりました' '$MOCK_DIR/denied.json'" > /dev/null
assert_contains "人間に回す" "$(labels_of 7)" "ai:stuck"
assert_contains "足りない許可を書く" "$(comments_of 7)" "Bash(git rebase:*)"

echo "== 作業回数の上限：1回はやり直す。やり直しても同じなら、人間に回す（10回は繰り返さない）"
init_state '{"labels":{"7":["ai:implement"]}}'
run_lib "handle_ai_failure 7 implement '実装AIが止まりました' '$MOCK_DIR/turns.json'" > /dev/null
assert_eq "1回目は大きい作業にしてやり直し待ち" "ai:implement,ai:retry,size:L" "$(labels_of 7)"
set_count 1
state_py "s['labels']['7']=['ai:implement']"
run_lib "handle_ai_failure 7 implement '実装AIが止まりました' '$MOCK_DIR/turns.json'" > /dev/null
assert_contains "2回目は人間に回す" "$(labels_of 7)" "ai:stuck"
assert_not_contains "やり直し待ちにしない" "$(labels_of 7)" "ai:retry"
assert_contains "理由を書く" "$(comments_of 7)" "また作業回数の上限に届きました"
assert_contains "次にすることを書く" "$(comments_of 7)" "size:L"

echo "== 作業回数の上限＋途中で断られた操作：許可不足として止めない。大きい作業（size:L）にしてやり直す（agent-desk #658）"
init_state '{"labels":{"7":["ai:implement"]}}'
run_lib "handle_ai_failure 7 implement '実装AIが止まりました' '$MOCK_DIR/turns_denied.json'" > /dev/null
assert_not_contains "人間に回さない" "$(labels_of 7)" "ai:stuck"
assert_contains "やり直し待ち" "$(labels_of 7)" "ai:retry"
assert_contains "size:L にする" "$(labels_of 7)" "size:L"
assert_contains "理由は手数" "$(comments_of 7)" "作業回数の上限（--max-turns。途中で断られた操作：1件）"
assert_not_contains "許可不足と書かない" "$(comments_of 7)" "許可不足"
init_state '{"labels":{"7":["ai:implement","size:S"]}}'
run_lib "handle_ai_failure 7 implement '実装AIが止まりました' '$MOCK_DIR/turns.json'" > /dev/null
assert_eq "size:S は外して size:L" "ai:implement,ai:retry,size:L" "$(labels_of 7)"
init_state '{"labels":{"7":["ai:plan"]}}'
run_lib "handle_ai_failure 7 plan '企画AIが止まりました' '$MOCK_DIR/turns.json'" > /dev/null
assert_not_contains "企画AIはサイズを変えない" "$(labels_of 7)" "size:L"

echo "== 企画AIの作業回数の上限が続く：ai:plan を外して人間に回す"
init_state '{"labels":{"7":["ai:plan"]}}'
run_lib "mark_for_retry 7 plan 'x'" > /dev/null
set_count 1
state_py "s['labels']['7']=['ai:plan']"
run_lib "handle_ai_failure 7 plan '企画AIが止まりました' '$MOCK_DIR/turns.json'" > /dev/null
assert_eq "ai:plan を外して ai:stuck" "ai:stuck" "$(labels_of 7)"

pr58='{"number":58,"state":"open","body":"Closes #5","head":{"sha":"abc","ref":"claude/issue-5-x"},"updated_at":"2026-01-01T00:00:00Z"}'
request() { echo '{"id":900,"issue":"58","user":{"login":"pipeline[bot]"},"created_at":"'"$(ago 1)"'","updated_at":"'"$(ago 1)"'","body":"@claude 直してください\n\n<!-- auto-fix -->\n<!-- auto-fix-sha: abc -->"}'; }

echo "== 修正AIが使用量の上限で終わった：リセットまで待つ（やり直しの回数を使わない）"
init_state '{"labels":{"58":[],"5":[]},"pulls":['"$pr58"'],"comments":['"$(request)"']}'
RUN_STARTED="$(ago 0)" CONCLUSION=failure EXECUTION_FILE="$MOCK_DIR/limit.json" run_script after-mention.sh > /dev/null
assert_contains "やり直し待ち" "$(labels_of 58)" "ai:retry"
assert_contains "リセット時刻を記録" "$(comments_of 58)" "limit-until=1761000000"
assert_contains "回数は0のまま" "$(comments_of 58)" "count=0 kind=mention"

echo "== 修正AIがエラーで終わった（実行記録なし）：今までどおり、やり直し待ち"
init_state '{"labels":{"58":[],"5":[]},"pulls":['"$pr58"'],"comments":['"$(request)"']}'
RUN_STARTED="$(ago 0)" CONCLUSION=failure run_script after-mention.sh > /dev/null
assert_contains "やり直し待ち" "$(labels_of 58)" "ai:retry"
assert_not_contains "上限の印は無い" "$(comments_of 58)" "limit-until"

echo "== レビューAIが使用量の上限で終わった（実行記録が渡されているとき）：リセットまで待つ"
init_state '{"labels":{"58":["ai:review"],"5":[]},"pulls":['"$pr58"']}'
CONCLUSION=failure HEAD_SHA=abc HEAD_BRANCH=claude/issue-5-x EXECUTION_FILE="$MOCK_DIR/limit.json" run_script after-review.sh > /dev/null
assert_contains "やり直し待ち" "$(labels_of 58)" "ai:retry"
assert_contains "リセット時刻を記録" "$(comments_of 58)" "limit-until=1761000000"
init_state '{"labels":{"58":["ai:review"],"5":[]},"pulls":['"$pr58"']}'
CONCLUSION=failure HEAD_SHA=abc HEAD_BRANCH=claude/issue-5-x run_script after-review.sh > /dev/null
assert_contains "実行記録が無ければ、今までどおりやり直し待ち" "$(comments_of 58)" "kind=review"
assert_not_contains "上限の印は無い" "$(comments_of 58)" "limit-until"


echo "== 最初の失敗の記録：「AIが止まった」と理由を書く（人間が再開したときの「回数を0に戻しました」にしない）"
init_state '{"labels":{"7":["ai:implement"]}}'
run_lib "mark_for_retry 7 implement '実装AIが途中で止まりました'" > /dev/null
assert_contains "止まったと書く" "$(comments_of 7)" "AIが止まったので、時間をおいて自動でやり直します"
assert_contains "理由の行が残る（やり直しのとき引き継ぐ）" "$(comments_of 7)" "理由：実装AIが途中で止まりました"
assert_not_contains "再開の文にしない" "$(comments_of 7)" "回数を0に戻しました"

echo "== レビューのワークフロー自体を変えるPR：レビューAIは動けないので、やり直さず、人間のマージ待ちにする"
init_state '{"labels":{"58":["ai:review"],"5":[]},"files":[".github/workflows/claude-review.yml","docs/pipeline.md"],"pulls":['"$pr58"']}'
CONCLUSION=success HEAD_SHA=abc HEAD_BRANCH=claude/issue-5-x run_script after-review.sh > /dev/null
assert_contains "ai:hold にする" "$(labels_of 58)" "ai:hold"
assert_not_contains "やり直し待ちにしない" "$(labels_of 58)" "ai:retry"
assert_not_contains "止まった扱いにもしない" "$(labels_of 58)" "ai:stuck"
assert_contains "理由を書く" "$(comments_of 58)" "レビューAIは動けません"
assert_contains "見張り役が読む印を残す" "$(comments_of 58)" "<!-- review-unavailable: abc -->"
init_state '{"labels":{"58":["ai:review"],"5":[]},"files":["src/a.ts"],"pulls":['"$pr58"']}'
CONCLUSION=success HEAD_SHA=abc HEAD_BRANCH=claude/issue-5-x run_script after-review.sh > /dev/null
assert_contains "ふつうのPRで結果が無ければ、今までどおりやり直し待ち" "$(labels_of 58)" "ai:retry"

finish
