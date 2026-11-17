#!/usr/bin/env bash
# 順番待ち：人間のマージ待ち（ai:hold）のPRが長く待たれているときは、進行中から外す（ai-dev-template #125）
source "$(dirname "$0")/lib.sh"
setup_mock
next() { run_script queue-next.sh; }
body() { printf '本文\n<!-- ai-touches: %s -->' "$1"; }
review='{"id":901,"issue":"20","user":{"login":"github-actions[bot]"},"created_at":"2026-11-17T00:00:00Z","updated_at":"2026-11-17T00:00:00Z","body":"## Code review\n\nNo issues found."}'
pr20='{"number":20,"state":"open","mergeable_state":"clean","head":{"ref":"claude/issue-9-x","sha":"abc"},"labels":[{"name":"ai:hold"}]}'
# 引数：ai:hold が付いてからの分、PRのラベル、コメント（JSON の配列の中身）、触る内容
hold_state() {
  local ev="" lab="$2" cm="${3-$review}"
  [ -n "$1" ] && ev='"events":{"20":[{"event":"labeled","label":{"name":"ai:hold"},"created_at":"'"$(ago "$1")"'"}]},'
  init_state '{"labels":{"20":'"$lab"',"3":["ai:queue"]},'"$ev"'"pulls":['"$pr20"'],"files":["src/lib/a.ts"],"comments":['"$cm"'],
    "issues_meta":{"3":{"title":"b","body":"'"$(body src/lib/a.ts | sed ':a;N;$!ba;s/\n/\\n/g')"'"}}}'
}

echo "== 待つ時間の前（30分）：今までどおり待つ。止めているPRに目印が付く"
hold_state 30 '["ai:hold"]'
next > /dev/null
assert_eq "#3 は待つ" "ai:queue" "$(labels_of 3)"
assert_contains "PRに目印（待つ Issue の番号）" "$(comments_of 20)" "このPRをマージすると #3 が動き出します"
assert_contains "目印は1行目" "$(comments_of 20 | grep -F 'hold-blocking' | head -1)" "<!-- hold-blocking: #3 -->"
next > /dev/null
assert_eq "目印は1つだけ" "1" "$(comments_of 20 | grep -c '動き出します')"
assert_not_contains "外したコメントは付かない" "$(comments_of 20)" "待たずに"

echo "== 待つ Issue が増えたら、番号を全部入れて書き換える（コメントは増えない）"
state_py "s['labels']['2']=['ai:queue']; s['issues_meta']['2']={'title':'a','body':'本文\n<!-- ai-touches: src/lib/a.ts -->'}"
next > /dev/null
assert_contains "印に両方の番号" "$(comments_of 20)" "<!-- hold-blocking: #2,#3 -->"
assert_eq "コメントは1つのまま" "1" "$(comments_of 20 | grep -c 'hold-blocking:')"

echo "== 60分を過ぎた：そのPRを外して始める。外したコメントは1回だけ。古い目印は「止めていません」になる"
hold_state 30 '["ai:hold"]'
next > /dev/null
state_py "s['events']['20'][0]['created_at']='$(ago 90)'"
next > /dev/null
assert_contains "#3 が実装へ" "$(labels_of 3)" "ai:implement"
assert_contains "外したコメント" "$(comments_of 20)" "人間のマージ待ちが長いので、このPRを待たずに #3 を始めます"
assert_contains "外した印" "$(comments_of 20)" "<!-- hold-released: #3 -->"
assert_not_contains "止めている目印は残らない" "$(comments_of 20)" "動き出します"
assert_contains "目印は書き換わる" "$(comments_of 20)" "<!-- hold-blocking: -->"
state_py "s['labels']['3']=['ai:queue']"
next > /dev/null
assert_eq "二度目は付かない" "1" "$(comments_of 20 | grep -c '待たずに')"

echo "== HOLD_BLOCK_MIN を変えられる（120分なら、90分はまだ待つ）"
hold_state 90 '["ai:hold"]'
HOLD_BLOCK_MIN=120 next > /dev/null
assert_eq "#3 は待つ" "ai:queue" "$(labels_of 3)"

echo "== 時刻が読めない：今までどおり待つ"
hold_state "" '["ai:hold"]'
next > /dev/null
assert_eq "#3 は待つ" "ai:queue" "$(labels_of 3)"

echo "== レビューが済んでいない ai:hold は、時間に関係なく進行中に数える"
hold_state 300 '["ai:hold"]' ''
next > /dev/null
assert_eq "#3 は待つ" "ai:queue" "$(labels_of 3)"
assert_not_contains "目印も付けない" "$(comments_of 20)" "動き出します"

echo "== ai:hold でないPRは、何分たっても外さない"
hold_state 300 '["ai:review"]'
next > /dev/null
assert_eq "#3 は待つ" "ai:queue" "$(labels_of 3)"

echo "== 並列の上限（MAX_PARALLEL）は守る"
hold_state 90 '["ai:hold"]'
state_py "s['labels']['4']=['ai:implement']; s['labels']['5']=['ai:implement']"
MAX_PARALLEL=2 next > /dev/null
assert_eq "#3 は上限なので待つ" "ai:queue" "$(labels_of 3)"

echo "== 部品：after-plan.sh が使う inflight_touches も同じ扱い"
hold_state 30 '["ai:hold"]'
assert_contains "時間内は進行中に数える" "$(run_lib inflight_touches)" "src/lib/a.ts"
hold_state 90 '["ai:hold"]'
assert_eq "過ぎたら外す" "" "$(run_lib inflight_touches)"
finish
