#!/usr/bin/env bash
# 見張り役：GitHub の API の読み取りに失敗したとき、空の結果を「正常（0件・ラベル無し・今日の0時から動いていない）」と読まない。
# 読めなければ、その回は飛ばす（次の見張りが改めて見る）
source "$(dirname "$0")/lib.sh"
setup_mock

echo "== 更新時刻を読めない Issue（企画・実装・画面案）：ai:retry を付けない"
for label in ai:plan ai:implement ai:mocks; do
  init_state '{"labels":{"9":["'"$label"'"]},"read_fail":["9"]}'
  out=$(run_script watchdog.sh)
  assert_eq "$label：ラベルは変わらない" "$label" "$(labels_of 9)"
  assert_not_contains "$label：やり直しの記録を書かない" "$(comments_of 9)" "auto-retry"
  assert_contains "$label：読めないとログに出す" "$out" "#9：更新時刻を読めないので、今回は見ません"
done

echo "== 更新時刻が空で返ってきた Issue：同じく飛ばす（date -d \"\" で今日の0時にしない）"
for label in ai:plan ai:implement ai:mocks; do
  init_state '{"labels":{"9":["'"$label"'"]},"issue_updated":{"9":""}}'
  run_script watchdog.sh > /dev/null
  assert_eq "$label：ラベルは変わらない" "$label" "$(labels_of 9)"
done

echo "== 比べ：更新時刻が読めて、時間がたっていれば、今までどおりやり直し待ちにする"
init_state '{"labels":{"9":["ai:plan"]},"issue_updated":{"9":"'"$(ago 50)"'"}}'
run_script watchdog.sh > /dev/null
assert_eq "やり直し待ちになる" "ai:plan,ai:retry" "$(labels_of 9)"

echo "== 実装AIの実行の一覧を読めない：その回は実装の止まりを見ない"
init_state '{"labels":{"9":["ai:implement"]},"issue_updated":{"9":"'"$(ago 50)"'"},"wf_runs_fail":["claude-implement.yml"]}'
out=$(run_script watchdog.sh)
assert_eq "ai:retry を付けない" "ai:implement" "$(labels_of 9)"
assert_contains "読めないとログに出す" "$out" "実装AIの実行の一覧を読めないので"

echo "== 実装AIの実行が始まるのを待っている（queued）：動いているとみなす"
init_state '{"labels":{"9":["ai:implement"]},"issue_updated":{"9":"'"$(ago 50)"'"},"wf_runs":{"claude-implement.yml":[{"status":"queued"}]}}'
out=$(run_script watchdog.sh)
assert_eq "ai:retry を付けない" "ai:implement" "$(labels_of 9)"
assert_contains "動いているとログに出す" "$out" "実装AIの実行が動いている（1 件）"

echo "== ラベルを読めない（ai:stuck・ai:skip が付いている物）：手を出さない"
for label in ai:stuck ai:skip; do
  for work in ai:plan ai:implement ai:mocks; do
    init_state '{"labels":{"9":["'"$work"'","'"$label"'"]},"issue_updated":{"9":"'"$(ago 200)"'"},"read_fail_labels":["9"]}'
    run_script watchdog.sh > /dev/null
    assert_eq "$work＋$label：ai:retry を付けない" "$(printf '%s\n' "$work" "$label" | sort | paste -sd, -)" "$(labels_of 9)"
  done
done

echo "== ラベルを読めない ai:retry の Issue：やり直さず、印も外さない"
init_state '{"labels":{"9":["ai:plan"]}}'
run_lib 'mark_for_retry 9 plan "エラー"' > /dev/null
age_retry_comments 40
state_py "s['labels']['9'].append('ai:skip'); s['read_fail_labels']=['9']"
out=$(run_script watchdog.sh)
assert_eq "ラベルは変わらない" "ai:plan,ai:retry,ai:skip" "$(labels_of 9)"
assert_contains "回数は増えない" "$(comments_of 9)" "count=0 kind=plan"
assert_contains "読めないとログに出す" "$out" "#9：ラベルを読めないので、今回は触りません"

echo "== ラベルを読めないPR（ai:stuck が付いている）：CIが終わって止まっていても、続きを動かさない"
pr='{"number":58,"state":"open","mergeable_state":"clean","body":"Closes #5","head":{"sha":"abc123","ref":"claude/issue-5-x","repo":{"full_name":"o/r"}},"labels":[],"updated_at":"'"$(ago 60)"'"}'
init_state '{"labels":{"58":["ai:stuck"]},"read_fail_labels":["58"],"pulls":['"$pr"'],"runs":[{"id":11,"name":"CI","status":"completed","conclusion":"success","created_at":"2026-01-01T00:00:00Z"}]}'
run_script watchdog.sh > /dev/null
assert_eq "ラベルは変わらない" "ai:stuck" "$(labels_of 58)"
assert_not_contains "続きを動かす印を付けない" "$(comments_of 58)" "auto-nudge"

echo "== CIのあと（after-ci.sh）：ラベルを読めなければ、ai:stuck のPRに手を出さない"
init_state '{"labels":{"58":["ai:stuck"]},"read_fail_labels":["58"],"pulls":['"$pr"']}'
out=$(RUN_ID=1 CONCLUSION=failure HEAD_SHA=abc123 HEAD_BRANCH=claude/issue-5-x run_script after-ci.sh)
assert_eq "ラベルは変わらない" "ai:stuck" "$(labels_of 58)"
assert_not_contains "直す依頼を出さない" "$(comments_of 58)" "auto-fix"
assert_contains "警告を出す" "$out" "ラベルを読めませんでした"

echo "== has_label：付いている 0・付いていない 1・読めない 2 を分ける"
init_state '{"labels":{"9":["ai:plan"],"10":["ai:plan"]},"read_fail_labels":["10"]}'
rc_of() { run_lib "rc=0; $1 || rc=\$?; echo \"rc=\$rc\""; }
assert_contains "付いている" "$(rc_of 'has_label 9 ai:plan')" "rc=0"
assert_contains "付いていない" "$(rc_of 'has_label 9 ai:stuck')" "rc=1"
assert_contains "読めない" "$(rc_of 'has_label 10 ai:stuck')" "rc=2"
assert_contains "読めなければ「付いている」側に倒す" "$(rc_of 'has_label_or_unreadable 10 ai:stuck')" "rc=0"
assert_contains "確かに付いていなければ 1" "$(rc_of 'has_label_or_unreadable 9 ai:stuck')" "rc=1"

finish
