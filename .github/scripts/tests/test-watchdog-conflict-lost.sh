#!/usr/bin/env bash
# 見張り役：コンフリクトの解消を頼んだのに、修正AIが応えないまま止まっているPR（3.2 と、3.4 の ai:hold）を、やり直し→人間へ回す
source "$(dirname "$0")/lib.sh"
setup_mock

pr_of() { # 番号 ブランチ
  echo '{"number":'"$1"',"state":"open","mergeable_state":"dirty","body":"Closes #5","head":{"sha":"abc123","ref":"'"$2"'"},"labels":[],"updated_at":"'"$(ago 600)"'"}'
}
req() { # 番号 何分前 [auto-fix | auto-fix-retry]
  state_py "s['comments'].append({'id':$((RANDOM + 1000)),'issue':'$1','user':{'login':'p'},'body':'@claude 解消して\\n<!-- ${3:-auto-fix} -->\\n<!-- auto-fix-sha: abc123 -->','created_at':'$(ago "$2")','updated_at':'$(ago "$2")'})"
}
review() { # 番号
  state_py "s['comments'].append({'id':$((RANDOM + 5000)),'issue':'$1','user':{'login':'github-actions[bot]'},'body':'## Code review\\n\\nNo issues found.','created_at':'$(ago 600)','updated_at':'$(ago 600)'})"
}
ci_ok='[{"id":1,"name":"CI","conclusion":"success","created_at":"2026-01-01T00:00:00Z"}]'

echo "== dirty・CI 0件・依頼に応答なしのまま45分以上：1回目はやり直し待ち、やり直しても応答が無ければ人間へ"
init_state '{"labels":{"70":[]},"pulls":['"$(pr_of 70 claude/issue-5-a)"']}'
req 70 60
run_script watchdog.sh > /dev/null
assert_contains "やり直し待ちになる" "$(labels_of 70)" "ai:retry"
assert_not_contains "まだ人間には回さない" "$(labels_of 70)" "ai:stuck"
assert_contains "同じ依頼をもう一度出すと書く" "$(comments_of 70)" "同じ依頼をもう一度"
# やり直しの依頼が出て（印は auto-fix-retry）、それも45分以上応答が無い
state_py "s['labels']['70']=[]"
req 70 50 auto-fix-retry
run_script watchdog.sh > /dev/null
assert_contains "2回目は人間に回す" "$(labels_of 70)" "ai:stuck"
assert_contains "人向けの理由" "$(comments_of 70)" "main とのコンフリクトの解消を頼みましたが、修正AIの応答がありませんでした"

echo "== 依頼が終わっている（Claude finished）のに dirty のまま45分：同じ扱い"
init_state '{"labels":{"71":[]},"pulls":['"$(pr_of 71 claude/issue-5-b)"']}'
req 71 90
state_py "s['comments'].append({'id':4242,'issue':'71','user':{'login':'claude[bot]'},'body':'**Claude finished**','created_at':'$(ago 80)','updated_at':'$(ago 80)'})"
run_script watchdog.sh > /dev/null
assert_contains "やり直し待ちになる" "$(labels_of 71)" "ai:retry"

echo "== 依頼から45分たっていない・修正AIが動いている：何もしない"
init_state '{"labels":{"72":[]},"pulls":['"$(pr_of 72 claude/issue-5-c)"']}'
req 72 20
run_script watchdog.sh > /dev/null
assert_eq "45分たっていなければ待つ" "" "$(labels_of 72)"
init_state '{"labels":{"73":[]},"pulls":['"$(pr_of 73 claude/issue-5-d)"'],"wf_runs":{"claude-mention.yml":[{"status":"in_progress","head_branch":"claude/issue-5-d"}]}}'
req 73 120
run_script watchdog.sh > /dev/null
assert_eq "修正AIが動いていれば待つ" "" "$(labels_of 73)"
init_state '{"labels":{"74":[]},"pulls":['"$(pr_of 74 claude/issue-5-e)"'],"wf_runs":{"claude-mention.yml":[{"status":"in_progress","head_branch":"claude/issue-5-other"}]}}'
req 74 120
run_script watchdog.sh > /dev/null
assert_contains "別のブランチの実行は数えない" "$(labels_of 74)" "ai:retry"

echo "== ai:hold のマージ待ちでも同じ"
init_state '{"labels":{"75":["ai:hold","ai:review"]},"pulls":['"$(pr_of 75 claude/issue-5-f)"'],"runs":'"$ci_ok"'}'
review 75
req 75 60
run_script watchdog.sh > /dev/null
assert_contains "やり直し待ちになる" "$(labels_of 75)" "ai:retry"
state_py "s['labels']['75']=['ai:hold','ai:review']"
req 75 50 auto-fix-retry
run_script watchdog.sh > /dev/null
assert_contains "2回目は人間に回す" "$(labels_of 75)" "ai:stuck"
init_state '{"labels":{"76":["ai:hold","ai:review"]},"pulls":['"$(pr_of 76 claude/issue-5-g)"'],"runs":'"$ci_ok"'}'
review 76
req 76 20
run_script watchdog.sh > /dev/null
assert_eq "ai:hold でも45分たっていなければ待つ" "ai:hold,ai:review" "$(labels_of 76)"

finish
