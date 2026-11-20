#!/usr/bin/env bash
# Supabase を起こしておく（supabase-keepalive.sh）：supabase のあるアプリだけで、小さな表に書く。止まっていたら理由を出して失敗にし、知らせる。
# データベースは疑似 psql で真似る（本物には触らない）
source "$(dirname "$0")/lib.sh"
setup_mock
T="$(mktemp -d)"; trap 'rm -rf "$T" "$MOCK_DIR"' EXIT
mkdir -p "$T/bin"
export FT="$T"
# 疑似 psql：受け取った SQL（-c の次）を psql.log に残す。FT/fail があれば、その中身を標準エラーに出して失敗する
cat > "$T/bin/psql" <<'SH'
#!/usr/bin/env bash
if [ -f "$FT/fail" ]; then cat "$FT/fail" >&2; exit 2; fi
while [ $# -gt 0 ]; do if [ "$1" = "-c" ]; then printf '%s\n' "$2" >> "$FT/psql.log"; shift; fi; shift; done
SH
chmod +x "$T/bin/psql"
keepalive() { (cd "$T" && env PATH="$T/bin:$PATH" bash "$SCRIPTS_DIR/supabase-keepalive.sh" 2>&1); }

echo "== 公開先に supabase が無いリポジトリでは、何もしない"
echo '{"deploy":[{"kind":"vercel"}]}' > "$T/pipeline.json"
out=$(SUPABASE_DB_URL=postgresql://x keepalive); code=$?
assert_eq "成功で終わる" "0" "$code"
assert_contains "何もしないと書く" "$out" "supabase が無い"
assert_eq "データベースに触らない" "" "$(cat "$T/psql.log" 2> /dev/null)"
rm -f "$T/pipeline.json"
out=$(SUPABASE_DB_URL=postgresql://x keepalive); code=$?
assert_eq "pipeline.json が無くても成功で終わる" "0" "$code"

echo "== supabase があれば、小さな表に今の時刻を書く（つなぐだけでは数えられないので、書き込む）"
echo '{"deploy":[{"kind":"vercel"},{"kind":"supabase"}]}' > "$T/pipeline.json"
out=$(SUPABASE_DB_URL=postgresql://x keepalive); code=$?
assert_eq "成功" "0" "$code"
assert_contains "書いたと書く" "$out" "Supabase に書き込みました"
assert_contains "表が無ければ作る" "$(cat "$T/psql.log")" "create table if not exists app_meta.heartbeat"
assert_contains "1行を書き直す（増やさない）" "$(cat "$T/psql.log")" "on conflict (id) do update"
assert_eq "通知しない" "0" "$(notify_count)"

echo "== 接続先の Secret が無ければ、警告だけで終わる（落とさない）"
out=$(SUPABASE_DB_URL='' keepalive); code=$?
assert_eq "成功で終わる" "0" "$code"
assert_contains "警告" "$out" "SUPABASE_DB_URL が無い"

echo "== もう止まっていたら、理由を出して失敗にし、スマホに知らせる"
echo "psql: error: FATAL:  (ENOTFOUND) tenant/user postgres.abc not found" > "$T/fail"
out=$(SUPABASE_DB_URL=postgresql://x keepalive); code=$?
assert_eq "失敗で終わる" "1" "$code"
assert_contains "止まっていると書く" "$out" "一時停止しています"
assert_contains "起こし方を書く" "$out" "Resume project"
assert_eq "1回知らせる" "1" "$(notify_count)"
assert_contains "知らせる中身" "$(cat "$MOCK_DIR/curl.log")" "一時停止しています"
assert_not_contains "知らせに psql の文そのものは入れない" "$(cat "$MOCK_DIR/curl.log")" "postgres.abc"

echo "== 理由の分からない失敗は「ログを見てください」"
: > "$MOCK_DIR/curl.log"
echo "ERROR:  something odd" > "$T/fail"
out=$(SUPABASE_DB_URL=postgresql://x keepalive); code=$?
assert_eq "失敗で終わる" "1" "$code"
assert_contains "決まった文" "$out" "Supabase に書き込めませんでした（ログを見てください）"
rm -f "$T/fail"

finish
