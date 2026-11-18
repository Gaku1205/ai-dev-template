#!/usr/bin/env bash
# GitHub API の回数を減らす仕組み（パイプラインの鍵は、全部のリポジトリで1時間5000回を分け合う）：
#   ・見張り役は、ほかのワークフローが終わるたびに起きても、同じ時間の枠でもう見張りが済んでいれば何もしない
#   ・見張り役・順番待ちは、開いている Issue・PR の一覧を最初に1回ずつ読んで、ラベルと本文はその写しから答える
source "$(dirname "$0")/lib.sh"
setup_mock

calls() { python3 -c "import json,os;print(json.load(open(os.environ['MOCK_STATE'])).get('api_calls',0))"; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
runs_json() { printf '{"workflow_runs":[%s]}' "$1"; }
taken() { run_lib "rc=0; watchdog_slot_taken '$1' $2 $3 $4 || rc=\$?; echo \"rc=\$rc\""; }

echo "== watchdog_slot_taken：同じ枠で、自分より前の見張りが成功しているか"
# 今＝1700000700。10分の枠の始まりは 1700000400
NOW=1700000700
in_slot=$(iso 1700000500)
before_slot=$(iso 1700000300)
assert_contains "枠の中に、前の成功がある" "$(taken "$(runs_json '{"id":150,"conclusion":"success","created_at":"'"$in_slot"'"}')" 200 $NOW 10)" "rc=0"
assert_contains "前の成功は、前の枠" "$(taken "$(runs_json '{"id":150,"conclusion":"success","created_at":"'"$before_slot"'"}')" 200 $NOW 10)" "rc=1"
assert_contains "枠を30分にすれば、同じ枠" "$(taken "$(runs_json '{"id":150,"conclusion":"success","created_at":"'"$before_slot"'"}')" 200 $NOW 30)" "rc=0"
for c in failure cancelled skipped; do
  assert_contains "前の実行が $c：数えない" "$(taken "$(runs_json '{"id":150,"conclusion":"'"$c"'","created_at":"'"$in_slot"'"}')" 200 $NOW 10)" "rc=1"
done
assert_contains "まだ動いている実行（結果なし）：数えない" "$(taken "$(runs_json '{"id":150,"status":"in_progress","conclusion":null,"created_at":"'"$in_slot"'"}')" 200 $NOW 10)" "rc=1"
assert_contains "自分より後の実行：数えない" "$(taken "$(runs_json '{"id":250,"conclusion":"success","created_at":"'"$in_slot"'"}')" 200 $NOW 10)" "rc=1"
assert_contains "自分だけ" "$(taken "$(runs_json '{"id":200,"conclusion":"success","created_at":"'"$in_slot"'"}')" 200 $NOW 10)" "rc=1"
assert_contains "実行が無い" "$(taken "$(runs_json '')" 200 $NOW 10)" "rc=1"
assert_contains "一覧が壊れている：間引かない" "$(taken 'こわれた' 200 $NOW 10)" "rc=1"
assert_contains "時刻が読めない実行：数えない" "$(taken "$(runs_json '{"id":150,"conclusion":"success","created_at":"x"}')" 200 $NOW 10)" "rc=1"
assert_contains "枠が0分：間引かない" "$(taken "$(runs_json '{"id":150,"conclusion":"success","created_at":"'"$in_slot"'"}')" 200 $NOW 0)" "rc=1"
assert_contains "自分の番号が無い：間引かない" "$(taken "$(runs_json '{"id":150,"conclusion":"success","created_at":"'"$in_slot"'"}')" "''" $NOW 10)" "rc=1"

echo "== 見張り役：workflow_run で起きて、同じ枠でもう見張りが済んでいれば、何もしない"
# #9 は、企画（ai:plan）のまま50分動きが無い（全部見れば、やり直し待ちになる）
now_s=$(date +%s)
slot_start=$(( now_s - now_s % 600 ))
state_with_run() { # 前の見張りの結果 作られた時刻（epoch）
  init_state '{"labels":{"9":["ai:plan"]},"issue_updated":{"9":"'"$(ago 50)"'"},"wf_runs":{"watchdog.yml":[{"id":150,"status":"completed","conclusion":"'"$1"'","created_at":"'"$(iso "$2")"'"}]}}'
}
state_with_run success "$slot_start"
out=$(GITHUB_EVENT_NAME=workflow_run GITHUB_RUN_ID=200 run_script watchdog.sh)
assert_contains "何もしないと出す" "$out" "もう見張りが済んでいるので、今回は何もしません"
assert_eq "ラベルは変わらない" "ai:plan" "$(labels_of 9)"
assert_eq "API は、実行の一覧の1回だけ" "1" "$(calls)"

echo "== 見張り役：間引かないとき（全部見る）"
state_with_run success "$slot_start"
GITHUB_EVENT_NAME=schedule GITHUB_RUN_ID=200 run_script watchdog.sh > /dev/null
assert_eq "定期の起動：全部見る" "ai:plan,ai:retry" "$(labels_of 9)"
state_with_run success "$slot_start"
GITHUB_EVENT_NAME=workflow_dispatch GITHUB_RUN_ID=200 run_script watchdog.sh > /dev/null
assert_eq "手動・目覚まし：全部見る" "ai:plan,ai:retry" "$(labels_of 9)"
state_with_run success "$(( slot_start - 60 ))"
GITHUB_EVENT_NAME=workflow_run GITHUB_RUN_ID=200 run_script watchdog.sh > /dev/null
assert_eq "前の成功が前の枠：全部見る" "ai:plan,ai:retry" "$(labels_of 9)"
state_with_run failure "$slot_start"
GITHUB_EVENT_NAME=workflow_run GITHUB_RUN_ID=200 run_script watchdog.sh > /dev/null
assert_eq "前の見張りが失敗：全部見る" "ai:plan,ai:retry" "$(labels_of 9)"
state_with_run success "$slot_start"
state_py "s['wf_runs_fail']=['watchdog.yml']"
GITHUB_EVENT_NAME=workflow_run GITHUB_RUN_ID=200 run_script watchdog.sh > /dev/null
assert_eq "実行の一覧を読めない：全部見る" "ai:plan,ai:retry" "$(labels_of 9)"
state_with_run success "$slot_start"
GITHUB_EVENT_NAME=workflow_run GITHUB_RUN_ID=200 WATCHDOG_SLOT_MIN=0 run_script watchdog.sh > /dev/null
assert_eq "WATCHDOG_SLOT_MIN=0：間引かない" "ai:plan,ai:retry" "$(labels_of 9)"
state_with_run success "$slot_start"
GITHUB_EVENT_NAME=workflow_run GITHUB_RUN_ID=120 run_script watchdog.sh > /dev/null
assert_eq "成功した実行が自分より後：全部見る" "ai:plan,ai:retry" "$(labels_of 9)"

echo "== 写し：ラベルは一覧から答え、自分の付け外しを反映する"
init_state '{"labels":{"9":["ai:plan"],"10":[]}}'
out=$(run_lib '
use_open_snapshot
has_label 9 ai:plan && echo "9=plan"
has_label 9 ai:stuck || echo "9!=stuck rc=$?"
has_label 10 ai:plan || echo "10!=plan rc=$?"
add_label 9 ai:stuck
has_label 9 ai:stuck && echo "added"
remove_label 9 ai:plan
has_label 9 ai:plan || echo "removed"
remove_label 9 ai:none
has_label 9 ai:stuck && echo "still"
take_label 9 ai:stuck && echo "took"
take_label 9 ai:stuck || echo "second take fails"
has_label 9 ai:stuck || echo "gone"
open_numbers_with_label ai:plan | paste -sd, -')
assert_contains "付いている" "$out" "9=plan"
assert_contains "付いていない（1）" "$out" "9!=stuck rc=1"
assert_contains "ラベルの無い Issue（1）" "$out" "10!=plan rc=1"
assert_contains "付けたラベルが見える" "$out" "added"
assert_contains "外したラベルは見えない" "$out" "removed"
assert_contains "付いていないラベルを外しても、写しは残る" "$out" "still"
assert_contains "取れた" "$out" "took"
assert_contains "二度目は取れない" "$out" "second take fails"
assert_contains "取ったラベルは見えない" "$out" "gone"
assert_eq "本物のラベルも同じ" "" "$(labels_of 9)"
# 一覧2回＋付ける1回＋外す4回（remove 2・take 2）。ラベルの確かめ・一覧では API を呼ばない
assert_eq "API は、一覧の2回と付け外しの5回だけ" "7" "$(calls)"

echo "== 写し：写しに無い番号（閉じている・あとから作られた）は、API から読む"
init_state '{"labels":{"9":["ai:plan"]}}'
out=$(run_lib '
use_open_snapshot
python3 -c "
import json, os
s = json.load(open(os.environ[\"MOCK_STATE\"])); s[\"labels\"][\"11\"] = [\"ai:queue\"]; json.dump(s, open(os.environ[\"MOCK_STATE\"], \"w\"))"
has_label 11 ai:queue && echo "11=queue"')
assert_contains "あとから作られた Issue のラベルも読める" "$out" "11=queue"

echo "== 写し：ラベルを外せたか分からない（404 以外の失敗）ときは、写しを捨てて API から読む"
init_state '{"labels":{"9":["ai:plan"]},"label_delete_fail":["9"]}'
out=$(run_lib '
use_open_snapshot
remove_label 9 ai:plan
[ -z "$OPEN_ITEMS" ] && echo "dropped"
has_label 9 ai:plan && echo "still plan"
open_numbers_with_label ai:plan | paste -sd, -')
assert_contains "写しを捨てる" "$out" "dropped"
assert_contains "API から読んで、まだ付いていると分かる" "$out" "still plan"
assert_contains "一覧も API から読む" "$out" "9"

echo "== 写し：一覧を読めなければ、写しなし（今までどおり API から読む）"
init_state '{"labels":{"9":["ai:plan"]},"fail_open_list":true}'
out=$(run_lib '
use_open_snapshot || echo "no snapshot"
has_label 9 ai:plan && echo "9=plan"
echo "count=$(count_open_issues_with_label ai:plan)"')
assert_contains "写しなし" "$out" "no snapshot"
assert_contains "ラベルは API から" "$out" "9=plan"
assert_contains "数も API から" "$out" "count=1"

echo "== 写し：本文も一覧から読む（写しが無ければ API）"
init_state '{"labels":{"9":["ai:queue"]},"issues_meta":{"9":{"body":"本文です <!-- ai-touches: src/a.ts -->"}}}'
assert_contains "写しから" "$(run_lib 'use_open_snapshot; issue_body 9')" "ai-touches: src/a.ts"
assert_contains "API から" "$(run_lib 'issue_body 9')" "ai-touches: src/a.ts"

echo "== API の回数：見張り役（開いているPRが6つ・実装中1つ・順番待ち2つ）"
# PR は、どれも1分前に更新（止まりの確かめには入らない）。#21・#22 は ai:hold（レビュー済みではないので、マージ待ちには数えない）
prs=$(python3 -c "
import json
print(json.dumps([{'number': n, 'state': 'open', 'mergeable_state': 'clean', 'body': '', 'updated_at': '$(ago 1)',
  'head': {'sha': 's%d' % n, 'ref': 'claude/issue-%d-x' % (n - 10), 'repo': {'full_name': 'o/r'}}} for n in range(21, 27)]))")
busy_state() {
  init_state '{"labels":{"21":["ai:hold"],"22":["ai:hold"],"23":["ai:review"],"24":[],"25":[],"26":[],"11":["ai:implement"],"3":["ai:queue"],"4":["ai:queue"],"5":["ai:skip"]},
    "issue_updated":{"11":"'"$(ago 1)"'","3":"'"$(ago 1)"'","4":"'"$(ago 1)"'","5":"'"$(ago 1)"'"},
    "issues_meta":{"3":{"body":"<!-- ai-touches: src/a.ts -->"},"4":{"body":"<!-- ai-touches: src/b.ts -->"}},
    "files":["src/z.ts"],"pulls":'"$prs"'}'
}
busy_state
out=$(RETRY_TIMER=off run_script watchdog.sh)
with_snapshot=$(calls)
assert_contains "順番待ちを見ている" "$out" "実装中 1 / 停止中 0（数えない） / openのPR 6"
busy_state
state_py "s['fail_open_list']=True"
# 一覧を読めないとき（写しなし）は、ラベルごとの一覧・ラベルの確かめを、その都度 API で読む（今までの読み方）
RETRY_TIMER=off run_script watchdog.sh > /dev/null
without_snapshot=$(calls)
echo "  （写しあり ${with_snapshot} 回 / 写しなし ${without_snapshot} 回）"
if [ "$with_snapshot" -le 40 ]; then assert_eq "写しがあれば40回以内" ok ok; else assert_eq "写しがあれば40回以内" "40以下" "$with_snapshot"; fi
if [ "$(( with_snapshot * 2 ))" -le "$without_snapshot" ]; then assert_eq "写しなしの半分以下" ok ok; else assert_eq "写しなしの半分以下" "$(( without_snapshot / 2 ))以下" "$with_snapshot"; fi

echo "== API の回数：何も無いリポジトリの見張りは、10回以内"
init_state '{}'
RETRY_TIMER=off run_script watchdog.sh > /dev/null
idle=$(calls)
echo "  （${idle} 回）"
if [ "$idle" -le 10 ]; then assert_eq "10回以内" ok ok; else assert_eq "10回以内" "10以下" "$idle"; fi

echo "== 順番待ち（queue-next.sh）：写しを使っても、今までどおり始める"
init_state '{"labels":{"3":["ai:queue"],"4":["ai:queue","priority:high"]}}'
out=$(run_script queue-next.sh)
assert_contains "急ぎの #4 を始める" "$out" "順番待ちの #4 を実装に回しました"
assert_eq "#4 は実装へ" "ai:implement,priority:high" "$(labels_of 4)"
assert_eq "#3 は待ったまま" "ai:queue" "$(labels_of 3)"
if [ "$(calls)" -le 6 ]; then assert_eq "API は6回以内" ok ok; else assert_eq "API は6回以内" "6以下" "$(calls)"; fi

finish
