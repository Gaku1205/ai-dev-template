#!/usr/bin/env bash
# 実装AIのあと（open-pr.sh）：AIが正常に終わったのに変更が無いとき、理由を書かずに止めない
source "$(dirname "$0")/lib.sh"
setup_mock
exec_file="$MOCK_DIR/execution.json"
run_open() { ISSUE=7 ISSUE_TITLE="題" AI_OUTCOME="${1:-success}" EXECUTION_FILE="$exec_file" GITHUB_RUN_ID=99 run_script open-pr.sh; }
denied='[{"type":"result","subtype":"success","result":"テストを動かせず、作業を終えました。","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"chmod +x .github/scripts/tests/test-x.sh"}},{"tool_name":"Bash","tool_input":{"command":"bash .github/scripts/tests/test-x.sh 2>&1"}}]}]'
clean='[{"type":"result","subtype":"success","result":"この作業は docs/pipeline.md の形式が決まるまで始められません。","permission_denials":[]}]'

echo "== 拒否があって変更が無い：拒否された操作を書いて、1回だけ実装をやり直す（人間に回さない）"
init_state '{"labels":{"7":["ai:implement"]}}'
printf '%s' "$denied" > "$exec_file"
run_open > /dev/null
c=$(comments_of 7)
assert_eq "ai:implement を付け直す（ai:stuck にしない）" "ai:implement" "$(labels_of 7)"
assert_contains "拒否された操作を書く" "$c" "Bash(chmod +x .github/scripts/tests/test-x.sh)"
assert_contains "AIの最後の言葉を書く" "$c" "テストを動かせず、作業を終えました。"
assert_contains "やり直しの印" "$c" "<!-- auto-perm-retry -->"
assert_contains "ログのURL" "$c" "actions/runs/99"
assert_eq "通知しない" "0" "$(notify_count)"

echo "== やり直しても同じ：足りない許可を書いて人間に回す（3回目は無い）"
run_open > /dev/null
c=$(comments_of 7)
assert_contains "ai:stuck" "$(labels_of 7)" "ai:stuck"
assert_contains "理由を書く" "$c" "1回自動でやり直しても"
assert_eq "やり直しの印は1つのまま" "1" "$(printf '%s' "$c" | grep -c 'auto-perm-retry')"
assert_eq "通知する" "1" "$(notify_count)"

echo "== 人間が再開（auto-resume）したあとは、また1回やり直せる"
state_py "
s['labels']['7']=['ai:implement']
for c in s['comments']: c['created_at']='2026-01-01T00:00:00Z'
s['next_id']+=1
s['comments'].append({'id':s['next_id'],'issue':'7','body':'▶ 再開\n<!-- auto-resume -->','user':{'login':'x'},'created_at':'2026-01-02T00:00:00Z','updated_at':'2026-01-02T00:00:00Z'})"
run_open > /dev/null
assert_eq "やり直す" "ai:implement" "$(labels_of 7)"
assert_eq "やり直しの印が2つ" "2" "$(comments_of 7 | grep -c 'auto-perm-retry')"

echo "== 拒否が無くて変更が無い：AIが最後に言ったことを書いて人間に回す（黙って止めない）"
init_state '{"labels":{"7":["ai:implement"]}}'
: > "$MOCK_DIR/curl.log"
printf '%s' "$clean" > "$exec_file"
run_open > /dev/null
c=$(comments_of 7)
assert_contains "ai:stuck" "$(labels_of 7)" "ai:stuck"
assert_contains "AIの最後の言葉" "$c" "形式が決まるまで始められません"
assert_contains "拒否は無いと書く" "$c" "拒否された操作はありません"
assert_not_contains "やり直さない" "$c" "auto-perm-retry"

echo "== 実行記録が無くても、理由のコメントは残す"
init_state '{"labels":{"7":["ai:implement"]}}'
rm -f "$exec_file"
run_open > /dev/null
assert_contains "コメントがある" "$(comments_of 7)" "変更が作られませんでした"
assert_contains "記録が無いと書く" "$(comments_of 7)" "実行記録にありません"

echo "== AIがエラーで終わって変更が無い：今までどおり、自動のやり直し待ち"
init_state '{"labels":{"7":["ai:implement"]}}'
run_open failure > /dev/null
assert_contains "ai:retry" "$(labels_of 7)" "ai:retry"

echo "== 実装AIが「すでに直っている」と確かめて終わった：人間に回さず、確かめた中身を残して閉じる（tochi-rirekisho #9）"
init_state '{"labels":{"7":["ai:implement"]},"issues_meta":{"7":{"title":"t","state":"open"}}}'
printf '%s' '[{"type":"result","subtype":"success","result":"このブランチでは既に直っていたため、コードは変えていません。コミット 5ec18d9 で対応済み。","permission_denials":[]}]' > "$exec_file"
run_open > /dev/null
assert_eq "閉じる" "closed" "$(python3 -c "import json,os;print(json.load(open(os.environ['MOCK_STATE']))['issues_meta']['7']['state'])")"
assert_not_contains "人間に回さない" "$(labels_of 7)" "ai:stuck"
assert_not_contains "ai:implement を外す" "$(labels_of 7)" "ai:implement"
assert_contains "理由と開き直し方" "$(comments_of 7)" "開き直してください"
assert_contains "AIの言葉を残す" "$(comments_of 7)" "5ec18d9"

echo "== 拒否があっても、すでに直っていると確かめたなら閉じる（やり直しを使わない）"
init_state '{"labels":{"7":["ai:implement"]},"issues_meta":{"7":{"title":"t","state":"open"}}}'
printf '%s' '[{"type":"result","subtype":"success","result":"The fix is already on this branch, so I made no code changes.","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"npx vitest run"}}]}]' > "$exec_file"
run_open > /dev/null
assert_eq "閉じる" "closed" "$(python3 -c "import json,os;print(json.load(open(os.environ['MOCK_STATE']))['issues_meta']['7']['state'])")"
assert_not_contains "やり直しの印を付けない" "$(comments_of 7)" "auto-perm-retry"

echo "== 直せなかった、は閉じない（今までどおり人間に回す）"
init_state '{"labels":{"7":["ai:implement"]},"issues_meta":{"7":{"title":"t","state":"open"}}}'
printf '%s' '[{"type":"result","subtype":"success","result":"原因が分からず、直せませんでした。","permission_denials":[]}]' > "$exec_file"
run_open > /dev/null
assert_eq "開いたまま" "open" "$(python3 -c "import json,os;print(json.load(open(os.environ['MOCK_STATE']))['issues_meta']['7']['state'])")"
assert_contains "人間に回す" "$(labels_of 7)" "ai:stuck"

echo "== 一部だけ直っている・直せなかった返事は、「すでに」があっても閉じない"
for msg in \
  '一部はすでに直っていましたが、残りの保存処理は原因が分からず直せませんでした。' \
  '既にmainに入っている変更とコンフリクトしたため、直せませんでした。' \
  'The list page was already fixed in main, but the detail page still fails and I could not fix it.'; do
  init_state '{"labels":{"7":["ai:implement"]},"issues_meta":{"7":{"title":"t","state":"open"}}}'
  printf '[{"type":"result","subtype":"success","result":"%s","permission_denials":[]}]' "$msg" > "$exec_file"
  run_open > /dev/null
  assert_eq "開いたまま" "open" "$(python3 -c "import json,os;print(json.load(open(os.environ['MOCK_STATE']))['issues_meta']['7']['state'])")"
  assert_contains "人間に回す" "$(labels_of 7)" "ai:stuck"
done

finish
