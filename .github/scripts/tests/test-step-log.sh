#!/usr/bin/env bash
# 進捗ログ（step-log.sh）：Issue ごとにコメントは1つだけ。工程ごとの行を上書きし、失敗しても止まらない
source "$(dirname "$0")/lib.sh"
setup_mock
init_state '{"pulls":[{"number":30,"body":"Closes #7","head":{"ref":"claude/issue-7-x","sha":"abc"}}]}'

log() { STEP_LOG_NOW="$1" run_script step-log.sh "${@:2}"; }
count_logs() { python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print(sum(1 for c in s['comments'] if c['issue']=='$1' and 'pipeline-step-log' in c['body']))"; }

echo "== 初回はコメントを作り、2回目以降は同じコメントを更新する"
log 2026-11-15T07:00:00Z --issue 7 --step plan --model sonnet --result running > /dev/null
assert_eq "コメントが1つ" "1" "$(count_logs 7)"
log 2026-11-15T07:02:30Z --issue 7 --step plan --model sonnet --result success > /dev/null
assert_eq "更新してもコメントは1つ" "1" "$(count_logs 7)"
body=$(comments_of 7)
assert_contains "先頭の目印" "$body" "<!-- pipeline-step-log -->"
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
order=$(printf '%s\n' "$body" | grep -oE '^<!-- step-log: \{"step":"[a-z]+"' | grep -oE '[a-z]+"$' | tr -d '"\n')
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
assert_eq "fix の行は1つ" "1" "$(printf '%s\n' "$body" | grep -c '^<!-- step-log: {"step":"fix"')"
assert_contains "review の失敗" "$body" "| review | sonnet | 2分0秒 | 失敗 | - |"
assert_eq "コメントは1つのまま" "1" "$(count_logs 7)"

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
