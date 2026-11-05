#!/usr/bin/env bash
# 会員と課金（saas）：土台を戻す（factory-saas.sh keep）、外の準備（factory-saas-provision.sh）、表の変更の公開（deploy-supabase.sh）。
# Supabase・Stripe・Vercel は疑似 curl で、データベースは疑似 psql で真似る（本物には触らない）
source "$(dirname "$0")/lib.sh"
ROOT="$(cd "$SCRIPTS_DIR/../.." && pwd)"
if [ ! -d "$ROOT/examples/saas" ]; then echo "見本が無いので、会員と課金のテストは飛ばします"; finish; exit $?; fi
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

echo "== デザイン担当の画面を入れた後：無くなった土台だけを戻し、作り直した見た目は上書きしない"
A="$T/app"; mkdir -p "$A/src/app/login"
echo 'export default function P() { return null; } // 作り直したログイン' > "$A/src/app/login/page.tsx"
bash "$SCRIPTS_DIR/factory-saas.sh" "$A" keep > /dev/null
assert_contains "作り直した見た目は残る" "$(cat "$A/src/app/login/page.tsx")" "作り直したログイン"
assert_contains "無くなった土台は戻る" "$(cat "$A/src/lib/viewer.ts" 2> /dev/null)" "getViewer"
assert_contains "課金の受け口も戻る" "$(cat "$A/src/app/api/stripe/webhook/route.ts" 2> /dev/null)" "constructEvent"

# 疑似 curl：呼ばれた物を calls.log に「メソッド アドレス 中身」で残し、アドレスで決めた答えと HTTP の番号を返す
cat > "$T/bin/curl" <<'PY'
#!/usr/bin/env python3
import os, sys
a = sys.argv[1:]; T = os.environ["FT"]
method = a[a.index("-X") + 1] if "-X" in a else "GET"
url = [x for x in a if x.startswith("http")][0]
data = []
for i, x in enumerate(a):
    if x in ("-d", "--data-urlencode", "--data-binary"): data.append(a[i + 1])
open(f"{T}/calls.log", "a").write(f"{method} {url} {' '.join(data)}\n")
fail = os.environ.get("FAIL_ON", "")
def reply(body, code=200):
    sys.stdout.write(body + "\n" + str(code)); sys.exit(0)
if fail and fail in url: reply('{"message":"forbidden"}', 403)
if url.endswith("/v1/organizations"): reply('[{"id":"org1","slug":"gaku-org"}]')
if url.endswith("/v1/projects") and method == "POST": reply('{"id":"abcref","ref":"abcref"}', 201)
if "/health" in url: reply('[{"name":"auth","status":"ACTIVE_HEALTHY"},{"name":"db","status":"ACTIVE_HEALTHY"},{"name":"rest","status":"ACTIVE_HEALTHY"}]')
if "/database/migrations" in url: reply('{}', 201)
if "/api-keys" in url and method == "GET": reply('[{"name":"anon","api_key":"anon-legacy"},{"type":"publishable","api_key":"sb_publishable_x"},{"type":"secret","api_key":"sb_secret_y"}]')
if "/config/auth" in url: reply('{}')
if "/config/database/pooler" in url: reply('[{"database_type":"PRIMARY","connection_string":"postgresql://postgres.abcref:[YOUR-PASSWORD]@aws-0-ap-northeast-1.pooler.supabase.com:6543/postgres"}]')
if url.endswith("/v1/products"): reply('{"id":"prod_1"}')
if url.endswith("/v1/prices"): reply('{"id":"price_1"}')
if url.endswith("/v1/billing_portal/configurations"): reply('{"id":"bpc_1"}')
if url.endswith("/v1/webhook_endpoints"): reply('{"id":"we_1","secret":"whsec_z"}')
if "/env" in url: reply('{"created":[]}', 201)
reply('{"message":"unknown"}', 404)
PY
cat > "$T/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $* value=$(cat)" >> "$FT/gh.log"
SH
chmod +x "$T/bin/curl" "$T/bin/gh"
prov() { # [環境変数...] -- 引数...
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  env PATH="$T/bin:$PATH" FT="$T" STATE_FILE="$T/state.json" NOTES_FILE="$T/notes.txt" PROJECT=paid-notes REPO_FULL=o/paid-notes \
    FACTORY_WAIT_SEC=0 SAAS_WAIT_TRIES=2 VERCEL_TOKEN=v "${envs[@]}" bash "$SCRIPTS_DIR/factory-saas-provision.sh" "$@"
}

echo "== 外の準備（init）：Supabase のプロジェクトを東京に作り、表を流し、鍵を Vercel に入れる。Stripe に月額の値段を作る"
rm -f "$T/calls.log" "$T/gh.log" "$T/notes.txt"
prov SUPABASE_ACCESS_TOKEN=sbp STRIPE_SECRET_KEY=sk_test_1 PRICE_YEN=680 -- init > "$T/out.txt"; code=$?
calls=$(cat "$T/calls.log")
assert_eq "全部できたら 0" "0" "$code"
assert_contains "組織を見て、東京に作る" "$calls" '"organization_slug":"gaku-org"'
assert_contains "東京" "$calls" '"code":"ap-northeast-1"'
assert_contains "最初の表を流す（流した印も）" "$calls" "app_meta.migrations"
assert_contains "表の中身" "$calls" "billing_customers"
assert_contains "確認メールを送らない" "$calls" '"mailer_autoconfirm":true'
assert_contains "月額の値段（円）" "$calls" "unit_amount=680"
assert_contains "毎月" "$calls" "recurring[interval]=month"
env_call=$(grep '/env' "$T/calls.log")
assert_contains "Vercel：Supabase のアドレス" "$env_call" "https://abcref.supabase.co"
assert_contains "Vercel：新しい形の鍵を使う（古い anon ではない）" "$env_call" "sb_publishable_x"
assert_not_contains "古い鍵は使わない" "$env_call" "anon-legacy"
assert_contains "Vercel：Stripe の値段" "$env_call" "price_1"
assert_contains "Vercel：会員ページの設定" "$env_call" "bpc_1"
assert_contains "表を足すための接続先をリポジトリに入れる（パスワードを入れ、セッションの形 5432）" "$(cat "$T/gh.log")" "pooler.supabase.com:5432/postgres"
assert_not_contains "パスワードの穴は残らない" "$(cat "$T/gh.log")" "[YOUR-PASSWORD]"
assert_contains "結果の行" "$(cat "$T/notes.txt")" "✅ Supabase のプロジェクトを作った：abcref（東京）"

echo "== 公開アドレスが決まったら（url）：Stripe の通知の受け口を登録し、署名の鍵を Vercel に入れ、ログインの戻り先を変える"
rm -f "$T/calls.log" "$T/notes.txt"
prov SUPABASE_ACCESS_TOKEN=sbp STRIPE_SECRET_KEY=sk_test_1 -- url https://paid-notes.vercel.app > /dev/null; code=$?
calls=$(cat "$T/calls.log")
assert_eq "全部できたら 0" "0" "$code"
assert_contains "通知の受け口" "$calls" "url=https://paid-notes.vercel.app/api/stripe/webhook"
assert_contains "契約の変化を受ける" "$calls" "enabled_events[]=customer.subscription.updated"
assert_contains "署名の鍵を Vercel に" "$(grep '/env' "$T/calls.log")" "whsec_z"
assert_contains "ログインの戻り先" "$calls" '"site_url":"https://paid-notes.vercel.app"'
prov -- url "https://x.vercel.app/a b" > /dev/null; code=$?
assert_eq "形の違うアドレスは使わない" "1" "$code"

echo "== 鍵が無い・本番の鍵・権限が足りない：その部分を飛ばして、理由を書く"
rm -f "$T/calls.log" "$T/notes.txt"
prov -- init > /dev/null; code=$?
assert_eq "できなかった所があれば 1" "1" "$code"
assert_contains "Supabase の鍵が無い" "$(cat "$T/notes.txt")" "SUPABASE_ACCESS_TOKEN が無い"
assert_contains "Stripe の鍵が無い" "$(cat "$T/notes.txt")" "STRIPE_SECRET_KEY が無い"
assert_not_contains "何も呼ばない" "$(cat "$T/calls.log" 2> /dev/null)" "http"
rm -f "$T/calls.log" "$T/notes.txt"
prov STRIPE_SECRET_KEY=sk_live_1 -- init > /dev/null
assert_contains "本番の鍵は使わない" "$(cat "$T/notes.txt")" "テストモードの鍵（sk_test_）ではない"
assert_not_contains "本番の Stripe は呼ばない" "$(cat "$T/calls.log" 2> /dev/null)" "/v1/products"
rm -f "$T/calls.log" "$T/notes.txt"
prov SUPABASE_ACCESS_TOKEN=sbp FAIL_ON=/v1/projects -- init > /dev/null
assert_contains "作れない理由（権限）" "$(cat "$T/notes.txt")" "Organization Projects の Read and write が要る"
assert_eq "権限の誤りは、書き方を変えて何度も試さない" "1" "$(grep -c 'POST .*/v1/projects ' "$T/calls.log")"

echo "== 表の変更の公開：まだ流していない物を、番号の順に1回ずつ流す。名前の形が違う物は流さない"
M="$T/mig"; mkdir -p "$M"
echo "create table a();" > "$M/0001_billing.sql"
echo "create table b();" > "$M/0003_notes.sql"
echo "create table c();" > "$M/0002_tags.sql"
echo "create table d();" > "$M/bad name.sql"
cat > "$T/bin/psql" <<'SH'
#!/usr/bin/env bash
# 流した印は applied.txt。select なら印を返し、それ以外は受け取った SQL を記録する
if printf '%s ' "$@" | grep -q "select name from app_meta.migrations"; then cat "$FT/applied.txt" 2> /dev/null; exit 0; fi
if printf '%s ' "$@" | grep -q -- "-c"; then exit 0; fi
sql=$(cat); echo "$sql" >> "$FT/psql.log"
n=$(printf '%s' "$sql" | sed -n "s/.*values ('\(.*\)').*/\1/p"); [ -n "$n" ] && echo "$n" >> "$FT/applied.txt"
SH
chmod +x "$T/bin/psql"
echo "0001_billing.sql" > "$T/applied.txt"; rm -f "$T/psql.log"
out=$(env PATH="$T/bin:$PATH" FT="$T" SUPABASE_DB_URL=postgresql://x MIGRATIONS_DIR="$M" bash "$SCRIPTS_DIR/deploy-supabase.sh" 2>&1)
assert_contains "2つ流す" "$out" "表の変更を 2 個流した"
assert_eq "番号の順" "0001_billing.sql 0002_tags.sql 0003_notes.sql" "$(tr '\n' ' ' < "$T/applied.txt" | sed 's/ $//')"
assert_not_contains "流した物は流し直さない" "$(cat "$T/psql.log")" "create table a()"
assert_contains "1つのまとまりで流す" "$(cat "$T/psql.log")" "begin;"
assert_contains "形の違う名前は知らせる" "$out" "bad name.sql は名前の形が違う"
out=$(env PATH="$T/bin:$PATH" FT="$T" SUPABASE_DB_URL=postgresql://x MIGRATIONS_DIR="$M" bash "$SCRIPTS_DIR/deploy-supabase.sh" 2>&1)
assert_contains "2回目は何も流さない" "$out" "表の変更を 0 個流した"
out=$(env PATH="$T/bin:$PATH" FT="$T" SUPABASE_DB_URL= MIGRATIONS_DIR="$M" bash "$SCRIPTS_DIR/deploy-supabase.sh" 2>&1); code=$?
assert_eq "接続先が無ければ失敗" "1" "$code"
assert_contains "理由" "$out" "SUPABASE_DB_URL が無い"

finish
