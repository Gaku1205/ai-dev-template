#!/usr/bin/env bash
# 工場：会員と月額課金のサービス（saas）の、外の準備をする。factory.sh の build ジョブから呼ぶ。
#   factory-saas-provision.sh init
#     1. Supabase：新しいプロジェクトを作り、立ち上がるのを待ち、最初の表（examples/saas/supabase/migrations/0001_billing.sql）を流し、
#        鍵（公開してよい鍵・サーバーの鍵）を取り、確認メールを送らない設定にする。あとで表を足すための接続先を、
#        新しいリポジトリの Secret（SUPABASE_DB_URL）に入れる
#     2. Stripe（テストモードだけ）：商品・月額の値段・会員ページの設定を作る
#     3. Vercel：プロジェクトの環境変数に、上の鍵と値を入れる（最初の公開より前に入れる）
#   factory-saas-provision.sh url <公開アドレス>
#     4. Stripe：通知の受け口（<アドレス>/api/stripe/webhook）を登録し、署名の鍵を Vercel に入れる
#     5. Supabase：ログインの戻り先を、公開アドレスにする
#     （このあと呼び出し側が、環境変数を効かせるために公開をやり直す）
# 環境変数：SUPABASE_ACCESS_TOKEN・STRIPE_SECRET_KEY（どちらも Environment「factory」の Secret。無ければその部分を飛ばす）、
#           VERCEL_TOKEN・VERCEL_TEAM_ID（任意）、PROJECT（Vercel のプロジェクト名＝リポジトリ名）、REPO_FULL（owner/repo）、GH_TOKEN、
#           PRICE_YEN（月額。既定 500）、STATE_FILE（init と url の間で、プロジェクトの番号などを渡すファイル）、
#           NOTES_FILE（結果の行を足すファイル。呼び出し側が報告に使う）、SAAS_WAIT_TRIES（既定 60）・FACTORY_WAIT_SEC（既定 5）、テスト用：SUPABASE_API・STRIPE_API・VERCEL_API
# 出力：1行ずつ「✅ 〜」「⚠️ 〜」。全部できたら 0、どこかで止まったら 1（できた所までは残る。サービスは鍵が無くても画面は動く）
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUPABASE_API="${SUPABASE_API:-https://api.supabase.com}"
STRIPE_API="${STRIPE_API:-https://api.stripe.com}"
VERCEL_API="${VERCEL_API:-https://api.vercel.com}"
WAIT="${FACTORY_WAIT_SEC:-5}"
STATE_FILE="${STATE_FILE:?STATE_FILE を指定}"
PRICE_YEN="${PRICE_YEN:-500}"
ok=0
NOTES_FILE="${NOTES_FILE:-/dev/null}"
say() { echo "$1"; echo "$1" >> "$NOTES_FILE"; }
bad() { echo "⚠️ $1"; echo "⚠️ $1" >> "$NOTES_FILE"; ok=1; }
# 鍵をログに出さない（GitHub Actions の伏せ字。標準出力に書く）
mask() { [ -n "${GITHUB_ACTIONS:-}" ] && [ -n "$1" ] && echo "::add-mask::$1"; return 0; }
state_get() { jq -r --arg k "$1" '.[$k] // empty' "$STATE_FILE" 2> /dev/null; }
state_set() { local t; t=$(mktemp); { [ -s "$STATE_FILE" ] && cat "$STATE_FILE" || echo '{}'; } | jq --arg k "$1" --arg v "$2" '.[$k] = $v' > "$t" && mv "$t" "$STATE_FILE"; }

# HTTP を呼ぶ。BODY と CODE に結果を入れ、2xx なら 0
call() {
  local out
  if ! out=$(curl -sS -w '\n%{http_code}' "$@" 2>&1); then BODY="$out"; CODE=000; return 1; fi
  CODE="${out##*$'\n'}"; BODY="${out%$'\n'*}"
  [[ "$CODE" =~ ^2 ]]
}
why() { printf '%s' "$BODY" | jq -r '.message // .error.message // .error // empty' 2> /dev/null | head -c 200; }
sb() { local m="$1" p="$2"; shift 2; call -X "$m" "$SUPABASE_API$p" -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H "Content-Type: application/json" "$@"; }
st() { local p="$1"; shift; call -X POST "$STRIPE_API$p" -u "$STRIPE_SECRET_KEY:" -H "Idempotency-Key: factory-${PROJECT}-${p//\//-}-${IDEM:-1}" "$@"; }
teamq() { [ -n "${VERCEL_TEAM_ID:-}" ] && printf '%s' "$1teamId=$VERCEL_TEAM_ID"; }

# Vercel の環境変数を入れる（あれば上書き）。引数：名前 値 …
vercel_env() {
  [ -n "${VERCEL_TOKEN:-}" ] || { bad "VERCEL_TOKEN が無いので、Vercel に鍵を入れられませんでした（Vercel の画面の Settings → Environment Variables で入れる）"; return 1; }
  local json='[]'
  while [ $# -ge 2 ]; do
    [ -n "$2" ] && json=$(jq -c --arg k "$1" --arg v "$2" '. + [{key: $k, value: $v, type: "encrypted", target: ["production", "preview"]}]' <<< "$json")
    shift 2
  done
  [ "$json" = '[]' ] && return 0
  if call -X POST "$VERCEL_API/v10/projects/${PROJECT:?}/env?upsert=true$(teamq '&')" -H "Authorization: Bearer $VERCEL_TOKEN" -H "Content-Type: application/json" --data-binary "$json"; then
    say "✅ Vercel に環境変数を入れた：$(jq -r '[.[].key] | join("・")' <<< "$json")"
  else
    bad "Vercel に環境変数を入れられませんでした（$(why)）"; return 1
  fi
}

init_supabase() {
  [ -n "${SUPABASE_ACCESS_TOKEN:-}" ] || { bad "SUPABASE_ACCESS_TOKEN が無いので、会員の準備（Supabase）を飛ばした（Environment「factory」に入れる）"; return 1; }
  sb GET /v1/organizations || { bad "Supabase の組織を読めませんでした（$(why)。トークンの Organizations の Read が要る）"; return 1; }
  local org; org=$(printf '%s' "$BODY" | jq -r '.[0].slug // .[0].id // empty')
  [ -n "$org" ] || { bad "Supabase の組織がありません（supabase.com で組織を1つ作る）"; return 1; }
  local pass; pass=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32); mask "$pass"
  local ref="" body
  # 東京に置く。書き方が変わっていても作れるように、新しい書き方から順に試す
  for body in \
    "$(jq -nc --arg n "$PROJECT" --arg o "$org" --arg p "$pass" '{name: $n, organization_slug: $o, db_pass: $p, region_selection: {type: "specific", code: "ap-northeast-1"}}')" \
    "$(jq -nc --arg n "$PROJECT" --arg o "$org" --arg p "$pass" '{name: $n, organization_slug: $o, db_pass: $p, region_selection: {type: "smartGroup", code: "apac"}}')" \
    "$(jq -nc --arg n "$PROJECT" --arg o "$org" --arg p "$pass" '{name: $n, organization_id: $o, db_pass: $p, region: "ap-northeast-1"}')"; do
    if sb POST /v1/projects --data-binary "$body"; then ref=$(printf '%s' "$BODY" | jq -r '.ref // .id // empty'); [ -n "$ref" ] && break; fi
    # 権限・上限の誤りは、書き方を変えても同じなので止める
    case "$CODE" in 401 | 402 | 403) break ;; esac
  done
  if [ -z "$ref" ]; then
    local msg; msg=$(why)
    case "$msg" in *limit* | *maximum* | *free*) bad "Supabase の無料プランの上限（動いているプロジェクト2つまで）で、プロジェクトを作れませんでした。使わないプロジェクトを一時停止してから作り直す（$msg）" ;;
      *) bad "Supabase のプロジェクトを作れませんでした（$CODE $msg。トークンの Organization Projects の Read and write が要る）" ;; esac
    return 1
  fi
  state_set ref "$ref"
  say "✅ Supabase のプロジェクトを作った：$ref（東京）"
  # 立ち上がるのを待つ（数分）
  local up=no
  for _ in $(seq 1 "${SAAS_WAIT_TRIES:-60}"); do
    if sb GET "/v1/projects/$ref/health?services=auth&services=db&services=rest" && [ "$(printf '%s' "$BODY" | jq -r 'if type == "array" and length > 0 then (map(.status == "ACTIVE_HEALTHY") | all) else false end')" = true ]; then up=yes; break; fi
    sleep "$WAIT"
  done
  [ "$up" = yes ] || { bad "Supabase のプロジェクトが立ち上がりきりませんでした（数分後に、工場の Issue を見ながら手で続きをやる）"; return 1; }
  # 最初の表。流した印を app_meta.migrations に残す（あとの表の追加は、公開の supabase が番号の順に流す）
  local sql; sql="create schema if not exists app_meta;
create table if not exists app_meta.migrations (name text primary key, applied_at timestamptz not null default now());
$(cat "$HERE/../../examples/saas/supabase/migrations/0001_billing.sql")
insert into app_meta.migrations (name) values ('0001_billing.sql') on conflict do nothing;"
  if sb POST "/v1/projects/$ref/database/migrations" --data-binary "$(jq -nc --arg q "$sql" '{name: "0001_billing", query: $q}')" ||
    sb POST "/v1/projects/$ref/database/query" --data-binary "$(jq -nc --arg q "$sql" '{query: $q}')"; then
    say "✅ 会員と課金の表を作った（billing_customers・subscriptions。自分の行だけ読める）"
  else
    bad "会員と課金の表を作れませんでした（$(why)。トークンの Database と Migrations の Read and write が要る）"
  fi
  # 鍵：新しい形（publishable・secret）を使う。無ければ作る。どうしても無ければ古い形（anon・service_role）
  local pub="" sec=""
  if sb GET "/v1/projects/$ref/api-keys?reveal=true"; then
    pub=$(printf '%s' "$BODY" | jq -r '[.[] | select(.type == "publishable")][0].api_key // empty')
    sec=$(printf '%s' "$BODY" | jq -r '[.[] | select(.type == "secret")][0].api_key // empty')
    local legacy_pub legacy_sec
    legacy_pub=$(printf '%s' "$BODY" | jq -r '[.[] | select(.name == "anon")][0].api_key // empty')
    legacy_sec=$(printf '%s' "$BODY" | jq -r '[.[] | select(.name == "service_role")][0].api_key // empty')
    if [ -z "$pub" ] && sb POST "/v1/projects/$ref/api-keys?reveal=true" --data-binary '{"type":"publishable","name":"default"}'; then pub=$(printf '%s' "$BODY" | jq -r '.api_key // empty'); fi
    if [ -z "$sec" ] && sb POST "/v1/projects/$ref/api-keys?reveal=true" --data-binary '{"type":"secret","name":"default","secret_jwt_template":{"role":"service_role"}}'; then sec=$(printf '%s' "$BODY" | jq -r '.api_key // empty'); fi
    [ -n "$pub" ] || pub="$legacy_pub"; [ -n "$sec" ] || sec="$legacy_sec"
  fi
  mask "$pub"; mask "$sec"
  if [ -z "$pub" ] || [ -z "$sec" ]; then bad "Supabase の鍵を取れませんでした（$(why)。トークンの API Keys の Read and write と API Key Secrets の Read が要る）"; return 1; fi
  # 確認メールは送らない（無料のメール送信は1時間に数通まで。登録してすぐ使えるように）
  if sb PATCH "/v1/projects/$ref/config/auth" --data-binary '{"mailer_autoconfirm":true}'; then
    say "✅ ログインの設定：確認メールを送らずに登録できるようにした"
  else
    bad "ログインの設定を変えられませんでした（$(why)。トークンの Auth Config の Read and write が要る）"
  fi
  # あとで表を足すための接続先（プロジェクトだけに効く。IPv4 で届く接続の取りまとめ役（pooler）の、セッションの形）
  if sb GET "/v1/projects/$ref/config/database/pooler"; then
    local cs; cs=$(printf '%s' "$BODY" | jq -r '(if type == "array" then ([.[] | select((.database_type // "PRIMARY") == "PRIMARY")][0]) else . end) | .connection_string // empty')
    if [ -n "$cs" ]; then
      cs="${cs//\[YOUR-PASSWORD\]/$pass}"; cs="${cs/:6543\//:5432/}"; mask "$cs"
      if printf '%s' "$cs" | gh secret set SUPABASE_DB_URL --repo "${REPO_FULL:?}" > /dev/null 2>&1; then say "✅ 表を足すための接続先を、リポジトリの Secret（SUPABASE_DB_URL）に入れた"
      else bad "SUPABASE_DB_URL をリポジトリに入れられませんでした（FACTORY_TOKEN に Secrets の Read and write が要る）"; fi
    else bad "Supabase の接続先が読めませんでした（あとで表を足す公開が動かない）"; fi
  else
    bad "Supabase の接続先を読めませんでした（$(why)。トークンの Connection Pooling の Read が要る）"
  fi
  SUPA_URL="https://$ref.supabase.co"; SUPA_PUB="$pub"; SUPA_SEC="$sec"
  return 0
}

init_stripe() {
  [ -n "${STRIPE_SECRET_KEY:-}" ] || { bad "STRIPE_SECRET_KEY が無いので、課金の準備（Stripe）を飛ばした（Environment「factory」に入れる）"; return 1; }
  case "$STRIPE_SECRET_KEY" in sk_test_* | rk_test_*) ;; *) bad "STRIPE_SECRET_KEY がテストモードの鍵（sk_test_）ではないので使わなかった。工場はテストモードだけで作る"; return 1 ;; esac
  [[ "$PRICE_YEN" =~ ^[0-9]+$ ]] && [ "$PRICE_YEN" -ge 100 ] && [ "$PRICE_YEN" -le 10000 ] || PRICE_YEN=500
  st /v1/products --data-urlencode "name=${APP_TITLE:-$PROJECT}" -d "metadata[repo]=${REPO_FULL:-}" || { bad "Stripe に商品を作れませんでした（$(why)）"; return 1; }
  local product; product=$(printf '%s' "$BODY" | jq -r '.id')
  st /v1/prices -d "product=$product" -d "unit_amount=$PRICE_YEN" -d currency=jpy -d "recurring[interval]=month" --data-urlencode "lookup_key=${PROJECT}-monthly" -d "nickname=月額" ||
    { bad "Stripe に値段を作れませんでした（$(why)）"; return 1; }
  STRIPE_PRICE=$(printf '%s' "$BODY" | jq -r '.id')
  if st /v1/billing_portal/configurations -d "features[payment_method_update][enabled]=true" -d "features[invoice_history][enabled]=true" \
    -d "features[subscription_cancel][enabled]=true" -d "features[subscription_cancel][mode]=at_period_end" -d "metadata[repo]=${REPO_FULL:-}"; then
    STRIPE_PORTAL=$(printf '%s' "$BODY" | jq -r '.id')
  else
    bad "Stripe の会員ページの設定を作れませんでした（$(why)。会員ページは Stripe の既定の設定で開く）"; STRIPE_PORTAL=""
  fi
  say "✅ Stripe（テストモード）に商品と値段を作った：月額 ${PRICE_YEN} 円"
  return 0
}

case "${1:-}" in
  init)
    : > "$STATE_FILE"
    SUPA_URL="" SUPA_PUB="" SUPA_SEC="" STRIPE_PRICE="" STRIPE_PORTAL=""
    init_supabase
    init_stripe
    stripe_key=""; [ -n "$STRIPE_PRICE" ] && stripe_key="$STRIPE_SECRET_KEY"
    vercel_env NEXT_PUBLIC_SUPABASE_URL "$SUPA_URL" NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY "$SUPA_PUB" SUPABASE_SECRET_KEY "$SUPA_SEC" \
      STRIPE_SECRET_KEY "$stripe_key" STRIPE_PRICE_ID "$STRIPE_PRICE" STRIPE_PORTAL_CONFIG "$STRIPE_PORTAL"
    [ -n "$STRIPE_PRICE" ] && state_set stripe yes
    exit "$ok"
    ;;
  url)
    site="${2:?公開アドレスを指定}"
    [[ "$site" =~ ^https://[A-Za-z0-9.-]+$ ]] || { bad "公開アドレスの形が違います：$site"; exit 1; }
    if [ "$(state_get stripe)" = yes ]; then
      if IDEM=webhook st /v1/webhook_endpoints --data-urlencode "url=$site/api/stripe/webhook" -d "description=${PROJECT} の会員の状態" -d "metadata[repo]=${REPO_FULL:-}" \
        -d "enabled_events[]=checkout.session.completed" -d "enabled_events[]=customer.subscription.created" \
        -d "enabled_events[]=customer.subscription.updated" -d "enabled_events[]=customer.subscription.deleted"; then
        whsec=$(printf '%s' "$BODY" | jq -r '.secret // empty'); mask "$whsec"
        say "✅ Stripe の通知の受け口を登録した：$site/api/stripe/webhook"
        vercel_env STRIPE_WEBHOOK_SECRET "$whsec"
      else
        bad "Stripe の通知の受け口を登録できませんでした（$(why)。支払っても有料にならない。Stripe の画面の Webhooks で $site/api/stripe/webhook を登録する）"
      fi
    fi
    ref=$(state_get ref)
    if [ -n "$ref" ] && [ -n "${SUPABASE_ACCESS_TOKEN:-}" ]; then
      if sb PATCH "/v1/projects/$ref/config/auth" --data-binary "$(jq -nc --arg u "$site" '{site_url: $u, uri_allow_list: ($u + "/**")}')"; then
        say "✅ ログインの戻り先を $site にした"
      else
        bad "ログインの戻り先を変えられませんでした（$(why)）"
      fi
    fi
    exit "$ok"
    ;;
  *) echo "使い方：factory-saas-provision.sh init | url <公開アドレス>"; exit 2 ;;
esac
