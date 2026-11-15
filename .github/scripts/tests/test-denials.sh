#!/usr/bin/env bash
# denials.sh：AIの実行記録から、拒否された操作を取り出す（拒否あり・なし・ファイル無し／壊れている）
source "$(dirname "$0")/lib.sh"
setup_mock
d="$MOCK_DIR/d"; mkdir -p "$d"
long=$(printf 'x%.0s' $(seq 1 400))

echo '[{"type":"system"},{"type":"result","permission_denials_count":2,"permission_denials":[{"tool_name":"Write","tool_input":{"file_path":"mocks/mock-a.html","content":"'"$long"'"}},{"tool_name":"Bash","tool_input":{"command":"npx playwright test"}}]}]' > "$d/denied.json"
echo '{"type":"result","permission_denials_count":0,"permission_denials":[]}' > "$d/none.json"
echo 'これは JSON ではない' > "$d/broken.json"

echo "== 拒否あり"
t=$(run_script denials.sh "$d/denied.json"); rc=$?
assert_eq "終了コード 0" "0" "$rc"
assert_contains "件数" "$t" "permission_denials_count: 2"
assert_contains "ツール名と引数" "$t" "- Bash: {\"command\":\"npx playwright test\"}"
assert_contains "Write も出る" "$t" "- Write: "
assert_not_contains "長い引数は切り詰める" "$t" "$long"
assert_contains "切り詰めの印" "$t" "…"
s=$(GITHUB_STEP_SUMMARY="$d/summary.md" run_script denials.sh --summary "$d/denied.json")
assert_eq "Summary に追記（標準出力は空）" "" "$s"
assert_contains "Summary の表" "$(cat "$d/summary.md")" "| \`Write\` |"
assert_contains "コメント用の短い文" "$(run_script denials.sh --comment "$d/denied.json")" "拒否されたツール（2件）：Bash、Write"
run_script denials.sh --check "$d/denied.json" > /dev/null
assert_eq "--check：拒否ありは 0" "0" "$?"

echo "== 拒否なし"
assert_eq "何も出さない" "" "$(run_script denials.sh "$d/none.json")"
assert_eq "コメントも空" "" "$(run_script denials.sh --comment "$d/none.json")"
run_script denials.sh --check "$d/none.json" > /dev/null
assert_eq "--check：拒否なしは 1" "1" "$?"

echo "== ファイル無し・壊れている"
for f in "$d/missing.json" "$d/broken.json"; do
  for m in "" --summary --comment; do
    o=$(GITHUB_STEP_SUMMARY="$d/s2.md" run_script denials.sh $m "$f"); rc=$?
    assert_eq "$(basename "$f") $m：何も出さず終了コード 0" "0:" "$rc:$o"
  done
  run_script denials.sh --check "$f" > /dev/null; rc=$?
  assert_eq "$(basename "$f") --check：1" "1" "$rc"
done
[ ! -e "$d/s2.md" ]; assert_eq "Summary を作らない" "0" "$?"

finish
