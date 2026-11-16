#!/usr/bin/env bash
# 工場：ゲームの雛形に切り替える（factory-game.sh）。日本語の書体の元と、使う文字だけを抜き出す仕組みが入るか
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ROOT="$(cd "$SCRIPTS_DIR/../.." && pwd)"
prep() { # テンプレートから作ったばかりのリポジトリのまね
  rm -rf "$T/app"; mkdir -p "$T/app/docs"
  cp -r "$ROOT/examples" "$T/app/"
  printf '# このリポジトリでのルール\n\nNext.js（App Router）＋TypeScript。\n\n## コードの書き方\n\n- x\n\n## PRとコメント\n' > "$T/app/CLAUDE.md"
  printf '# 仕様書\n' > "$T/app/docs/spec.md"
  printf 'node_modules/\n' > "$T/app/.gitignore"
}
for mode in exe web; do
  echo "== $mode：書体の元・抜き出す仕組み・ビルドへの組み込み"
  prep
  bash "$SCRIPTS_DIR/factory-game.sh" "$T/app" "$mode" > "$T/out.txt" 2>&1
  assert_eq "終了コード 0" "0" "$?"
  assert_eq "書体の元がある" "yes" "$([ -f "$T/app/assets/fonts/MPLUS1-var.woff2" ] && echo yes || echo no)"
  assert_eq "ライセンスがある" "yes" "$([ -f "$T/app/assets/fonts/OFL.txt" ] && echo yes || echo no)"
  assert_eq "抜き出す仕組みがある" "yes" "$([ -f "$T/app/scripts/subset-fonts.mjs" ] && echo yes || echo no)"
  assert_contains "ビルドの前に書体を作る" "$(cat "$T/app/package.json")" '"build": "npm run fonts &&'
  assert_contains "作った書体は git に入れない" "$(cat "$T/app/.gitignore")" "public/fonts/"
  assert_contains "@font-face" "$(cat "$T/app/index.html")" "./fonts/mplus1.woff2"
  assert_contains "AGENTS.md に書体の注意" "$(cat "$T/app/AGENTS.md")" "GameJP"
  assert_eq "examples は消える" "no" "$([ -d "$T/app/examples" ] && echo yes || echo no)"
done
finish
