#!/usr/bin/env bash
# CIが落ちたあと（after-ci.sh）：見た目だけが落ちて、意図した変更なら基準画像を自動で撮り直す。それ以外はAIに直させる
source "$(dirname "$0")/lib.sh"
setup_mock

run_case() { # PR本文 落ちたステップ名
  python3 - "$1" "$2" <<'PY'
import json, os, sys
pr = {'number': 58, 'body': sys.argv[1], 'state': 'open', 'head': {'sha': 'abc', 'ref': 'claude/issue-54-x'}, 'updated_at': '2026-01-01T00:00:00Z'}
steps = [{'name': '型チェック', 'conclusion': 'success'}] + [{'name': n, 'conclusion': 'failure'} for n in sys.argv[2].split(',')] + [{'name': '見た目のテストの結果（差分の画像）を残す', 'conclusion': 'success'}]
s = {'next_id': 0, 'comments': [], 'labels': {'58': []}, 'issue_updated': {}, 'pulls': [pr], 'jobs': [{'steps': steps}], 'checks': [], 'runs': [], 'branches': [], 'authors': {},
     'files': os.environ.get('PR_FILES', 'src/app/page.tsx').split(), 'rerun_fail': bool(os.environ.get('RERUN_FAIL'))}
json.dump(s, open(os.environ['MOCK_STATE'], 'w'))
PY
  RUN_ID=1 CONCLUSION=failure HEAD_SHA=abc HEAD_BRANCH=claude/issue-54-x run_script after-ci.sh > /dev/null
}

echo "== 見た目だけ落ちた・PRに visual:update の記載あり → 撮り直しのラベル"
run_case "Closes #1 基準の画像は visual:update で" "見た目のテスト"
assert_contains "visual:update が付く" "$(labels_of 58)" "visual:update"

echo "== 見た目だけ落ちた・記載なし → 撮り直さず、AIに直させる"
run_case "Closes #1" "見た目のテスト"
assert_not_contains "visual:update は付かない" "$(labels_of 58)" "visual:update"
assert_contains "直す依頼のコメントが付く" "$(comments_of 58)" "auto-fix"

echo "== 型チェックが落ちた → 記載があっても AIに直させる"
run_case "visual:update" "型チェック"
assert_not_contains "visual:update は付かない" "$(labels_of 58)" "visual:update"
assert_contains "直す依頼のコメントが付く" "$(comments_of 58)" "auto-fix"

reruns() { python3 -c "import json,os;print(len(json.load(open(os.environ['MOCK_STATE'])).get('reruns',[])))"; }

echo "== パイプライン自体のテストだけが落ちた・PRは .github/ を触っていない → AIに頼まず、1回だけCIをやり直す"
run_case "Closes #1" "スクリプトのテスト"
assert_eq "落ちたジョブをやり直す" "1" "$(reruns)"
assert_not_contains "AIには直させない" "$(comments_of 58)" "auto-fix"
assert_contains "印つきで知らせる" "$(comments_of 58)" "auto-pipeline-test-rerun"

rerun_tokens() { python3 -c "import json,os;print(','.join(json.load(open(os.environ['MOCK_STATE'])).get('rerun_tokens',[])))"; }
echo "== やり直しは READ_TOKEN（Actions を書けるトークン）で呼ぶ（App の鍵 GH_TOKEN は Actions が Read のため）"
READ_TOKEN=readtok GH_TOKEN=apptok run_case "Closes #1" "スクリプトのテスト"
assert_eq "READ_TOKEN で呼ぶ" "readtok" "$(rerun_tokens)"

echo "== やり直しても落ちた（印がもうある） → 人間に回す"
run_case "Closes #1" "shellcheck"
state_py "s['reruns']=[]; s['comments']=[{'id':9,'issue':'58','body':'x <!-- auto-pipeline-test-rerun -->','user':{'login':'p'},'created_at':'$(ago 5)','updated_at':'$(ago 5)'}]"
RUN_ID=1 CONCLUSION=failure HEAD_SHA=abc HEAD_BRANCH=claude/issue-54-x run_script after-ci.sh > /dev/null
assert_contains "ai:stuck" "$(labels_of 58)" "ai:stuck"
assert_eq "もうやり直さない" "0" "$(reruns)"
assert_not_contains "AIには直させない" "$(comments_of 58)" "auto-fix"

echo "== やり直しの API が断られた → 人間に回す"
RERUN_FAIL=1 run_case "Closes #1" "スクリプトのテスト"
assert_contains "ai:stuck" "$(labels_of 58)" "ai:stuck"

echo "== actionlint の手順だけが落ちた・PRは .github/ を触っていない → AIに頼まず、1回だけやり直し、手順の名前を知らせる"
run_case "Closes #1" "ワークフローの確認（actionlint）"
assert_eq "落ちたジョブをやり直す" "1" "$(reruns)"
assert_not_contains "AIには直させない" "$(comments_of 58)" "auto-fix"
assert_contains "落ちた手順の名前を入れる" "$(comments_of 58)" "（ワークフローの確認（actionlint））"
echo "== actionlint がやり直しても落ちた → 人間に回す（手順の名前つき）"
state_py "s['reruns']=[]; s['comments']=[{'id':9,'issue':'58','body':'x <!-- auto-pipeline-test-rerun -->','user':{'login':'p'},'created_at':'$(ago 5)','updated_at':'$(ago 5)'}]"
RUN_ID=1 CONCLUSION=failure HEAD_SHA=abc HEAD_BRANCH=claude/issue-54-x run_script after-ci.sh > /dev/null
assert_contains "ai:stuck" "$(labels_of 58)" "ai:stuck"
assert_contains "手順の名前が理由に出る" "$(comments_of 58)" "ワークフローの確認（actionlint）"
assert_eq "もうやり直さない" "0" "$(reruns)"
assert_not_contains "AIには直させない" "$(comments_of 58)" "auto-fix"

echo "== 見た目＋パイプライン側が落ちた → AIに頼まず、1回だけやり直す（撮り直しはまだ頼まない）"
run_case "Closes #1 visual:update" "見た目のテスト,スクリプトのテスト"
assert_eq "落ちたジョブをやり直す" "1" "$(reruns)"
assert_not_contains "AIには直させない" "$(comments_of 58)" "auto-fix"
assert_not_contains "まだ撮り直さない" "$(labels_of 58)" "visual:update"
assert_contains "コミットつきの印" "$(comments_of 58)" "コミット abc"

echo "== やり直し済み（同じコミット）でまだ見た目＋パイプライン側が落ちる → 見た目以外だけを修正AIに頼む"
run_case "Closes #1 visual:update" "見た目のテスト,スクリプトのテスト"
state_py "s['reruns']=[]; s['comments']=[{'id':9,'issue':'58','body':'x（コミット abc）<!-- auto-pipeline-test-rerun -->','user':{'login':'p'},'created_at':'$(ago 5)','updated_at':'$(ago 5)'}]"
RUN_ID=1 CONCLUSION=failure HEAD_SHA=abc HEAD_BRANCH=claude/issue-54-x run_script after-ci.sh > /dev/null
assert_eq "もうやり直さない" "0" "$(reruns)"
assert_contains "直す依頼が付く" "$(comments_of 58)" "auto-fix"
assert_contains "見た目以外だけを直す依頼" "$(comments_of 58)" "見た目以外の失敗だけを直してください"
assert_not_contains "人間には回さない" "$(labels_of 58)" "ai:stuck"

echo "== 前のコミットでやり直した印は、新しいコミットのやり直しを止めない"
run_case "Closes #1 visual:update" "見た目のテスト,スクリプトのテスト"
state_py "s['reruns']=[]; s['comments']=[{'id':9,'issue':'58','body':'x（コミット old）<!-- auto-pipeline-test-rerun -->','user':{'login':'p'},'created_at':'$(ago 5)','updated_at':'$(ago 5)'}]"
RUN_ID=1 CONCLUSION=failure HEAD_SHA=abc HEAD_BRANCH=claude/issue-54-x run_script after-ci.sh > /dev/null
assert_eq "やり直す" "1" "$(reruns)"

echo "== やり直しで通った後に見た目だけ落ちる → 撮り直しへ進む"
run_case "Closes #1 visual:update" "見た目のテスト"
state_py "s['comments']=[{'id':9,'issue':'58','body':'x（コミット abc）<!-- auto-pipeline-test-rerun -->','user':{'login':'p'},'created_at':'$(ago 5)','updated_at':'$(ago 5)'}]"
RUN_ID=1 CONCLUSION=failure HEAD_SHA=abc HEAD_BRANCH=claude/issue-54-x run_script after-ci.sh > /dev/null
assert_contains "visual:update が付く" "$(labels_of 58)" "visual:update"

echo "== 見た目＋パイプライン側が落ちて、PRが .github/ を触っている → やり直さず、AIに直させる"
PR_FILES=".github/scripts/watchdog.sh" run_case "Closes #1 visual:update" "見た目のテスト,スクリプトのテスト"
assert_eq "やり直さない" "0" "$(reruns)"
assert_contains "直す依頼のコメントが付く" "$(comments_of 58)" "auto-fix"

echo "== 見た目＋型チェックが落ちた（パイプライン側ではない） → やり直さず、AIに直させる"
run_case "Closes #1 visual:update" "見た目のテスト,型チェック"
assert_eq "やり直さない" "0" "$(reruns)"
assert_contains "直す依頼のコメントが付く" "$(comments_of 58)" "auto-fix"

echo "== PRが .github/ を触っている（テンプレート自身など） → 今までどおりAIに直させる"
PR_FILES=".github/scripts/watchdog.sh" run_case "Closes #1" "スクリプトのテスト"
assert_eq "やり直さない" "0" "$(reruns)"
assert_contains "直す依頼のコメントが付く" "$(comments_of 58)" "auto-fix"

echo "== CIが取り消された（時間切れなど） → AIに頼まず、1回だけやり直す（PR #161）"
run_case "Closes #1" "型チェック"
state_py "s['reruns']=[]; s['comments']=[]; s['labels']['58']=['ai:review']"
RUN_ID=1 CONCLUSION=cancelled HEAD_SHA=abc HEAD_BRANCH=claude/issue-54-x run_script after-ci.sh > /dev/null
assert_eq "取り消されたジョブをやり直す" "1" "$(reruns)"
assert_contains "印つきで知らせる" "$(comments_of 58)" "auto-ci-cancel-rerun"
assert_not_contains "AIには直させない" "$(comments_of 58)" "auto-fix"
assert_not_contains "人間には回さない" "$(labels_of 58)" "ai:stuck"

echo "== 同じコミットでまた取り消された（印がもうある） → 人間に回す"
state_py "s['reruns']=[]"
RUN_ID=1 CONCLUSION=cancelled HEAD_SHA=abc HEAD_BRANCH=claude/issue-54-x run_script after-ci.sh > /dev/null
assert_eq "もうやり直さない" "0" "$(reruns)"
assert_contains "ai:stuck" "$(labels_of 58)" "ai:stuck"

echo "== 前のコミットで取り消された印は数えない → 新しいコミットでは、もう一度やり直す"
run_case "Closes #1" "型チェック"
state_py "s['reruns']=[]; s['comments']=[{'id':9,'issue':'58','body':'x コミット old <!-- auto-ci-cancel-rerun -->','user':{'login':'p'},'created_at':'$(ago 5)','updated_at':'$(ago 5)'}]"
RUN_ID=1 CONCLUSION=cancelled HEAD_SHA=abc HEAD_BRANCH=claude/issue-54-x run_script after-ci.sh > /dev/null
assert_eq "やり直す" "1" "$(reruns)"

sync_case() { # CIの結果 mainとの差
  python3 - "$2" <<'PY'
import json, os, sys
pr = {'number': 70, 'body': os.environ.get('SYNC_BODY', '<!-- pipeline-sync -->'), 'user': {'login': os.environ.get('SYNC_AUTHOR', 'gaku-ai-pipeline[bot]')}, 'state': 'open', 'head': {'sha': 'abc', 'ref': 'pipeline-sync/123abcd'}, 'updated_at': '2026-01-01T00:00:00Z'}
s = {'next_id': 0, 'comments': [], 'labels': {'70': []}, 'issue_updated': {}, 'pulls': [pr], 'jobs': [], 'checks': [], 'runs': [], 'branches': [{'name': 'pipeline-sync/123abcd'}], 'authors': {}, 'ahead_by': int(sys.argv[1])}
if os.environ.get('MERGE_FAIL'): s['merge_fail'] = os.environ['MERGE_FAIL']
if os.environ.get('MERGE_FAIL_TIMES'): s['merge_fail_times'] = int(os.environ['MERGE_FAIL_TIMES'])
if os.environ.get('UPDATE_BRANCH_FAIL'): s['update_branch_fail'] = True
if os.environ.get('COMPARE_FAIL'): s['compare_fail'] = True
if os.environ.get('COMPARE_CLOSE'): s['compare_close_pr'] = 70
json.dump(s, open(os.environ['MOCK_STATE'], 'w'))
PY
  RUN_ID=1 CONCLUSION="$1" HEAD_SHA=abc HEAD_BRANCH=pipeline-sync/123abcd run_script after-ci.sh > /dev/null
}
merged_of() { python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print(','.join(map(str,s.get('merged',[]))))"; }

echo "== パイプラインの更新のPR：CIが通ればレビューなしでマージする"
sync_case success 0
assert_eq "マージされる" "70" "$(merged_of)"
assert_not_contains "レビューに回さない" "$(labels_of 70)" "ai:review"
assert_not_contains "ブランチが消える" "$(branch_names)" "pipeline-sync/123abcd"

echo "== パイプラインの更新のPR：CIが落ちたら、AIに直させず人間に回す"
sync_case failure 0
assert_eq "マージしない" "" "$(merged_of)"
assert_contains "ai:stuck が付く" "$(labels_of 70)" "ai:stuck"
assert_not_contains "AIに直させない" "$(comments_of 70)" "auto-fix"

echo "== AIが作った pipeline-sync/ のPRは、近道にしない（ふつうにレビューへ）"
SYNC_AUTHOR='claude[bot]' sync_case success 0
assert_eq "マージしない" "" "$(merged_of)"
assert_contains "レビューに回す" "$(labels_of 70)" "ai:review"
echo "== 印の無い pipeline-sync/ のPRも、近道にしない"
SYNC_BODY='x' sync_case success 0
assert_eq "マージしない" "" "$(merged_of)"

echo "== パイプラインの更新のPR：マージできなかったら、黙らず人間に回す"
MERGE_FAIL='HTTP 405: Merge conflict' sync_case success 0
assert_eq "マージされない" "" "$(merged_of)"
assert_contains "ai:stuck が付く" "$(labels_of 70)" "ai:stuck"
assert_contains "理由をコメントする" "$(comments_of 70)" "マージできませんでした"
assert_not_contains "AIに直させない" "$(comments_of 70)" "auto-fix"


echo "== パイプラインの更新のPR：マージが一時的なエラー（502）なら、待って試し直す（1回の 502 で人間に回さない）"
MERGE_FAIL_TIMES=2 sync_case success 0
assert_eq "3回目でマージされる" "70" "$(merged_of)"
assert_not_contains "人間に回さない" "$(labels_of 70)" "ai:stuck"
MERGE_FAIL_TIMES=3 sync_case success 0
assert_eq "3回とも駄目ならマージしない" "" "$(merged_of)"
assert_contains "人間に回す" "$(labels_of 70)" "ai:stuck"

update_branches() { python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print(','.join(map(str,s.get('update_branches',[]))))"; }
echo "== パイプラインの更新のPR：main が先に進んでいれば取り込む（マージはCIのあと）"
sync_case success 3
assert_eq "取り込む" "70" "$(update_branches)"
assert_eq "まだマージしない" "" "$(merged_of)"
assert_not_contains "人間には回さない" "$(labels_of 70)" "ai:stuck"

echo "== パイプラインの更新のPR：main の取り込みが失敗した（コンフリクト・一時的なエラー）→ 黙らず人間に回す"
: > "$MOCK_DIR/curl.log"
UPDATE_BRANCH_FAIL=1 sync_case success 3
assert_contains "ai:stuck が付く" "$(labels_of 70)" "ai:stuck"
assert_contains "理由をコメントする" "$(comments_of 70)" "main の変更を取り込めませんでした"
assert_not_contains "AIに直させない" "$(comments_of 70)" "auto-fix"
assert_contains "通知する" "$(cat "$MOCK_DIR/curl.log")" "配られた更新に main を取り込めませんでした"
assert_eq "マージしない" "" "$(merged_of)"

echo "== パイプラインの更新のPR：CIの途中で閉じられて main と比べられない → 失敗にせず、何もしない（新しい配布に置き換わった）"
rc=0; COMPARE_FAIL=1 COMPARE_CLOSE=1 RUN_ID=1 sync_case success 0 || rc=$?
assert_eq "失敗にしない" "0" "$rc"
assert_eq "マージしない" "" "$(merged_of)"
assert_not_contains "ai:stuck を付けない" "$(labels_of 70)" "ai:stuck"
assert_eq "コメントしない" "" "$(comments_of 70)"

echo "== パイプラインの更新のPR：開いたままなのに main と比べられない → 今まで通り失敗にする（黙ってマージしない）"
rc=0; COMPARE_FAIL=1 sync_case success 0 || rc=$?
assert_eq "失敗にする" "1" "$rc"
assert_eq "マージしない" "" "$(merged_of)"

echo "== ふつうのPR：CIの途中で閉じられて main と比べられない → 失敗にせず、何もしない"
state_py "s['pulls']=[{'number':58,'body':'Closes #1','state':'open','head':{'sha':'abc','ref':'claude/issue-54-x'},'updated_at':'2026-01-01T00:00:00Z'}]; s['labels']={'58':[]}; s['comments']=[]; s['compare_fail']=True; s['compare_close_pr']=58"
rc=0; RUN_ID=1 CONCLUSION=success HEAD_SHA=abc HEAD_BRANCH=claude/issue-54-x run_script after-ci.sh > /dev/null || rc=$?
assert_eq "失敗にしない" "0" "$rc"
assert_not_contains "ai:stuck を付けない" "$(labels_of 58)" "ai:stuck"

finish
