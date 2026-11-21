#!/usr/bin/env bash
# 見張り役（watchdog.sh の 3.7）：順番待ち（ai:queue・ai:blocked）が、動いていない相手を待っているのを見つけて知らせる
source "$(dirname "$0")/lib.sh"
setup_mock

reason_comment() { # 待つ側の番号 本文 [作った時刻]
  python3 -c "import json,sys;print(json.dumps({'id':int(sys.argv[1])*100,'issue':sys.argv[1],'body':sys.argv[2],'user':{'login':'claude[bot]'},'created_at':sys.argv[3],'updated_at':sys.argv[3]}))" "$1" "$2" "${3:-2026-01-01T00:00:00Z}"
}
# 場面ごとに、前の場面の通知の記録（curl.log）を消す（init_state は消さないので、包む）
lib_init_state_def="$(declare -f init_state)"
eval "lib_${lib_init_state_def}"
init_state() { lib_init_state "$@"; : > "$MOCK_DIR/curl.log"; }
stuck_notes() { grep -c '動いていない相手' "$MOCK_DIR/curl.log" || true; }
wait_comments() { comments_of "$1" | grep -c 'wait-stuck' || true; }

echo "== 相手が ai:implement なのに1時間以上動きが無い：待つ側に1回コメントして、通知する"
init_state '{"labels":{"1":["ai:implement"],"2":["ai:queue"]},"issue_updated":{"1":"'"$(ago 120)"'"},"comments":['"$(reason_comment 2 '順番待ちの理由：進行中の #1 が、同じファイルを書き換えるため。前の作業が終わると自動で始まります。')"']}'
run_script watchdog.sh > /dev/null
assert_eq "待つ側にコメントが1つ" "1" "$(wait_comments 2)"
assert_contains "何を待っているか書く" "$(comments_of 2)" "#1 を待っています"
assert_contains "相手が動いていない理由を書く" "$(comments_of 2)" "Actions の実行もありません"
assert_eq "通知は1回" "1" "$(stuck_notes)"
assert_eq "順番待ちのまま（勝手に動かさない）" "ai:queue" "$(labels_of 2)"

echo "== 同じ組み合わせでは、もう一度動かしても知らせない（1日1回まで）"
run_script watchdog.sh > /dev/null
assert_eq "コメントは1つのまま" "1" "$(wait_comments 2)"
assert_eq "通知は1回のまま" "1" "$(stuck_notes)"

echo "== 24時間たったら、もう一度知らせる"
state_py "
for c in s['comments']:
    if 'wait-stuck' in c['body']: c['created_at'] = '$(ago 1500)'"
run_script watchdog.sh > /dev/null
assert_eq "コメントが2つ" "2" "$(wait_comments 2)"
assert_eq "通知は2回" "2" "$(stuck_notes)"

echo "== 相手が最近動いている（1時間以内）なら、知らせない"
init_state '{"labels":{"1":["ai:implement"],"2":["ai:queue"]},"issue_updated":{"1":"'"$(ago 10)"'"},"comments":['"$(reason_comment 2 '順番待ちの理由：進行中の #1 が、同じファイルを書き換えるため。')"']}'
run_script watchdog.sh > /dev/null
assert_eq "コメントしない" "0" "$(wait_comments 2)"
assert_eq "通知しない" "0" "$(stuck_notes)"

echo "== 相手のブランチの実行が動いている間は、Issue の更新が古くても知らせない"
init_state '{"labels":{"1":["ai:implement"],"2":["ai:queue"]},"issue_updated":{"1":"'"$(ago 120)"'"},"runs":[{"id":5,"name":"Claude Implement","status":"in_progress","head_branch":"claude/issue-1-x"}],"comments":['"$(reason_comment 2 '順番待ちの理由：進行中の #1 が、同じファイルを書き換えるため。')"']}'
run_script watchdog.sh > /dev/null
assert_eq "コメントしない" "0" "$(wait_comments 2)"

echo "== 相手が ai:skip のとき：知らせる"
init_state '{"labels":{"1":["ai:skip"],"2":["ai:queue"]},"comments":['"$(reason_comment 2 '順番待ちの理由：進行中の #1 が、同じファイルを書き換えるため。')"']}'
run_script watchdog.sh > /dev/null
assert_eq "コメントが1つ" "1" "$(wait_comments 2)"
assert_contains "人間待ちと書く" "$(comments_of 2)" "ai:skip"
assert_eq "通知は1回" "1" "$(stuck_notes)"

echo "== 相手が ai:stuck のとき：知らせる"
init_state '{"labels":{"1":["ai:stuck"],"2":["ai:queue"]},"comments":['"$(reason_comment 2 '順番待ちの理由：進行中の #1 が、同じファイルを書き換えるため。')"']}'
run_script watchdog.sh > /dev/null
assert_eq "コメントが1つ" "1" "$(wait_comments 2)"
assert_contains "確認待ちと書く" "$(comments_of 2)" "ai:stuck"
assert_eq "通知は1回" "1" "$(stuck_notes)"

echo "== 相手が閉じているとき：知らせずに、順番待ちを進める"
init_state '{"labels":{"1":[],"2":["ai:queue"]},"issues_meta":{"1":{"state":"closed","title":"t"}},"comments":['"$(reason_comment 2 '順番待ちの理由：進行中の #1 が、同じファイルを書き換えるため。')"']}'
run_script watchdog.sh > /dev/null
assert_eq "コメントしない" "0" "$(wait_comments 2)"
assert_eq "通知しない" "0" "$(stuck_notes)"
assert_eq "順番待ちが進む" "ai:implement" "$(labels_of 2)"

echo "== 待ちが輪になっている（#2 が #3 を、#3 が #2 を待つ）：両方に知らせる"
init_state '{"labels":{"2":["ai:queue"],"3":["ai:queue"]},"comments":['"$(reason_comment 2 '順番待ちの理由：#3 が同じファイルを書き換えるため。')"','"$(reason_comment 3 '順番待ちの理由：#2 が同じファイルを書き換えるため。')"']}'
run_script watchdog.sh > /dev/null
assert_eq "#2 にコメント" "1" "$(wait_comments 2)"
assert_eq "#3 にコメント" "1" "$(wait_comments 3)"
assert_contains "輪と書く" "$(comments_of 2)" "輪になっています"
assert_eq "通知は2回" "2" "$(stuck_notes)"

echo "== ai:blocked の待ち先（このリポジトリ）が ai:stuck：知らせる。別のリポジトリの待ち先は見ない"
init_state '{"labels":{"3":["ai:blocked"],"9":["ai:stuck"]},"comments":['"$(reason_comment 3 '⏳ 待っています
<!-- blocked-by: o/r#9 -->
<!-- blocked-by: o/other#58 -->')"'],"other_repos":{"o/other":{"58":{"state":"open"}}}}'
run_script watchdog.sh > /dev/null
assert_eq "待つ側にコメントが1つ" "1" "$(wait_comments 3)"
assert_contains "#9 を待っていると書く" "$(comments_of 3)" "#9 を待っています"
assert_eq "ai:blocked のまま" "ai:blocked" "$(labels_of 3)"

echo "== 待つ側が ai:skip なら、何もしない"
init_state '{"labels":{"1":["ai:stuck"],"2":["ai:queue","ai:skip"]},"comments":['"$(reason_comment 2 '順番待ちの理由：進行中の #1 が、同じファイルを書き換えるため。')"']}'
run_script watchdog.sh > /dev/null
assert_eq "コメントしない" "0" "$(wait_comments 2)"

finish
