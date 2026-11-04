// サーバー（Server Component・Server Action・Route Handler）で使う Supabase。ログインしている人の権限で動く（RLS が効く）
import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import { publicEnv } from "@/lib/env";

export async function supabaseServer() {
  const cookieStore = await cookies();
  return createServerClient(publicEnv.supabaseUrl, publicEnv.supabaseKey, {
    cookies: {
      getAll() {
        return cookieStore.getAll();
      },
      setAll(list) {
        try {
          for (const { name, value, options } of list) cookieStore.set(name, value, options);
        } catch {
          // Server Component からは cookie を書けない。ログインの更新は src/proxy.ts が行う
        }
      },
    },
  });
}
