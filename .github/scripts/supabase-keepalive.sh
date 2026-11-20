#!/usr/bin/env bash
# Supabase を起こしておく（supabase-keepalive.yml から1日1回）。
# Supabase の無料プランは、1週間データベースの操作が少ないと、プロジェクトを一時停止する。止まると、公開したアプリの会員・課金・保存が
# 動かなくなり、表の変更（deploy-supabase.sh）も流せない（11/21、tide-almanac が 11/12 頃から止まっていた）。
# つなぐだけでは操作に数えられないので、小さな表（app_meta.heartbeat。1行だけ）に今の時刻を書く。
# もう止まっていたら、理由を出して失敗にし、スマホに知らせる（notify.sh の deploy_failed）。起こすのは人間（ダッシュボードの Resume project）。
#
# 公開先（pipeline.json の deploy）に supabase が無いリポジトリでは、何もしない。
# 環境変数：SUPABASE_DB_URL（Secret）、PIPELINE_JSON（既定 pipeline.json）、PSQL（テスト用）、NTFY_TOPIC・NOTIFY_EVENTS（通知）、GITHUB_REPOSITORY
set -uo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=supabase-lib.sh
source "$dir/supabase-lib.sh"
PSQL="${PSQL:-psql}"
cfg="${PIPELINE_JSON:-pipeline.json}"

if [ ! -f "$cfg" ] || ! jq -e '(.deploy // []) | map(.kind) | index("supabase")' "$cfg" > /dev/null 2>&1; then
  echo "公開先に supabase が無いので、何もしません"
  exit 0
fi
if [ -z "${SUPABASE_DB_URL:-}" ]; then
  echo "::warning::Secret の SUPABASE_DB_URL が無いので、Supabase を起こしておけません（Supabase の Connect → Session pooler の接続先を入れてください）"
  exit 0
fi

sql="create schema if not exists app_meta;
create table if not exists app_meta.heartbeat (id int primary key, at timestamptz not null default now());
insert into app_meta.heartbeat (id, at) values (1, now()) on conflict (id) do update set at = excluded.at;"

# 標準エラーだけを受け取る（理由の判定に使う）
if err=$("$PSQL" "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -qAtX -c "$sql" 2>&1 > /dev/null); then
  echo "Supabase に書き込みました（一時停止を防ぐため）"
  exit 0
fi

printf '%s\n' "$err" >&2
reason="$(supabase_error_reason "$err")"
reason="${reason:-Supabase に書き込めませんでした（ログを見てください）}"
echo "::error::$reason"
"$dir/notify.sh" deploy_failed "Supabase が止まっています（${GITHUB_REPOSITORY:-}）" "$reason" 5 || true
exit 1
