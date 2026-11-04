import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { safeNext } from "@/lib/billing";
import { getViewer } from "@/lib/viewer";
import { LoginForm } from "./LoginForm";
import s from "@/components/member.module.css";

export const metadata: Metadata = { title: "ログイン" };

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ next?: string }> }) {
  const { next } = await searchParams;
  const to = safeNext(next);
  const viewer = await getViewer();
  if (viewer.user) redirect(to);
  return (
    <main className={s.page}>
      <h1 className={s.title}>ログイン</h1>
      <p className={s.lead}>はじめての人は、メールアドレスとパスワードを入れて「新しく登録する」。</p>
      <LoginForm next={to} />
    </main>
  );
}
