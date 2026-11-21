#!/usr/bin/env bash
# selfcheck-call.sh（agent-desk の自己点検を呼ぶ）のテスト。偽の curl で、呼び方と、どの場合も終了コード 0 になることを確かめる
source "$(dirname "$0")/lib.sh"
setup_mock

# 偽 curl：引数を args.log、標準入力（ヘッダ）を stdin.log に残す。-o の先に応答を書き、-w の分として HTTP コードを出す
# FAKE_CODE=HTTPコード、FAKE_RC=curl の終了コード（0以外なら、コードは 000）
cat > "$MOCK_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$MOCK_DIR/args.log"
cat >> "$MOCK_DIR/stdin.log"
out=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-o" ]; then out="$2"; fi
  shift
done
if [ "${FAKE_RC:-0}" -ne 0 ]; then printf '000'; exit "$FAKE_RC"; fi
if [ -n "$out" ]; then
  if [ -n "${FAKE_BODY:-}" ]; then printf '%s' "$FAKE_BODY" > "$out"; else echo '{"mismatches":2}' > "$out"; fi
fi
printf '%s' "${FAKE_CODE:-200}"
EOF
chmod +x "$MOCK_DIR/bin/curl"

export MOCK_DIR
SECRET="ghs_SECRET_TOKEN_123"
export GH_TOKEN="$SECRET" AGENT_DESK_URL="https://desk.example.com"
RC=0

call() { # 環境変数を整えて動かす。出力は LAST_OUT、終了コードは RC
  : > "$MOCK_DIR/args.log"; : > "$MOCK_DIR/stdin.log"
  LAST_OUT=$(bash "$SCRIPTS_DIR/selfcheck-call.sh" 2>&1); RC=$?
}

echo "AGENT_DESK_URL が無い"
AGENT_DESK_URL="" FAKE_CODE=200 call
assert_eq "終了コード 0" "0" "$RC"
assert_eq "curl は呼ばれない" "" "$(cat "$MOCK_DIR/args.log")"

echo "GH_TOKEN が空"
GH_TOKEN="" call
assert_eq "終了コード 0" "0" "$RC"
assert_eq "curl は呼ばれない" "" "$(cat "$MOCK_DIR/args.log")"

echo "200"
FAKE_CODE=200 call
assert_eq "終了コード 0" "0" "$RC"
assert_contains "POST" "$(cat "$MOCK_DIR/args.log")" "-X POST"
assert_contains "URL が /api/selfcheck" "$(cat "$MOCK_DIR/args.log")" "https://desk.example.com/api/selfcheck"
assert_contains "30秒の上限" "$(cat "$MOCK_DIR/args.log")" "--max-time 30"
assert_contains "Authorization: Bearer が付く" "$(cat "$MOCK_DIR/stdin.log")" "Authorization: Bearer $SECRET"
assert_contains "結果を1行出す" "$LAST_OUT" "HTTP 200"
assert_not_contains "警告は出ない" "$LAST_OUT" "::warning::"
assert_not_contains "鍵が出力に出ない" "$LAST_OUT" "$SECRET"
assert_not_contains "鍵が curl の引数に出ない" "$(cat "$MOCK_DIR/args.log")" "$SECRET"

echo "末尾に / がある URL"
AGENT_DESK_URL="https://desk.example.com/" FAKE_CODE=200 call
assert_contains "// にならない" "$(cat "$MOCK_DIR/args.log")" "https://desk.example.com/api/selfcheck"
assert_not_contains "//api にならない" "$(cat "$MOCK_DIR/args.log")" "//api/selfcheck"

echo "404"
FAKE_CODE=404 call
assert_eq "終了コード 0" "0" "$RC"
assert_not_contains "警告を出さない" "$LAST_OUT" "::warning::"

for code in 401 500; do
  echo "$code"
  FAKE_CODE=$code call
  assert_eq "終了コード 0" "0" "$RC"
  assert_contains "警告を出す" "$LAST_OUT" "::warning::"
  assert_contains "コードが入る" "$LAST_OUT" "HTTP $code"
  assert_eq "警告は1行" "1" "$(grep -c '::warning::' <<< "$LAST_OUT")"
  assert_not_contains "鍵が出力に出ない" "$LAST_OUT" "$SECRET"
done

echo "時間切れ（curl の終了コード 28）"
FAKE_RC=28 call
assert_eq "終了コード 0" "0" "$RC"
assert_contains "警告を出す" "$LAST_OUT" "::warning::"
assert_contains "時間切れと分かる" "$LAST_OUT" "時間切れ"

echo "つながらない（curl の終了コード 7）"
FAKE_RC=7 call
assert_eq "終了コード 0" "0" "$RC"
assert_contains "警告を出す" "$LAST_OUT" "::warning::"
assert_not_contains "鍵が出力に出ない" "$LAST_OUT" "$SECRET"

# ── CPU の予算（agent-desk#698）：budget が warn・over なら、同じ日・同じ段で1回だけスマホに知らせる ──
export SELFCHECK_TODAY=2026-11-21 SELFCHECK_LOG_ISSUE=212
init_state '{"issues_meta":{"212":{"title":"記録","state":"closed"}}}'
ntfy_count() { grep -c 'ntfy.sh' "$MOCK_DIR/args.log" || true; }
WARN_BODY='{"mismatches":0,"usage":{"todayMs":130000,"avg7Ms":60000,"ratio":0.54},"budget":"warn"}'
OVER_BODY='{"mismatches":0,"usage":{"todayMs":250000,"avg7Ms":90000,"ratio":1.04},"budget":"over"}'

echo "budget が ok なら知らせない"
FAKE_BODY='{"usage":{"todayMs":1000,"avg7Ms":1000,"ratio":0.004},"budget":"ok"}' call
assert_eq "終了コード 0" "0" "$RC"
assert_eq "通知なし" "0" "$(ntfy_count)"
assert_eq "記録も残さない" "" "$(comments_of 212)"

echo "budget が unknown・無いなら知らせない"
FAKE_BODY='{"usage":null,"budget":"unknown"}' call
assert_eq "通知なし" "0" "$(ntfy_count)"
FAKE_BODY='{"mismatches":1}' call
assert_eq "budget が無くても通知なし" "0" "$(ntfy_count)"

echo "warn：1回知らせて、記録を残す"
FAKE_BODY="$WARN_BODY" call
assert_eq "終了コード 0" "0" "$RC"
assert_eq "通知1回" "1" "$(ntfy_count)"
assert_contains "50% の題" "$(cat "$MOCK_DIR/stdin.log")" "予算の50%を超えました"
assert_contains "今日の量が入る" "$(cat "$MOCK_DIR/stdin.log")" "130000ms"
assert_contains "割合が入る" "$(cat "$MOCK_DIR/stdin.log")" "予算の 54%"
assert_contains "種類は usage の優先度4" "$(cat "$MOCK_DIR/stdin.log")" '"priority": 4'
assert_contains "記録のコメント" "$(comments_of 212)" '<!-- selfcheck-budget {"date":"2026-11-21","budget":"warn"} -->'
assert_not_contains "鍵が通知に出ない" "$(grep -v '^Authorization: ' "$MOCK_DIR/stdin.log")" "$SECRET"

echo "同じ日にもう一度 warn：鳴らさない（30分ごとの見張りで増えない）"
FAKE_BODY="$WARN_BODY" call
assert_eq "通知なし" "0" "$(ntfy_count)"
assert_eq "記録は1つのまま" "1" "$(grep -c 'selfcheck-budget' <<< "$(comments_of 212)")"

echo "同じ日に over へ上がった：もう一度知らせる"
FAKE_BODY="$OVER_BODY" call
assert_eq "通知1回" "1" "$(ntfy_count)"
assert_contains "超えたの題" "$(cat "$MOCK_DIR/stdin.log")" "1日の予算を超えました"
assert_contains "優先度5" "$(cat "$MOCK_DIR/stdin.log")" '"priority": 5'
FAKE_BODY="$OVER_BODY" call
assert_eq "over の2回目は鳴らさない" "0" "$(ntfy_count)"
FAKE_BODY="$WARN_BODY" call
assert_eq "over の後の warn も鳴らさない" "0" "$(ntfy_count)"

echo "次の日：また知らせる"
SELFCHECK_TODAY=2026-11-22 FAKE_BODY="$WARN_BODY" call
assert_eq "通知1回" "1" "$(ntfy_count)"

echo "bot でない人の偽の記録は数えない"
init_state '{"issues_meta":{"212":{"title":"記録","state":"closed"}}}'
state_py "s['comments'].append({'id': 999, 'body': '<!-- selfcheck-budget {\"date\":\"2026-11-21\",\"budget\":\"over\"} -->', 'user': {'login': 'stranger'}, 'created_at': '2026-11-21T00:00:00Z', 'updated_at': '2026-11-21T00:00:00Z', 'issue': '212'})"
FAKE_BODY="$OVER_BODY" call
assert_eq "知らせる" "1" "$(ntfy_count)"

echo "記録が読めない：知らせずに警告（30分ごとに鳴らさない）"
init_state '{"issues_meta":{"212":{"title":"記録","state":"closed"}},"read_fail_comments":["212"]}'
FAKE_BODY="$OVER_BODY" call
assert_eq "終了コード 0" "0" "$RC"
assert_eq "通知なし" "0" "$(ntfy_count)"
assert_contains "警告を出す" "$LAST_OUT" "::warning::"

finish
