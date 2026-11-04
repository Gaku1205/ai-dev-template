import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { billingEnabled } from "@/lib/env";
import { planLabel } from "@/lib/billing";
import { getViewer } from "@/lib/viewer";
import s from "@/components/member.module.css";

export const metadata: Metadata = { title: "アカウント" };

export default async function AccountPage({ searchParams }: { searchParams: Promise<{ ok?: string }> }) {
  const viewer = await getViewer();
  if (!viewer.user) redirect("/login?next=/account");
  const { ok } = await searchParams;
  const canPay = billingEnabled();
  return (
    <main className={s.page}>
      <h1 className={s.title}>アカウント</h1>
      {ok === "1" && !viewer.pro ? <p className={s.note}>支払いを受け付けました。反映まで数秒かかります。少し待ってから開き直してください。</p> : null}
      <dl className={s.list}>
        <dt>メールアドレス</dt>
        <dd>{viewer.user.email}</dd>
        <dt>プラン</dt>
        <dd>{planLabel(viewer.subscription)}</dd>
      </dl>
      {!canPay ? (
        <p className={s.note}>いまは課金の設定がまだです（Vercel の環境変数）。</p>
      ) : viewer.pro ? (
        <form action="/api/stripe/portal" method="post">
          <button type="submit" className={s.secondary}>
            支払い方法・解約
          </button>
        </form>
      ) : (
        <form action="/api/stripe/checkout" method="post">
          <button type="submit" className={s.primary}>
            有料プランにする
          </button>
        </form>
      )}
      <form action="/auth/signout" method="post">
        <button type="submit" className={s.link}>
          ログアウト
        </button>
      </form>
    </main>
  );
}
