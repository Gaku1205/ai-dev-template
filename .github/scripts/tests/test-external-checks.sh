#!/usr/bin/env bash
# CI 以外のチェック（Vercel など、GitHub Actions 以外が付ける check run・コミットステータス）が通っていないとき：
# 黙ってマージしないまま止まらず、名前と理由をPRに書き、時間をおいて確かめ直し（AIは動かさない）、続くなら人間に回す
source "$(dirname "$0")/lib.sh"
setup_mock
printf '%s\n' '# 普通のリポジトリ' > "$MOCK_DIR/CLAUDE_default.md"
export CLAUDE_MD="$MOCK_DIR/CLAUDE_default.md"
export EXTERNAL_CHECK_WAIT_SEC=0
cd "$SCRIPTS_DIR/../.." || exit 1

CI_OK='{"name":"check","status":"completed","conclusion":"success","app":{"slug":"github-actions"}}'
vercel_check() { # 状態（completed など） 結果（failure など。無ければ null）
  echo '{"name":"Vercel","status":"'"$1"'","conclusion":'"$([ -n "${2:-}" ] && echo "\"$2\"" || echo null)"',"app":{"slug":"vercel"},"output":{"title":"Deployment failed"},"details_url":"https://vercel.example/d/1"}'
}
# PR #58（先頭 abc）。レビューは「指摘なし」で済んでいる。引数：check run の配列の中身 [足す項目（JSON の中身）]
setup() {
  init_state '{"labels":{"58":[]},"files":["src/a.ts"],"pulls":[{"number":58,"state":"open","mergeable_state":"clean","body":"Closes #54","head":{"sha":"abc","ref":"claude/issue-54-x","repo":{"full_name":"o/r"}},"updated_at":"'"$(ago 3)"'"}],"checks":['"$1"'],"branches":[{"name":"claude/issue-54-x","date":"2026-01-01T00:00:00Z"}]'"${2:+,$2}"'}'
  state_py "s['comments'].append({'id':500,'issue':'58','body':'## Code review\n\nNo issues found.','user':{'login':'github-actions[bot]'},'created_at':'$(ago 5)','updated_at':'$(ago 5)'})"
}
after_review() { CONCLUSION=success HEAD_SHA=abc HEAD_BRANCH=claude/issue-54-x run_script after-review.sh; }
merged() { python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print(','.join(map(str,s.get('merged',[]))))"; }
marks() { comments_of 58 | grep -c 'external-checks: abc' || true; }

echo "== CIもレビューも通ったが、CI 以外の check run が落ちている：名前と理由を書いて、やり直し待ち（黙って終わらない）"
setup "$CI_OK,$(vercel_check completed failure)"
out=$(after_review)
assert_eq "マージしない" "" "$(merged)"
assert_contains "やり直し待ち" "$(labels_of 58)" "ai:retry"
assert_contains "やり直しの種類は merge（AIを動かさない）" "$(comments_of 58)" "kind=merge"
assert_contains "チェックの名前を書く" "$(comments_of 58)" '`Vercel`（check run）：落ちています'
assert_contains "理由を書く" "$(comments_of 58)" "failure：Deployment failed"
assert_contains "見に行く先を書く" "$(comments_of 58)" "https://vercel.example/d/1"
assert_contains "何回目かを書く" "$(comments_of 58)" "1/2回目"
assert_eq "先頭コミットの印が付く" "1" "$(marks)"
assert_not_contains "まだ人間には回さない" "$(labels_of 58)" "ai:stuck"

echo "== 待ち時間が過ぎても落ちたまま：見張り役が確かめ直す（レビューはやり直さない）。もう一度だけ待つ"
age_retry_comments 40
out=$(run_script watchdog.sh)
assert_contains "マージの判断をやり直す" "$out" "merge をやり直します"
assert_not_contains "レビューに回さない（AIを動かさない）" "$(labels_of 58)" "ai:review"
assert_contains "もう一度やり直し待ち" "$(labels_of 58)" "ai:retry"
assert_eq "印が2つになる" "2" "$(marks)"
assert_contains "2回目と書く" "$(comments_of 58)" "2/2回目"

echo "== それでも落ちたまま：人間に回す（チェックの名前と理由を書く）"
age_retry_comments 40
run_script watchdog.sh > /dev/null
assert_contains "人間に回す" "$(labels_of 58)" "ai:stuck"
assert_not_contains "やり直し待ちは外れる" "$(labels_of 58)" "ai:retry"
assert_contains "止めた理由に名前が入る" "$(comments_of 58)" "CI 以外のチェックが通っていません（Vercel）。時間をおいて2回確かめ直しても、変わりませんでした"
assert_eq "印は増えない" "2" "$(marks)"
assert_contains "紐づく Issue も止める" "$(labels_of 54)" "ai:stuck"

echo "== 人間が再開したあとは、数え直す（すぐ人間に戻さない）"
state_py "
s['labels']['58'] = []
s['comments'].append({'id':900,'issue':'58','body':'▶ 続けます\n\n<!-- auto-resume -->','user':{'login':'pipeline[bot]'},'created_at':'$(ago 0)','updated_at':'$(ago 0)'})
s['now'] = '$(date -u -d '1 minute' +%Y-%m-%dT%H:%M:%SZ)'"
after_review > /dev/null
assert_contains "やり直し待ちに戻る" "$(labels_of 58)" "ai:retry"
assert_not_contains "人間に回さない" "$(labels_of 58)" "ai:stuck"

echo "== 待っている間にチェックが通った：見張り役がそのままマージする（レビューはやり直さない）"
setup "$CI_OK,$(vercel_check completed failure)"
after_review > /dev/null
state_py "s['checks'] = [$(printf '%s' "$CI_OK" | sed 's/null/None/g'), {'name':'Vercel','status':'completed','conclusion':'success','app':{'slug':'vercel'}}]"
age_retry_comments 40
run_script watchdog.sh > /dev/null
assert_eq "マージされる" "58" "$(merged)"
assert_not_contains "レビューに回さない" "$(labels_of 58)" "ai:review"
assert_not_contains "やり直し待ちは外れる" "$(labels_of 58)" "ai:retry"

echo "== まだ終わっていないだけ：少し待ち、その間に通ればそのままマージする"
setup "$CI_OK,$(vercel_check in_progress)" '"checks_flip_after":1,"checks_later":['"$CI_OK"',{"name":"Vercel","status":"completed","conclusion":"success","app":{"slug":"vercel"}}]'
after_review > /dev/null
assert_eq "マージされる" "58" "$(merged)"
assert_eq "コメントは増えない" "0" "$(marks)"

echo "== 待っても終わらない：「まだ終わっていません」と書いて、やり直し待ち"
setup "$CI_OK,$(vercel_check in_progress)"
after_review > /dev/null
assert_eq "マージしない" "" "$(merged)"
assert_contains "名前と状態を書く" "$(comments_of 58)" '`Vercel`（check run）：まだ終わっていません（in_progress'
assert_contains "やり直し待ち" "$(labels_of 58)" "ai:retry"

echo "== CI（GitHub Actions）のチェックがまだ動いている：今までどおり、何も書かずに待つ（CIが終われば進行役が進める）"
setup '{"name":"check","status":"in_progress","conclusion":null,"app":{"slug":"github-actions"}}'
out=$(after_review)
assert_contains "ログに出す" "$out" "CIがまだ全部通っていない"
assert_eq "ラベルは変わらない" "" "$(labels_of 58)"
assert_eq "コメントは増えない" "0" "$(marks)"

echo "== コミットステータスだけが落ちている：今までどおりマージを試す（GitHub が断らなければマージできる）"
setup "$CI_OK" '"statuses":[{"context":"Vercel","state":"failure","description":"Deployment has failed","target_url":"https://vercel.example/d/2"}]'
after_review > /dev/null
assert_eq "マージされる" "58" "$(merged)"

echo "== マージを GitHub が断った＋コミットステータスが落ちている：落ちているステータスの名前と理由を書く"
setup "$CI_OK" '"merge_fail":"HTTP 405: Required status check \"Vercel\" is failing","statuses":[{"context":"Vercel","state":"failure","description":"Deployment has failed","target_url":"https://vercel.example/d/2"},{"context":"ok-one","state":"success"}]'
state_py "s['pulls'][0]['mergeable_state'] = 'blocked'"
after_review > /dev/null
assert_eq "マージされない" "" "$(merged)"
assert_contains "ステータスの名前と理由" "$(comments_of 58)" '`Vercel`（コミットステータス）：落ちています（failure：Deployment has failed） https://vercel.example/d/2'
assert_not_contains "通っているステータスは書かない" "$(comments_of 58)" "ok-one"
assert_contains "マージの失敗の文も入る" "$(comments_of 58)" "自動でマージできませんでした（状態：blocked"
assert_contains "やり直しの種類は merge" "$(comments_of 58)" "kind=merge"

echo "== マージを GitHub が断った（落ちているチェックは見つからない）：やり直し待ち。見張り役は、AIを動かさずにマージだけをやり直す"
setup "$CI_OK" '"merge_fail":"HTTP 405: Pull Request is not mergeable"'
state_py "s['pulls'][0]['mergeable_state'] = 'blocked'"
after_review > /dev/null
assert_contains "やり直しの種類は merge" "$(comments_of 58)" "kind=merge"
assert_contains "理由に状態が入る" "$(comments_of 58)" "状態：blocked"
state_py "del s['merge_fail']"
age_retry_comments 40
run_script watchdog.sh > /dev/null
assert_eq "次の見張りでマージされる" "58" "$(merged)"
assert_not_contains "レビューに回さない" "$(labels_of 58)" "ai:review"

echo "== マージのやり直しを待つ間に、新しいコミットが入った（先頭のレビュー結果が無い）：何もしない（CIとレビューの流れに任せる）"
setup "$CI_OK,$(vercel_check completed failure)"
after_review > /dev/null
state_py "s['comments'] = [c for c in s['comments'] if not c['body'].startswith('## Code review')]"
age_retry_comments 40
out=$(run_script watchdog.sh)
assert_contains "ログに出す" "$out" "先頭コミットのレビュー結果がまだ無いので、マージはやり直しません"
assert_eq "マージしない" "" "$(merged)"
assert_not_contains "やり直し待ちは外れる" "$(labels_of 58)" "ai:retry"
assert_not_contains "人間には回さない" "$(labels_of 58)" "ai:stuck"

echo "== 「CIが通っているか」は CI の最新の実行で決める（#201）"
ci_run() { # id 状態 結果 作られた時刻
  echo '{"id":'"$1"',"name":"CI","event":"pull_request","status":"'"$2"'","conclusion":'"$([ -n "${3:-}" ] && echo "\"$3\"" || echo null)"',"created_at":"'"$4"'"}'
}
SHOOT_CANCELLED='{"name":"shoot","status":"completed","conclusion":"cancelled","app":{"slug":"github-actions"}}'
with_runs() { state_py "s['runs'] = [$(printf '%s' "$1" | sed 's/null/None/g')]"; }

setup "$CI_OK,$SHOOT_CANCELLED"
with_runs "$(ci_run 1 completed success 2026-01-01T00:00:00Z)"
after_review > /dev/null
assert_eq "取り消された shoot が残っていても、CI が success ならマージへ進む" "58" "$(merged)"

for case in "動いている|in_progress||" "落ちている|completed|failure" "取り消された|completed|cancelled"; do
  IFS='|' read -r label st concl <<< "$case"
  setup "$CI_OK"
  with_runs "$(ci_run 1 "$st" "$concl" 2026-01-01T00:00:00Z)"
  out=$(after_review)
  assert_eq "CI が$label：マージしない" "" "$(merged)"
  assert_contains "CI が$label：理由をログに出す" "$out" "CIがまだ全部通っていない"
done

setup "$CI_OK" '"ci_runs_none":true'
out=$(after_review)
assert_eq "CI の実行が見つからない：マージしない" "" "$(merged)"
assert_contains "見つからない：ログに出す" "$out" "CIがまだ全部通っていない"

setup "$CI_OK" '"runs_fail":true'
out=$(after_review)
assert_eq "CI の実行が読めない：マージしない" "" "$(merged)"

setup "$CI_OK"
with_runs "$(ci_run 1 completed failure 2026-01-01T00:00:00Z),$(ci_run 2 completed success 2026-01-02T00:00:00Z)"
after_review > /dev/null
assert_eq "古い方が failure でも、新しい方が success ならマージへ進む" "58" "$(merged)"

setup "$CI_OK"
with_runs "$(ci_run 2 completed success 2026-01-01T00:00:00Z),$(ci_run 1 completed failure 2026-01-02T00:00:00Z)"
after_review > /dev/null
assert_eq "新しい方が failure なら進まない（並びの順ではなく created_at で決める）" "" "$(merged)"

echo "== チェックの一覧の形（名前・状態・理由・URL）"
init_state '{"checks":['"$CI_OK"','"$(vercel_check completed timed_out)"',{"name":"review","status":"in_progress","app":{"slug":"claude"}},{"name":"Netlify","status":"queued","conclusion":null,"app":{"slug":"netlify"}}],"statuses":[{"context":"ci/ext","state":"pending","description":"waiting"},{"context":"good","state":"success"}]}'
out=$(run_lib 'external_checks_not_ok abc')
assert_eq "通っていない物だけ・CI とレビューは入れない" "3" "$(printf '%s\n' "$out" | grep -c .)"
assert_contains "落ちた check run" "$out" "$(printf 'check\tVercel\tfailed\ttimed_out：Deployment failed\thttps://vercel.example/d/1')"
assert_contains "終わっていない check run" "$out" "$(printf 'check\tNetlify\tpending\tqueued')"
assert_contains "終わっていないステータス" "$out" "$(printf 'status\tci/ext\tpending\tpending：waiting')"
assert_eq "読めないときは、無いとみなす（止めない）" "" "$(MOCK_STATE=/nonexistent run_lib 'external_checks_not_ok abc' 2> /dev/null | grep -c . | grep -v '^0$' || true)"

finish
