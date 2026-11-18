#!/usr/bin/env bash
# 再開（resume.sh）：人間が ai:stuck を外したあと、止まった所から自動で続ける
# 「Resume が自分を数える」不具合：Resume 自身の実行を、CIの結果や実行中として数えてしまう。それが再び入ったら落ちる
source "$(dirname "$0")/lib.sh"
setup_mock
# resume.sh は after-ci.sh を .github/scripts/ から呼ぶので、リポジトリのルートで動かす
cd "$SCRIPTS_DIR/../.." || exit 1

# PR #58（先頭コミット abc）の状態を作る。引数は actions の実行（runs）の JSON 配列
setup_pr() {
  init_state "$(python3 - "$1" <<'PY'
import json, sys
pr = {'number': 58, 'body': 'Closes #54', 'state': 'open', 'head': {'sha': 'abc', 'ref': 'claude/issue-54-x'}, 'updated_at': '2026-01-01T00:00:00Z'}
print(json.dumps({'labels': {'58': [], '54': ['ai:stuck']}, 'pulls': [pr], 'runs': json.loads(sys.argv[1])}))
PY
)"
}
run_resume() { NUMBER="$1" IS_PR="$2" run_script resume.sh; }

# CI の実行と、そのあとに始まった Resume 自身の実行（実行中）
ci_run() { printf '{"id":11,"name":"CI","status":"%s","conclusion":%s,"created_at":"2026-01-01T00:00:00Z"}' "$1" "$2"; }
resume_run='{"id":12,"name":"Resume","status":"in_progress","conclusion":null,"created_at":"2026-01-01T00:05:00Z"}'

echo "== PR・CIが成功している → ai:review が付く（あとに始まった Resume 自身の実行は数えない）"
setup_pr "[$(ci_run completed '"success"'),$resume_run]"
out=$(run_resume 58 true)
assert_eq "ai:review が付く" "ai:review" "$(labels_of 58)"
assert_contains "レビューを依頼した" "$out" "CIが通ったのでレビューを依頼しました"
assert_not_contains "実行中とは見なさない" "$out" "CIが実行中"
assert_not_contains "直す依頼は出ない" "$(comments_of 58)" "@claude"
assert_not_contains "紐づくIssueの ai:stuck が外れる" "$(labels_of 54)" "ai:stuck"
assert_contains "再開の記録が残る" "$(comments_of 58)" "auto-resume"

echo "== PR・CIが失敗している → 直す依頼（@claude のコメント）が出る"
setup_pr "[$(ci_run completed '"failure"'),$resume_run]"
out=$(run_resume 58 true)
assert_contains "直す依頼が出る" "$(comments_of 58)" "@claude CIが失敗しました"
assert_contains "自動の依頼の印が付く" "$(comments_of 58)" "auto-fix"
assert_contains "依頼1回目" "$(comments_of 58)" "自動の依頼 1/3"
assert_not_contains "ai:review は付かない" "$(labels_of 58)" "ai:review"

echo "== PR・CIが実行中 → 何もせず待つ（Resume 自身が終わっていても、CIの結果とは見なさない）"
resume_done='{"id":12,"name":"Resume","status":"completed","conclusion":"success","created_at":"2026-01-01T00:05:00Z"}'
setup_pr "[$(ci_run in_progress null),$resume_done]"
out=$(run_resume 58 true)
assert_contains "実行中なので待つ" "$out" "CIが実行中です"
assert_not_contains "ai:review は付かない" "$(labels_of 58)" "ai:review"
assert_not_contains "直す依頼は出ない" "$(comments_of 58)" "@claude"

echo "== PR・コンフリクト中（dirty）でCIが0件 → 空のコミットを足さず、解消を頼む"
setup_pr "[]"
state_py "s['pulls'][0]['mergeable_state']='dirty'"
out=$(run_resume 58 true)
assert_not_contains "空のコミットを足さない" "$out" "newcommit"
assert_eq "ブランチを更新しない" "0" "$(python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print(len(s.get('new_commits',[]))+len(s.get('ref_updates',[])))")"
assert_contains "解消を頼む" "$(comments_of 58)" "git merge origin/main"
assert_contains "先頭への依頼の印" "$(comments_of 58)" "auto-fix-sha: abc"

echo "== 配布のPR（pipeline-sync/*）はコンフリクトでも頼まない"
setup_pr "[]"
state_py "s['pulls'][0]['mergeable_state']='dirty'; s['pulls'][0]['head']['ref']='pipeline-sync/x'"
out=$(run_resume 58 true)
assert_not_contains "解消を頼まない" "$(comments_of 58)" "git merge origin/main"
assert_not_contains "空のコミットも足さない" "$out" "newcommit"

echo "== PR・コンフリクトしていない・CIが0件 → 今までどおり空のコミットで動かし直す"
setup_pr "[]"
state_py "s['pulls'][0]['mergeable_state']='clean'"
nosleep=$(mktemp -d)
printf '#!/bin/sh\nexit 0\n' > "$nosleep/sleep"
chmod +x "$nosleep/sleep"
out=$(PATH="$nosleep:$PATH" run_resume 58 true)
assert_contains "動かし直す" "$out" "newcommit を足しました"

echo "== PRではなくIssue（ai:implement・PRなし）→ ai:implement が付き直る"
init_state '{"labels":{"7":["ai:implement"]}}'
out=$(run_resume 7 false)
assert_contains "実装をやり直した" "$out" "実装をやり直しました"
assert_eq "ai:implement が付いている" "ai:implement" "$(labels_of 7)"

echo "== Issue・すでにPRがある → 実装はやり直さない"
init_state '{"labels":{"7":["ai:implement"]},"pulls":[{"number":9,"head":{"ref":"claude/issue-7-x","sha":"abc"}}]}'
out=$(run_resume 7 false)
assert_contains "やり直さない" "$out" "PRがあるので、実装はやり直しません"

echo "== 再開で回数を0に戻すとき、「AIが止まった」とは書かない"
run_lib "write_retry_record 40 0 implement '人間が再開しました'" > /dev/null
assert_contains "再開の文" "$(comments_of 40)" "▶ 人間が再開しました。自動のやり直しの回数を0に戻しました。"
assert_not_contains "止まったとは書かない" "$(comments_of 40)" "AIが止まったので"
assert_contains "印は残る（次のやり直しで書き換える）" "$(comments_of 40)" "<!-- count=0 kind=implement -->"


echo "== Issue・作業のラベルが無い（企画で人間に回したとき ai:plan は外してある）→ 企画からやり直す"
init_state '{"labels":{"54":[]}}'
out=$(run_resume 54 false)
assert_eq "ai:plan が付く" "ai:plan" "$(labels_of 54)"
assert_contains "ログに出す" "$out" "企画からやり直しました"

echo "== Issue・待っている物（質問・順番待ち・ほかの作業待ち）や ai:skip は、そのまま"
for l in ai:question ai:queue ai:blocked ai:skip; do
  init_state '{"labels":{"54":["'"$l"'"]}}'
  run_resume 54 false > /dev/null
  assert_eq "$l はそのまま" "$l" "$(labels_of 54)"
done

echo "== Issue の ai:stuck だけ外された・PRも止まっている → PRの ai:stuck も外して、PRの続きを始める"
init_state '{"labels":{"54":["ai:implement"],"58":["ai:stuck"]},"pulls":[{"number":58,"body":"Closes #54","state":"open","head":{"sha":"abc","ref":"claude/issue-54-x"},"updated_at":"2026-01-01T00:00:00Z"}]}'
out=$(run_resume 54 false)
assert_eq "PRの ai:stuck が外れる" "" "$(labels_of 58)"
assert_eq "Issue は実装をやり直さない" "ai:implement" "$(labels_of 54)"
assert_contains "ログに出す" "$out" "PRの止まった所から続けます"


echo "== Issue・作業のラベルは無いが、この Issue を閉じるPRが開いている（人間のPRなど）→ 企画し直さない"
init_state '{"labels":{"54":[],"58":[]},"pulls":[{"number":58,"body":"Closes #54","state":"open","head":{"sha":"abc","ref":"my-branch"},"updated_at":"2026-01-01T00:00:00Z"}]}'
run_resume 54 false > /dev/null
assert_eq "ai:plan を付けない" "" "$(labels_of 54)"
init_state '{"labels":{"5":[],"58":[]},"pulls":[{"number":58,"body":"Closes #54","state":"open","head":{"sha":"abc","ref":"my-branch"},"updated_at":"2026-01-01T00:00:00Z"}]}'
run_resume 5 false > /dev/null
assert_eq "別の番号（#54）のPRは関係ない" "ai:plan" "$(labels_of 5)"

finish
