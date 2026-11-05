#!/usr/bin/env bash
# 公開（supabase）：supabase/migrations/*.sql のうち、まだ流していない物を、番号の順に1ファイルずつ1回だけ流す（deploy.yml から呼ぶ）。
#   - ファイルの名前は「0002_名前.sql」（4桁の番号・_・小文字の英数字と _）。形が違う物は流さない
#   - 流した印は Supabase のデータベースの app_meta.migrations（工場が最初の表と一緒に作る。無ければここで作る）
#   - 1ファイルを1つのまとまり（トランザクション）で流す。失敗したらそのファイルは無かったことになり、後ろのファイルも流さない
#   - 流したファイルは書き換えない決まり（書き換えても流し直さない。直すときは次の番号のファイルを足す）
# 環境変数：SUPABASE_DB_URL（Secret。工場が入れる。そのプロジェクトのデータベースにだけ入れる接続先）、MIGRATIONS_DIR（既定 supabase/migrations）、PSQL（テスト用）
# 出力：GITHUB_OUTPUT に applied=流した数
set -euo pipefail
PSQL="${PSQL:-psql}"
dir="${MIGRATIONS_DIR:-supabase/migrations}"
if [ -z "${SUPABASE_DB_URL:-}" ]; then
  echo "::error::Secret の SUPABASE_DB_URL が無い（工場が会員と課金のサービスを作るときに入れる。手で入れるなら Supabase の Connect → Session pooler の接続先）"
  exit 1
fi
shopt -s nullglob
files=("$dir"/*.sql)
if [ "${#files[@]}" -eq 0 ]; then
  echo "流す表の変更はありません"
  echo "applied=0" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi
q() { "$PSQL" "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -qAtX "$@"; }
q -c "create schema if not exists app_meta; create table if not exists app_meta.migrations (name text primary key, applied_at timestamptz not null default now());"
done_list=$(q -c "select name from app_meta.migrations")
applied=0
while IFS= read -r f; do
  n=$(basename "$f")
  if ! [[ "$n" =~ ^[0-9]{4}_[a-z0-9_]+\.sql$ ]]; then
    echo "::warning::$n は名前の形が違うので流さない（例：0002_notes.sql）"
    continue
  fi
  if printf '%s\n' "$done_list" | grep -qxF "$n"; then continue; fi
  echo "流す：$n"
  { echo "begin;"; cat "$f"; echo; echo "insert into app_meta.migrations (name) values ('$n');"; echo "commit;"; } | q
  applied=$((applied + 1))
done < <(printf '%s\n' "${files[@]}" | sort)
echo "表の変更を ${applied} 個流した"
echo "applied=$applied" >> "${GITHUB_OUTPUT:-/dev/null}"
