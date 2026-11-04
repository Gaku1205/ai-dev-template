// サーバーだけで使う Stripe。クライアントコンポーネントから import しない
import Stripe from "stripe";
import { serverEnv } from "@/lib/env";

export function stripe(): Stripe {
  return new Stripe(serverEnv().stripeSecretKey);
}
