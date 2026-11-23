#!/usr/bin/env bash
# 公開先を決める：サーバーの要らないアプリは GitHub Pages、サーバーが要る物は Vercel（Hobby の CPU の上限で止まらないように）。
# factory.sh（新しいサービス）と move-to-pages.sh（今あるアプリを移す）が source して使う。
#
# 使い方：
#   pick_deploy <言語> <説明> [課金 yes|no] [ログイン yes|no]   github-pages か vercel を1行で出す
#   pages_next_config                                            GitHub Pages 用の next.config.ts を出す（gaku1205-portfolio と同じ形）
#   pages_pipeline_json <リポジトリ名> [pipeline.json]           deploy を github-pages にした pipeline.json を出す（元があればそれを土台に）
# 直接動かすと pick_deploy を呼ぶ：pick-deploy.sh nextjs "説明" no no
#
# 決め方（迷ったら vercel。サーバーが要るのに Pages に出すと壊れるため）：
#   - 言語が nextjs 以外（data・saas・python・game・webgame）は vercel（game・python は公開先が別に決まっている）
#   - 課金・ログインが yes なら vercel
#   - 説明に、サーバーで動く物（API・ログイン・会員・課金・AI・メール・共有・データベースなど）を思わせる言葉があれば vercel
#   - 説明に、サーバーの要らない印（データは端末・静的・ポートフォリオ・ゲームなど）があるときだけ github-pages
#   - どちらでもなければ vercel

# サーバーが要ると思われる言葉（英字は前後が英字でないときだけ）。日本語は部分一致
PICK_SERVER_JA='サーバー|ログイン|サインイン|会員|アカウント|認証|課金|決済|支払|サブスク|有料|データベース|メール|通知|共有|同期|クラウド|投稿|コメント|ランキング|みんなで|他の人|ユーザー同士'
PICK_SERVER_EN='API|DB|AI|OAuth|Webhook|Stripe|Supabase|Firebase|OpenAI|Claude|GPT|Gemini|LLM'
# サーバーの要らない印
PICK_STATIC_JA='データは端末|端末だけ|端末に保存|端末のみ|ブラウザだけ|ブラウザのみ|ブラウザ内|ローカルストレージ|静的|ポートフォリオ|ランディング|紹介ページ|紹介サイト|ゲーム|サーバー不要|サーバーなし|サーバーレス|オフライン'
PICK_STATIC_EN='localStorage|LP'

_pick_has() { # 文章 日本語の言葉 英字の言葉
  grep -qE -- "$2" <<< "$1" && return 0
  grep -qE -- "(^|[^A-Za-z])($3)([^A-Za-z]|$)" <<< "$1"
}

pick_deploy() {
  local stack="${1:-}" text="${2:-}" paid="${3:-no}" login="${4:-no}"
  [ "$stack" = nextjs ] || { echo vercel; return 0; }
  [ "$paid" != yes ] && [ "$login" != yes ] || { echo vercel; return 0; }
  # 「サーバー不要」「サーバーなし」「サーバーレス」は、サーバーが要る言葉として数えない
  local server_text
  server_text=$(sed -E 's/サーバー(不要|なし|レス|は要らない|は不要)//g' <<< "$text")
  if _pick_has "$server_text" "$PICK_SERVER_JA" "$PICK_SERVER_EN"; then echo vercel; return 0; fi
  # 印は、元の文章で見る（「サーバー不要」自体が印）
  if _pick_has "$text" "$PICK_STATIC_JA" "$PICK_STATIC_EN"; then echo github-pages; return 0; fi
  echo vercel
}

# 理由を1行で（工場の最初のコメントと設計メモに書く）
pick_deploy_reason() { # 公開先
  case "$1" in
    github-pages) echo "公開先は GitHub Pages：サーバーで動く物（API・ログイン・課金・AI を呼ぶ処理・データベース）が無いので、Vercel を使わない（Vercel はサーバーが要る物だけ）" ;;
    *) echo "公開先は Vercel：サーバーで動く物が要る（または、要らないと言い切れない）ので、今までどおり" ;;
  esac
}

# GitHub Pages 用の next.config.ts（静的な書き出し。basePath は公開のビルドで PAGES_BASE_PATH=/<リポジトリ名> を付けたときだけ）
pages_next_config() {
  cat <<'TS'
import type { NextConfig } from "next";

// GitHub Pages に置く（サーバーの要らない静的な書き出し）。
// 公開のビルドだけ PAGES_BASE_PATH=/<リポジトリ名> が付く（pipeline.json の deploy の build）。手元と CI では空（直下）。決まった形でない値は使わない
const raw = process.env.PAGES_BASE_PATH ?? "";
const basePath = /^\/[A-Za-z0-9._-]+$/.test(raw) ? raw : "";

const nextConfig: NextConfig = {
  output: "export",
  trailingSlash: true,
  images: { unoptimized: true },
  ...(basePath ? { basePath } : {}),
  // next/image の文字の src（"/photos/a.jpg"）と素の <a> には階層が自動で付かない。前に NEXT_PUBLIC_BASE_PATH を付けて使う
  env: { NEXT_PUBLIC_BASE_PATH: basePath },
};

export default nextConfig;
TS
}

# deploy を github-pages にした pipeline.json。元の pipeline.json があれば deploy だけ差し替え、無ければ Next.js の既定の確認コマンドを入れる
pages_pipeline_json() { # リポジトリ名 [元の pipeline.json]
  local name="$1" src="${2:-}" base
  if [ -n "$src" ] && [ -f "$src" ] && jq -e 'type == "object"' "$src" > /dev/null 2>&1; then
    base=$(jq -c . "$src")
  else
    base='{"tools":{"node":"22"},"setup":["npm ci"],"checks":[{"name":"型チェック","run":"npm run typecheck"},{"name":"リント","run":"npm run lint"},{"name":"テスト","run":"npm run test"},{"name":"ビルド","run":"npm run build"}]}'
  fi
  jq --arg b "PAGES_BASE_PATH=/$name npm run build" '.deploy = [{"kind": "github-pages", "build": $b}]' <<< "$base"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  pick_deploy "$@"
fi
