#!/usr/bin/env bash
# AIの実行の結果をログと Summary に出す（ai-report.sh）：拒否された操作と、AIが最後に言ったこと
source "$(dirname "$0")/lib.sh"
setup_mock
f="$MOCK_DIR/e.json"; sum="$MOCK_DIR/summary.md"
report() { : > "$sum"; GITHUB_STEP_SUMMARY="$sum" RUNNER_TEMP="$MOCK_DIR" bash "$SCRIPTS_DIR/ai-report.sh" "$@" 2>&1; }

echo "== 拒否と最後の言葉を、ログと Summary の両方に出す"
printf '%s' '[{"type":"system"},{"type":"result","subtype":"success","num_turns":13,"permission_denials_count":2,"result":"書けませんでした。\n理由は `ls` が使えないからです。","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"ls mocks/"}},{"tool_name":"Bash","tool_input":{"command":"cat `x`"}}]}]' > "$f"
out=$(report --title "画面案" "$f"); rc=$?
assert_eq "終了コード 0" "0" "$rc"
assert_contains "見出し" "$out" "### 画面案"
assert_contains "結果・手数・拒否の数" "$out" "結果：success（手数 13・拒否 2 件）"
assert_contains "拒否された操作" "$out" 'Bash(ls mocks/)'
assert_contains "最後の言葉は1行に" "$out" "書けませんでした。 理由は"
assert_eq "Summary にも同じ物" "$out" "$(cat "$sum")"

echo "== 拒否が無ければ、拒否の行は出さない"
printf '%s' '{"type":"result","subtype":"error_max_turns","num_turns":60,"result":""}' > "$f"
out=$(report "$f")
assert_contains "結果" "$out" "結果：error_max_turns（手数 60・拒否 0 件）"
assert_not_contains "拒否の行なし" "$out" "拒否された操作"
assert_not_contains "最後の言葉なし" "$out" "最後に言ったこと"

echo "== ファイルが無い・壊れていても止めない"
out=$(report "$MOCK_DIR/none.json"); rc=$?
assert_eq "終了コード 0" "0" "$rc"
assert_contains "無いと知らせる" "$out" "実行記録がありません"
printf 'こわれた' > "$f"
out=$(report "$f"); rc=$?
assert_eq "壊れていても 0" "0" "$rc"

finish
