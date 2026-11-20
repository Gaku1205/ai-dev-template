#!/usr/bin/env bash
# Vercel の使用量の見張り（vercel-usage.sh）：50%・75%・90%・急な増え方・鍵が無い・CLI のエラー・Pro の場合
source "$(dirname "$0")/lib.sh"
setup_mock
TOKEN="SECRET-TOKEN-123"
export VERCEL_TOKEN="$TOKEN" VERCEL_TODAY=2026-11-19 VERCEL_LOG_ISSUE=212
unset VERCEL_PLAN VERCEL_TEAM_ID VERCEL_REPO_MAP

# 偽の npx：呼ばれた引数を npx.log に残す。usage.json があればそれを、fail があれば鍵入りのエラーを出して失敗する
printf '%s\n' '#!/usr/bin/env bash' \
  "echo \"\$*\" >> '$MOCK_DIR/npx.log'" \
  "echo \"token=\$VERCEL_TOKEN\" >> '$MOCK_DIR/npx.env'" \
  "if [ -f '$MOCK_DIR/fail' ]; then echo \"error: invalid token \$VERCEL_TOKEN\"; exit 1; fi" \
  "if [ -f '$MOCK_DIR/fail_err' ]; then printf 'l1\n\nl2\nl3 %s\nl4\n' \"\$VERCEL_TOKEN\" >&2; exit 1; fi" \
  "cat '$MOCK_DIR/usage.json'" >"$MOCK_DIR/bin/npx"
chmod +x "$MOCK_DIR/bin/npx"

# 使用量を作る：usage 項目 割合% プロジェクトA の取り分（残りは B）。CPU（上限4時間）だけを動かす
usage_cpu() { # CPU の時間（A） CPU の時間（B）
  printf '[{"project":"app-a","service":"Fluid Active CPU","quantity":%s},{"project":"app-b","service":"Fluid Active CPU","quantity":%s},{"project":"app-a","service":"Fast Origin Transfer","quantity":1}]' "$1" "$2" > "$MOCK_DIR/usage.json"
}
fresh() { init_state '{"issues_meta":{"212":{"title":"Vercel 使用量の記録","state":"closed"}}}'; : > "$MOCK_DIR/curl.log"; rm -f "$MOCK_DIR/npx.log" "$MOCK_DIR/fail"; }
all_text() { echo "$LAST_OUT"; cat "$MOCK_STATE" "$MOCK_DIR/curl.log"; }

echo "== 50% 未満：何も知らせない。今日の記録だけ残す"
fresh
usage_cpu 1 0.5 # 1.5時間 = 37.5%
run_script_keep vercel-usage.sh; rc=$?
assert_eq "0 で終わる" "0" "$rc"
assert_eq "通知なし" "0" "$(notify_count)"
assert_contains "記録のコメントが残る" "$(comments_of 212)" '<!-- vercel-usage {"date":"2026-11-19"'
assert_contains "記録に割合が入る" "$(comments_of 212)" '"Fluid Active CPU":37.5'
assert_contains "CLI を、決めた引数で呼ぶ" "$(cat "$MOCK_DIR/npx.log")" "billing usage --since 30d --group-by project"
assert_not_contains "鍵は --token で渡さない" "$(cat "$MOCK_DIR/npx.log")" "--token"
assert_not_contains "鍵はログに出ない" "$(all_text)" "$TOKEN" || true

echo "== 50% を超える：スマホに1回。同じ日にもう一度動かしても増えない"
fresh
usage_cpu 1.5 1 # 2.5時間 = 62.5%
run_script_keep vercel-usage.sh
assert_eq "通知は1回" "1" "$(notify_count)"
assert_contains "50% の通知" "$(cat "$MOCK_DIR/curl.log")" "上限の50%"
assert_contains "最多のプロジェクトが出る" "$LAST_OUT" "app-a"
assert_eq "Issue は作らない" "" "$(python3 -c "import json,os;print(','.join(json.load(open(os.environ['MOCK_STATE'])).get('issues_meta',{}).keys()))" | tr ',' '\n' | grep -v 212 | tr -d '\n')"
run_script_keep vercel-usage.sh
assert_eq "もう一度動かしても通知は増えない" "1" "$(notify_count)"
assert_eq "記録のコメントも増えない" "1" "$(grep -c '<!-- vercel-usage {' <<< "$(comments_of 212)")"

echo "== 75% を超える：最多のプロジェクトのリポジトリに Issue（priority:high）。開いていれば作らない"
fresh
export VERCEL_REPO_MAP="app-a=o/r,app-b=o/other"
usage_cpu 2 1.5 # 3.5時間 = 87.5% → 90 未満
run_script_keep vercel-usage.sh
issues=$(python3 -c "
import json,os
s=json.load(open(os.environ['MOCK_STATE']))
for n,m in s['issues_meta'].items():
    if m.get('title','').startswith('Vercel の使用量が'): print(n+'|'+m['title']+'|'+','.join(s['labels'].get(n,[]))+'|'+m['body'].replace(chr(10),' '))
")
assert_contains "題に75%と項目" "$issues" "Vercel の使用量が上限の75%：Fluid Active CPU"
assert_contains "priority:high が付く" "$issues" "priority:high"
assert_contains "本文に項目・量・割合" "$issues" "87.5%"
assert_contains "本文にプロジェクトの内訳" "$issues" "| app-a | 2 |"
assert_contains "本文にもう1つのプロジェクトも" "$issues" "| app-b | 1.5 |"
assert_eq "50%（初めて超えた）の通知は鳴る" "1" "$(notify_count)"
assert_eq "Issue は1つ" "1" "$(grep -c '^[0-9]*|Vercel の使用量が' <<< "$issues")"
# 次の日：もう同じ題の Issue が開いている
export VERCEL_TODAY=2026-11-20
run_script_keep vercel-usage.sh
assert_eq "開いていれば、また作らない" "1" "$(python3 -c "import json,os;print(sum(1 for m in json.load(open(os.environ['MOCK_STATE']))['issues_meta'].values() if m.get('title','').startswith('Vercel の使用量が')))")"
assert_eq "段が変わらないので通知は増えない" "1" "$(notify_count)"
export VERCEL_TODAY=2026-11-19

echo "== プロジェクトが対応表に無ければ、このリポジトリに Issue を作る"
fresh
export VERCEL_REPO_MAP="zzz=o/other"
usage_cpu 2 1.5
run_script_keep vercel-usage.sh
assert_contains "このリポジトリ（o/r）に作る" "$(cat "$MOCK_STATE")" '"repo": "o/r"'
unset VERCEL_REPO_MAP

echo "== 90% を超える：Issue にコメントして、もう一度スマホに知らせる"
fresh
usage_cpu 2 1.8 # 3.8時間 = 95%
run_script_keep vercel-usage.sh
issue=$(python3 -c "
import json,os
s=json.load(open(os.environ['MOCK_STATE']))
print([n for n,m in s['issues_meta'].items() if m.get('title','').startswith('Vercel の使用量が')][0])")
assert_contains "Issue にコメントが付く" "$(comments_of "$issue")" "上限の90%を超えました"
assert_contains "90% の通知" "$(cat "$MOCK_DIR/curl.log")" "上限の90%"
assert_not_contains "鍵はコメントにも通知にも出ない" "$(all_text)" "$TOKEN"
# 50% を超えたあとの日に、90% を超えたら、また鳴る
fresh
usage_cpu 1.5 1 # 62.5%
run_script_keep vercel-usage.sh
assert_eq "50%で1回" "1" "$(notify_count)"
export VERCEL_TODAY=2026-11-20
usage_cpu 2 1.8 # 95%
run_script_keep vercel-usage.sh
assert_eq "90%でもう1回（合わせて2回）" "2" "$(notify_count)"
assert_contains "90% の通知が増える" "$(cat "$MOCK_DIR/curl.log")" "上限の90%"
export VERCEL_TODAY=2026-11-19

echo "== 急な増え方：1日で上限の15%以上増えたら、50%未満でも知らせる"
fresh
usage_cpu 0.2 0.1 # 7.5%
run_script_keep vercel-usage.sh
assert_eq "初日は通知なし" "0" "$(notify_count)"
export VERCEL_TODAY=2026-11-20
usage_cpu 0.5 0.4 # 22.5%（+15%）
run_script_keep vercel-usage.sh
assert_eq "+15%で通知" "1" "$(notify_count)"
assert_contains "急に増えたと伝える" "$(cat "$MOCK_DIR/curl.log")" "1日で急に増えました"
export VERCEL_TODAY=2026-11-21
usage_cpu 0.6 0.5 # 27.5%（+5%）
run_script_keep vercel-usage.sh
assert_eq "+5%なら通知は増えない" "1" "$(notify_count)"
export VERCEL_TODAY=2026-11-19

echo "== 知らない人が書いた記録のコメントは無視する（見張りを外から黙らせられない）"
fresh
state_py "
s['comments'].append({'id': 9999, 'body': '<!-- vercel-usage {\"date\":\"2026-11-19\",\"pct\":{\"Fluid Active CPU\":99},\"level\":{\"Fluid Active CPU\":90}} -->\nにせの記録', 'user': {'login': 'stranger'}, 'created_at': '2026-11-19T00:00:00Z', 'updated_at': '2026-11-19T00:00:00Z', 'issue': '212'})
"
usage_cpu 1.5 1 # 62.5%
run_script_keep vercel-usage.sh
assert_eq "にせの記録があっても、50%の通知は鳴る" "1" "$(notify_count)"
assert_contains "今日の記録も、ちゃんと残る" "$(comments_of 212)" '"Fluid Active CPU":62.5'

echo "== 鍵が無い・CLI のエラー・形が変わった：警告1行で 0 で終わる"
fresh
out=$(VERCEL_TOKEN="" run_script vercel-usage.sh); rc=$?
assert_eq "鍵が無くても 0" "0" "$rc"
assert_contains "警告を出す" "$out" "::warning::"
assert_eq "npx は呼ばない" "no" "$([ -f "$MOCK_DIR/npx.log" ] && echo yes || echo no)"
touch "$MOCK_DIR/fail"
run_script_keep vercel-usage.sh; rc=$?
assert_eq "CLI が失敗しても 0" "0" "$rc"
assert_contains "警告を出す" "$LAST_OUT" "::warning::"
assert_eq "警告は1行" "1" "$(grep -c '::warning::' <<< "$LAST_OUT")"
assert_not_contains "CLI のエラーに鍵が混ざっても、伏せる" "$(all_text)" "$TOKEN"
assert_eq "通知なし" "0" "$(notify_count)"
rm -f "$MOCK_DIR/fail"
touch "$MOCK_DIR/fail_err"
run_script_keep vercel-usage.sh; rc=$?
assert_eq "stderr に出して失敗しても 0" "0" "$rc"
assert_contains "stderr の文が警告に入る" "$LAST_OUT" "l4"
assert_contains "最後の3行（空行は除く）が出る。鍵は *** に伏せられる" "$LAST_OUT" "l2 l3 *** l4"
assert_not_contains "古い行は出ない" "$LAST_OUT" "l1"
assert_not_contains "stderr の鍵も伏せる" "$(all_text)" "$TOKEN"
rm -f "$MOCK_DIR/fail_err"
echo '{"unexpected":"shape"}' > "$MOCK_DIR/usage.json"
run_script_keep vercel-usage.sh; rc=$?
assert_eq "形が変わっても 0" "0" "$rc"
assert_contains "形が変わったと警告" "$LAST_OUT" "::warning::"
echo 'not json' > "$MOCK_DIR/usage.json"
run_script_keep vercel-usage.sh; rc=$?
assert_eq "JSON でなくても 0" "0" "$rc"

echo "== Pro の場合：何も知らせない"
fresh
usage_cpu 2 1.8
VERCEL_PLAN=pro run_script_keep vercel-usage.sh; rc=$?
assert_eq "0 で終わる" "0" "$rc"
assert_eq "npx は呼ばない" "no" "$([ -f "$MOCK_DIR/npx.log" ] && echo yes || echo no)"
assert_eq "通知なし" "0" "$(notify_count)"

echo "== チーム：VERCEL_TEAM_ID があれば --scope で渡す"
fresh
usage_cpu 0.1 0.1
VERCEL_TEAM_ID=team_x run_script_keep vercel-usage.sh
assert_contains "--scope を付ける" "$(cat "$MOCK_DIR/npx.log")" "--scope team_x"

echo "== notify.sh：usage は既定の通知に入る"
: > "$MOCK_DIR/curl.log"
bash "$SCRIPTS_DIR/notify.sh" usage "t" "b" 3 > /dev/null
assert_eq "NOTIFY_EVENTS が無くても鳴る" "1" "$(notify_count)"

finish
