#!/usr/bin/env bash
# 他の Issue・PR の完了待ち（ai:blocked）：企画AIが BLOCKED と書いたら待ち（after-plan.sh）、待ち先が全部閉じたら見張り役が企画に戻す（watchdog.sh）
source "$(dirname "$0")/lib.sh"
setup_mock
work="$MOCK_DIR/work"; mkdir -p "$work"
run_plan() { (cd "$work" && printf '%s\n' "$@" > plan-result.txt && ISSUE=3 PLAN_OUTCOME=success GH_TOKEN=pipe GITHUB_TOKEN_FOR_LABELS=x bash "$SCRIPTS_DIR/after-plan.sh" 2>&1); }
block_comment() { # 待ち先...（owner/repo#N）
  local body="⏳ 待っています" t
  for t in "$@"; do body="$body
<!-- blocked-by: $t -->"; done
  python3 -c "import json,sys;print(json.dumps({'id':1,'issue':'3','body':sys.argv[1],'user':{'login':'github-actions[bot]'},'created_at':'2026-01-01T00:00:00Z','updated_at':'2026-01-01T00:00:00Z'}))" "$body"
}

echo "== 企画AIが BLOCKED と書いた：ai:blocked を付けて、待ち先の印をコメントに書く（人間には回さない）"
init_state '{"labels":{"3":["ai:plan"]}}'
run_plan BLOCKED "o/other#58" "#9" "https://github.com/o/app/pull/12" > /dev/null
c=$(comments_of 3)
assert_eq "ai:blocked だけ" "ai:blocked" "$(labels_of 3)"
assert_contains "別のリポジトリの待ち先" "$c" "<!-- blocked-by: o/other#58 -->"
assert_contains "#N はこのリポジトリ" "$c" "<!-- blocked-by: o/r#9 -->"
assert_contains "URL も読む" "$c" "<!-- blocked-by: o/app#12 -->"
assert_contains "人が読む待ち先（このリポジトリは #N だけ）" "$c" "待ち先：o/other#58、#9、o/app#12"
assert_not_contains "human-request では止めない" "$c" "human-request"
assert_eq "通知しない（人間は何もしなくてよい）" "0" "$(notify_count)"

echo "== 自分自身・重複・読めない行は捨てる"
init_state '{"labels":{"3":["ai:plan"]}}'
run_plan BLOCKED "#3" "o/r#3" "#9" "#9" "なにか" > /dev/null
assert_eq "印は1つだけ" "1" "$(comments_of 3 | grep -c 'blocked-by')"

echo "== 待ち先が1つも読み取れない：理由を書いて人間に回す（黙って待ち続けない）"
init_state '{"labels":{"3":["ai:plan"]}}'
run_plan BLOCKED "あとで" > /dev/null
assert_eq "ai:stuck" "ai:stuck" "$(labels_of 3)"
assert_contains "理由を書く" "$(comments_of 3)" "待ち先が読み取れませんでした"

echo "== 見張り役：待ち先がまだ開いている間は戻さない"
init_state '{"labels":{"3":["ai:blocked"],"9":[]},"comments":['"$(block_comment o/r#9)"']}'
out=$(run_script watchdog.sh)
assert_eq "ai:blocked のまま" "ai:blocked" "$(labels_of 3)"
assert_contains "待つと知らせる" "$out" "まだ開いているので、待ちます"

echo "== 見張り役：待ち先が全部閉じたら、ai:blocked を外して ai:plan に戻す"
state_py "s.setdefault('issues_meta',{})['9']={'state':'closed','title':'t'}"
out=$(run_script watchdog.sh)
assert_eq "ai:plan に戻る" "ai:plan" "$(labels_of 3)"
assert_contains "コメントを書く" "$(comments_of 3)" "待ち先が全部終わったので、企画に戻します"

echo "== 見張り役：別のリポジトリの待ち先と、PR の待ち先（片方が開いていれば待つ・両方閉じたら戻す）"
init_state '{"labels":{"3":["ai:blocked"]},"comments":['"$(block_comment o/other#58 o/app#12)"'],"other_repos":{"o/other":{"58":{"state":"closed"}},"o/app":{"12":{"state":"open","pull_request":{}}}}}'
run_script watchdog.sh > /dev/null
assert_eq "片方が開いていれば待つ" "ai:blocked" "$(labels_of 3)"
state_py "s['other_repos']['o/app']['12']['state']='closed'"
run_script watchdog.sh > /dev/null
assert_eq "両方閉じたら戻す" "ai:plan" "$(labels_of 3)"

echo "== 見張り役：待ち先を読めないときは戻さない。読めないまま長くたったら、理由を書いて人間に回す"
init_state '{"labels":{"3":["ai:blocked"]},"comments":['"$(block_comment o/private#1)"']}'
out=$(run_script watchdog.sh)
assert_eq "戻さない" "ai:blocked" "$(labels_of 3)"
assert_contains "読めないと知らせる" "$out" "読めないので、今回は何もしません"
state_py "s['issue_updated']['3']='$(ago 90)'"
run_script watchdog.sh > /dev/null
assert_contains "長く読めなければ人間に回す" "$(labels_of 3)" "ai:stuck"
assert_contains "理由を書く" "$(comments_of 3)" "状態を読めないまま"
assert_not_contains "企画には戻さない" "$(labels_of 3)" "ai:plan"

echo "== 見張り役：待ち先のコメントが2つあれば、新しい方だけを見る"
init_state '{"labels":{"3":["ai:blocked"],"9":[],"10":[]},"issues_meta":{"9":{"state":"open"},"10":{"state":"closed"}},"comments":['"$(block_comment o/r#9)"','"$(block_comment o/r#10 | sed 's/"id": 1/"id": 2/')"']}'
run_script watchdog.sh > /dev/null
assert_eq "新しい待ち先（閉じている）で戻る" "ai:plan" "$(labels_of 3)"

echo "== 見張り役：印の無い ai:blocked は、理由を書いて人間に回す"
init_state '{"labels":{"3":["ai:blocked"]}}'
run_script watchdog.sh > /dev/null
assert_contains "人間に回す" "$(labels_of 3)" "ai:stuck"
assert_contains "理由" "$(comments_of 3)" "待ち先の印（blocked-by）がありません"

finish
