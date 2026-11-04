-- 会員と課金の土台（工場が最初に1回だけ流す）。
-- 書き込みは、サーバー側の秘密の鍵（Stripe の通知を受けた時）だけが行う。会員は自分の行を読むだけ。

create table if not exists public.billing_customers (
  user_id uuid primary key references auth.users (id) on delete cascade,
  stripe_customer_id text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists public.subscriptions (
  id text primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  status text not null,
  price_id text,
  current_period_end timestamptz,
  cancel_at_period_end boolean not null default false,
  updated_at timestamptz not null default now()
);
create index if not exists subscriptions_user_id_idx on public.subscriptions (user_id);

alter table public.billing_customers enable row level security;
alter table public.subscriptions enable row level security;

drop policy if exists "自分の顧客番号だけ読める" on public.billing_customers;
create policy "自分の顧客番号だけ読める" on public.billing_customers for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists "自分の契約だけ読める" on public.subscriptions;
create policy "自分の契約だけ読める" on public.subscriptions for select to authenticated using ((select auth.uid()) = user_id);

-- 新しい表を自動で公開しない設定でも読めるように、読む権利をはっきり渡す
grant select on public.billing_customers to authenticated;
grant select on public.subscriptions to authenticated;
