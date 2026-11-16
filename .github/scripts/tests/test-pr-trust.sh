#!/usr/bin/env bash
# 修正AIの前（pr-trust.sh）：このリポジトリの claude/ ブランチのPRだけ、確認コマンドを動かしてよい（restrict=false）
source "$(dirname "$0")/lib.sh"
setup_mock
pr_of() { # 番号 ブランチ headのリポジトリ state
  echo '{"number":'"$1"',"state":"'"${4:-open}"'","head":{"sha":"abc","ref":"'"$2"'","repo":{"full_name":"'"$3"'"}},"base":{"repo":{"full_name":"o/r"}},"user":{"login":"gaku-ai-pipeline[bot]","type":"Bot"}}'
}
trust() { local f="$MOCK_DIR/out"; : > "$f"; PR="$1" GITHUB_OUTPUT="$f" bash "$SCRIPTS_DIR/pr-trust.sh" > /dev/null 2>&1; cat "$f"; }
init_state '{"pulls":['"$(pr_of 1 claude/issue-5-x o/r)"','"$(pr_of 2 claude/issue-5-x evil/r)"','"$(pr_of 3 dependabot/npm/x o/r)"','"$(pr_of 4 claude/issue-6-y o/r closed)"','"$(pr_of 5 claude/issue-7-z O/R)"']}'

echo "== このリポジトリの claude/ ブランチ：動かしてよい"
assert_eq "restrict=false" "restrict=false" "$(trust 1)"
assert_eq "大文字小文字が違っても同じリポジトリ" "restrict=false" "$(trust 5)"

echo "== それ以外は、既定のまま（PRのコードを動かさせない）"
assert_eq "fork のPR" "restrict=true" "$(trust 2)"
assert_eq "claude/ ではないブランチ（dependabot など）" "restrict=true" "$(trust 3)"
assert_eq "閉じたPR" "restrict=true" "$(trust 4)"
assert_eq "PRではない（Issue へのコメント）" "restrict=true" "$(trust 99)"
assert_eq "番号が無い" "restrict=true" "$(trust "")"
assert_eq "番号が数字ではない" "restrict=true" "$(trust "1;x")"

finish
