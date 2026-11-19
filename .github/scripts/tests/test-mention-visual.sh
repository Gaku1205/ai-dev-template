#!/usr/bin/env bash
# 修正AIが変更なしで終わり、AIの返事・レビューの指摘・PRの説明に「基準の画像の撮り直し」の依頼があるとき：
# 人間に回さず、パイプラインが visual:update を付ける（CIが通っていても。1つのPRで2回まで）
source "$(dirname "$0")/lib.sh"
setup_mock
pr_json() { printf '{"number":58,"body":"%s","state":"open","head":{"sha":"abc","ref":"claude/issue-57-x"},"updated_at":"2026-01-01T00:00:00Z"}' "${1:-Closes #57}"; }
setup_case() { # 1: AIの返事 2: 落ちたステップ（JSONの配列） 3: CIの結果（既定 failure） 4: PRの説明
  init_state '{"labels":{"58":[]},"pulls":['"$(pr_json "${4:-Closes #57}")"'],"runs":[{"id":9,"name":"CI","conclusion":"'"${3:-failure}"'","created_at":"2026-01-01T00:00:00Z"}],"jobs":[{"steps":'"$2"'}]}'
  state_py "
s['comments'].append({'id':50,'issue':'58','body':'@claude x\\n<!-- auto-fix -->\\n<!-- auto-fix-sha: abc -->','user':{'login':'x'},'created_at':'$(ago 2)','updated_at':'$(ago 2)'})
s['comments'].append({'id':51,'issue':'58','body':'''$1''','user':{'login':'claude[bot]'},'created_at':'$(ago 1)','updated_at':'$(ago 1)'})
s['next_id']=51"
}
run_after() { RUN_STARTED=$(ago 1) CONCLUSION=success run_script after-mention.sh; }
visual_only='[{"name":"見た目のテスト","conclusion":"failure"},{"name":"テスト","conclusion":"success"}]'
all_ok='[{"name":"見た目のテスト","conclusion":"success"}]'

echo "== 見た目のテストだけが落ち、AIが visual:update を頼んだ：撮り直す"
setup_case '基準の画像が古いだけです。`visual:update` ラベルで撮り直してください。' "$visual_only"
out=$(run_after)
assert_contains "撮り直しを依頼したと出す" "$out" "撮り直しを依頼しました"
assert_contains "visual:update が付く" "$(labels_of 58)" "visual:update"
assert_not_contains "人間に回さない" "$(labels_of 58)" "ai:stuck"
assert_contains "印つきのコメント（回数に数える）" "$(comments_of 58)" "auto-visual-update"
assert_contains "回数が書かれる" "$(comments_of 58)" "1/2回目"

echo "== CIは通っていて、レビューが「基準の画像が古い」と指摘した（AIは別の言い方）：撮り直す"
setup_case 'コードは直さなくてよいです。撮り直しは CLAUDE.md で禁止されているので、私からはできません。' "$all_ok" success
state_py "
s['comments'].append({'id':45,'issue':'58','body':'## Code review\\n基準の画像（repo-merge.png）が古いです。撮り直してください。','user':{'login':'github-actions[bot]'},'created_at':'$(ago 3)','updated_at':'$(ago 3)'})"
run_after > /dev/null
assert_contains "visual:update が付く" "$(labels_of 58)" "visual:update"
assert_not_contains "人間に回さない" "$(labels_of 58)" "ai:stuck"

echo "== レビューの行への指摘で頼まれた（CIは通っている）：撮り直す"
setup_case '直す所はありません。' "$all_ok" success
state_py "
s['review_comments']=[{'user':{'login':'claude[bot]'},'original_commit_id':'abc','created_at':'$(ago 3)','body':'このスナップショットは古いので更新が要ります（visual:update）'}]"
run_after > /dev/null
assert_contains "visual:update が付く" "$(labels_of 58)" "visual:update"

echo "== 古いコミットへの行への指摘は見ない：撮り直さない"
setup_case 'うまくいきませんでした。' "$all_ok" success
state_py "
s['review_comments']=[{'user':{'login':'claude[bot]'},'original_commit_id':'old','created_at':'$(ago 30)','body':'visual:update で撮り直して'}]"
run_after > /dev/null
assert_not_contains "visual:update は付けない" "$(labels_of 58)" "visual:update"
assert_contains "ai:stuck" "$(labels_of 58)" "ai:stuck"

echo "== PRの説明にだけ撮り直しの依頼がある（CIは通っている）：PRの説明は見ないので撮り直さない"
setup_case 'うまくいきませんでした。' "$all_ok" success '見た目を変えたので visual:update ラベルで基準の画像を撮り直してください'
run_after > /dev/null
assert_not_contains "visual:update は付けない" "$(labels_of 58)" "visual:update"
assert_contains "ai:stuck" "$(labels_of 58)" "ai:stuck"

echo "== 2回撮り直したあとに main を取り込んだ（基準の画像は main の側に戻った）：もう一度撮り直す（agent-desk #316）"
setup_case '`visual:update` で撮り直してください。' "$visual_only"
state_py "
for i in (60, 61): s['comments'].append({'id':i,'issue':'58','body':'撮り直します\\n<!-- auto-visual-update -->','user':{'login':'p'},'created_at':'$(ago 30)','updated_at':'$(ago 30)'})
s['pr_commits']={'58':[{'sha':'a1','parents':[{'sha':'p'}],'commit':{'committer':{'date':'$(ago 40)'}}},{'sha':'m1','parents':[{'sha':'a1'},{'sha':'main'}],'commit':{'committer':{'date':'$(ago 10)'}}}]}"
run_after > /dev/null
assert_contains "visual:update が付く" "$(labels_of 58)" "visual:update"
assert_not_contains "人間に回さない" "$(labels_of 58)" "ai:stuck"
assert_contains "取り込み後の1回目として数える" "$(comments_of 58)" "1/2回目"

echo "== main を取り込んだ後に2回撮り直した：人間に回す"
setup_case '`visual:update` で撮り直してください。' "$visual_only"
state_py "
for i in (60, 61): s['comments'].append({'id':i,'issue':'58','body':'撮り直します\\n<!-- auto-visual-update -->','user':{'login':'p'},'created_at':'$(ago 5)','updated_at':'$(ago 5)'})
s['pr_commits']={'58':[{'sha':'m1','parents':[{'sha':'a1'},{'sha':'main'}],'commit':{'committer':{'date':'$(ago 10)'}}}]}"
run_after > /dev/null
assert_contains "ai:stuck" "$(labels_of 58)" "ai:stuck"

echo "== 人間が ai:stuck を外して続きを頼んだ後は、数え直す"
setup_case '`visual:update` で撮り直してください。' "$visual_only"
state_py "
for i in (60, 61): s['comments'].append({'id':i,'issue':'58','body':'撮り直します\\n<!-- auto-visual-update -->','user':{'login':'p'},'created_at':'$(ago 30)','updated_at':'$(ago 30)'})
s['comments'].append({'id':62,'issue':'58','body':'続きから\\n<!-- auto-resume -->','user':{'login':'p'},'created_at':'$(ago 20)','updated_at':'$(ago 20)'})"
run_after > /dev/null
assert_contains "visual:update が付く" "$(labels_of 58)" "visual:update"
assert_not_contains "人間に回さない" "$(labels_of 58)" "ai:stuck"

echo "== 2回撮り直したあと、3回目の同じ依頼は人間に回す"
setup_case '`visual:update` で撮り直してください。' "$visual_only"
state_py "
for i in (60, 61): s['comments'].append({'id':i,'issue':'58','body':'撮り直します\\n<!-- auto-visual-update -->','user':{'login':'p'},'created_at':'$(ago 30)','updated_at':'$(ago 30)'})"
run_after > /dev/null
assert_contains "ai:stuck" "$(labels_of 58)" "ai:stuck"
assert_not_contains "visual:update は付けない" "$(labels_of 58)" "visual:update"
assert_contains "2回まで、と書く" "$(comments_of 58)" "2回まで"

echo "== 1回撮り直したあとは、もう1回撮り直す"
setup_case '`visual:update` で撮り直してください。' "$visual_only"
state_py "
s['comments'].append({'id':60,'issue':'58','body':'撮り直します\\n<!-- auto-visual-update -->','user':{'login':'p'},'created_at':'$(ago 30)','updated_at':'$(ago 30)'})"
run_after > /dev/null
assert_contains "visual:update が付く" "$(labels_of 58)" "visual:update"
assert_contains "2回目と書く" "$(comments_of 58)" "2/2回目"

reruns() { python3 -c "import json,os;print(len(json.load(open(os.environ['MOCK_STATE'])).get('reruns',[])))"; }
template_issues() { python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print(sum(1 for m in s.get('issues_meta',{}).values() if m.get('title','').startswith('パイプライン側のテストが落ちている')))"; }
both_real='[{"name":"見た目のテスト","conclusion":"failure"},{"name":"テスト","conclusion":"failure"}]'
both_pipe='[{"name":"見た目のテスト","conclusion":"failure"},{"name":"スクリプトのテスト","conclusion":"failure"}]'
rerun_done="s['comments'].append({'id':52,'issue':'58','body':'やり直し（コミット abc）\\\\n<!-- auto-pipeline-test-rerun -->','user':{'login':'p'},'created_at':'$(ago 1)','updated_at':'$(ago 1)'})"

echo "== ほかのチェックも落ちている・まだやり直していない：人間に回さず、落ちたジョブを1回だけやり直す"
setup_case '`visual:update` で撮り直してください。' "$both_real"
run_after > /dev/null
assert_eq "落ちたジョブをやり直す" "1" "$(reruns)"
assert_not_contains "人間に回さない" "$(labels_of 58)" "ai:stuck"
assert_not_contains "visual:update はまだ付けない" "$(labels_of 58)" "visual:update"
assert_contains "コミットつきの印" "$(comments_of 58)" "コミット abc"

echo "== やり直しても見た目以外（PRの変更が原因）が落ちる：見た目以外だけを直すよう修正AIに頼む（直す回数に数える）"
setup_case '`visual:update` で撮り直してください。' "$both_real"
state_py "$rerun_done"
run_after > /dev/null
assert_eq "もうやり直さない" "0" "$(reruns)"
assert_not_contains "人間に回さない" "$(labels_of 58)" "ai:stuck"
assert_contains "見た目以外だけを直す依頼" "$(comments_of 58)" "見た目以外の失敗（テスト）だけを"
assert_contains "画像の差は気にしない" "$(comments_of 58)" "画像の差は気にしなくていいです"
assert_eq "直す依頼が1つ増える" "2" "$(comments_of 58 | grep -c '<!-- auto-fix -->')"

echo "== 見た目以外だけを直すよう頼んだのに、また変更なし：人間に回す"
setup_case '`visual:update` で撮り直してください。' "$both_real"
state_py "$rerun_done
s['comments'][0]['body'] += '\\n<!-- auto-fix-nonvisual -->'"
run_after > /dev/null
assert_contains "ai:stuck" "$(labels_of 58)" "ai:stuck"
assert_eq "直す依頼は増えない" "1" "$(comments_of 58 | grep -c '<!-- auto-fix -->')"

echo "== 変更なしで終わり、パイプライン側だけ落ちている（やり直し済み）：人間に回り、テンプレートに Issue ができる"
setup_case '`visual:update` で撮り直してください。.github/ は触れません。' "$both_pipe"
state_py "$rerun_done"
PIPELINE_TEMPLATE_REPO=o/tpl run_after > /dev/null
assert_contains "ai:stuck" "$(labels_of 58)" "ai:stuck"
assert_contains "PRと関係ない所のテストと書く" "$(comments_of 58)" "PRと関係ない所（パイプライン側）のテスト"
assert_eq "テンプレートに Issue ができる" "1" "$(template_issues)"
assert_not_contains "修正AIには頼まない" "$(comments_of 58)" "auto-fix-nonvisual"

echo "== 同じ題名の開いた Issue があれば、作らずコメントで足す"
setup_case '`visual:update` で撮り直してください。' "$both_pipe"
state_py "$rerun_done
s['issues_meta']={'200':{'title':'パイプライン側のテストが落ちている（たまに落ちる・壊れている）','state':'open'}}
s['labels']['200']=[]"
PIPELINE_TEMPLATE_REPO=o/tpl run_after > /dev/null
assert_contains "ai:stuck" "$(labels_of 58)" "ai:stuck"
assert_eq "Issue は増えない" "1" "$(template_issues)"
assert_contains "既存の Issue にコメントで足す" "$(comments_of 200)" "o/r#58"

echo "== パイプライン側が落ちていても、PRが .github/ を触っている：PRの変更が原因かもしれないので、修正AIに頼む"
setup_case '`visual:update` で撮り直してください。' "$both_pipe"
state_py "$rerun_done
s['files']=['.github/scripts/x.sh']"
run_after > /dev/null
assert_not_contains "人間に回さない" "$(labels_of 58)" "ai:stuck"
assert_contains "見た目以外だけを直す依頼" "$(comments_of 58)" "見た目以外の失敗"

echo "== AIも、レビューも、PRの説明も撮り直しを頼んでいない：撮り直さない"
setup_case 'うまくいきませんでした。' "$visual_only"
run_after > /dev/null
assert_contains "ai:stuck" "$(labels_of 58)" "ai:stuck"
assert_not_contains "visual:update は付けない" "$(labels_of 58)" "visual:update"

echo "== main とコンフリクトしたまま：撮り直しは動かないので visual:update を付けない。拒否があれば、手がかりを付けて1回だけ出し直す"
exec_file="$MOCK_DIR/exec.json"
printf '%s' '[{"type":"result","subtype":"success","result":"","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"git checkout --ours tests/visual/__screenshots__"}}]}]' > "$exec_file"
setup_case '基準の画像12枚がコンフリクトしています。`git checkout --ours` が実行できませんでした。解消したら `visual:update` ラベルで撮り直してください。' "$visual_only"
state_py "s['pulls'][0]['mergeable_state']='dirty'"
out=$(RUN_STARTED=$(ago 1) CONCLUSION=success EXECUTION_FILE="$exec_file" run_script after-mention.sh)
c=$(comments_of 58)
assert_not_contains "visual:update を付けない" "$(labels_of 58)" "visual:update"
assert_not_contains "撮り直しの回数を使わない" "$c" "auto-visual-update"
assert_contains "許可の拒否として出し直す" "$c" "auto-perm-retry"
assert_contains "拒否された操作を書く" "$c" "git checkout --ours tests/visual/__screenshots__"
assert_contains "解消のしかたを書く" "$c" "git checkout --theirs -- パス"
assert_not_contains "人間に回さない" "$(labels_of 58)" "ai:stuck"

echo "== コンフリクトしたままで、拒否も無い：理由を書いて人間に回す（黙って visual:update を付けて止まらない）"
setup_case '基準の画像がコンフリクトしています。`visual:update` ラベルで撮り直してください。' "$visual_only"
state_py "s['pulls'][0]['mergeable_state']='dirty'"
run_after > /dev/null
assert_not_contains "visual:update を付けない" "$(labels_of 58)" "visual:update"
assert_contains "人間に回す" "$(labels_of 58)" "ai:stuck"
assert_contains "理由" "$(comments_of 58)" "コンフリクトを解消できず"

echo "== コンフリクトが無ければ、今までどおり撮り直す"
setup_case '基準の画像が古いだけです。`visual:update` ラベルで撮り直してください。' "$visual_only"
state_py "s['pulls'][0]['mergeable_state']='clean'"
run_after > /dev/null
assert_contains "visual:update が付く" "$(labels_of 58)" "visual:update"

finish
