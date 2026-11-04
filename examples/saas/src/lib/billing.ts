// 会員と課金の判定（入力から出力が決まる物だけ。テストは billing.test.ts）

/** subscriptions 表の1行（読む項目だけ） */
export type SubscriptionRow = {
  status: string;
  current_period_end: string | null;
  cancel_at_period_end?: boolean | null;
};

/** Stripe の契約の状態のうち、有料の機能を使ってよい物 */
export function isPaidStatus(status: string | null | undefined): boolean {
  return status === "active" || status === "trialing";
}

/**
 * 有料プランの会員か。支払いが遅れている（past_due）間も、いまの期間が終わるまでは使える
 * （カードの更新を待つ。期間が過ぎたら無料に戻る）
 */
export function isPro(sub: SubscriptionRow | null | undefined, now: Date = new Date()): boolean {
  if (!sub) return false;
  if (isPaidStatus(sub.status)) return true;
  if (sub.status === "past_due" && sub.current_period_end) return new Date(sub.current_period_end).getTime() > now.getTime();
  return false;
}

/** ログインのあとに戻る先。同じサイトの中のパスだけ許す（外のサイトへ飛ばされないように） */
export function safeNext(next: unknown, fallback = "/account"): string {
  if (typeof next !== "string" || !next.startsWith("/") || next.startsWith("//") || next.startsWith("/\\")) return fallback;
  return next;
}

/** Stripe の時刻（秒）を ISO の文字列に。無ければ null */
export function stripeTime(sec: number | null | undefined): string | null {
  return typeof sec === "number" && Number.isFinite(sec) ? new Date(sec * 1000).toISOString() : null;
}

/** 会員の状態を、画面に出す日本語にする */
export function planLabel(sub: SubscriptionRow | null | undefined, now: Date = new Date()): string {
  if (!isPro(sub, now)) return "無料プラン";
  const end = sub?.current_period_end ? new Date(sub.current_period_end) : null;
  const day = end ? `${end.getFullYear()}年${end.getMonth() + 1}月${end.getDate()}日` : "";
  if (sub?.status === "past_due") return `有料プラン（支払いが確認できていません。${day}まで使えます）`;
  if (sub?.cancel_at_period_end) return `有料プラン（${day}で終わります）`;
  return day ? `有料プラン（次の更新：${day}）` : "有料プラン";
}
