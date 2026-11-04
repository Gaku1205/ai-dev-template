// 会員と課金の設定（Vercel の環境変数。工場が作るときに入れる）。値が無いときは、会員・課金の機能を止めて画面だけ動かす
// （手元や CI のビルドでも壊れないように）。NEXT_PUBLIC_ の物は、ビルドのときに埋め込まれるので、名前をそのまま書く。

export const publicEnv = {
  supabaseUrl: process.env.NEXT_PUBLIC_SUPABASE_URL ?? "",
  supabaseKey: process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? "",
};

/** ログインが使えるか（Supabase の設定がある） */
export function authEnabled(): boolean {
  return publicEnv.supabaseUrl !== "" && publicEnv.supabaseKey !== "";
}

/** サーバーだけで読む秘密の設定。クライアントコンポーネントから呼ばない */
export function serverEnv() {
  return {
    supabaseSecretKey: process.env.SUPABASE_SECRET_KEY ?? "",
    stripeSecretKey: process.env.STRIPE_SECRET_KEY ?? "",
    stripePriceId: process.env.STRIPE_PRICE_ID ?? "",
    stripeWebhookSecret: process.env.STRIPE_WEBHOOK_SECRET ?? "",
    stripePortalConfig: process.env.STRIPE_PORTAL_CONFIG ?? "",
  };
}

/** 課金が使えるか（Supabase と Stripe の設定がそろっている） */
export function billingEnabled(): boolean {
  const s = serverEnv();
  return authEnabled() && s.supabaseSecretKey !== "" && s.stripeSecretKey !== "" && s.stripePriceId !== "";
}
