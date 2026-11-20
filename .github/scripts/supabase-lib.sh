#!/usr/bin/env bash
# Supabase のデータベースにつながらなかったときの理由を、人が読める文にする（deploy-supabase.sh・supabase-keepalive.sh が source する）。
# 返すのは決まった文だけ（psql のエラーの文そのものは返さない。公開の状態の説明・通知に、外から来た文を入れないため）。
# 当てはまらなければ空を返す（呼ぶ側が「ログを見てください」の文にする）。
#
# 11/21：tide-almanac の Supabase が 11/12 頃から一時停止していて、表の変更が4回とも
#   FATAL:  (ENOTFOUND) tenant/user postgres.<id> not found
# で落ちた。画面には「表の変更を流せませんでした（ログを見てください）」としか出ず、止まっていることに気づけなかった。

# 使い方：supabase_error_reason "psql のエラー出力"
supabase_error_reason() {
  local err="${1:-}"
  if grep -qiE 'tenant/user .* not found|project is paused' <<< "$err"; then
    echo "Supabase のプロジェクトが一時停止しています（ダッシュボードで Resume project を押してから、やり直してください。止まっていなければ、Secret の SUPABASE_DB_URL の接続先が違います）"
  elif grep -qiE 'password authentication failed' <<< "$err"; then
    echo "Supabase の接続先のパスワードが違います（Secret の SUPABASE_DB_URL を、Connect → Session pooler の物に入れ直してください）"
  elif grep -qiE 'could not translate host name|Name or service not known|timeout expired|Connection timed out|Connection refused' <<< "$err"; then
    echo "Supabase のデータベースにつながりませんでした（接続先が違うか、Supabase の不調です）"
  fi
}
