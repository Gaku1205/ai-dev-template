#!/usr/bin/env bash
# 答えを受け取った後（after-answer.sh）：閉じた Issue に ai:plan を付けない（agent-desk #555）。開いている物と読めなかった物は今まで通り
source "$(dirname "$0")/lib.sh"
setup_mock

echo "== 閉じた Issue にオーナーが答えても、ai:plan を付けない"
init_state '{"labels":{"3":["ai:question"]},"issues_meta":{"3":{"state":"closed"}}}'
LAST_OUT=$(ISSUE=3 GH_TOKEN=pipe GITHUB_TOKEN_FOR_LABELS=x run_script after-answer.sh)
assert_eq "ai:question は外れ、ai:plan は付かない" "" "$(labels_of 3)"
assert_contains "閉じているので清書に戻さないと、ログに残す" "$LAST_OUT" "閉じているので、清書には戻しません"

echo "== 閉じた Issue で、パイプラインの鍵が無いときも ai:plan を付けず、通知もしない"
init_state '{"labels":{"3":["ai:question"]},"issues_meta":{"3":{"state":"closed"}}}'
ISSUE=3 GH_TOKEN= GITHUB_TOKEN_FOR_LABELS=x run_script_keep after-answer.sh > /dev/null
assert_eq "ai:plan は付かない" "" "$(labels_of 3)"
assert_eq "通知も送らない" "0" "$(notify_count)"

echo "== 開いている Issue への答えは、今まで通り ai:plan に戻す"
init_state '{"labels":{"3":["ai:question"]}}'
ISSUE=3 GH_TOKEN=pipe GITHUB_TOKEN_FOR_LABELS=x run_script_keep after-answer.sh > /dev/null
assert_eq "ai:question を外して ai:plan" "ai:plan" "$(labels_of 3)"

echo "== 状態が読めないときは、今まで通り ai:plan を付ける"
init_state '{"labels":{"3":["ai:question"]},"read_fail":["3"]}'
ISSUE=3 GH_TOKEN=pipe GITHUB_TOKEN_FOR_LABELS=x run_script_keep after-answer.sh > /dev/null
assert_eq "読めないときは ai:plan に戻す" "ai:plan" "$(labels_of 3)"

finish
