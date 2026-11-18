#!/usr/bin/env bash
# 見張り役（2.）：ほかの実装が動いていても、90分以上動きの無い ai:implement（PRなし）は拾う。45〜90分は、実装が動いている間は触らない
source "$(dirname "$0")/lib.sh"
setup_mock

impl() { # 更新からの分 [足す項目（JSON の中身）]
  init_state '{"labels":{"9":["ai:implement"]},"issue_updated":{"9":"'"$(ago "$1")"'"}'"${2:+,$2}"'}'
}
running='"wf_runs":{"claude-implement.yml":[{"id":1,"status":"in_progress"}]}'

echo "== 90分以上：ほかの実装が動いていても、やり直し待ちにする"
impl 100 "$running"
run_script watchdog.sh > /dev/null
assert_eq "ai:retry が付く" "ai:implement,ai:retry" "$(labels_of 9)"
assert_contains "記録の種類は implement" "$(comments_of 9)" "kind=implement"

echo "== 90分以上：待っている実行（queued）があっても拾う"
impl 100 '"wf_runs":{"claude-implement.yml":[{"id":1,"status":"queued"}]}'
run_script watchdog.sh > /dev/null
assert_eq "ai:retry が付く" "ai:implement,ai:retry" "$(labels_of 9)"

echo "== 45〜90分：実装が動いている間は触らない"
impl 60 "$running"
out=$(run_script watchdog.sh)
assert_eq "ai:retry を付けない" "ai:implement" "$(labels_of 9)"
assert_contains "ログに出す" "$out" "実装AIの実行が動いている（1 件）"

echo "== 45〜90分：動いていなければ、今までどおりやり直し待ちにする"
impl 60
run_script watchdog.sh > /dev/null
assert_eq "ai:retry が付く" "ai:implement,ai:retry" "$(labels_of 9)"

echo "== 45分未満：動いていなくても触らない"
impl 30
run_script watchdog.sh > /dev/null
assert_eq "何もしない" "ai:implement" "$(labels_of 9)"

echo "== 一覧を読めない：45〜90分は見ない、90分以上は拾う"
impl 60 '"wf_runs_fail":["claude-implement.yml"]'
run_script watchdog.sh > /dev/null
assert_eq "60分：触らない" "ai:implement" "$(labels_of 9)"
impl 100 '"wf_runs_fail":["claude-implement.yml"]'
run_script watchdog.sh > /dev/null
assert_eq "100分：拾う" "ai:implement,ai:retry" "$(labels_of 9)"

echo "== 90分以上でも、ai:stuck・ai:skip は触らない"
for l in ai:stuck ai:skip; do
  init_state '{"labels":{"9":["ai:implement","'"$l"'"]},"issue_updated":{"9":"'"$(ago 200)"'"},'"$running"'}'
  run_script watchdog.sh > /dev/null
  assert_eq "$l：何もしない" "ai:implement,$l" "$(labels_of 9)"
done

echo "== 同時に動く別の Issue：止まった物だけ拾い、新しい物は触らない"
init_state '{"labels":{"9":["ai:implement"],"10":["ai:implement"]},"issue_updated":{"9":"'"$(ago 120)"'","10":"'"$(ago 50)"'"},'"$running"'}'
run_script watchdog.sh > /dev/null
assert_eq "止まった #9 は拾う" "ai:implement,ai:retry" "$(labels_of 9)"
assert_eq "新しい #10 は触らない" "ai:implement" "$(labels_of 10)"

finish
