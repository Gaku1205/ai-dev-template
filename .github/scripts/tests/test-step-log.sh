#!/usr/bin/env bash
# 進捗ログ（step-log.sh）：Issue ごとにコメントは1つだけ。工程ごとの行を上書きし、失敗しても止まらない
source "$(dirname "$0")/lib.sh"
setup_mock
init_state '{"pulls":[{"number":30,"body":"Closes #7","head":{"ref":"claude/issue-7-x","sha":"abc"}}]}'

log() { STEP_LOG_NOW="$1" run_script step-log.sh "${@:2}"; }
count_logs() { python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print(sum(1 for c in s['comments'] if c['issue']=='$1' and 'ai-step-log' in c['body']))"; }

echo "== 初回はコメントを作り、2回目以降は同じコメントを更新する"
log 2026-11-15T07:00:00Z --issue 7 --step plan --model sonnet --result running > /dev/null
assert_eq "コメントが1つ" "1" "$(count_logs 7)"
log 2026-11-15T07:02:30Z --issue 7 --step plan --model sonnet --result success > /dev/null
assert_eq "更新してもコメントは1つ" "1" "$(count_logs 7)"
body=$(comments_of 7)
assert_contains "先頭の目印" "$body" "<!-- ai-step-log -->"
assert_contains "開始時刻を引き継ぐ" "$body" '"started":"2026-11-15T07:00:00Z"'
assert_contains "終了時刻" "$body" '"finished":"2026-11-15T07:02:30Z"'
assert_contains "所要時間" "$body" "| plan | sonnet | 2分30秒 | 成功 | - |"

echo "== 全工程のモデル名・所要時間・結果が出る（PR番号から Issue を引く）"
log 2026-11-15T07:03:00Z --issue 7 --step mocks --model opus --result running > /dev/null
log 2026-11-15T07:13:00Z --issue 7 --step mocks --model opus --result success > /dev/null
log 2026-11-15T07:14:00Z --pr 30 --step implement --model haiku --result running > /dev/null
log 2026-11-15T07:20:05Z --pr 30 --step implement --model haiku --result success > /dev/null
log 2026-11-15T07:21:00Z --pr 30 --step ci --model null --result running > /dev/null
log 2026-11-15T07:25:00Z --pr 30 --step ci --model null --result success > /dev/null
log 2026-11-15T07:26:00Z --pr 30 --step review --model sonnet --result running > /dev/null
log 2026-11-15T07:27:00Z --pr 30 --step review --model sonnet --result success > /dev/null
log 2026-11-15T07:30:00Z --pr 30 --step deploy --model "" --result running > /dev/null
assert_eq "コメントは1つのまま" "1" "$(count_logs 7)"
body=$(comments_of 7)
assert_contains "mocks" "$body" "| mocks | opus | 10分0秒 | 成功 | - |"
assert_contains "implement" "$body" "| implement | haiku | 6分5秒 | 成功 | - |"
assert_contains "ci はモデル無し" "$body" '"step":"ci","model":null'
assert_contains "ci の表" "$body" "| ci | - | 4分0秒 | 成功 | - |"
assert_contains "review" "$body" "| review | sonnet | 1分0秒 | 成功 | - |"
assert_contains "進行中の工程" "$body" "| deploy | - | - | 進行中 | - |"
assert_contains "進行中は finished が null" "$body" '"step":"deploy","model":null,"started":"2026-11-15T07:30:00Z","finished":null,"result":"running"'
order=$(printf '%s\n' "$body" | grep -oE '^<!-- ai-step \{"step":"[a-z]+"' | grep -oE '[a-z]+"$' | tr -d '"\n')
assert_eq "工程の順に並ぶ" "planmocksimplementcireviewdeploy" "$order"

echo "== 失敗のあと修正が入ると「修正 n回目 / 3」が記録される"
log 2026-11-15T07:26:00Z --pr 30 --step review --model sonnet --result running > /dev/null
log 2026-11-15T07:28:00Z --pr 30 --step review --model sonnet --result failure > /dev/null
log 2026-11-15T07:29:00Z --pr 30 --step fix --model sonnet --result running --attempt 1 --max-attempts 3 > /dev/null
log 2026-11-15T07:31:00Z --pr 30 --step fix --model sonnet --result success --attempt 1 --max-attempts 3 > /dev/null
assert_contains "1回目" "$(comments_of 7)" "| fix | sonnet | 2分0秒 | 成功 | 修正 1回目 / 3 |"
log 2026-11-15T07:32:00Z --pr 30 --step fix --model opus --result running --attempt 2 --max-attempts 3 > /dev/null
body=$(comments_of 7)
assert_contains "2回目で行を上書き" "$body" "| fix | opus | - | 進行中 | 修正 2回目 / 3 |"
assert_contains "JSON に attempt" "$body" '"attempt":2,"max_attempts":3'
assert_eq "fix の行は1つ" "1" "$(printf '%s\n' "$body" | grep -c '^<!-- ai-step {"step":"fix"')"
assert_contains "review の失敗" "$body" "| review | sonnet | 2分0秒 | 失敗 | - |"
assert_eq "コメントは1つのまま" "1" "$(count_logs 7)"

echo "== 同時に書いても行が消えない：書いた後に読み直し、消えていたら足して書き直す"
# 割り込み役の gh：本物（疑似 gh）の前か後に、ほかの工程の書き込みを1回だけ起こす
#   RACE_AFTER  ：コメントを書いた（PATCH・POST）直後に動かす python（変数 s が状態）
#   RACE_BEFORE ：コメントを作る（POST）直前に動かす python
mkdir -p "$MOCK_DIR/racebin"
cat > "$MOCK_DIR/racebin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" | head -1 >> "$MOCK_DIR/gh-calls.log"
race() { [ -f "$1" ] || return 0; code=$(cat "$1"); rm -f "$1"; python3 -c "
import json, os, sys
s = json.load(open(os.environ['MOCK_STATE']))
exec(sys.argv[1])
json.dump(s, open(os.environ['MOCK_STATE'], 'w'))" "$code"; }
write=0
case "$*" in
  *"-X PATCH"*"issues/comments/"*) write=1 ;;
  *"issues/"*"/comments -f body="*) write=1; race "$MOCK_DIR/RACE_BEFORE" ;;
esac
"$MOCK_DIR/bin/gh" "$@"; rc=$?
[ "$write" = 1 ] && race "$MOCK_DIR/RACE_AFTER"
exit $rc
GH
chmod +x "$MOCK_DIR/racebin/gh"
export MOCK_DIR
rlog() { : > "$MOCK_DIR/gh-calls.log"; PATH="$MOCK_DIR/racebin:$PATH" STEP_LOG_NOW="$1" run_script step-log.sh "${@:2}"; }
calls() { grep -c -e "$1" "$MOCK_DIR/gh-calls.log" || true; }
steps_in() { comments_of "$1" | grep -oE '^<!-- ai-step \{"step":"[a-z]+"' | grep -oE '[a-z]+"$' | tr -d '"' | tr '\n' ' '; }
# ほかの工程の書き込み：割り込まれる前の表（自分の行が無い古い表）に、review の行を足した本文で上書きする
other_write() { cat <<PY
import re
for c in s['comments']:
    if c['issue']=='$1' and 'ai-step-log' in c['body']:
        c['body'] = OLD + '\n<!-- ai-step {"step":"review","model":"sonnet","started":"2026-11-15T08:00:00Z","finished":"2026-11-15T08:01:00Z","result":"success"} -->'
PY
}
old_body_py() { python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print('OLD='+repr([c['body'] for c in s['comments'] if c['issue']=='$1' and 'ai-step-log' in c['body']][0]))"; }

init_state '{}'
log 2026-11-15T07:00:00Z --issue 20 --step plan --model sonnet --result success > /dev/null
{ old_body_py 20; other_write 20; } > "$MOCK_DIR/RACE_AFTER"
out=$(rlog 2026-11-15T08:01:00Z --issue 20 --step ci --model null --result success --started 2026-11-15T07:55:00Z)
assert_eq "ほかの工程に上書きされても、3つの行が全部残る" "plan ci review " "$(steps_in 20)"
assert_contains "書き直したことを出す" "$out" "足して書き直します"
assert_eq "コメントは1つ" "1" "$(count_logs 20)"
assert_eq "書き込みは2回（最初と、書き直し）" "2" "$(calls "-X PATCH")"

echo "== 割り込みが無ければ、API は読み直しの1回が増えるだけ（一覧1・書き込み1・読み直し1）"
out=$(rlog 2026-11-15T08:05:00Z --issue 20 --step fix --model sonnet --result running --attempt 1)
assert_eq "API の回数" "3" "$(wc -l < "$MOCK_DIR/gh-calls.log" | tr -d ' ')"
assert_eq "書き込みは1回" "1" "$(calls "-X PATCH")"
assert_not_contains "書き直さない" "$out" "書き直します"

echo "== 進行中の行に戻されたとき（置き換える前の行）も、消されたと見て書き直す"
{ old_body_py 20; other_write 20; } > "$MOCK_DIR/RACE_AFTER"
rlog 2026-11-15T08:09:00Z --issue 20 --step fix --model sonnet --result success --attempt 1 > /dev/null
assert_contains "fix は成功の行" "$(comments_of 20)" '"step":"fix","model":"sonnet","started":"2026-11-15T08:05:00Z","finished":"2026-11-15T08:09:00Z","result":"success"'
assert_eq "fix の行は1つ" "1" "$(comments_of 20 | grep -c '^<!-- ai-step {"step":"fix"')"

echo "== 同じ工程のもっと新しい記録（修正の2回目）が入っていたら、古い記録で上書きしない"
cat > "$MOCK_DIR/RACE_AFTER" <<'PY'
for c in s['comments']:
    if c['issue']=='20' and 'ai-step-log' in c['body']:
        c['body'] = '\n'.join(l for l in c['body'].split('\n') if '"step":"fix"' not in l) + '\n<!-- ai-step {"step":"fix","model":"opus","started":"2026-11-15T08:20:00Z","finished":null,"result":"running","attempt":2,"max_attempts":3} -->'
PY
out=$(rlog 2026-11-15T08:10:00Z --issue 20 --step fix --model sonnet --result failure --attempt 1)
assert_contains "新しい記録が残る" "$(comments_of 20)" '"result":"running","attempt":2'
assert_not_contains "書き直さない" "$out" "書き直します"

echo "== 何度書き直しても消され続けるときは、決めた回数でやめる（延々と続けない）"
init_state '{}'
log 2026-11-15T07:00:00Z --issue 21 --step plan --model sonnet --result success > /dev/null
cat > "$MOCK_DIR/racebin/gh-loop" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" | head -1 >> "$MOCK_DIR/gh-calls.log"
"$MOCK_DIR/bin/gh" "$@"; rc=$?
case "$*" in *"-X PATCH"*) python3 -c "
import json, os
s = json.load(open(os.environ['MOCK_STATE']))
for c in s['comments']:
    c['body'] = '\n'.join(l for l in c['body'].split('\n') if '\"step\":\"ci\"' not in l)
json.dump(s, open(os.environ['MOCK_STATE'], 'w'))" ;; esac
exit $rc
GH
mkdir -p "$MOCK_DIR/loopbin"; cp "$MOCK_DIR/racebin/gh-loop" "$MOCK_DIR/loopbin/gh"; chmod +x "$MOCK_DIR/loopbin/gh"
: > "$MOCK_DIR/gh-calls.log"
out=$(PATH="$MOCK_DIR/loopbin:$PATH" bash "$SCRIPTS_DIR/step-log.sh" --issue 21 --step ci --model null --result success 2>&1); code=$?
assert_eq "終了コード 0" "0" "$code"
assert_eq "書き込みは3回まで（最初と、書き直し2回）" "3" "$(calls "-X PATCH")"

echo "== 2つの工程が同時に進捗ログを作ったら、先の1つに足して、今作った方を消す（コメントは1つ）"
init_state '{}'
cat > "$MOCK_DIR/RACE_BEFORE" <<'PY'
s['next_id'] += 1
s['comments'].append({'id': s['next_id'], 'issue': '22', 'user': {'login': 'github-actions[bot]'}, 'created_at': '2026-11-15T08:00:00Z', 'updated_at': '2026-11-15T08:00:00Z',
  'body': '<!-- ai-step-log -->\n### 進捗ログ\n\n<!-- ai-step {"step":"review","model":"sonnet","started":"2026-11-15T08:00:00Z","finished":"2026-11-15T08:01:00Z","result":"success"} -->'})
PY
out=$(rlog 2026-11-15T08:01:00Z --issue 22 --step ci --model null --result success)
assert_eq "コメントは1つ" "1" "$(count_logs 22)"
assert_eq "両方の行が残る" "ci review " "$(steps_in 22)"
assert_contains "何が起きたかを出す" "$out" "先に進捗ログを作っていた"
echo "== 1つだけ作ったとき（ふつう）は、消さない"
init_state '{}'
out=$(rlog 2026-11-15T08:01:00Z --issue 23 --step plan --model sonnet --result running)
assert_eq "コメントは1つ" "1" "$(count_logs 23)"
assert_eq "消す呼び出しは無い" "0" "$(calls "-X DELETE")"
assert_eq "API の回数（一覧1・作る1・一覧の読み直し1）" "3" "$(wc -l < "$MOCK_DIR/gh-calls.log" | tr -d ' ')"

echo "== gh が失敗しても終了コードは 0（警告を出すだけ）"
mkdir -p "$MOCK_DIR/failbin"
printf '#!/usr/bin/env bash\necho "HTTP 403" >&2\nexit 1\n' > "$MOCK_DIR/failbin/gh"
chmod +x "$MOCK_DIR/failbin/gh"
out=$(PATH="$MOCK_DIR/failbin:$PATH" bash "$SCRIPTS_DIR/step-log.sh" --issue 8 --step plan --model sonnet --result running 2>&1); code=$?
assert_eq "終了コード 0" "0" "$code"
assert_contains "警告が出る" "$out" "::warning::進捗ログを残せませんでした"
assert_not_contains "error にはしない" "$out" "::error"
out=$(bash "$SCRIPTS_DIR/step-log.sh" --step nothing --result running 2>&1); code=$?
assert_eq "引数が間違っていても 0" "0" "$code"
out=$(env -u GITHUB_REPOSITORY bash "$SCRIPTS_DIR/step-log.sh" --issue 8 --step plan --result running 2>&1); code=$?
assert_eq "リポジトリ不明でも 0" "0" "$code"

finish
