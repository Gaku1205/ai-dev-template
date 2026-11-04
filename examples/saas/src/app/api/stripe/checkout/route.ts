// 有料プランの申し込み：Stripe の支払い画面（Checkout）へ送る。フォームの POST で呼ぶ
import { NextResponse } from "next/server";
import { billingEnabled, serverEnv } from "@/lib/env";
import { stripe } from "@/lib/stripe";
import { getViewer } from "@/lib/viewer";
import { customerFor } from "../customer";

export async function POST(request: Request) {
  const origin = new URL(request.url).origin;
  const viewer = await getViewer();
  if (!viewer.user) return NextResponse.redirect(`${origin}/login?next=/account`, 303);
  if (!billingEnabled()) return NextResponse.redirect(`${origin}/account`, 303);
  if (viewer.pro) return NextResponse.redirect(`${origin}/account`, 303);
  const customer = await customerFor(viewer.user, true);
  if (!customer) return NextResponse.redirect(`${origin}/account`, 303);
  const session = await stripe().checkout.sessions.create({
    mode: "subscription",
    customer,
    client_reference_id: viewer.user.id,
    line_items: [{ price: serverEnv().stripePriceId, quantity: 1 }],
    subscription_data: { metadata: { user_id: viewer.user.id } },
    allow_promotion_codes: true,
    success_url: `${origin}/account?ok=1`,
    cancel_url: `${origin}/account`,
  });
  return NextResponse.redirect(session.url ?? `${origin}/account`, 303);
}
