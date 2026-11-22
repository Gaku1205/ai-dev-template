#!/usr/bin/env bash
# 見張り役のラベルの矛盾の修正：組み合わせごとに直る／矛盾が無ければ何もしない／20件まで／閉じた物は直近7日だけ
source "$(dirname "$0")/lib.sh"
setup_mock

recent=$(ago 60)
old=$(ago $((10 * 24 * 60)))

echo "== ai:queue と ai:implement"
init_state '{"labels":{"1":["ai:queue","ai:implement"]}}'
run_script watchdog.sh > /dev/null
assert_eq "ai:queue が外れる" "ai:implement" "$(labels_of 1)"
assert_contains "1行コメントが付く" "$(comments_of 1)" "ai:queue を外しました"

echo "== ai:plan と ai:implement"
init_state '{"labels":{"2":["ai:plan","ai:implement"]}}'
run_script watchdog.sh > /dev/null
assert_eq "ai:plan が外れる" "ai:implement" "$(labels_of 2)"
assert_contains "コメントが付く" "$(comments_of 2)" "ai:plan を外しました"

echo "== 記録の無い ai:retry"
init_state '{"labels":{"3":["ai:retry"]}}'
: > "$MOCK_DIR/curl.log"
run_script watchdog.sh > /dev/null
assert_eq "ai:retry が外れて ai:stuck になる" "ai:stuck" "$(labels_of 3)"
assert_contains "コメントが付く" "$(comments_of 3)" "ai:stuck にしました"
assert_contains "ラベルの矛盾を直した趣旨を残す" "$(comments_of 3)" "見張り役がラベルの矛盾を直しました"
assert_eq "コメントは1つだけ" "1" "$(comments_of 3 | grep -c '自動で進めるのを止めました')"
assert_eq "通知が1回" "1" "$(notify_count)"

echo "== 記録のある ai:retry は触らない"
init_state '{"labels":{"4":["ai:retry"]},"comments":[{"id":1,"body":"x\n<!-- auto-retry -->\n<!-- count=1 kind=plan -->","user":{"login":"github-actions[bot]"},"created_at":"'"$(ago 1)"'","updated_at":"'"$(ago 1)"'","issue":"4"}],"next_id":1}'
run_script watchdog.sh > /dev/null
assert_eq "ラベルはそのまま" "ai:retry" "$(labels_of 4)"
assert_not_contains "コメントを足さない" "$(comments_of 4)" "見張り役がラベルの矛盾"

echo "== 閉じた物（直近7日）"
init_state '{"labels":{"5":["ai:stuck","ai:retry","ai:queue","size:S"],"6":["ai:stuck"]},"issues_meta":{"5":{"state":"closed","closed_at":"'"$recent"'"},"6":{"state":"closed","closed_at":"'"$old"'"}}}'
run_script watchdog.sh > /dev/null
assert_eq "直近に閉じた物は外れる" "size:S" "$(labels_of 5)"
assert_contains "コメントが付く" "$(comments_of 5)" "閉じているのに"
assert_eq "7日より前に閉じた物は触らない" "ai:stuck" "$(labels_of 6)"
assert_eq "古い物にコメントしない" "" "$(comments_of 6)"

echo "== 閉じた Issue に残った ai:implement も外れる（古い物は触らない）"
init_state '{"labels":{"5":["ai:implement","size:S"],"6":["ai:implement"]},"issues_meta":{"5":{"state":"closed","closed_at":"'"$recent"'"},"6":{"state":"closed","closed_at":"'"$old"'"}}}'
run_script watchdog.sh > /dev/null
assert_eq "直近に閉じた物から外れる" "size:S" "$(labels_of 5)"
assert_eq "7日より前に閉じた物は触らない" "ai:implement" "$(labels_of 6)"

echo "== 閉じた理由が completed で ai:implement だけ残った Issue は、コメント無しで外す"
init_state '{"labels":{"5":["ai:implement","size:S"],"6":["ai:implement","ai:stuck"],"7":["ai:implement"]},"issues_meta":{"5":{"state":"closed","closed_at":"'"$recent"'","state_reason":"completed"},"6":{"state":"closed","closed_at":"'"$recent"'","state_reason":"completed"},"7":{"state":"closed","closed_at":"'"$recent"'","state_reason":"not_planned"}}}'
run_script watchdog.sh > /dev/null
assert_eq "ai:implement が外れる" "size:S" "$(labels_of 5)"
assert_eq "コメントしない" "" "$(comments_of 5)"
assert_eq "ai:stuck も残っているときは両方外れる" "" "$(labels_of 6)"
assert_contains "ほかのラベルが残っていたら今までどおりコメントする" "$(comments_of 6)" "閉じているのに"
assert_eq "completed 以外の理由は今までどおり外れる" "" "$(labels_of 7)"
assert_contains "completed 以外はコメントする" "$(comments_of 7)" "閉じているのに"

echo "== 閉じた Issue に残った ai:plan・ai:question も外れる（古い物は触らない）"
init_state '{"labels":{"5":["ai:plan","size:S"],"6":["ai:question"],"7":["ai:question"]},"issues_meta":{"5":{"state":"closed","closed_at":"'"$recent"'"},"6":{"state":"closed","closed_at":"'"$recent"'"},"7":{"state":"closed","closed_at":"'"$old"'"}}}'
run_script watchdog.sh > /dev/null
assert_eq "直近に閉じた物の ai:plan が外れる" "size:S" "$(labels_of 5)"
assert_contains "コメントが付く" "$(comments_of 5)" "ai:plan"
assert_eq "直近に閉じた物の ai:question が外れる" "" "$(labels_of 6)"
assert_eq "7日より前に閉じた物の ai:question は触らない" "ai:question" "$(labels_of 7)"

echo "== 矛盾が無いとき"
init_state '{"labels":{"7":["ai:implement"],"8":["ai:queue"],"9":["ai:stuck"]}}'
run_script watchdog.sh > /dev/null
assert_eq "7 のラベル" "ai:implement" "$(labels_of 7)"
assert_eq "8 のラベル" "ai:queue" "$(labels_of 8)"
assert_eq "9 のラベル" "ai:stuck" "$(labels_of 9)"
assert_not_contains "コメントしない" "$(comments_of 7)$(comments_of 8)$(comments_of 9)" "見張り役がラベルの矛盾"

echo "== 1回に直すのは20件まで"
state_py "s['labels']={str(i):['ai:queue','ai:implement'] for i in range(1,26)}"
run_script watchdog.sh > /dev/null
left=$(python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print(sum(1 for l in s['labels'].values() if 'ai:queue' in l))")
assert_eq "5件が残る" "5" "$left"

finish
