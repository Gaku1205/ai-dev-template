// ログインしている人の、Stripe の顧客番号（無ければ作って覚える）。サーバーだけで使う
import { stripe } from "@/lib/stripe";
import { supabaseAdmin } from "@/lib/supabase/admin";

export async function customerFor(user: { id: string; email: string }, create: boolean): Promise<string | null> {
  const admin = supabaseAdmin();
  const { data } = await admin.from("billing_customers").select("stripe_customer_id").eq("user_id", user.id).limit(1);
  const found = (data?.[0] as { stripe_customer_id: string } | undefined)?.stripe_customer_id;
  if (found || !create) return found ?? null;
  const customer = await stripe().customers.create({ email: user.email, metadata: { user_id: user.id } });
  const { error } = await admin.from("billing_customers").insert({ user_id: user.id, stripe_customer_id: customer.id });
  if (error) {
    // 同時に2回押されたとき：先に入った方を使う
    const { data: again } = await admin.from("billing_customers").select("stripe_customer_id").eq("user_id", user.id).limit(1);
    return (again?.[0] as { stripe_customer_id: string } | undefined)?.stripe_customer_id ?? null;
  }
  return customer.id;
}
