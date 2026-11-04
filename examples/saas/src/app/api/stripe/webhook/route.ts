// Stripe からの通知（契約が始まった・変わった・終わった）を受けて、subscriptions 表に書く。
// 署名を確かめてから書く（偽の通知で有料にされないように）。工場が Stripe にこのアドレスを登録する
import type Stripe from "stripe";
import { serverEnv } from "@/lib/env";
import { stripeTime } from "@/lib/billing";
import { stripe } from "@/lib/stripe";
import { supabaseAdmin } from "@/lib/supabase/admin";

async function userIdFor(sub: Stripe.Subscription, hint: string | null): Promise<string | null> {
  if (hint) return hint;
  if (sub.metadata?.user_id) return sub.metadata.user_id;
  const customer = typeof sub.customer === "string" ? sub.customer : sub.customer.id;
  const { data } = await supabaseAdmin().from("billing_customers").select("user_id").eq("stripe_customer_id", customer).limit(1);
  return (data?.[0] as { user_id: string } | undefined)?.user_id ?? null;
}

async function save(sub: Stripe.Subscription, hint: string | null = null) {
  const userId = await userIdFor(sub, hint);
  if (!userId) return;
  const item = sub.items.data[0];
  await supabaseAdmin()
    .from("subscriptions")
    .upsert({
      id: sub.id,
      user_id: userId,
      status: sub.status,
      price_id: item?.price.id ?? null,
      current_period_end: stripeTime(item?.current_period_end),
      cancel_at_period_end: sub.cancel_at_period_end,
      updated_at: new Date().toISOString(),
    });
}

export async function POST(request: Request) {
  const secret = serverEnv().stripeWebhookSecret;
  if (!secret) return new Response("webhook secret がありません", { status: 503 });
  const body = await request.text();
  let event: Stripe.Event;
  try {
    event = stripe().webhooks.constructEvent(body, request.headers.get("stripe-signature") ?? "", secret);
  } catch {
    return new Response("署名が正しくありません", { status: 400 });
  }
  switch (event.type) {
    case "checkout.session.completed": {
      const session = event.data.object;
      if (session.mode === "subscription" && session.subscription) {
        const id = typeof session.subscription === "string" ? session.subscription : session.subscription.id;
        await save(await stripe().subscriptions.retrieve(id), session.client_reference_id);
      }
      break;
    }
    case "customer.subscription.created":
    case "customer.subscription.updated":
    case "customer.subscription.deleted":
      await save(event.data.object);
      break;
    default:
      break;
  }
  return Response.json({ received: true });
}
