"use client";
import { useActionState } from "react";
import { signIn, signUp, type AuthState } from "./actions";
import s from "@/components/member.module.css";

export function LoginForm({ next }: { next: string }) {
  const [state, action, pending] = useActionState(
    (prev: AuthState, form: FormData) => (form.get("mode") === "signup" ? signUp(prev, form) : signIn(prev, form)),
    { error: "" },
  );
  return (
    <form action={action} className={s.form}>
      <input type="hidden" name="next" value={next} />
      <label className={s.field}>
        <span>メールアドレス</span>
        <input name="email" type="email" autoComplete="email" required />
      </label>
      <label className={s.field}>
        <span>パスワード（8文字以上）</span>
        <input name="password" type="password" autoComplete="current-password" minLength={8} required />
      </label>
      {state.error ? (
        <p className={s.error} role="alert">
          {state.error}
        </p>
      ) : null}
      <div className={s.row}>
        <button type="submit" name="mode" value="signin" className={s.primary} disabled={pending}>
          ログイン
        </button>
        <button type="submit" name="mode" value="signup" className={s.secondary} disabled={pending}>
          新しく登録する
        </button>
      </div>
    </form>
  );
}
