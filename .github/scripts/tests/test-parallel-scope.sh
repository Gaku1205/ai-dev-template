#!/usr/bin/env bash
# 並列の上限を、持ち主の全部のリポジトリで合わせて数える（PARALLEL_SCOPE。#216）：
#   ・全体で上限を超えない・空きができたら全部の順番待ちから一番古い物を始める・同時に始めて超えたら新しい方が戻る
#   ・鍵がほかのリポジトリを読めなければ、このリポジトリだけで数え、Summary と Doctor に ⚠️
#   ・PARALLEL_SCOPE=repo なら今までどおり
source "$(dirname "$0")/lib.sh"
setup_mock
# 全部で数える（lib.sh の既定は repo）。昼の上限 1・夜は無し
unset PARALLEL_SCOPE
export PARALLEL_DAY=1 PARALLEL_NIGHT_HOURS="" PARALLEL_OVERRIDE=""
SUMMARY="$MOCK_DIR/summary.md"
export GITHUB_STEP_SUMMARY="$SUMMARY"

queued_ev() { printf '[{"event":"labeled","label":{"name":"ai:queue"},"created_at":"%s"}]' "$(ago "$1")"; }
both_ev() { printf '[{"event":"labeled","label":{"name":"ai:queue"},"created_at":"%s"},{"event":"labeled","label":{"name":"ai:implement"},"created_at":"%s"}]' "$(ago "$1")" "$(ago "$2")"; }
labels_in() { python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print(','.join(sorted(s['repos']['$1']['labels'].get('$2',[]))))"; }
comments_in() { python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print('\n'.join(c['body'] for c in s['repos']['$1'].get('comments',[]) if c['issue']=='$2'))"; }
search_calls() { python3 -c "import json,os;print(json.load(open(os.environ['MOCK_STATE'])).get('api_calls',0))"; }

echo "== 広さを決める（parallel_scope_decide）"
assert_eq "設定が repo" "repo" "$(run_lib "parallel_scope_decide repo '{}'")"
assert_eq "全部読める" "global" "$(run_lib "parallel_scope_decide global '{\"search_ok\":true,\"repos\":[{\"repo\":\"o/r2\",\"ok\":true,\"why\":\"\"}]}'")"
assert_eq "未設定は global" "global" "$(run_lib "parallel_scope_decide '' '{\"search_ok\":true,\"repos\":[]}'")"
assert_contains "検索できない：repo に落とす" "$(run_lib "parallel_scope_decide global '{\"search_ok\":false,\"repos\":[]}'")" "repo 検索（Search API）"
assert_contains "読めないリポジトリ：repo に落とし、名前と理由を出す" "$(run_lib "parallel_scope_decide global '{\"search_ok\":true,\"repos\":[{\"repo\":\"o/r2\",\"ok\":false,\"why\":\"読めません\"}]}'")" "repo 鍵で読めないリポジトリがあります：o/r2（読めません）"

echo "== 全部の順番待ちを始める順（global_queue_order）"
order=$(run_lib "global_queue_order '[{\"repo\":\"o/r\",\"n\":3,\"at\":\"2026-11-18T10:00:00Z\",\"p\":false},{\"repo\":\"o/r2\",\"n\":5,\"at\":\"2026-11-18T09:00:00Z\",\"p\":false},{\"repo\":\"o/r3\",\"n\":1,\"at\":\"\",\"p\":false},{\"repo\":\"o/r\",\"n\":9,\"at\":\"2026-11-18T11:00:00Z\",\"p\":true}]'" | paste -sd, -)
assert_eq "急ぎを先に、あとは ai:queue の古い順（時刻の分からない物は最後）" "o/r 9,o/r2 5,o/r 3,o/r3 1" "$order"

echo "== 取り合いで戻す物（global_overflow_pick）"
pick() { run_lib "global_overflow_pick $1 '$2'" | paste -sd, -; }
two='{"active":[{"repo":"o/r","n":3,"key":"2026-11-18T10:00:00Z"},{"repo":"o/r2","n":5,"key":"2026-11-18T09:00:00Z"}],"mine":[{"repo":"o/r","n":3}]}'
assert_eq "上限1・自分の方が新しい：自分が戻る" "o/r 3" "$(pick 1 "$two")"
two_other='{"active":[{"repo":"o/r","n":3,"key":"2026-11-18T10:00:00Z"},{"repo":"o/r2","n":5,"key":"2026-11-18T09:00:00Z"}],"mine":[{"repo":"o/r2","n":5}]}'
assert_eq "上限1・自分の方が古い：戻さない（相手が戻る）" "" "$(pick 1 "$two_other")"
assert_eq "上限2：戻さない" "" "$(pick 2 "$two")"
old='{"active":[{"repo":"o/r","n":3,"key":""},{"repo":"o/r2","n":5,"key":"2026-11-18T09:00:00Z"}],"mine":[{"repo":"o/r2","n":5}]}'
assert_eq "時刻の分からない物は古い扱い（前から動いている物を追い出さない）" "o/r2 5" "$(pick 1 "$old")"
notmine='{"active":[{"repo":"o/r","n":3,"key":"2026-11-18T08:00:00Z"},{"repo":"o/r2","n":5,"key":"2026-11-18T09:00:00Z"}],"mine":[]}'
assert_eq "自分が始めた物でなければ戻さない（夜になって上限が下がった、など）" "" "$(pick 1 "$notmine")"

echo "== 2つのリポジトリ・上限1：ほかのリポジトリで1つ動いていれば、このリポジトリの順番待ちは始めない"
init_state '{"labels":{"3":["ai:queue"]},"issues_meta":{"3":{"body":"<!-- ai-touches: src/a.ts -->"}},"events":{"3":'"$(queued_ev 10)"'},
  "repos":{"o/r2":{"labels":{"5":["ai:implement"]},"issues_meta":{"5":{"body":"<!-- ai-touches: src/b.ts -->"}}}}}'
: > "$SUMMARY"
out=$(run_script queue-next.sh)
assert_contains "全部で数える" "$out" "全部のリポジトリで実装中 1（o/r 0・o/r2 1）"
assert_contains "上限なので始めない" "$out" "全部のリポジトリで並列の上限（1）なので、今は始めません"
assert_eq "#3 は待ったまま" "ai:queue" "$(labels_of 3)"
assert_eq "Summary に ⚠️ は出ない" "" "$(cat "$SUMMARY")"

echo "== 空きができたら、全部の順番待ちから一番古い物を始める（ほかのリポジトリの物も）"
init_state '{"labels":{"3":["ai:queue"]},"issues_meta":{"3":{"body":"<!-- ai-touches: src/a.ts -->"}},"events":{"3":'"$(queued_ev 10)"'},
  "repos":{"o/r2":{"labels":{"5":["ai:queue"]},"issues_meta":{"5":{"body":"<!-- ai-touches: src/b.ts -->"}},"events":{"5":'"$(queued_ev 30)"'}}}}'
out=$(run_script queue-next.sh)
assert_contains "ほかのリポジトリの #5 を始める" "$out" "順番待ちの #5 を実装に回しました"
assert_eq "o/r2#5 は実装へ" "ai:implement" "$(labels_in o/r2 5)"
assert_contains "o/r2#5 に始めたことを書く" "$(comments_in o/r2 5)" "順番が来たので実装を始めます"
assert_eq "このリポジトリの #3 は待ったまま" "ai:queue" "$(labels_of 3)"
assert_contains "上限まで来たので止める" "$out" "ここまでにします"

echo "== 上限2：1回の実行で、全体の上限まで並べて始める（#202）"
init_state '{"labels":{"3":["ai:queue"],"4":["ai:queue"]},"issues_meta":{"3":{"body":"<!-- ai-touches: src/a.ts -->"},"4":{"body":"<!-- ai-touches: src/c.ts -->"}},"events":{"3":'"$(queued_ev 10)"',"4":'"$(queued_ev 5)"'},
  "repos":{"o/r2":{"labels":{"5":["ai:queue"]},"issues_meta":{"5":{"body":"<!-- ai-touches: src/b.ts -->"}},"events":{"5":'"$(queued_ev 30)"'}}}}'
PARALLEL_DAY=2 run_script queue-next.sh > /dev/null
assert_eq "o/r2#5（一番古い）が実装へ" "ai:implement" "$(labels_in o/r2 5)"
assert_eq "#3（2番目）が実装へ" "ai:implement" "$(labels_of 3)"
assert_eq "#4（3番目）は待ったまま" "ai:queue" "$(labels_of 4)"

echo "== 重なりの判断は、そのリポジトリの中で今までどおり（重なる物は飛ばして次）"
init_state '{"labels":{"3":["ai:queue"],"8":["ai:implement"]},"issues_meta":{"3":{"body":"<!-- ai-touches: src/a.ts -->"},"8":{"body":"<!-- ai-touches: src/x.ts -->"}},"events":{"3":'"$(queued_ev 10)"'},
  "repos":{"o/r2":{"labels":{"5":["ai:queue"],"6":["ai:implement"]},"issues_meta":{"5":{"body":"<!-- ai-touches: src/b.ts -->"},"6":{"body":"<!-- ai-touches: src/b.ts -->"}},"events":{"5":'"$(queued_ev 30)"'}}}}'
out=$(PARALLEL_DAY=3 run_script queue-next.sh)
assert_contains "o/r2#5 は、o/r2 の進行中の物と重なるので待つ" "$out" "#5：進行中の作業と触るファイルが重なるので、待ちます"
assert_eq "o/r2#5 は待ったまま" "ai:queue" "$(labels_in o/r2 5)"
assert_eq "次の #3 を始める" "ai:implement" "$(labels_of 3)"

echo "== 同時に始めて上限を超えたら、ai:queue が新しい方が順番待ちに戻る"
# o/r の #3（10分前に順番待ち）と o/r2 の #5（30分前に順番待ち）を、2つの順番待ちが同時に始めた
race_state() {
  init_state '{"labels":{"3":["ai:implement"]},"issues_meta":{"3":{"body":"<!-- ai-touches: src/a.ts -->"}},"events":{"3":'"$(both_ev 10 0)"'},
    "repos":{"o/r2":{"labels":{"5":["ai:implement"]},"issues_meta":{"5":{"body":"<!-- ai-touches: src/b.ts -->"}},"events":{"5":'"$(both_ev 30 0)"'}}}}'
}
race_state
out=$(run_lib 'parallel_scope_resolve; global_yield_overflow 1 "o/r 3
"')
assert_contains "数え直す" "$out" "数え直し：全部のリポジトリで実装中 2（並列の上限 1）"
assert_eq "新しい方（#3）は順番待ちに戻る" "ai:queue" "$(labels_of 3)"
assert_contains "#3 に戻したことを書く" "$(comments_of 3)" "順番待ちに戻しました"
assert_eq "古い方（o/r2#5）は実装のまま" "ai:implement" "$(labels_in o/r2 5)"
race_state
out=$(run_lib 'parallel_scope_resolve; global_yield_overflow 1 "o/r2 5
"')
assert_eq "相手の実行（o/r2#5 を始めた側）は、自分の物を戻さない" "ai:implement" "$(labels_in o/r2 5)"
assert_eq "相手の実行は、ほかの物（#3）も触らない" "ai:implement" "$(labels_of 3)"

echo "== 検索の反映が遅れても、数え直しで見つける（このリポジトリと、順番待ちで知ったリポジトリは一覧から数える）"
race_state
state_py "s['search_lag']=['o/r2#5']; s['repos']['o/r2']['labels']['6']=['ai:queue']"
out=$(run_lib 'parallel_scope_resolve; global_yield_overflow 1 "o/r 3
"')
assert_eq "o/r2#5 が検索に出なくても、#3 が戻る" "ai:queue" "$(labels_of 3)"

echo "== 企画のあと（after-plan.sh）：ほかのリポジトリで上限まで動いていれば、順番待ちに入れる"
work="$MOCK_DIR/work"; mkdir -p "$work"
init_state '{"labels":{"3":["ai:plan"]},"issues_meta":{"3":{"body":"<!-- ai-touches: src/a.ts -->"}},
  "repos":{"o/r2":{"labels":{"5":["ai:implement"]},"issues_meta":{"5":{"body":"<!-- ai-touches: src/b.ts -->"}}}}}'
out=$(cd "$work" && printf 'READY size:S\nPARALLEL\n' > plan-result.txt && ISSUE=3 PLAN_OUTCOME=success GITHUB_TOKEN_FOR_LABELS=x bash "$SCRIPTS_DIR/after-plan.sh" 2>&1)
assert_contains "全部で数える" "$out" "全部のリポジトリで実装中 1"
assert_eq "#3 は順番待ちへ" "ai:queue,size:S" "$(labels_of 3)"

echo "== 鍵がほかのリポジトリを読めない（403）：このリポジトリだけで数え、Summary に ⚠️"
init_state '{"labels":{"3":["ai:queue"]},"issues_meta":{"3":{"body":"<!-- ai-touches: src/a.ts -->"}},"fail_repos":["o/r2"],
  "repos":{"o/r2":{"labels":{"5":["ai:implement"]}}}}'
: > "$SUMMARY"
out=$(run_script queue-next.sh)
assert_contains "警告を出す" "$out" "::warning::⚠️ 並列の上限を、このリポジトリ（o/r）だけで数えています"
assert_contains "Summary に ⚠️ と理由" "$(cat "$SUMMARY")" "⚠️ 並列の上限を、このリポジトリ（o/r）だけで数えています：鍵で読めないリポジトリがあります：o/r2（読めません（403・404））"
assert_eq "このリポジトリだけで数えて、#3 を始める" "ai:implement" "$(labels_of 3)"

echo "== 鍵のインストールにほかのリポジトリが入っていない：このリポジトリだけで数え、⚠️"
init_state '{"labels":{"3":["ai:queue"]},"issues_meta":{"3":{"body":"<!-- ai-touches: src/a.ts -->"}},"installation_repos":["o/r"],
  "repos":{"o/r2":{"labels":{"5":["ai:implement"]}}}}'
: > "$SUMMARY"
run_script queue-next.sh > /dev/null
assert_contains "Summary に理由" "$(cat "$SUMMARY")" "o/r2（鍵のインストールに入っていません）"
assert_eq "#3 を始める" "ai:implement" "$(labels_of 3)"

echo "== 検索できない：このリポジトリだけで数え、⚠️"
init_state '{"labels":{"3":["ai:queue"]},"issues_meta":{"3":{"body":"<!-- ai-touches: src/a.ts -->"}},"search_fail":true}'
: > "$SUMMARY"
run_script queue-next.sh > /dev/null
assert_contains "Summary に理由" "$(cat "$SUMMARY")" "検索（Search API）で、ほかのリポジトリの Issue を探せませんでした"

echo "== Doctor：読めないリポジトリがあれば ⚠️、全部読めれば ✅"
init_state '{"fail_repos":["o/r2"],"repos":{"o/r2":{"labels":{"5":["ai:implement"]}}}}'
doc=$(REPO=o/r PIPELINE_TOKEN=x bash -c "source '$SCRIPTS_DIR/doctor.sh'; check_parallel_scope" 2>&1)
assert_contains "⚠️ と理由" "$doc" "⚠️ 並列の上限を、このリポジトリだけで数えている（鍵で読めないリポジトリがあります：o/r2"
init_state '{"repos":{"o/r2":{"labels":{"5":["ai:implement"]}}}}'
doc=$(REPO=o/r PIPELINE_TOKEN=x bash -c "source '$SCRIPTS_DIR/doctor.sh'; check_parallel_scope" 2>&1)
assert_contains "✅ 全部で数える" "$doc" "✅ 並列の上限は、持ち主の全部のリポジトリで合わせて数える（いま数えに入る、ほかのリポジトリ：1 個）"
doc=$(REPO=o/r PIPELINE_TOKEN=x PARALLEL_SCOPE=repo bash -c "source '$SCRIPTS_DIR/doctor.sh'; check_parallel_scope" 2>&1)
assert_contains "✅ 設定で repo" "$doc" "このリポジトリだけで数える（Variable PARALLEL_SCOPE=repo）"

echo "== PARALLEL_SCOPE=repo：今までどおり（ほかのリポジトリを数えない・検索しない）"
init_state '{"labels":{"3":["ai:queue"]},"issues_meta":{"3":{"body":"<!-- ai-touches: src/a.ts -->"}},
  "repos":{"o/r2":{"labels":{"5":["ai:implement"]}}}}'
: > "$SUMMARY"
out=$(PARALLEL_SCOPE=repo run_script queue-next.sh)
assert_contains "このリポジトリだけの数" "$out" "実装中 0 / 停止中 0（数えない） / openのPR 0（並列の上限 1"
assert_eq "#3 を始める" "ai:implement" "$(labels_of 3)"
assert_not_contains "全部では数えない" "$out" "全部のリポジトリ"
assert_eq "Summary に ⚠️ は出ない" "" "$(cat "$SUMMARY")"

echo "== 見張り役の目覚まし：ほかのリポジトリにだけ順番待ちがあっても、上限が変わる時刻に起こす"
init_state '{"repos":{"o/r2":{"labels":{"5":["ai:queue"],"6":["ai:implement"]},"issues_meta":{"5":{"body":"<!-- ai-touches: src/b.ts -->"},"6":{"body":"<!-- ai-touches: src/b.ts -->"}}}}}'
out=$(TIMER_CLOCK_REPO=1 PARALLEL_NIGHT_HOURS="01-08" run_script watchdog.sh)
assert_contains "目覚ましをかける（テンプレートのリポジトリ）" "$out" "目覚ましを"
init_state '{"repos":{"o/r2":{"labels":{"5":["ai:queue"],"6":["ai:implement"]},"issues_meta":{"5":{"body":"<!-- ai-touches: src/b.ts -->"},"6":{"body":"<!-- ai-touches: src/b.ts -->"}}}}}'
out=$(PARALLEL_SCOPE=repo PARALLEL_NIGHT_HOURS="01-08" run_script watchdog.sh)
assert_not_contains "repo なら、ほかのリポジトリの順番待ちでは起こさない" "$out" "目覚ましを"

finish
