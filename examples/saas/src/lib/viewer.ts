// いま見ている人（ログインしているか・有料プランか）。サーバーで使う。
// 有料の機能は、画面に出す前にも、データを書く前にも、必ずこれで確かめる（ボタンを隠すだけでは守れない）
import { connection } from "next/server";
import { authEnabled } from "@/lib/env";
import { isPro, type SubscriptionRow } from "@/lib/billing";
import { supabaseServer } from "@/lib/supabase/server";

export type Viewer = {
  user: { id: string; email: string } | null;
  pro: boolean;
  subscription: SubscriptionRow | null;
};

export async function getViewer(): Promise<Viewer> {
  // 見る人ごとに違うので、ビルドのときに作り置きしない（設定が無いビルドでも同じ動きにする）
  await connection();
  if (!authEnabled()) return { user: null, pro: false, subscription: null };
  const supabase = await supabaseServer();
  const { data } = await supabase.auth.getUser();
  if (!data.user) return { user: null, pro: false, subscription: null };
  const { data: rows } = await supabase
    .from("subscriptions")
    .select("status, current_period_end, cancel_at_period_end")
    .eq("user_id", data.user.id)
    .order("updated_at", { ascending: false })
    .limit(1);
  const subscription = (rows?.[0] as SubscriptionRow | undefined) ?? null;
  return { user: { id: data.user.id, email: data.user.email ?? "" }, pro: isPro(subscription), subscription };
}
