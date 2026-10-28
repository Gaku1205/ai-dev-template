#!/usr/bin/env bash
# レビューのあと（after-review.sh）：指摘なし・CI通過なら自動でマージ。パイプライン自体を変えるPRと ai:hold のPRは、マージを人間に任せる
source "$(dirname "$0")/lib.sh"
setup_mock

run_case() { # 変更ファイル（スペース区切り） ラベル（カンマ区切り、空でもよい）
  local files labels
  files=$(printf '%s\n' $1 | python3 -c "import sys,json;print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")
  labels=$(python3 -c "import sys,json;print(json.dumps([l for l in sys.argv[1].split(',') if l]))" "$2")
  init_state '{"labels":{"58":'"$labels"'},"files":'"$files"',"pulls":[{"number":58,"state":"open","body":"Closes #54","head":{"sha":"abc","ref":"claude/issue-54-x"},"updated_at":"2026-01-01T00:00:00Z"}],"checks":[{"name":"check","status":"completed","conclusion":"success","app":{"slug":"github-actions"}}],"branches":[{"name":"claude/issue-54-x","date":"2026-01-01T00:00:00Z"}]}'
  state_py "s['comments'].append({'id':1,'issue':'58','body':'## Code review\n\nNo issues found.','user':{'login':'github-actions[bot]'},'created_at':'$(ago 1)','updated_at':'$(ago 1)'})"
  CONCLUSION=success HEAD_SHA=abc HEAD_BRANCH=claude/issue-54-x run_script after-review.sh > /dev/null
}
merged() { python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print(','.join(map(str,s.get('merged',[]))))"; }

echo "== アプリだけの変更：自動でマージする（マージ後、AIのブランチを消す）"
run_case "src/app/page.tsx" ""
assert_eq "マージされる" "58" "$(merged)"
assert_eq "ブランチが消える" "" "$(branch_names)"

echo "== .github/ を触るPR：マージしない。ai:hold が付き、「マージできます」の通知が出る"
run_case ".github/scripts/watchdog.sh src/a.ts" ""
assert_eq "マージされない" "" "$(merged)"
assert_eq "ai:hold が付く" "ai:hold" "$(labels_of 58)"
assert_contains "通知が出る" "$(cat "$MOCK_DIR/curl.log")" "マージできます"

echo "== docs/pipeline.md・CLAUDE.md・AGENTS.md を触るPR：同じ"
for f in docs/pipeline.md CLAUDE.md AGENTS.md; do
  run_case "$f" ""
  assert_eq "$f：マージされず、ai:hold が付く" ":ai:hold" "$(merged):$(labels_of 58)"
done

echo "== 似た名前（docs/spec.md、src/.github-note.ts）は、パイプライン自体の変更ではない"
run_case "docs/spec.md src/.github-note.ts" ""
assert_eq "マージされる" "58" "$(merged)"

echo "== ai:hold が付いているPR：アプリだけの変更でもマージしない"
run_case "src/app/page.tsx" "ai:hold"
assert_eq "マージされない" "" "$(merged)"

finish
