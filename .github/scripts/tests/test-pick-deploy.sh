#!/usr/bin/env bash
# pick-deploy.sh：サーバーの要らない案は github-pages、要る案・迷う案は vercel
source "$(dirname "$0")/lib.sh"
source "$SCRIPTS_DIR/pick-deploy.sh"

echo "== サーバーの要らない案は github-pages"
assert_eq "データは端末だけ" github-pages "$(pick_deploy nextjs "家計のメモ。データは端末だけに保存する" no no)"
assert_eq "静的なページ（ポートフォリオ）" github-pages "$(pick_deploy nextjs "自分の作品を並べるポートフォリオ" no no)"
assert_eq "ゲーム" github-pages "$(pick_deploy nextjs "30秒で遊べるパズルゲーム" no no)"
assert_eq "サーバー不要と書いてある（サーバーの言葉には数えない）" github-pages "$(pick_deploy nextjs "計算ツール。サーバー不要" no no)"
assert_eq "localStorage" github-pages "$(pick_deploy nextjs "ToDo。localStorage に置く" no no)"

echo "== サーバーが要る案は vercel"
assert_eq "ログイン" vercel "$(pick_deploy nextjs "ログインして使うメモ。データは端末だけ" no no)"
assert_eq "課金 yes" vercel "$(pick_deploy nextjs "静的なページ" yes no)"
assert_eq "ログイン yes" vercel "$(pick_deploy nextjs "静的なページ" no yes)"
assert_eq "AI を呼ぶ" vercel "$(pick_deploy nextjs "ゲーム。AI が相手になる" no no)"
assert_eq "API" vercel "$(pick_deploy nextjs "天気の API をまとめる静的なページ" no no)"
assert_eq "共有" vercel "$(pick_deploy nextjs "みんなで共有するゲーム" no no)"
assert_eq "Supabase" vercel "$(pick_deploy nextjs "Supabase に保存するゲーム" no no)"

echo "== 迷ったら vercel"
assert_eq "印が無い" vercel "$(pick_deploy nextjs "毎朝の天気と予定を1枚で見るページ" no no)"
assert_eq "空の説明" vercel "$(pick_deploy nextjs "" no no)"
assert_eq "英字は単語のときだけ（main は AI ではない）" github-pages "$(pick_deploy nextjs "main の LP を作るゲーム" no no)"

echo "== nextjs 以外は vercel（公開先が別に決まる物・サーバーが要る物）"
assert_eq "saas" vercel "$(pick_deploy saas "静的なページ" no no)"
assert_eq "python" vercel "$(pick_deploy python "ゲーム" no no)"
assert_eq "webgame" vercel "$(pick_deploy webgame "ゲーム" no no)"

echo "== 直接動かせる・GitHub Pages 用の物"
assert_eq "直接動かす" github-pages "$(bash "$SCRIPTS_DIR/pick-deploy.sh" nextjs "静的なページ" no no)"
cfg=$(pages_next_config)
assert_contains "output: export" "$cfg" 'output: "export"'
assert_contains "trailingSlash" "$cfg" "trailingSlash: true"
assert_contains "images.unoptimized" "$cfg" "images: { unoptimized: true }"
assert_contains "basePath は PAGES_BASE_PATH から" "$cfg" 'process.env.PAGES_BASE_PATH ?? ""'
assert_contains "決まった形の値だけ使う" "$cfg" '/^\/[A-Za-z0-9._-]+$/.test(raw)'
assert_contains "NEXT_PUBLIC_BASE_PATH を渡す" "$cfg" "env: { NEXT_PUBLIC_BASE_PATH: basePath }"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
assert_eq "元が無ければ確認コマンドも入れる" "4" "$(pages_pipeline_json my-app | jq '.checks | length')"
assert_eq "build に基準のパス" '[{"kind":"github-pages","build":"PAGES_BASE_PATH=/my-app npm run build"}]' "$(pages_pipeline_json my-app | jq -c .deploy)"
echo '{"tools":{"node":"20"},"checks":[{"name":"x","run":"npm run lint"}],"deploy":[{"kind":"vercel"}]}' > "$T/p.json"
assert_eq "元があれば deploy だけ差し替える" '{"tools":{"node":"20"},"checks":[{"name":"x","run":"npm run lint"}],"deploy":[{"kind":"github-pages","build":"PAGES_BASE_PATH=/my-app npm run build"}]}' "$(pages_pipeline_json my-app "$T/p.json" | jq -c .)"
finish
