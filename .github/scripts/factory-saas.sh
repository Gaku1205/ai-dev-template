#!/usr/bin/env bash
# 工場：テンプレートから作ったリポジトリ（Next.js）に、会員登録・ログイン（Supabase）と月額の有料プラン（Stripe）の土台を入れる。
# 使い方：factory-saas.sh <リポジトリのフォルダ> [install|lock|keep]
#   install：土台を入れ、依存を npm install で入れる（工場の design ジョブ。デザイン担当がすぐ動かせるように）
#   lock（既定）：土台を入れ、package.json と package-lock.json だけ更新する（工場の build ジョブ。node_modules は作らない）
#   keep：src/ の、無くなった土台のファイルだけを戻す（デザイン担当の画面を入れた後。作り直した見た目は上書きしない）
# 土台の中身は examples/saas（説明は examples/saas/README.md。新しいリポジトリでは docs/billing.md になる）。
set -euo pipefail
cd "${1:?フォルダを指定}"
mode="${2:-lock}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ex="$HERE/../../examples/saas"
[ -d "$ex/src" ] || { echo "examples/saas がありません"; exit 1; }
# 依存（工場が入れる。アプリの AI は依存を足せない）
DEPS="@supabase/supabase-js@2.118.0 @supabase/ssr@0.12.7 stripe@23.0.0"

# src/ の土台を入れる。既にあるファイルは上書きしない（keep でも、最初でも同じ。テンプレートの page.tsx などは残す）
copy_src() {
  ( cd "$ex/src" && find . -type f ) | while IFS= read -r f; do
    if [ ! -e "src/$f" ]; then mkdir -p "src/$(dirname "$f")"; cp "$ex/src/$f" "src/$f"; fi
  done
}

if [ "$mode" = keep ]; then
  copy_src
  echo "会員と課金の土台のうち、無くなっていた物を戻した"
  exit 0
fi
case "$mode" in install | lock) ;; *) echo "種類「$mode」は install・lock・keep のどれか"; exit 1 ;; esac

copy_src
mkdir -p supabase/migrations docs
cp "$ex/supabase/migrations/"*.sql supabase/migrations/
cp "$ex/README.md" docs/billing.md
# 確認コマンドと公開先：いつもの Next.js に、表の変更（supabase/migrations）を流す公開を足す
cat > pipeline.json <<'JSON'
{
  "tools": { "node": "22" },
  "setup": ["npm ci"],
  "checks": [
    { "name": "型チェック", "run": "npm run typecheck" },
    { "name": "リント", "run": "npm run lint" },
    { "name": "テスト", "run": "npm run test" },
    { "name": "ビルド", "run": "npm run build" }
  ],
  "deploy": [{ "kind": "vercel" }, { "kind": "supabase" }]
}
JSON
# shellcheck disable=SC2086
if [ "$mode" = install ]; then
  npm install --no-audit --no-fund --save $DEPS > /dev/null
else
  npm install --package-lock-only --no-audit --no-fund --ignore-scripts --save $DEPS > /dev/null
fi
# CLAUDE.md と仕様書に、会員と課金のことを書く
python3 - <<'PY'
import re  # noqa: F401
s = open("CLAUDE.md", encoding="utf-8").read()
s = s.replace("Next.js（App Router）＋TypeScript。", "Next.js（App Router）＋TypeScript。会員登録・ログインは Supabase、月額の有料プランは Stripe。", 1)
rule = "- 会員と課金の決まりは `docs/billing.md`。有料の機能は、サーバーで `getViewer()` の `pro` を確かめてから出す。会員のデータの表は、新しい番号の `supabase/migrations/*.sql` で足す（RLS 必須）。課金とログインの土台のファイル（`docs/billing.md` の一覧）は中身を変えない\n"
if "docs/billing.md" not in s:
    s = s.replace("\n\n## 作業のしかた\n", "\n" + rule + "\n## 作業のしかた\n", 1)
open("CLAUDE.md", "w", encoding="utf-8").write(s)
p = open("docs/spec.md", encoding="utf-8").read()
p = p.replace("- 技術：Next.js（App Router）＋TypeScript、テストはVitest", "- 技術：Next.js（App Router）＋TypeScript、テストはVitest。会員登録・ログインは Supabase、月額の有料プランは Stripe（`docs/billing.md`）", 1)
if "## 無料と有料" not in p:
    p = p.replace("## 画面\n", "## 無料と有料\n\n- 無料でできること：\n- 有料プラン（月額）でできること：\n\n## 画面\n", 1)
open("docs/spec.md", "w", encoding="utf-8").write(p)
PY
echo "会員と月額課金（Supabase・Stripe）の土台を入れた"
