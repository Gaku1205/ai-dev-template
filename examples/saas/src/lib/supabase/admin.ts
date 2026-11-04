// サーバーだけで使う、管理者の権限の Supabase（RLS を通らない）。Stripe の通知を書き込むときだけ使う。
// クライアントコンポーネントから import しない（秘密の鍵が漏れる）
import { createClient } from "@supabase/supabase-js";
import { publicEnv, serverEnv } from "@/lib/env";

export function supabaseAdmin() {
  return createClient(publicEnv.supabaseUrl, serverEnv().supabaseSecretKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
