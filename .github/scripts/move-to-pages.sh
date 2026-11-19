#!/usr/bin/env bash
# 今あるアプリを、Vercel から GitHub Pages に移す（マネージャーが手で使う）。
#   使い方：GH_TOKEN=<そのリポジトリに push・PR・Pages ができる鍵> move-to-pages.sh <owner/repo>
#
#   1. そのリポジトリにサーバーで動くファイル（app/api/・route.ts・middleware.ts・"use server"・supabase/migrations）があれば、理由を出して止まる
#   2. 無ければ、pipeline.json（deploy を github-pages・build に PAGES_BASE_PATH=/<リポジトリ名> npm run build）と next.config.ts
#      （output: "export"・trailingSlash・images.unoptimized・basePath）を書き換える PR を作る
#   3. Pages を有効にする（もう有効なら飛ばす）
#   4. basePath の付け忘れになりそうな物（素の <a href="/…">・<img src="/…">）を探して、PR の本文に一覧を書く
#
# テスト用の環境変数：MOVE_GIT_URL（clone 先の書式。%s にリポジトリ名）
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=pick-deploy.sh
source "$HERE/pick-deploy.sh"

REPO="${1:-}"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "使い方：move-to-pages.sh <owner/repo>" >&2; exit 2; }
NAME="${REPO#*/}"
GIT_URL="${MOVE_GIT_URL:-https://x-access-token:${GH_TOKEN:-}@github.com/%s.git}"
BRANCH="move-to-pages"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck disable=SC2059
git clone -q "$(printf "$GIT_URL" "$REPO")" "$work/app" 2> /dev/null || { echo "❌ $REPO を clone できません" >&2; exit 1; }
cd "$work/app" || exit 1

# ---- 1. サーバーで動くファイルが無いか ----
found=()
while IFS= read -r f; do found+=("$f（API の route）"); done < <(git ls-files | grep -E '(^|/)app/api/' | head -n 5)
while IFS= read -r f; do found+=("$f（route）"); done < <(git ls-files | grep -E '(^|/)route\.(ts|tsx|js|jsx|mjs)$' | grep -vE '(^|/)app/api/' | head -n 5)
while IFS= read -r f; do found+=("$f（middleware）"); done < <(git ls-files | grep -E '(^|/)(middleware|proxy)\.(ts|js|mjs)$' | head -n 5)
while IFS= read -r f; do found+=("$f（サーバーアクション）"); done < <(git grep -lE '^[[:space:]]*["'"'"']use server["'"'"']' -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.mjs' 2> /dev/null | head -n 5)
while IFS= read -r f; do found+=("$f（Supabase の migrations）"); done < <(git ls-files | grep -E '(^|/)supabase/migrations/' | head -n 3)
if [ "${#found[@]}" -gt 0 ]; then
  echo "❌ $REPO はサーバーで動くファイルがあるので、GitHub Pages には移せません（Vercel のまま）：" >&2
  printf '  - %s\n' "${found[@]}" >&2
  exit 1
fi

# ---- 2. pipeline.json と next.config を書き換える ----
old_config=""
for c in next.config.ts next.config.mjs next.config.js next.config.cjs; do
  if [ -f "$c" ]; then old_config="$old_config $c"; git rm -q -f "$c"; fi
done
pages_next_config > next.config.ts
pages_pipeline_json "$NAME" pipeline.json > pipeline.json.new && mv pipeline.json.new pipeline.json

# ---- 4. basePath の付け忘れ（素の <a href="/…">・<img src="/…">。next/link・next/image は自動で付く） ----
raw=$(git grep -nE '<(a|img)[^>]*(href|src)=("/[^/"]|\{?["'"'"']/[^/"'"'"'])' -- '*.tsx' '*.jsx' '*.html' 2> /dev/null | cut -c1-200 | head -n 60)
css=$(git grep -nE 'url\(["'"'"']?/[^/]' -- '*.css' '*.tsx' 2> /dev/null | cut -c1-200 | head -n 20)

git checkout -q -b "$BRANCH"
git add -A
if git diff --cached --quiet; then echo "✅ $REPO は、もう GitHub Pages の形になっています（変える物が無い）"; changed=no; else
  git -c user.name="move-to-pages" -c user.email="noreply@github.com" commit -q -m "公開先を GitHub Pages に移す（サーバーの要らないアプリ）"
  changed=yes
fi

body="### 何を変えたか
- \`pipeline.json\`：deploy を \`github-pages\`（build は \`PAGES_BASE_PATH=/$NAME npm run build\`）にした
- \`next.config.ts\`：\`output: \"export\"\`・\`trailingSlash: true\`・\`images.unoptimized\`・\`basePath\`（公開のビルドだけ \`PAGES_BASE_PATH\` から）
- サーバーで動くファイル（\`app/api/\`・\`route.ts\`・\`middleware.ts\`・\`\"use server\"\`・\`supabase/migrations\`）が無いことを確かめた
${old_config:+- 元の next.config（${old_config# }）は置き換えた。独自の設定があった場合は、差分を見て戻してほしい
}
### basePath の付け忘れになりそうな所（人が見て直す）
Pages は \`https://<owner>.github.io/$NAME/\` に置かれるので、素の \`/\` から始まる \`<a href>\`・\`<img src>\` は 404 になる。\`next/link\`・\`next/image\` は自動で付く。
"
if [ -n "$raw" ]; then body="${body}
\`\`\`
${raw}
\`\`\`
"; else body="${body}
- 見つからなかった
"; fi
if [ -n "$css" ]; then body="${body}
CSS・コードの \`url(/…)\`：
\`\`\`
${css}
\`\`\`
"; fi
body="${body}
### 人間が確認すること
- マージ後、Actions の公開が通り、\`https://${REPO%%/*}.github.io/$NAME/\` が開くこと
- Vercel のプロジェクトは、Pages が動くのを見てから止める"

if [ "$changed" = yes ]; then
  git push -q -f origin "HEAD:$BRANCH" || { echo "❌ push できません" >&2; exit 1; }
  base=$(gh api "repos/$REPO" -q .default_branch 2> /dev/null); base="${base:-main}"
  if url=$(gh api -X POST "repos/$REPO/pulls" -f title="公開先を GitHub Pages に移す" -f head="$BRANCH" -f base="$base" -f body="$body" -q .html_url 2>&1); then
    echo "✅ PR を作った：$url"
  else
    echo "❌ PR を作れませんでした：$(printf '%s' "$url" | tail -1 | cut -c1-160)" >&2; exit 1
  fi
fi

# ---- 3. Pages を有効にする（もう有効なら飛ばす） ----
if gh api "repos/$REPO/pages" > /dev/null 2>&1; then
  echo "✅ GitHub Pages はもう有効になっている"
elif out=$(gh api -X POST "repos/$REPO/pages" -f build_type=workflow 2>&1); then
  echo "✅ GitHub Pages を有効にした（Source は GitHub Actions）"
else
  echo "⚠️ GitHub Pages を有効にできませんでした（https://github.com/$REPO/settings/pages を開いて、Source を GitHub Actions にする）：$(printf '%s' "$out" | tail -1 | cut -c1-160)" >&2
fi
