// ブラウザ（クライアントコンポーネント）で使う Supabase。公開してよい鍵だけを使う
import { createBrowserClient } from "@supabase/ssr";
import { publicEnv } from "@/lib/env";

export function supabaseBrowser() {
  return createBrowserClient(publicEnv.supabaseUrl, publicEnv.supabaseKey);
}
