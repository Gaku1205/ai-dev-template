#!/usr/bin/env bash
# やり直しの目覚まし：見張り役が、いちばん早くやり直せる時刻に retry-timer.yml をかける（定期の起動が遅れても待ちすぎない）
source "$(dirname "$0")/lib.sh"
setup_mock
dispatches() { python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print('\n'.join(d['workflow']+' '+d.get('inputs[at]','') for d in s.get('dispatches',[])))"; }

echo "== 待ち中の物があれば、その時刻に目覚ましをかける"
init_state '{"labels":{"7":["ai:implement"],"8":["ai:implement"]}}'
run_lib 'mark_for_retry 7 implement "上限"' > /dev/null
run_lib 'mark_for_retry 8 implement "上限"' > /dev/null
state_py "
for c in s['comments']:
    if c['issue']=='8' and 'auto-retry' in c['body']: c['updated_at']='$(ago 20)'"
out=$(run_script watchdog.sh)
assert_contains "かけたと書く" "$out" "目覚ましを"
d=$(dispatches)
assert_eq "1つだけかける" "1" "$(printf '%s\n' "$d" | grep -c retry-timer.yml)"
at=$(printf '%s' "$d" | awk '{print $2}')
expect=$(( $(date +%s) + 10 * 60 ))
assert_eq "いちばん早い物（#8：あと約10分）の時刻" "ok" "$([ "$at" -ge $((expect - 90)) ] && [ "$at" -le $((expect + 90)) ] && echo ok || echo "$at")"

echo "== 同じ時刻の目覚ましがもう待っていれば、かけ直さない"
state_py "s['dispatches']=[]; s['wf_runs']={'retry-timer.yml':[{'status':'in_progress','display_title':'やり直しの目覚まし $at'}]}"
out=$(run_script watchdog.sh)
assert_contains "もうかかっている" "$out" "もうかかっています"
assert_eq "かけない" "" "$(dispatches)"

echo "== 待っている目覚ましが遅すぎる（もっと早い物ができた）ときは、かけ直す"
state_py "s['wf_runs']={'retry-timer.yml':[{'status':'queued','display_title':'やり直しの目覚まし $((at + 3600))'},{'status':'completed','display_title':'やり直しの目覚まし $at'}]}"
run_script watchdog.sh > /dev/null
assert_eq "かけ直す" "1" "$(dispatches | grep -c retry-timer.yml)"

echo "== 上限のリセットが遠いときは、最大 340 分先にかける（起きた見張り役がかけ直す）"
init_state '{"labels":{"9":["ai:implement"]}}'
run_lib 'mark_for_retry 9 implement "上限"' > /dev/null
state_py "
for c in s['comments']:
    if 'auto-retry' in c['body'] and 'limit-until' not in c['body']: c['body'] += '\n<!-- limit-until=$(( $(date +%s) + 10 * 3600 )) -->'"
WATCHDOG_HEARTBEAT_MIN=1000 run_script watchdog.sh > /dev/null
at=$(dispatches | awk '{print $2}')
cap=$(( $(date +%s) + 340 * 60 ))
assert_eq "340分先まで" "ok" "$([ "$at" -ge $((cap - 90)) ] && [ "$at" -le $((cap + 5)) ] && echo ok || echo "$at")"

echo "== やり直し待ちが無い・ai:stuck の物だけ・RETRY_TIMER=off のときは、かけない"
init_state '{"labels":{"5":["ai:review-done"]}}'
run_script watchdog.sh > /dev/null
assert_eq "待ちが無い" "" "$(dispatches)"
init_state '{"labels":{"7":["ai:implement"]}}'
run_lib 'mark_for_retry 7 implement "上限"' > /dev/null
RETRY_TIMER=off run_script watchdog.sh > /dev/null
assert_eq "off" "" "$(dispatches)"
state_py "s['labels']['7'].append('ai:stuck')"
run_script watchdog.sh > /dev/null
assert_eq "ai:stuck の物" "" "$(dispatches)"

echo "== 順番待ちを止めている ai:hold のPRは、進行中から外れる時刻（付いて60分）に目覚ましをかける（PR #162）"
review='{"id":901,"issue":"20","user":{"login":"github-actions[bot]"},"created_at":"2026-11-17T00:00:00Z","updated_at":"2026-11-17T00:00:00Z","body":"## Code review\n\nNo issues found."}'
pr20='{"number":20,"state":"open","mergeable_state":"clean","head":{"ref":"claude/issue-9-x","sha":"abc"},"labels":[{"name":"ai:hold"}]}'
init_state '{"labels":{"20":["ai:hold"],"3":["ai:queue"]},"events":{"20":[{"event":"labeled","label":{"name":"ai:hold"},"created_at":"'"$(ago 30)"'"}]},"pulls":['"$pr20"'],"files":["src/lib/a.ts"],"comments":['"$review"'],
  "issues_meta":{"3":{"title":"b","body":"本文\n<!-- ai-touches: src/lib/a.ts -->"}}}'
run_script watchdog.sh > /dev/null
assert_eq "#3 はまだ待つ" "ai:queue" "$(labels_of 3)"
at=$(dispatches | grep retry-timer.yml | awk '{print $2}')
expect=$(( $(date +%s) + 31 * 60 ))
assert_eq "あと約30分の時刻" "ok" "$([ -n "$at" ] && [ "$at" -ge $((expect - 120)) ] && [ "$at" -le $((expect + 120)) ] && echo ok || echo "${at:-なし}")"

echo "== 順番待ちが無ければ、ai:hold のPRがあっても目覚ましはかけない"
state_py "s['labels']['3']=['ai:skip']; s['dispatches']=[]"
run_script watchdog.sh > /dev/null
assert_eq "かけない" "" "$(dispatches)"

near15() { local at="$1" expect=$(( $(date +%s) + ${2:-15} * 60 )); [ -n "$at" ] && [ "$at" -ge $((expect - 120)) ] && [ "$at" -le $((expect + 120)) ] && echo ok || echo "${at:-なし}"; }

echo "== 進行中の物（ai:implement など）があれば、15分後に目覚ましをかける"
init_state '{"labels":{"5":["ai:implement"]}}'
run_script watchdog.sh > /dev/null
assert_eq "約15分後" "ok" "$(near15 "$(dispatches | awk '{print $2}')")"
init_state '{"labels":{"5":["ai:plan"]}}'
WATCHDOG_HEARTBEAT_MIN=7 run_script watchdog.sh > /dev/null
assert_eq "WATCHDOG_HEARTBEAT_MIN=7：7分後" "ok" "$(near15 "$(dispatches | awk '{print $2}')" 7)"

echo "== もっと早い目覚ましがかかっていれば、かけ直さない"
init_state '{"labels":{"5":["ai:plan"]},"wf_runs":{"retry-timer.yml":[{"status":"queued","display_title":"やり直しの目覚まし '"$(( $(date +%s) + 300 ))"'"}]}}'
run_script watchdog.sh > /dev/null
assert_eq "かけない" "" "$(dispatches)"

echo "== ラベルの無い Issue（オーナー作）は対象。ほかの人の Issue・ai:skip・ai:stuck は対象外"
init_state '{"labels":{"5":[]}}'
run_script watchdog.sh > /dev/null
assert_eq "ラベル無し" "ok" "$(near15 "$(dispatches | awk '{print $2}')")"
init_state '{"labels":{"5":[]},"authors":{"5":"stranger"}}'
run_script watchdog.sh > /dev/null
assert_eq "ほかの人の Issue" "" "$(dispatches)"
init_state '{"labels":{"5":["ai:skip"],"6":["ai:stuck","ai:implement"]}}'
run_script watchdog.sh > /dev/null
assert_eq "ai:skip・ai:stuck" "" "$(dispatches)"

echo "== 開いているPR：進行中なら対象。ai:stuck・下書き・fork・人間のマージ待ちだけなら対象外"
mkpr() { printf '{"number":%s,"state":"open","draft":%s,"mergeable_state":"clean","updated_at":"%s","head":{"ref":"claude/issue-9-x","sha":"abc","repo":{"full_name":"%s"}},"labels":[%s]}' "$1" "$2" "$(ago 1)" "$3" "$4"; }
repo=$(run_lib 'echo "$REPO"')
init_state '{"labels":{"30":[]},"pulls":['"$(mkpr 30 false "$repo" "")"']}'
run_script watchdog.sh > /dev/null
assert_eq "進行中のPR" "ok" "$(near15 "$(dispatches | awk '{print $2}')")"
init_state '{"labels":{"30":["ai:stuck"]},"pulls":['"$(mkpr 30 false "$repo" '{"name":"ai:stuck"}')"']}'
run_script watchdog.sh > /dev/null
assert_eq "ai:stuck のPR" "" "$(dispatches)"
init_state '{"labels":{"30":[]},"pulls":['"$(mkpr 30 true "$repo" "")"']}'
run_script watchdog.sh > /dev/null
assert_eq "下書き" "" "$(dispatches)"
init_state '{"labels":{"30":[]},"pulls":['"$(mkpr 30 false "someone/fork" "")"']}'
run_script watchdog.sh > /dev/null
assert_eq "fork" "" "$(dispatches)"
init_state '{"labels":{"20":["ai:hold"]},"events":{"20":[{"event":"labeled","label":{"name":"ai:hold"},"created_at":"'"$(ago 30)"'"}]},"pulls":['"$(mkpr 20 false "$repo" '{"name":"ai:hold"}')"'],"comments":['"$review"']}'
run_script watchdog.sh > /dev/null
assert_eq "人間のマージ待ち" "" "$(dispatches)"

echo "== 順番待ちがあり、夜の始まり／終わり・上書きの期限が先にあれば、その1分後にかける"
# #1 が実装中で、昼夜とも上限 1 なので、#3 は順番待ちのまま。15分ごとの目覚ましは遠くして、変わり目の分だけを見る
q='{"labels":{"1":["ai:implement"],"3":["ai:queue"]}}'
tz_now=$(date +%s)
nxt=$(( tz_now + 3 * 3600 ))
nh=$(TZ=Asia/Tokyo date -d "@$nxt" +%H)
want=$(TZ=Asia/Tokyo date -d "$(TZ=Asia/Tokyo date -d "@$nxt" +%Y-%m-%d) $nh:00" +%s)
[ "$want" -gt "$tz_now" ] || want=$(( want + 86400 ))
want=$(( want + 60 ))
within() { [ -n "$1" ] && [ "$1" -ge $(( $2 - 120 )) ] && [ "$1" -le $(( $2 + 120 )) ] && echo ok || echo "${1:-なし}（期待 $2）"; }
export PARALLEL_DAY=1 PARALLEL_NIGHT=1 WATCHDOG_HEARTBEAT_MIN=1000
init_state "$q"
TIMER_CLOCK_REPO=1 PARALLEL_NIGHT_HOURS="$nh-$(( (10#$nh + 5) % 24 ))" run_script watchdog.sh > /dev/null
assert_eq "夜の始まりの1分後" "ok" "$(within "$(dispatches | awk '{print $2}')" "$want")"
init_state "$q"
TIMER_CLOCK_REPO=0 PARALLEL_NIGHT_HOURS="$nh-$(( (10#$nh + 5) % 24 ))" run_script watchdog.sh > /dev/null
assert_not_contains "テンプレートでないリポジトリは、遠い先（3時間後）の切り替えではかけない（Actions の枠を食わない）" "$(within "$(dispatches | awk '{print $2}')" "$want")" "ok"
assert_eq "#3 は順番待ちのまま" "ai:queue" "$(labels_of 3)"
init_state "$q"
TIMER_CLOCK_REPO=1 PARALLEL_NIGHT_HOURS="$(( (10#$nh + 19) % 24 ))-$nh" run_script watchdog.sh > /dev/null
assert_eq "夜の終わりの1分後" "ok" "$(within "$(dispatches | awk '{print $2}')" "$want")"
init_state "$q"
ov="night until $(TZ=Asia/Tokyo date -d "@$(( tz_now + 600 ))" +%Y-%m-%dT%H:%M:%S+09:00)"
TIMER_CLOCK_REPO=0 PARALLEL_OVERRIDE="$ov" run_script watchdog.sh > /dev/null
assert_eq "上書きの期限の1分後（近い＝45分以内なら、テンプレートでなくてもかける）" "ok" "$(within "$(dispatches | awk '{print $2}')" $(( tz_now + 660 )))"
init_state '{"labels":{"1":["ai:review-done"]}}'
PARALLEL_OVERRIDE="$ov" run_script watchdog.sh > /dev/null
assert_eq "順番待ちが無ければ変わり目ではかけない" "" "$(dispatches)"
unset PARALLEL_DAY PARALLEL_NIGHT WATCHDOG_HEARTBEAT_MIN

echo "== 間引いた回（workflow_run の10分の枠が済み）でも、目覚ましはかかる"
init_state '{"labels":{"5":["ai:implement"]},"wf_runs":{"watchdog.yml":[{"id":1,"status":"completed","conclusion":"success","created_at":"'"$(ago 1)"'","event":"schedule"}]}}'
GITHUB_EVENT_NAME=workflow_run GITHUB_RUN_ID=999 run_script watchdog.sh > /dev/null
assert_eq "かかる" "ok" "$(near15 "$(dispatches | awk '{print $2}')")"

echo "== RETRY_TIMER=off では進行中の物があっても何もしない"
init_state '{"labels":{"5":["ai:implement"]}}'
RETRY_TIMER=off run_script watchdog.sh > /dev/null
assert_eq "off" "" "$(dispatches)"

finish
