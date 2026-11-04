// 支払い方法の変更・解約：Stripe の会員ページ（Customer Portal）へ送る。フォームの POST で呼ぶ
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
  const customer = await customerFor(viewer.user, false);
  if (!customer) return NextResponse.redirect(`${origin}/account`, 303);
  const config = serverEnv().stripePortalConfig;
  const session = await stripe().billingPortal.sessions.create({
    customer,
    return_url: `${origin}/account`,
    ...(config ? { configuration: config } : {}),
  });
  return NextResponse.redirect(session.url, 303);
}
