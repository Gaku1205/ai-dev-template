#!/usr/bin/env bash
# 工場の相談（factory-talk.py・factory-talk-publish.sh）：案 → 見た目の方向 → ざっくり画面 → 最終確認 → 作る、の流れと、
# 返事の読み替え・形の確かめ・コメント・画像の置き場。GitHub は疑似 gh、画像の置き場は手元の git で真似る
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
talk() { python3 "$SCRIPTS_DIR/factory-talk.py" "$@"; }
png() { printf '\x89PNG\r\n\x1a\n0000' > "$1"; }
mkdir -p "$T/out"

echo "== 始める：段階は案から"
talk init "潮と釣りの何か" "スマホで使いたい" > "$T/s0.json"
assert_eq "段階" "ideas" "$(jq -r .stage "$T/s0.json")"
assert_eq "メモ" "潮と釣りの何か" "$(jq -r .memo "$T/s0.json")"

echo "== 案：形の違う物は捨て、質問を整える"
cat > "$T/out/ideas.json" <<'EOF'
{"ideas":[
 {"name":"tide-almanac","stack":"saas","title":"潮汐暦","pitch":"潮の暦\nです","who":"釣り人","paid":"月480円","novel":"時合い","screen":"曲線"},
 {"name":"Bad Name","stack":"saas","title":"x"},
 {"name":"surf-log","stack":"nextjs","title":"波の記録","pitch":"p","paid":"有料の話"},
 {"name":"reef-batch","stack":"python","title":"処理","pitch":"p"},
 {"name":"kelp-game","stack":"webgame","title":"昆布","pitch":"p"},
 {"name":"shore-cam","stack":"nextjs","title":"浜","pitch":"p"}],
 "questions":[{"q":"スマホ中心？","options":["スマホ","PC"],"recommend":9},{"q":"選択肢が1つ","options":["だけ"]}]}
EOF
talk check ideas "$T/out" > "$T/o.json"; code=$?
assert_eq "形が合えば 0" "0" "$code"
assert_eq "形の違う名前は捨てる（5つ残る）" "5" "$(jq '.ideas | length' "$T/o.json")"
assert_eq "改行は消す" "潮の暦 です" "$(jq -r '.ideas[0].pitch' "$T/o.json")"
assert_eq "saas でなければ有料の欄は空" "" "$(jq -r '.ideas[1].paid' "$T/o.json")"
assert_eq "選択肢が2つ未満の質問は捨てる" "1" "$(jq '.questions | length' "$T/o.json")"
assert_eq "おすすめが範囲外なら最初" "0" "$(jq '.questions[0].recommend' "$T/o.json")"
echo '{"ideas":[{"name":"a-b","stack":"x"}]}' > "$T/bad.json"; mkdir -p "$T/bad"; cp "$T/bad.json" "$T/bad/ideas.json"
talk check ideas "$T/bad" > /dev/null 2>&1; assert_eq "案が足りなければ失敗" "1" "$?"

echo "== 案を見せる：番号・質問・返し方・印"
talk merge "$T/s0.json" ideas "$T/o.json" "issue-7/r1-ideas" > "$T/s1.json"
body=$(talk render "$T/s1.json" "https://raw.example/o/r/factory-talk")
assert_contains "1つ目の案" "$body" "### 1. 潮汐暦（\`tide-almanac\`・saas）"
assert_contains "質問とおすすめ" "$body" "- A. スマホ（おすすめ）"
assert_contains "返し方" "$body" "Q1はA"
assert_contains "印" "$body" "<!-- factory-talk:v1:"
jq -n --arg b "$body" '[{"user":{"login":"Gaku1205"},"body":"<!-- factory-talk:v1:e30= -->"},{"user":{"login":"github-actions[bot]"},"body":$b}]' > "$T/comments.json"
assert_eq "印から state を戻す（オーナーの書いた印は使わない）" "ideas 5" "$(talk state "$T/comments.json" | jq -r '"\(.stage) \(.ideas | length)"')"

echo "== 返事を当てはめる"
echo '{"action":"pick","choice":"1","answers":[{"q":"スマホ中心？","a":"スマホ"}],"note":"名前は短く"}' > "$T/r.json"
talk apply "$T/s1.json" "$T/r.json" > "$T/a.json"
assert_eq "案を選ぶと見た目の方向へ" "looks" "$(jq -r .next "$T/a.json")"
assert_eq "選んだ案" "0" "$(jq -r .state.idea "$T/a.json")"
assert_eq "答えを残す" "スマホ" "$(jq -r '.state.answers[0].a' "$T/a.json")"
assert_eq "注文を残す" "名前は短く" "$(jq -r '.state.notes[0].note' "$T/a.json")"
echo '{"action":"pick","choice":"3"}' > "$T/r.json"
assert_eq "画面の無い案（python）は最終確認へ" "confirm" "$(talk apply "$T/s1.json" "$T/r.json" | jq -r .next)"
echo '{"action":"pick","choice":"9"}' > "$T/r.json"
assert_eq "無い番号は聞き直す" "clarify" "$(talk apply "$T/s1.json" "$T/r.json" | jq -r .next)"
echo '{"action":"pick","choice":"1,4,5"}' > "$T/r.json"
talk apply "$T/s1.json" "$T/r.json" > "$T/am.json"
assert_eq "いくつか選ぶと、まとめた案を足す" "6 5" "$(jq -r '"\(.state.ideas | length) \(.state.idea)"' "$T/am.json")"
assert_eq "まとめた案は名前が空で、元の番号を持つ" " 1,4,5" "$(jq -r '.state.ideas[5] | "\(.name) \(.parts | join(","))"' "$T/am.json")"
assert_eq "まとめた案の呼び名" "潮汐暦・昆布・浜" "$(jq -r '.state.ideas[5].title' "$T/am.json")"
assert_eq "まとめても見た目の方向へ" "looks" "$(jq -r .next "$T/am.json")"
echo '{"action":"pick","choice":"1〜3"}' > "$T/r.json"
assert_eq "範囲でも選べる" "1,2,3" "$(talk apply "$T/s1.json" "$T/r.json" | jq -r '.state.ideas[-1].parts | join(",")')"
echo '{"action":"pick","choice":"2,9"}' > "$T/r.json"
assert_eq "無い番号が混ざれば聞き直す" "clarify" "$(talk apply "$T/s1.json" "$T/r.json" | jq -r .next)"
echo '{"action":"redo","note":"もっと変なの"}' > "$T/r.json"
talk apply "$T/s1.json" "$T/r.json" > "$T/a2.json"
assert_eq "やり直しは同じ段階" "ideas" "$(jq -r .next "$T/a2.json")"
echo '{"action":"go"}' > "$T/r.json"
assert_eq "選ぶ前の「作る」は聞き直す" "clarify" "$(talk apply "$T/s1.json" "$T/r.json" | jq -r .next)"
jq '.state' "$T/a.json" > "$T/s2.json"

echo "== agent-desk のボタンの返事（印）はそのまま読む"
mark=$(printf '{"action":"pick","choice":"2"}' | base64 -w0)
assert_eq "印の返事" "2" "$(printf '2を選ぶ\n<!-- factory-answer:%s -->' "$mark" | talk answer | jq -r .choice)"
assert_eq "印が無ければ空" "" "$(printf '2で' | talk answer)"

echo "== 見た目の方向：画像の無い方向は捨てる"
cat > "$T/out/looks.json" <<'EOF'
{"looks":[{"title":"潮見表","idea":"紙","colors":["#F2EDE3","red"],"refs":["https://a.example/","javascript:x"]},{"title":"夜","idea":"暗い"},{"title":"写真","idea":"写真"}],"questions":[]}
EOF
png "$T/out/look-1-1440.png"; png "$T/out/look-3-1440.png"; echo "not png" > "$T/out/look-2-1440.png"
talk check looks "$T/out" > "$T/o.json"
assert_eq "画像のある方向だけ" "1 3" "$(jq -r '[.looks[].n] | join(" ")' "$T/o.json")"
assert_eq "色は hex だけ" "#F2EDE3" "$(jq -r '.looks[0].colors | join(",")' "$T/o.json")"
assert_eq "参考は https だけ" "https://a.example/" "$(jq -r '.looks[0].refs | join(",")' "$T/o.json")"
talk merge "$T/s2.json" looks "$T/o.json" "issue-7/r2-looks" > "$T/s3.json"
assert_contains "板の画像" "$(talk render "$T/s3.json" https://raw.example/x)" "https://raw.example/x/issue-7/r2-looks/look-3-1440.png"
echo '{"action":"pick","choice":"2"}' > "$T/r.json"
assert_eq "出していない方向は選べない" "clarify" "$(talk apply "$T/s3.json" "$T/r.json" | jq -r .next)"
echo '{"action":"pick","choice":"3"}' > "$T/r.json"
talk apply "$T/s3.json" "$T/r.json" | jq '.state' > "$T/s4.json"
assert_eq "方向を選ぶとざっくり画面へ" "mocks" "$(jq -r .stage "$T/s4.json")"

echo "== ざっくり画面 → 最終確認 → 作る"
echo '{"mocks":[{"title":"曲線","note":"n"},{"title":"表","note":"m"}]}' > "$T/out/mocks.json"
for k in a b; do png "$T/out/mock-$k-1440.png"; png "$T/out/mock-$k-390.png"; done
talk check mocks "$T/out" > "$T/o.json"
talk merge "$T/s4.json" mocks "$T/o.json" "issue-7/r3-mocks" > "$T/s5.json"
echo '{"action":"pick","choice":"B","note":"A の色で"}' > "$T/r.json"
talk apply "$T/s5.json" "$T/r.json" | jq '.state' > "$T/s6.json"
assert_eq "画面を選ぶと最終確認へ" "confirm b" "$(jq -r '"\(.stage) \(.mock)"' "$T/s6.json")"
echo '{"name":"tide-almanac","stack":"saas","description":"潮の暦","free":["1地点"],"paid":["比較"],"price":480,"pages":["トップ"]}' > "$T/out/confirm.json"
talk check confirm "$T/out" > "$T/o.json"
echo '{"name":"tide-almanac","stack":"saas","description":"潮の暦","price":5}' > "$T/bad/confirm.json"
talk check confirm "$T/bad" > /dev/null 2>&1; assert_eq "saas の値段が範囲外なら失敗" "1" "$?"
talk merge "$T/s6.json" confirm "$T/o.json" "issue-7/r4-confirm" > "$T/s7.json"
body=$(talk render "$T/s7.json" https://raw.example/x)
assert_contains "値段" "$body" "有料（月 480 円）"
assert_contains "選んだ画面（ざっくり画面の置き場の物）" "$body" "https://raw.example/x/issue-7/r3-mocks/mock-b-1440.png"
assert_contains "作るの案内" "$body" "作る"
echo '{"action":"go"}' > "$T/r.json"
talk apply "$T/s7.json" "$T/r.json" > "$T/a.json"
assert_eq "作る" "go" "$(jq -r .next "$T/a.json")"
jq '.state' "$T/a.json" > "$T/s8.json"
talk brief "$T/s8.json" > "$T/b.json"
assert_eq "工場へ渡す名前" "tide-almanac saas" "$(jq -r '"\(.name) \(.stack)"' "$T/b.json")"
assert_contains "選んだ画面の HTML と画像" "$(jq -r '.files | join(" ")' "$T/b.json")" "issue-7/r3-mocks/mock-b.html issue-7/r3-mocks/mock-b-1440.png"
assert_contains "選んだ方向の板" "$(jq -r '.files | join(" ")' "$T/b.json")" "issue-7/r2-looks/look-3-1440.png"
assert_contains "答えと注文を詳しいメモに" "$(jq -r .detail "$T/b.json")" "オーナーの注文（mocks）：A の色で"
assert_contains "値段を書く指示" "$(jq -r .detail "$T/b.json")" "factory-price.txt にこの数字を書く"

echo "== 見せる・待つ（publish）"
mkdir -p "$T/bin" "$T/w"
cat > "$T/bin/gh" <<'SH'
#!/usr/bin/env bash
args="$*"
echo "gh $args" >> "$FT/gh.log"
case "$args" in
  *"issues/7 --jq .title"*) echo "新サービス：潮" ;;
esac
SH
chmod +x "$T/bin/gh"
git init -q --bare "$T/assets.git"
pub() { (cd "$T/w" && env PATH="$T/bin:$PATH" FT="$T" GITHUB_REPOSITORY=o/r ISSUE=7 GH_TOKEN=x ASSETS_REMOTE="$T/assets.git" RUNNER_TEMP="$T/tmp" NTFY_TOPIC= NEXT="$1" bash "$SCRIPTS_DIR/factory-talk-publish.sh"); }
mkdir -p "$T/tmp" "$T/w/talk" "$T/w/out"
cp "$T/s2.json" "$T/w/talk/state.json"; echo '{"next":"looks","message":""}' > "$T/w/talk/route.json"
cp "$T/out/looks.json" "$T/out/look-1-1440.png" "$T/out/look-3-1440.png" "$T/w/out/"
rm -f "$T/gh.log"; pub looks > /dev/null 2>&1; code=$?
assert_eq "見せられたら 0" "0" "$code"
assert_contains "コメントを書く" "$(cat "$T/gh.log")" "issues/7/comments"
assert_contains "画像は factory-talk ブランチの URL" "$(cat "$T/gh.log")" "https://raw.githubusercontent.com/o/r/factory-talk/issue-7/r2-looks/look-1-1440.png"
assert_contains "返事を待つ印" "$(cat "$T/gh.log")" "labels[]=factory:wait"
assert_eq "画像を置いた" "issue-7/r2-looks/look-1-1440.png issue-7/r2-looks/look-3-1440.png" "$(git --git-dir="$T/assets.git" ls-tree -r --name-only factory-talk | tr '\n' ' ' | sed 's/ $//')"
rm -f "$T/w/out/"* "$T/gh.log"; pub looks > /dev/null 2>&1
assert_contains "作れなかったら、やり直せると書いて待つ" "$(cat "$T/gh.log")" "もう一回"
assert_contains "作れなかったときも印を残す" "$(cat "$T/gh.log")" "factory-talk:v1:"
echo '{"next":"clarify","message":"番号で書いてね"}' > "$T/w/talk/route.json"; rm -f "$T/gh.log"; pub clarify > /dev/null 2>&1
assert_contains "聞き直す" "$(cat "$T/gh.log")" "番号で書いてね"
cp "$T/s8.json" "$T/w/talk/state.json"; rm -f "$T/gh.log"; pub go > /dev/null 2>&1
assert_contains "作るなら Factory を動かす" "$(cat "$T/gh.log")" "actions/workflows/factory.yml/dispatches"
assert_contains "Issue の番号を渡す" "$(cat "$T/gh.log")" "inputs[issue]=7"
assert_not_contains "作り始めたら待たない" "$(cat "$T/gh.log")" "factory:wait"

finish
