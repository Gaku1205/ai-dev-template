#!/usr/bin/env bash
# 画面案（mocks-publish.sh）：AIが作ったざっくり画面2案を ai-mocks ブランチに置き、選択肢と質問を書いて ai:question で待つ。
# 作れなかったら止めて知らせる。画像の置き場は手元の git で真似る
source "$(dirname "$0")/lib.sh"
setup_mock
w="$MOCK_DIR/w"; mkdir -p "$w/out" "$MOCK_DIR/tmp"
git init -q --bare "$MOCK_DIR/assets.git"
png() { printf '\x89PNG\r\n\x1a\n0000' > "$1"; }
pub() { (cd "$w" && ISSUE=5 ASSETS_REMOTE="$MOCK_DIR/assets.git" RUNNER_TEMP="$MOCK_DIR/tmp" bash "$SCRIPTS_DIR/mocks-publish.sh" > /dev/null 2>&1); }

echo "== 2案を置いて、選択肢と質問を書いて待つ"
init_state '{"labels":{"5":["ai:mocks"]}}'
echo '{"mocks":[{"title":"曲線が主役","note":"n"},{"title":"表が主役","note":"m"}],"questions":[{"q":"暗い画面？","options":["暗い","明るい"],"recommend":1}]}' > "$w/out/mocks.json"
for k in a b; do echo "<html></html>" > "$w/out/mock-$k.html"; png "$w/out/mock-$k-1440.png"; png "$w/out/mock-$k-390.png"; done
pub
assert_eq "画面案の印を外して、答え待ち" "ai:question" "$(labels_of 5)"
c=$(comments_of 5)
assert_contains "答え待ちの印" "$c" "<!-- ai-question -->"
assert_contains "置き場の印（企画AIが目標の画面を書くのに使う）" "$c" "<!-- ai-mocks: issue-5/r1 -->"
assert_contains "画像は ai-mocks ブランチ" "$c" "https://raw.githubusercontent.com/o/r/ai-mocks/issue-5/r1/mock-a-1440.png"
assert_contains "質問とおすすめ" "$c" "- B. 明るい（おすすめ）"
assert_contains "HTML も置く（実装AIに渡す）" "$(git --git-dir="$MOCK_DIR/assets.git" ls-tree -r --name-only ai-mocks)" "issue-5/r1/mock-b.html"

echo "== 出し直しは次の回の置き場"
init_state '{"labels":{"5":["ai:mocks"]}}'
pub
assert_contains "2回目" "$(comments_of 5)" "<!-- ai-mocks: issue-5/r2 -->"

echo "== 作れなかったら止めて知らせる"
init_state '{"labels":{"5":["ai:mocks"]}}'
rm -f "$w/out/"*
pub
assert_eq "止まった" "ai:stuck" "$(labels_of 5)"
assert_contains "理由" "$(comments_of 5)" "画面案を作れませんでした"

finish
