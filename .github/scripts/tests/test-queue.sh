#!/usr/bin/env bash
# 順番待ち（queue-next.sh）：進めてよいとき・いけないとき
source "$(dirname "$0")/lib.sh"
setup_mock

pr='{"number":5,"state":"open","body":"","head":{"sha":"abc","ref":"claude/issue-5-x"},"updated_at":"2026-01-01T00:00:00Z"}'

echo "== 何も進行中でなければ、順番待ちの先頭（番号が小さい方）を実装に回す"
init_state '{"labels":{"2":["ai:queue"],"3":["ai:queue"]}}'
run_script queue-next.sh > /dev/null
assert_eq "#2 が実装に回る" "ai:implement" "$(labels_of 2)"
assert_eq "#3 は待ったまま" "ai:queue" "$(labels_of 3)"

echo "== 企画の段階で止まった物（人間の作業待ち・質問）があっても、止まらない"
init_state '{"labels":{"1":["ai:stuck"],"2":["ai:queue"]}}'
run_script queue-next.sh > /dev/null
assert_eq "#2 が実装に回る" "ai:implement" "$(labels_of 2)"

echo "== 実装中の物があるあいだは進めない"
init_state '{"labels":{"1":["ai:implement"],"2":["ai:queue"]}}'
run_script queue-next.sh > /dev/null
assert_eq "#2 は待ったまま" "ai:queue" "$(labels_of 2)"

echo "== 実装で止まった物（ai:implement が残っている）は席に数えない：夜の上限1でも、触るファイルが重ならない順番待ちは始まる"
bodies='"issues_meta":{"1":{"title":"a","body":"本文\n<!-- ai-touches: src/lib/a.ts -->"},"2":{"title":"b","body":"本文\n<!-- ai-touches: src/lib/b.ts -->"}}'
init_state '{"labels":{"1":["ai:implement","ai:stuck"],"2":["ai:queue"]},'"$bodies"'}'
out=$(MAX_PARALLEL=1 run_script queue-next.sh)
assert_eq "#2 が実装に回る" "ai:implement" "$(labels_of 2)"
assert_contains "実装中は0" "$out" "実装中 0"

echo "== 止まった物と触るファイルが重なる順番待ちは待つ"
init_state '{"labels":{"1":["ai:implement","ai:stuck"],"2":["ai:queue"]},"issues_meta":{"1":{"title":"a","body":"本文\n<!-- ai-touches: src/lib/a.ts -->"},"2":{"title":"b","body":"本文\n<!-- ai-touches: src/lib/a.ts -->"}}}'
MAX_PARALLEL=1 run_script queue-next.sh > /dev/null
assert_eq "#2 は待ったまま" "ai:queue" "$(labels_of 2)"

echo "== PRが ai:stuck の Issue も席に数えない"
stuckpr='{"number":5,"state":"open","body":"","head":{"sha":"abc","ref":"claude/issue-1-x"},"labels":[{"name":"ai:stuck"}],"updated_at":"2026-01-01T00:00:00Z"}'
init_state '{"labels":{"1":["ai:implement"],"5":["ai:stuck"],"2":["ai:queue"]},"pulls":['"$stuckpr"'],"files":["src/lib/a.ts"],"issues_meta":{"2":{"title":"b","body":"本文\n<!-- ai-touches: src/lib/b.ts -->"}}}'
out=$(MAX_PARALLEL=1 run_script queue-next.sh)
assert_eq "#2 が実装に回る" "ai:implement" "$(labels_of 2)"

echo "== 60分を過ぎたマージ待ちは席に数えない／60分以内は数える"
review='{"id":901,"issue":"5","user":{"login":"github-actions[bot]"},"created_at":"2026-11-17T00:00:00Z","updated_at":"2026-11-17T00:00:00Z","body":"## Code review\n\nNo issues found."}'
holdpr='{"number":5,"state":"open","mergeable_state":"clean","head":{"ref":"claude/issue-1-x","sha":"abc"},"labels":[{"name":"ai:hold"}]}'
for min in 90 10; do
  init_state '{"labels":{"1":["ai:implement"],"5":["ai:hold"],"2":["ai:queue"]},"events":{"5":[{"event":"labeled","label":{"name":"ai:hold"},"created_at":"'"$(ago $min)"'"}]},"pulls":['"$holdpr"'],"files":["src/lib/a.ts"],"comments":['"$review"'],"issues_meta":{"2":{"title":"b","body":"本文\n<!-- ai-touches: src/lib/b.ts -->"}}}'
  MAX_PARALLEL=1 run_script queue-next.sh > /dev/null
  if [ "$min" = 90 ]; then assert_eq "90分：#2 が始まる" "ai:implement" "$(labels_of 2)"; else assert_eq "10分：#2 は待つ" "ai:queue" "$(labels_of 2)"; fi
done

echo "== openのPRがあるあいだは進めない"
init_state '{"labels":{"2":["ai:queue"]},"pulls":['"$pr"']}'
run_script queue-next.sh > /dev/null
assert_eq "#2 は待ったまま" "ai:queue" "$(labels_of 2)"

echo "== 順番待ちが無ければ何もしない"
init_state '{"labels":{"1":["ai:stuck"]}}'
out=$(run_script queue-next.sh)
assert_contains "「ありません」と出る" "$out" "順番待ちはありません"

echo "== 同時に2回進めても、順番待ちは1回だけ始まる（コメントも1回）"
init_state '{"labels":{"30":["ai:queue"]}}'
run_lib "start_next_in_queue" > /dev/null
run_lib "start_next_in_queue" > /dev/null
assert_eq "実装に回る" "ai:implement" "$(labels_of 30)"
assert_eq "コメントは1回" "1" "$(comments_of 30 | grep -c '順番が来たので')"

finish
