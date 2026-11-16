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

echo "== 使った量（トークン）が実行記録にあれば出す。無ければ行ごと出さない"
printf '%s' '{"type":"result","subtype":"success","num_turns":5,"result":"","usage":{"input_tokens":1200,"cache_creation_input_tokens":300,"cache_read_input_tokens":90000,"output_tokens":4500}}' > "$f"
out=$(report "$f")
assert_contains "入力・キャッシュ・出力" "$out" "使った量：入力 1500・キャッシュから 90000・出力 4500 トークン"
printf '%s' '{"type":"result","subtype":"success","num_turns":5,"result":""}' > "$f"
assert_not_contains "無ければ出さない" "$(report "$f")" "使った量"

echo "== push が失敗したら、GitHub の返事を出す（原因を追えるように）"
cat > "$f" <<'JSON'
[{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","input":{"command":"git push -u origin claude/issue-1-x"}},{"type":"tool_use","id":"t2","input":{"command":"npm run build"}}]}},
 {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"error TS2304 (ビルドの物は出さない)"},{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":[{"type":"text","text":"To https://github.com/o/r\n ! [remote rejected] HEAD -> claude/issue-1-x (refusing to allow a GitHub App to create or update workflow `.github/workflows/ci.yml` without `workflows` permission)\nerror: failed to push some refs"}]}]}},
 {"type":"result","subtype":"success","num_turns":3,"result":"push できませんでした"}]
JSON
out=$(report "$f")
assert_contains "push の失敗の行" "$out" "push の失敗："
assert_contains "GitHub の理由" "$out" "without \`workflows\` permission"
assert_not_contains "ほかのコマンドの失敗は出さない" "$out" "TS2304"
printf '%s' '{"type":"result","subtype":"success","num_turns":5,"result":""}' > "$f"
assert_not_contains "push が無ければ出さない" "$(report "$f")" "push の失敗"

echo "== ファイルが無い・壊れていても止めない"
out=$(report "$MOCK_DIR/none.json"); rc=$?
assert_eq "終了コード 0" "0" "$rc"
assert_contains "無いと知らせる" "$out" "実行記録がありません"
printf 'こわれた' > "$f"
out=$(report "$f"); rc=$?
assert_eq "壊れていても 0" "0" "$rc"

finish
