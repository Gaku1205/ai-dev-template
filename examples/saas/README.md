# 会員と月額課金のしくみ

このサービスは、会員登録・ログイン（Supabase）と、月額の有料プラン（Stripe）を持っています。工場が作るときに、Supabase のプロジェクト・Stripe の商品と値段・通知の受け口・Vercel の環境変数を用意しました。最初は **Stripe のテストモード**（お金は動かない）です。

## 決まり（AIが実装するとき）

- 有料の機能は、**サーバーで** `getViewer()`（`src/lib/viewer.ts`）の `pro` を確かめてから出す・書く。ボタンを隠すだけでは守れない
  - 画面：`const viewer = await getViewer(); if (!viewer.pro) { /* 無料の表示か、料金の案内 */ }`
  - 書き込み（Server Action・Route Handler）：最初に `getViewer()` を確かめ、`user` が無ければ断る。有料の物は `pro` も確かめる
- 会員のデータを置く表は、**新しい番号の SQL ファイル**で足す（`supabase/migrations/0002_〜.sql`、`0003_〜.sql` …）。main にマージされると、公開（`deploy` の `supabase`）が番号の順に1回ずつ流す。**流したファイルは書き換えない**（直すときは次の番号のファイルを足す）
  - 表には必ず `alter table … enable row level security;` と、`(select auth.uid()) = user_id` で自分の行だけ読める・書ける policy を付ける。`grant select, insert, update, delete on … to authenticated;` も書く（新しい表を自動で公開しない設定のため）
  - 読み書きは、ログインしている人の権限で動く `supabaseServer()`（RLS が効く）を使う。`supabaseAdmin()`（RLS を通らない）は、Stripe の通知のように「人がいない処理」だけ
- 次のファイルは**中身を変えない**（課金とログインの土台。変えると、お金やログインが壊れる）：
  `src/lib/env.ts`・`src/lib/billing.ts`・`src/lib/viewer.ts`・`src/lib/stripe.ts`・`src/lib/supabase/`・`src/proxy.ts`・`src/app/api/stripe/`・`src/app/auth/`・`src/app/login/actions.ts`・`supabase/migrations/0001_billing.sql`
  - 見た目（`src/app/login/page.tsx`・`LoginForm.tsx`・`src/app/account/page.tsx`・`src/components/member.module.css`）は、`docs/design.md` に合わせて作り直してよい。フォームの送り先（`/api/stripe/checkout`・`/api/stripe/portal`・`/auth/signout`）と、入力の `name`（`email`・`password`・`next`・`mode`）は変えない
- 秘密の鍵（`SUPABASE_SECRET_KEY`・`STRIPE_SECRET_KEY` など）は、クライアントコンポーネント（`"use client"`）から import しない
- 定期実行（`vercel.json` の `crons`）は、Vercel の無料プラン（Hobby）では**1日1回まで**（`*/15 * * * *` のように1日に何度も動く式にすると、公開そのものが断られる）。もっと細かく動かしたい物は、1日1回でまとめて済む作りにするか、Issue に「人間に頼むこと」として書く
- 環境変数が無いとき（手元・CI）は、ログインと課金が止まって画面だけ動く（`authEnabled()`・`billingEnabled()`）。テストやビルドは、鍵が無くても通るように書く

## 流れ

1. 会員登録・ログイン：`/login`（メールアドレスとパスワード。確認メールは送らない設定）
2. 有料プランにする：`/account` の「有料プランにする」→ `/api/stripe/checkout` → Stripe の支払い画面
3. 支払いが終わると、Stripe が `/api/stripe/webhook` に知らせる → `subscriptions` 表に書く → `getViewer().pro` が true になる
4. 支払い方法の変更・解約：`/account` の「支払い方法・解約」→ Stripe の会員ページ

テストモードでは、カード番号 `4242 4242 4242 4242`（期限は未来の日付、ほかは何でもよい）で支払える。

## 環境変数（Vercel。工場が入れた）

| 名前 | 中身 |
| --- | --- |
| `NEXT_PUBLIC_SUPABASE_URL` | Supabase のプロジェクトのアドレス |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | 公開してよい鍵 |
| `SUPABASE_SECRET_KEY` | サーバーだけで使う鍵（RLS を通らない） |
| `STRIPE_SECRET_KEY` | Stripe の鍵（テストモードは `sk_test_`） |
| `STRIPE_PRICE_ID` | 月額の値段 |
| `STRIPE_WEBHOOK_SECRET` | 通知の署名を確かめる鍵 |
| `STRIPE_PORTAL_CONFIG` | Stripe の会員ページの設定 |

本物の課金に切り替えるのは人間の作業です（Stripe の本人確認・口座、特定商取引法に基づく表記・利用規約・プライバシーポリシーのページ、本番の鍵への差し替え）。
