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
[ -n "$out" ] && echo '{"mismatches":2}' > "$out"
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

finish
