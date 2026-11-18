#!/usr/bin/env bash
# 見た目のテストがあり、本文に visual:update があるPRは、最初のレビューをCIのあとに回す。
# PRができた直後（open-pr.sh）と、直して push した直後（after-mention.sh）。CIが通ったあとは after-ci.sh が頼む
source "$(dirname "$0")/lib.sh"
setup_mock

pr_json() { # 1: 本文
  python3 -c "import json,sys;print(json.dumps({'number':101,'body':sys.argv[1],'state':'open','head':{'sha':'abc','ref':'claude/issue-7-x'},'updated_at':'2026-01-01T00:00:00Z','mergeable_state':'clean'}))" "$1"
}
# 実装AIの最後のコメント（Create PR のリンク付き）の本文。1: PRの本文
link_body() {
  python3 -c "import json,sys,urllib.parse;print(json.dumps('[Create PR](https://github.com/o/r/compare/main...claude/issue-7-x?quick_pull=1&title=t&body='+urllib.parse.quote(sys.argv[1])+')'))" "$1"
}
# 1: PRの本文 2: ブランチの内容（contents の JSON）
open_case() {
  init_state '{"labels":{"7":["ai:implement"],"101":[]},"ahead_by":1,"branches":[{"name":"claude/issue-7-x","date":"2026-01-02T00:00:00Z"}],"pulls":['"$(pr_json "$1")"'],"contents":'"$2"',"uncreated_pulls":[101]}'
  state_py "
s['comments'].append({'id':1,'issue':'7','body':$(link_body "$1"),'user':{'login':'claude[bot]'},'created_at':'2026-01-02T00:00:00Z','updated_at':'2026-01-02T00:00:00Z'})
s['next_id']=1"
}
run_open() { ISSUE=7 ISSUE_TITLE="題" AI_OUTCOME=success GITHUB_RUN_ID=99 run_script open-pr.sh; }
pkg_visual='{"claude/issue-7-x":{"package.json":"{\"scripts\":{\"test:visual\":\"playwright test\"}}"}}'
pj_visual='{"claude/issue-7-x":{"package.json":"{\"scripts\":{}}","pipeline.json":"{\"checks\":[{\"run\":\"npm run test:visual\"}]}"}}'
no_visual='{"claude/issue-7-x":{"package.json":"{\"scripts\":{\"test\":\"vitest\"}}"}}'

echo "== 見た目のテスト（package.json）があり、本文に visual:update：作った直後に ai:review を付けない"
open_case "Closes #7 visual:update" "$pkg_visual"
out=$(run_open)
assert_contains "後回しと出す" "$out" "最初のレビューはCIのあとに回します"
assert_not_contains "ai:review が付かない" "$(labels_of 101)" "ai:review"

echo "== 見た目のテスト（pipeline.json の checks）があり、本文に visual:update：付けない"
open_case "Closes #7 visual:update" "$pj_visual"
run_open > /dev/null
assert_not_contains "ai:review が付かない" "$(labels_of 101)" "ai:review"

echo "== 見た目のテストがあるが、本文に visual:update が無い：今までどおり付ける"
open_case "Closes #7" "$pkg_visual"
run_open > /dev/null
assert_contains "ai:review が付く" "$(labels_of 101)" "ai:review"

echo "== 本文に visual:update があるが、見た目のテストが無い：今までどおり付ける"
open_case "Closes #7 visual:update" "$no_visual"
run_open > /dev/null
assert_contains "ai:review が付く" "$(labels_of 101)" "ai:review"

echo "== ブランチの package.json も pipeline.json も読めない：見た目のテストは無いと扱い、付ける"
open_case "Closes #7 visual:update" '{}'
run_open > /dev/null
assert_contains "ai:review が付く" "$(labels_of 101)" "ai:review"

echo "== defer_review_for_visual：本文は呼ぶたびに読み直す（AIが本文を直したあと）"
open_case "Closes #7" "$pkg_visual"
r=$(run_lib 'REPO=o/r; defer_review_for_visual 101 && echo defer || echo now')
assert_eq "本文に無いので同時に始める" "now" "$r"
state_py "s['pulls'][0]['body']='Closes #7 visual:update'"
r=$(run_lib 'REPO=o/r; defer_review_for_visual 101 && echo defer || echo now')
assert_contains "本文に書かれたので後回し" "$r" "defer"

echo "== 直して push した直後（after-mention.sh）：後回しなら付けず、そうでなければ付ける"
mention_case() { # 1: 本文
  init_state '{"labels":{"101":[]},"pulls":['"$(pr_json "$1")"'],"contents":'"$pkg_visual"'}'
  state_py "
s['comments'].append({'id':50,'issue':'101','body':'@claude x\\n<!-- auto-fix -->\\n<!-- auto-fix-sha: old -->','user':{'login':'x'},'created_at':'$(ago 2)','updated_at':'$(ago 2)'})
s['next_id']=50"
}
run_mention() { RUN_STARTED=$(ago 1) CONCLUSION=success PR_NUMBER=101 run_script after-mention.sh; }
mention_case "Closes #7 visual:update"
out=$(run_mention)
assert_contains "後回しと出す" "$out" "最初のレビューはCIのあとに回します"
assert_not_contains "ai:review が付かない" "$(labels_of 101)" "ai:review"
mention_case "Closes #7"
run_mention > /dev/null
assert_contains "visual:update が無ければ付く" "$(labels_of 101)" "ai:review"

finish
