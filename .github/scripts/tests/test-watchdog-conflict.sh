#!/usr/bin/env bash
# 見張り役：main とコンフリクトしていて CI が動いていないPRを、AIに解消させる（3.2）
source "$(dirname "$0")/lib.sh"
setup_mock

pr_of() { # 番号 ブランチ mergeable_state
  echo '{"number":'"$1"',"state":"open","mergeable_state":"'"$3"'","body":"Closes #5","head":{"sha":"abc123","ref":"'"$2"'"},"labels":[],"updated_at":"2026-01-01T00:00:00Z"}'
}

echo "== コンフリクトしていて CI が無い：AIに解消を頼む"
init_state '{"labels":{"58":[]},"pulls":['"$(pr_of 58 claude/issue-5-x dirty)"']}'
run_script watchdog.sh > /dev/null
c=$(comments_of 58)
assert_contains "解消を頼む" "$c" "git merge origin/main"
assert_contains "先頭の sha を記録" "$c" "auto-fix-sha: abc123"
run_script watchdog.sh > /dev/null
assert_eq "同じ先頭には2回頼まない" "1" "$(comments_of 58 | grep -c 'auto-fix-sha: abc123')"

echo "== コンフリクトしていない・配布のPR・CI が動いている：何もしない"
init_state '{"labels":{"59":[]},"pulls":['"$(pr_of 59 claude/issue-5-y clean)"']}'
run_script watchdog.sh > /dev/null
assert_not_contains "コンフリクトが無ければ頼まない" "$(comments_of 59)" "コンフリクト"
init_state '{"labels":{"60":[]},"pulls":['"$(pr_of 60 pipeline-sync/abc dirty)"']}'
run_script watchdog.sh > /dev/null
assert_not_contains "配布のPRは触らない" "$(comments_of 60)" "コンフリクト"
init_state '{"labels":{"61":[]},"pulls":['"$(pr_of 61 claude/issue-5-z dirty)"'],"runs":[{"id":1,"name":"CI","conclusion":"success","created_at":"2026-01-01T00:00:00Z"}]}'
run_script watchdog.sh > /dev/null
assert_not_contains "CI が動いていれば、after-ci に任せる" "$(comments_of 61)" "CIが動いていません"

echo "== visual:update が付いたまま、コンフリクトで撮り直しが動いていない：ラベルを外して、AIにコンフリクトを解消させる"
old_pr() { pr_of "$1" "$2" "$3" | sed "s/2026-01-01T00:00:00Z/$(ago 20)/"; }
init_state '{"labels":{"61":["visual:update","ai:review"]},"pulls":['"$(old_pr 61 claude/issue-5-v dirty)"'],"runs":[{"id":1,"name":"CI","conclusion":"success"}]}'
run_script watchdog.sh > /dev/null
c=$(comments_of 61)
assert_not_contains "ラベルを外す" "$(labels_of 61)" "visual:update"
assert_contains "コンフリクトの解消を頼む" "$c" "git merge origin/main"
assert_contains "混ぜられないファイルの扱いを書く" "$c" "git checkout --theirs -- パス"
assert_contains "直す依頼として数える" "$c" "<!-- auto-fix -->"

echo "== コンフリクトは無いのに撮り直しが動いていない：1回だけ付け直し、2回目は人間に回す"
init_state '{"labels":{"62":["visual:update"]},"pulls":['"$(old_pr 62 claude/issue-5-w clean)"'],"runs":[{"id":1,"name":"CI","conclusion":"success"}]}'
run_script watchdog.sh > /dev/null
assert_contains "付け直す" "$(labels_of 62)" "visual:update"
assert_contains "付け直したと書く" "$(comments_of 62)" "auto-visual-relabel: abc123"
run_script watchdog.sh > /dev/null
assert_contains "2回目は人間に回す" "$(labels_of 62)" "ai:stuck"
assert_not_contains "ラベルは外す" "$(labels_of 62)" "visual:update"

echo "== 撮り直しが動いている・付いたばかり：何もしない"
init_state '{"labels":{"63":["visual:update"]},"pulls":['"$(old_pr 63 claude/issue-5-z clean)"'],"runs":[{"id":1,"name":"CI","conclusion":"success"}],"wf_runs":{"visual-update.yml":[{"status":"in_progress","head_branch":"claude/issue-5-z"}]}}'
run_script watchdog.sh > /dev/null
assert_eq "動いていれば触らない" "visual:update" "$(labels_of 63)"
init_state '{"labels":{"64":["visual:update"]},"pulls":['"$(pr_of 64 claude/issue-5-q dirty | sed "s/2026-01-01T00:00:00Z/$(ago 2)/")"'],"runs":[{"id":1,"name":"CI","conclusion":"success"}]}'
run_script watchdog.sh > /dev/null
assert_eq "付いたばかりなら待つ" "visual:update" "$(labels_of 64)"

echo "== mergeable が null（GitHub が計算中。mergeable_state は unknown）：頼まず、空のコミットも足さず、次の見張りまで待つ"
init_state '{"labels":{"65":[]},"pulls":['"$(pr_of 65 claude/issue-5-n unknown | sed 's/"body"/"mergeable":null,"body"/')"']}'
out=$(run_script watchdog.sh)
assert_contains "待つと出す" "$out" "GitHub が計算中"
assert_not_contains "解消を頼まない" "$(comments_of 65)" "git merge origin/main"
assert_not_contains "空のコミットも足さない" "$(comments_of 65)" "空のコミット"
assert_not_contains "人間に回さない" "$(labels_of 65)" "ai:stuck"
state_py "s['pulls'][0]['mergeable_state']='dirty'; s['pulls'][0]['mergeable']=False"
run_script watchdog.sh > /dev/null
assert_contains "計算が済んで dirty なら、次の見張りで頼む" "$(comments_of 65)" "git merge origin/main"

echo "== 同じ先頭コミットに、直す依頼がもう出ている：重ねて頼まない"
init_state '{"labels":{"66":[]},"pulls":['"$(pr_of 66 claude/issue-5-o dirty)"']}'
state_py "s['comments'].append({'id':1,'issue':'66','user':{'login':'p'},'body':'@claude x\\n<!-- auto-fix -->\\n<!-- auto-fix-sha: abc123 -->','created_at':'$(ago 3)','updated_at':'$(ago 3)'})"
run_script watchdog.sh > /dev/null
assert_eq "依頼は1つのまま" "1" "$(comments_of 66 | grep -c 'auto-fix-sha: abc123')"

finish
