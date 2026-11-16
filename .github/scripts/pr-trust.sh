#!/usr/bin/env bash
# 修正AI（claude-mention.yml）の前：このPRのコードを、AIが確認コマンド（npm run test など）で動かしてよいかを決める。
#
# claude-code-action は、PRの作者に書き込み権限が確認できないとき（ボットは、allowed_bots に入っていても必ずこの扱い）、
# パッケージマネージャー・テスト・インタプリタなどのコマンドを、--allowedTools に入っていても拒否する（restrict_untrusted_prs。既定で有効）。
# このパイプラインのPRは、パイプラインの App（ボット）が作るので、何もしないと修正AIは確認コマンドを1つも動かせない。
#
# 動かしてよいのは、次の全部を満たすPRだけ（それ以外は、既定のまま拒否させる）：
#   - PRのブランチが、このリポジトリの中にある（fork ではない。このリポジトリに push できるのは、書き込み権限のある人とAppだけ）
#   - ブランチ名が claude/ で始まる（実装AIが、このリポジトリのワークフローの中で作ったブランチ）
#   - PRが開いている
#
# 環境変数：GH_TOKEN、GITHUB_REPOSITORY、PR（PRの番号。Issue へのコメントで起きたときは、Issue の番号が入る）
# 出力（GITHUB_OUTPUT）：restrict=false（動かしてよい）／restrict=true（既定のまま）
set -u
out="${GITHUB_OUTPUT:-/dev/stdout}"
decide() { echo "restrict=$1" >> "$out"; echo "$2"; exit 0; }

case "${PR:-}" in '' | *[!0-9]*) decide true "PRの番号が無いので、既定のまま（PRのコードは動かさせない）" ;; esac
json=$(gh api "repos/$GITHUB_REPOSITORY/pulls/$PR" 2> /dev/null) || decide true "#$PR はPRではない・読めないので、既定のまま"
# 1回の jq で読む。形が違えば全部 false になる
ok=$(printf '%s' "$json" | jq -r --arg repo "$GITHUB_REPOSITORY" '
  (.state == "open")
  and ((.head.repo.full_name // "") | ascii_downcase) == ($repo | ascii_downcase)
  and ((.base.repo.full_name // "") | ascii_downcase) == ($repo | ascii_downcase)
  and ((.head.ref // "") | startswith("claude/"))' 2> /dev/null) || ok=false
if [ "$ok" = "true" ]; then
  decide false "PR #$PR は、このリポジトリの claude/ ブランチなので、確認コマンドを動かしてよい"
fi
decide true "PR #$PR は、このリポジトリの claude/ ブランチではないので、既定のまま（PRのコードは動かさせない）"
