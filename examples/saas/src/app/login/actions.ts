"use server";
// ログイン・会員登録（メールアドレスとパスワード）。確認メールは送らない設定（工場が Supabase に入れる）
import { redirect } from "next/navigation";
import { authEnabled } from "@/lib/env";
import { safeNext } from "@/lib/billing";
import { supabaseServer } from "@/lib/supabase/server";

export type AuthState = { error: string };

function read(form: FormData) {
  const email = String(form.get("email") ?? "").trim();
  const password = String(form.get("password") ?? "");
  const next = safeNext(form.get("next"));
  return { email, password, next };
}

function check(email: string, password: string): string {
  if (!authEnabled()) return "いまはログインできません（会員の設定がまだです）";
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return "メールアドレスの形を確かめてください";
  if (password.length < 8) return "パスワードは8文字以上にしてください";
  return "";
}

export async function signIn(_prev: AuthState, form: FormData): Promise<AuthState> {
  const { email, password, next } = read(form);
  const bad = check(email, password);
  if (bad) return { error: bad };
  const supabase = await supabaseServer();
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) return { error: "メールアドレスかパスワードが違います" };
  redirect(next);
}

export async function signUp(_prev: AuthState, form: FormData): Promise<AuthState> {
  const { email, password, next } = read(form);
  const bad = check(email, password);
  if (bad) return { error: bad };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.auth.signUp({ email, password });
  if (error) return { error: error.message.includes("already") ? "このメールアドレスはもう登録されています。ログインしてください" : "登録できませんでした。少し待ってからもう一度" };
  if (!data.session) return { error: "登録しました。ログインしてください" };
  redirect(next);
}
