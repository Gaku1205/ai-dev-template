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
run_script watchdog.sh > /dev/null
at=$(dispatches | awk '{print $2}')
cap=$(( $(date +%s) + 340 * 60 ))
assert_eq "340分先まで" "ok" "$([ "$at" -ge $((cap - 90)) ] && [ "$at" -le $((cap + 5)) ] && echo ok || echo "$at")"

echo "== やり直し待ちが無い・ai:stuck の物だけ・RETRY_TIMER=off のときは、かけない"
init_state '{"labels":{"5":["ai:implement"]}}'
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
state_py "s['labels']['3']=[]; s['dispatches']=[]"
run_script watchdog.sh > /dev/null
assert_eq "かけない" "" "$(dispatches)"

finish
