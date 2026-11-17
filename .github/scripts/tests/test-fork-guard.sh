#!/usr/bin/env bash
# 見張り役：fork からの他人のPR・他人が作った Issue には、何もしない
source "$(dirname "$0")/lib.sh"
setup_mock

pr_of() { # 番号 ブランチ headのリポジトリ 何分前に更新
  echo '{"number":'"$1"',"state":"open","mergeable_state":"dirty","body":"Closes #5","head":{"sha":"abc123","ref":"'"$2"'","repo":{"full_name":"'"$3"'"}},"labels":[],"updated_at":"'"$(ago "$4")"'"}'
}
state_field() { python3 -c "import json,os;print(len(json.load(open(os.environ['MOCK_STATE'])).get('$1',[])))"; }
waiting_ci='[{"id":1,"name":"CI","conclusion":"action_required","created_at":"2026-01-01T00:00:00Z"}]'

echo "== fork のPR（CI が承認待ち・同じ名前のブランチ）：空コミットも push もしない"
for ref in main claude/issue-5-x; do
  init_state '{"labels":{"70":[]},"pulls":['"$(pr_of 70 "$ref" evil/r 10)"'],"runs":'"$waiting_ci"'}'
  run_script watchdog.sh > /dev/null
  assert_eq "空コミットを作らない（$ref）" "0" "$(state_field new_commits)"
  assert_eq "ブランチを動かさない（$ref）" "0" "$(state_field ref_updates)"
done

echo "== fork のPR（main とコンフリクト・CI なし）：修正の依頼を出さない"
init_state '{"labels":{"71":[]},"pulls":['"$(pr_of 71 feature evil/r 10)"']}'
run_script watchdog.sh > /dev/null
assert_eq "コメントが付かない" "" "$(comments_of 71)"
assert_eq "ラベルも付かない" "" "$(labels_of 71)"

echo "== head のリポジトリが読めない（fork が削除された）PR も、何もしない"
init_state '{"labels":{"72":[]},"pulls":['"$(pr_of 72 feature evil/r 10 | sed 's#"repo":{"full_name":"evil/r"}#"repo":null#')"']}'
run_script watchdog.sh > /dev/null
assert_eq "コメントが付かない" "" "$(comments_of 72)"

echo "== このリポジトリのPR（承認待ち）：今までどおり空コミットで動かし直す"
init_state '{"labels":{"73":[]},"pulls":['"$(pr_of 73 claude/issue-5-y o/r 10)"'],"runs":'"$waiting_ci"'}'
run_script watchdog.sh > /dev/null
assert_eq "空コミットを作る" "1" "$(state_field new_commits)"
assert_eq "ブランチを動かす" "1" "$(state_field ref_updates)"

echo "== rerun_ci_if_waiting_approval を直接呼んでも、fork のPRには何もしない"
init_state '{"labels":{"74":[]},"pulls":['"$(pr_of 74 main evil/r 10)"'],"runs":'"$waiting_ci"'}'
run_lib 'rerun_ci_if_waiting_approval 74 abc123 main' > /dev/null
assert_eq "空コミットを作らない" "0" "$(state_field new_commits)"
assert_eq "ブランチを動かさない" "0" "$(state_field ref_updates)"

echo "== 他人が作った Issue（ai:retry）：ai:plan を付け直さず、ai:skip で止める"
retry_issue() { # 番号 作者
  init_state '{"labels":{"80":["ai:plan"]},"authors":{"80":"'"$2"'"}}'
  run_lib 'write_retry_record 80 1 plan "AIのエラー" "" ""; add_label 80 ai:retry' > /dev/null
  age_retry_comments 60
  run_script watchdog.sh > /dev/null
}
retry_issue 80 stranger
assert_contains "ai:skip で止める" "$(labels_of 80)" "ai:skip"
assert_not_contains "ai:retry を外す" "$(labels_of 80)" "ai:retry"
assert_eq "企画のやり直し（記録）が増えない" "1" "$(comments_of 80 | grep -c 'auto-retry')"

echo "== オーナーの Issue：今までどおりやり直す"
retry_issue 80 o
assert_not_contains "ai:skip は付かない" "$(labels_of 80)" "ai:skip"
assert_contains "ai:plan が付いている" "$(labels_of 80)" "ai:plan"
assert_not_contains "ai:retry は外れる" "$(labels_of 80)" "ai:retry"

finish
