#!/usr/bin/env bash
# デザインの関門と審査（design-judge.py・design-review.sh）：設計メモの形・本物の絵の枚数・lint の FAIL を測り、
# 審査役の「はい・いいえ」から、上限を当てはめた点と合格かどうかを決める。撮影と lint は疑似のコマンドで真似る
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
judge() { python3 "$SCRIPTS_DIR/design-judge.py" "$@"; }
big() { head -c 20000 /dev/zero > "$1"; }
cd "$T" || exit 1
mkdir -p talk/img

concept() { # ファイル 持ち物の数 [種類]
  {
    echo "種類: ${3:-ページ}"; echo; echo "## 持ち物"
    for i in $(seq 1 "$2"); do echo "- 物$i"; done
    echo; echo "## 考えの候補"; echo "- 古い地形図が目次になる"; echo "- 地番の札が見出しになる"; echo "- 登記の年表が背骨になる"
    echo; echo "## 考え"; echo "この画面では、古い地形図が目次になる。"
    echo; echo "## 通し表"; echo "| 欄 | 考え | 主役 | 素材 | 構図 |"; echo "| --- | --- | --- | --- | --- |"
    echo "| 最初 | a | b | c | 全面 |"; echo "| 履歴 | a | b | c | 表 |"; echo "| 料金 | a | b | c | 帯 |"
  } > "$1"
}

echo "== 関門：設計メモの形"
concept talk/concept.md 9
echo '<html><body><img src="img/a.jpg"><img src="img/b.png"><img src="img/c.webp"></body></html>' > talk/mock-a.html
big talk/img/a.jpg; big talk/img/b.png; big talk/img/c.webp
echo '[{"file":"a.jpg"},{"file":"b.png"},{"file":"c.webp"}]' > talk/img/credits.json
out=$(judge gate --concept talk/concept.md --out g.json talk/mock-a.html)
assert_contains "形が合い、本物の絵が3枚あれば通る" "$out" "ok=true"
assert_eq "本物の絵の枚数" "3" "$(jq .real g.json)"
concept talk/short.md 4
judge gate --concept talk/short.md --out g.json talk/mock-a.html > /dev/null
assert_contains "持ち物が足りない" "$(jq -r '.problems | join(" ")' g.json)" "「## 持ち物」が 4 個しかない"
printf '種類: ページ\n\n## 持ち物\n' > talk/noidea.md; for i in 1 2 3 4 5 6 7 8; do echo "- 物$i" >> talk/noidea.md; done
printf '\n## 考え\nすっきりした雑誌風にする。\n' >> talk/noidea.md
judge gate --concept talk/noidea.md --out g.json talk/mock-a.html > /dev/null
assert_contains "見た目の言葉だけの考えは通さない" "$(jq -r '.problems | join(" ")' g.json)" "「## 考え」に"
assert_contains "通し表が無い" "$(jq -r '.problems | join(" ")' g.json)" "「## 通し表」が足りない"
judge gate --concept talk/none.md --out g.json talk/mock-a.html > /dev/null
assert_contains "設計メモが無い" "$(jq -r '.problems[0]' g.json)" "設計メモ（concept.md）が無い"
printf '種類: ページ\n\n## 持ち物\n' > talk/looks.md; for i in 1 2 3 4 5 6 7 8; do echo "- 物$i" >> talk/looks.md; done
printf '\n## 考えの候補\n- 古い地形図が目次になる\n- 地番の札が見出しになる\n' >> talk/looks.md
judge gate --concept talk/looks.md --part looks --out g.json talk/mock-a.html > /dev/null
assert_contains "方向の段階：考えの候補が3つ要る" "$(jq -r '.problems | join(" ")' g.json)" "「## 考えの候補」が 2 個しかない"
judge gate --concept talk/concept.md --part looks --out g.json talk/mock-a.html > /dev/null
assert_eq "方向の段階：候補が3つあれば通る（考え・通し表はまだ見ない）" "true" "$(jq .ok g.json)"

echo "== 関門：本物の絵（出どころの記録がある物だけを数える）"
echo '[{"file":"a.jpg"}]' > talk/img/credits.json
judge gate --concept talk/concept.md --out g.json talk/mock-a.html > /dev/null
assert_eq "記録の無い画像は数えない" "1 2" "$(jq -r '"\(.real) \(.uncredited)"' g.json)"
assert_contains "足りないと知らせる" "$(jq -r '.problems[0]' g.json)" "本物の絵が 1 枚しか使われていない（3 枚以上要る）"
echo '<html><body><img src="img/a.jpg"><img src="img/none.jpg"><svg></svg></body></html>' > talk/mock-b.html
judge gate --concept talk/concept.md --out g.json talk/mock-b.html > /dev/null
assert_contains "無い画像を知らせる" "$(jq -r '.problems | join(" ")' g.json)" "画像のファイルが無い：img/none.jpg"
assert_eq "描いた絵（svg）は数に入れない" "1 1" "$(jq -r '"\(.real) \(.drawn)"' g.json)"
concept talk/app.md 9 "道具の画面"
out=$(judge gate --concept talk/app.md --min-real 4 --out g.json talk/mock-b.html)
assert_eq "道具の画面は、写真の枚数を問わない" "app 0" "$(jq -r '"\(.kind) \(.min_real)"' g.json)"
mkdir -p src public/photos
echo 'export const hero = "/photos/sea.jpg";' > src/page.tsx; big public/photos/sea.jpg
echo '- sea.jpg：海（誰か、CC0）https://example.com' > public/photos/CREDITS.md
judge gate --concept talk/concept.md --min-real 1 --out g.json src > /dev/null
assert_eq "src の中の /photos/… は public から探す（CREDITS.md の記録）" "1 true" "$(jq -r '"\(.real) \(.ok)"' g.json)"

echo "== 関門：lint の FAIL"
echo '[{"file":"a.jpg"},{"file":"b.png"},{"file":"c.webp"}]' > talk/img/credits.json
echo '{"files":1,"findings":[{"level":"FAIL","id":"mono","file":"talk/mock-a.html","line":3,"match":"font-family:monospace"},{"level":"WARN","id":"cream","file":"x","line":1,"match":"y"}]}' > lint.json
out=$(judge gate --concept talk/concept.md --lint lint.json --out g-lint.json talk/mock-a.html)
assert_contains "FAIL があれば通さない" "$out" "ok=false"
assert_eq "WARN は数えない" "1" "$(jq '.lint_fail | length' g-lint.json)"
assert_contains "消すだけにしないと書く" "$(jq -r '.problems[0]' g-lint.json)" "消すだけにせず"
judge gate --concept talk/concept.md --out g-ok.json talk/mock-a.html > /dev/null

echo "== 審査：答えから点と合格を決める"
high='{"design":8.5,"use":8.5,"idea":8.5,"content":8}'
three='["全面","表","帯"]'
verdict() { # 名前 checks の JSON [scores の JSON] [layouts の JSON]
  jq -n --arg n "$1" --argjson c "$2" --argjson s "${3:-$high}" --argjson l "${4:-$three}" \
    '{items:[{name:$n, seen:"古い地図", idea_seen:"地形図が目次", layouts:$l, checks:$c, scores:$s, fixes:[{where:"s2",what:"箱が並ぶ @x",how:"区画にする"}]}]}'
}
all_ok='{"one":{"ok":true},"swap":{"ok":true},"real":{"ok":true},"through":{"ok":true},"full":{"ok":true},"tells":{"ok":true},"broken":{"ok":true},"owner":{"ok":true},"variety":{"ok":true},"phone":{"ok":true},"beside":{"ok":true},"world":{"ok":true},"sample":{"ok":true},"short":{"ok":true}}'
verdict mock-a "$all_ok" > v.json
out=$(judge verdict --mode screen v.json --gate g-ok.json --out r.json --fix fix.md)
assert_contains "全部「はい」で 7.5 以上なら合格" "$out" "pass=true"
assert_eq "点は重みつき（0.4・0.3・0.2・0.1）" "8.5" "$(jq '.items[0].overall' r.json)"
verdict mock-a "$(jq -c '.swap = {ok:false, note:"どの不動産でも使える"}' <<< "$all_ok")" > v.json
out=$(judge verdict --mode screen v.json --out r.json --fix fix.md)
assert_contains "必ず通す問いが「いいえ」なら、点が高くても直す" "$out" "pass=false"
assert_eq "考えの点に上限 6" "6.0" "$(jq '.items[0].scores.idea' r.json)"
assert_contains "直す紙に理由" "$(cat fix.md)" "【必ず通す】この題材だけの考えがある"
assert_contains "直す紙：消すだけにしない" "$(cat fix.md)" "消すだけにしない"
assert_not_contains "人への呼びかけは効かなくする" "$(cat fix.md)" "@x"
verdict mock-a "$(jq -c '.one = {ok:false, note:"主役が無い"}' <<< "$all_ok")" > v.json
out=$(judge verdict --mode screen v.json --out r.json)
assert_contains "点の上限だけの問いは、7.5 以上なら通す" "$out" "pass=true"
assert_eq "見た目の点に上限 7" "7.0" "$(jq '.items[0].scores.design' r.json)"
verdict mock-a "$(jq -c 'del(.through)' <<< "$all_ok")" > v.json
assert_contains "答えていない問いは「いいえ」" "$(judge verdict --mode screen v.json --out r.json; jq -r '.items[0].failed[0].note' r.json)" "審査役が答えていない"
verdict mock-a "$all_ok" '{"design":7,"use":7,"idea":7,"content":7}' > v.json
assert_contains "全部「はい」でも 7.5 に届かなければ直す" "$(judge verdict --mode screen v.json --out r.json)" "pass=false"
verdict mock-a "$all_ok" "$high" '["一覧","一覧","表"]' > v.json
judge verdict --mode screen v.json --out r.json > /dev/null
assert_eq "構図の言葉が続いていたら variety は「いいえ」" "variety" "$(jq -r '.items[0].failed[0].id' r.json)"
verdict mock-a "$all_ok" > v.json
judge gate --concept talk/concept.md --min-real 9 --out g-few.json talk/mock-a.html > /dev/null
out=$(judge verdict --mode screen v.json --gate g-few.json --out r.json)
assert_contains "関門で本物の絵が足りなければ、審査役が「はい」でも直す" "$out" "pass=false"
assert_eq "real は「いいえ」になる" "real" "$(jq -r '.items[0].failed[0].id' r.json)"
out=$(judge verdict --mode screen v.json --gate g-lint.json --out r.json --fix fix.md)
assert_contains "lint の FAIL が残っていれば直す" "$out" "pass=false"
assert_eq "lint の FAIL で全体の上限 6.5" "6.5" "$(jq '.items[0].overall' r.json)"
assert_contains "直す紙に関門の指摘" "$(cat fix.md)" "## 関門（機械で測った物。全部直す）"

echo "== 審査：世界観・例の値・スマホの長さ"
verdict mock-a "$(jq -c '.world = {ok:false, note:"白地に灰色の角丸"}' <<< "$all_ok")" > v.json
out=$(judge verdict --mode screen v.json --out r.json --fix fix.md)
assert_contains "world が「いいえ」なら不合格（必ず通す）" "$out" "pass=false"
assert_eq "world の上限は見た目 6.5" "6.5" "$(jq '.items[0].scores.design' r.json)"
assert_contains "直す紙に world の名前" "$(cat fix.md)" "【必ず通す】題材の世界観が最初の1画面で伝わる"
verdict mock-a "$(jq -c '.sample = {ok:false, note:"48,600円が入っている"}' <<< "$all_ok")" > v.json
out=$(judge verdict --mode screen v.json --out r.json --fix fix.md)
assert_contains "sample が「いいえ」だけでは落ちない" "$out" "pass=true"
assert_eq "sample の上限は使いやすさ 7.0" "7.0" "$(jq '.items[0].scores.use' r.json)"
assert_contains "直す紙に sample の名前" "$(cat fix.md)" "【点の上限】例の値が入力欄に見える"
verdict mock-a "$(jq -c '.short = {ok:false, note:"縦 7,400px"}' <<< "$all_ok")" > v.json
out=$(judge verdict --mode screen v.json --out r.json)
assert_contains "short が「いいえ」だけでは落ちない" "$out" "pass=true"
assert_eq "short の上限は使いやすさ 7.0" "7.0" "$(jq '.items[0].scores.use' r.json)"
verdict mock-a "$all_ok" > v.json
judge gate --concept talk/concept.md --phone-height 7400 --out g-tall.json talk/mock-a.html > /dev/null
assert_eq "関門が縦の長さを書く" "7400" "$(jq .phone_height g-tall.json)"
judge verdict --mode screen v.json --gate g-tall.json --out r.json > /dev/null
assert_eq "5,000px 超なら、審査役が「はい」でも short は「いいえ」" "short" "$(jq -r '.items[0].failed[0].id' r.json)"
judge gate --concept talk/concept.md --phone-height 4800 --out g-tall.json talk/mock-a.html > /dev/null
assert_contains "5,000px 以下なら通る" "$(judge verdict --mode screen v.json --gate g-tall.json --out r.json)" "pass=true"
verdict mock-a "$(jq -c 'del(.world, .sample, .short)' <<< "$all_ok")" > v.json
judge verdict --mode screen v.json --out r.json > /dev/null
assert_eq "答えを飛ばした新しい問いは「いいえ」" "world sample short" "$(jq -r '[.items[0].failed[].id] | join(" ")' r.json)"
jq -n '{items:[{name:"change", checks:{fits:{ok:true},full:{ok:true},tells:{ok:true},broken:{ok:true},phone:{ok:true},world:{ok:true},sample:{ok:true},short:{ok:false,note:"長い"}}, scores:{design:8,use:8,idea:8,content:8}, fixes:[]}]}' > v.json
assert_contains "変更の審査にも新しい問いが入る" "$(judge verdict --mode change v.json --out r.json --critique critique.md)" "pass=true"
assert_contains "実装の審査の形に short の名前" "$(cat critique.md)" "スマホのページが長すぎない"

echo "== 審査：種類ごとの問い"
jq -n --argjson c '{"one":{"ok":true},"swap":{"ok":true},"real":{"ok":true},"full":{"ok":true},"tells":{"ok":true},"owner":{"ok":true},"world":{"ok":true},"sample":{"ok":true}}' \
  '{items:[1,2,3] | map({name:"look-\(.)", checks:$c, scores:{design:8,use:8,idea:8,content:8}}), set:{distinct:{ok:false, note:"3つとも同じ構図で色だけ違う"}}}' > v.json
out=$(judge verdict --mode looks v.json --out r.json --fix fix.md)
assert_contains "方向：色違いなら直す" "$out" "pass=false"
assert_contains "直す紙に全体の指摘" "$(cat fix.md)" "3つとも同じ構図で色だけ違う"
jq '.set.distinct.ok = true' v.json > v2.json
assert_contains "方向：考えから違えば通る（through などは問わない）" "$(judge verdict --mode looks v2.json --out r.json)" "pass=true"
jq -n '{items:[{name:"change", checks:{fits:{ok:false,note:"白い箱を足しただけ"},full:{ok:true},tells:{ok:true},broken:{ok:true},phone:{ok:true},world:{ok:true},sample:{ok:true},short:{ok:true}}, scores:{design:8,use:8,idea:8,content:8}, fixes:[]}]}' > v.json
out=$(judge verdict --mode change v.json --out r.json --critique critique.md)
assert_contains "変更：らしさに沿っていなければ直す" "$out" "pass=false"
assert_eq "実装の審査の形（1行目が点数）" "点数: 7.7" "$(head -1 critique.md)"
assert_eq "実装の審査の形（2行目が判定）" "判定: 直す" "$(sed -n 2p critique.md)"

echo "== 審査役が結果を書かなかった：合格とは言わない"
out=$(judge verdict --mode screen none.json --gate g-ok.json --out r-none.json)
assert_contains "none（直させない・合格とも言わない）" "$out" "pass=none"
assert_contains "見せる行" "$(judge summary r-none.json)" "審査できなかった"
out=$(judge verdict --mode screen none.json --gate g-lint.json --out r.json --fix fix.md)
assert_contains "関門が通っていなければ、関門の分は直させる" "$out" "pass=false"
echo '{"items":[{"name":"x","scores":{"design":"高い"}}]}' > bad.json
assert_contains "形の違う答えは、審査していない扱い" "$(judge verdict --mode screen bad.json --out r.json)" "pass=none"

echo "== オーナーに見せる行"
verdict mock-a "$(jq -c '.swap = {ok:false, note:"x"}' <<< "$all_ok")" > v.json; judge verdict --mode screen v.json --out r1.json > /dev/null
verdict mock-a "$all_ok" > v.json; judge verdict --mode screen v.json --out r2.json > /dev/null
line=$(judge summary r1.json r2.json)
assert_contains "1回目と直した後" "$line" "1回目 ⚠️ mock-a 8.0 点（残った指摘：この題材だけの考えがある） → 直した後 ✅ mock-a 8.5 点"

echo "== 複数の案から使う案を選ぶ（pick）"
res() { # ファイル 合格(true|false) 点 [judged]
  jq -n --argjson p "$2" --argjson s "$3" --argjson j "${4:-true}" \
    '{mode:"screen", pass:$p, judged:$j, items:(if $j then [{name:"x", pass:$p, overall:$s, failed:[], fixes:[]}] else [] end), set_failed:[], gate_ok:true}' > "$1"
}
res p0.json false 7.0; res p1.json true 7.6; res p2.json true 8.2
out=$(judge pick p0.json p1.json p2.json)
assert_contains "合格した案の中で最高点を選ぶ" "$out" "index=2"
assert_contains "合格があれば直しは要らない" "$out" "fix=false"
res p0.json false 7.4; res p1.json true 7.5
assert_contains "高い点でも不合格の案より、合格した案を優先" "$(judge pick p0.json p1.json)" "index=1"
res p0.json false 8.9; res p1.json true 7.5
assert_contains "不合格の方が点が高くても、合格を選ぶ" "$(judge pick p0.json p1.json)" "index=1"
res p0.json true 8.0; res p1.json true 8.0
assert_contains "同点は番号が小さい方" "$(judge pick p0.json p1.json)" "index=0"
res p0.json false 6.0; res p1.json false 6.8; res p2.json false 6.8
out=$(judge pick p0.json p1.json p2.json)
assert_contains "合格が無ければ最高点（同点は小さい方）" "$out" "index=1"
assert_contains "最高点が 6.8（0.7 点差）なら直さない" "$out" "fix=false"
res p0.json false 6.0; res p1.json false 5.0
out=$(judge pick p0.json p1.json)
assert_contains "最高点 6.0 は 1.5 点低い：直す" "$out" "fix=true"
assert_contains "直す対象は最高点の案" "$out" "index=0"
res p0.json false 6.1
assert_contains "1.4 点低いだけでは直さない" "$(judge pick p0.json)" "fix=false"
res p0.json false 3.0 false; res p1.json false 6.9
out=$(judge pick p0.json p1.json)
assert_contains "審査できなかった案は選ばない" "$out" "index=1"
res p0.json true 9.0 false; res p1.json false 7.0
assert_contains "審査できなかった案は、合格と書いてあっても選ばない" "$(judge pick p0.json p1.json)" "index=1"
res p0.json false 0 false; res p1.json false 0 false
out=$(judge pick p0.json p1.json none.json)
assert_contains "全部審査できなければ番号は空" "$out" "index="
assert_not_contains "番号は空（0 などを入れない）" "$out" "index=0"
assert_contains "全部審査できなければ直しは false" "$out" "fix=false"
res p0.json false 7.0; res p1.json true 7.9
line=$(judge summary --picked 1 p0.json p1.json)
assert_contains "複数案：各案の点" "$line" "案1 7.0 点 ／ 案2 7.9 点（合格）★"
assert_contains "複数案：選んだ案" "$line" "選んだ案：案2"
assert_contains "複数案：選べなかったとき" "$(judge summary --picked "" p0.json none.json)" "案2 審査できなかった → 選べる案が無かった"
res p0.json true 8.0
assert_contains "案が1つのときの表示は今までどおり" "$(judge summary p0.json)" "✅ x 8.0 点"

echo "== 審査役に渡す紙：オーナーが決めた事を入れる"
echo '{"memo":"土地の履歴","ideas":[{"title":"土地の履歴書","pitch":"p","who":"w"}],"idea":0,"look":2,"looks":[{"n":2,"title":"地図","idea":"地形図が目次になる"}],"answers":[{"q":"地図は？","a":"本物の古い地形図を重ねる"}],"notes":[{"stage":"looks","note":"朱はやめて"}]}' > state.json
b=$(judge brief --state state.json --concept talk/concept.md --stage mocks)
assert_contains "答え" "$b" "地図は？ → 本物の古い地形図を重ねる"
assert_contains "注文" "$b" "注文（looks）：朱はやめて"
assert_contains "選んだ方向" "$b" "オーナーが選んだ見た目の方向：地図"
assert_contains "設計メモは、見た後に読む" "$b" "絵を見て「見えた物」を書き終えてから読む"

echo "== design-review.sh：審査に出す物をそろえる（撮影と lint は疑似）"
mkdir -p bin talk/refs
cat > bin/shot <<'EOS'
#!/usr/bin/env bash
# 疑似の撮影：--out の先に、対象ごとの画像を作る
out=.shots; w=1440; files=()
while [ $# -gt 0 ]; do case "$1" in --out) out="$2"; shift ;; --widths) w="$2"; shift ;; --scrolls) shift ;; --serve) ;; *) files+=("$1") ;; esac; shift; done
mkdir -p "$out"
for f in "${files[@]}"; do n=$(basename "$f" .html); [ "$n" = / ] && n=top; printf 'png' > "$out/$n-$w-s1.png"; printf 'png' > "$out/$n-$w-s2.png"; done
EOS
printf '#!/usr/bin/env bash\necho %s\n' "'{\"files\":1,\"findings\":[]}'" > bin/lint
chmod +x bin/shot bin/lint
cp state.json talk/state.json
echo '<html><body><img src="img/a.jpg"><img src="img/b.png"><img src="img/c.webp"></body></html>' > talk/mock-b.html
for i in 1 2 3 4 5 6 7 8; do printf 'png' > "talk/refs/site$i-1440.png"; done; printf 'png' > talk/refs/site1-1440-s2.png
review() { SHOT="$T/bin/shot" LINT="$T/bin/lint" GITHUB_OUTPUT="$T/out.txt" bash "$SCRIPTS_DIR/design-review.sh" "$@"; }
rm -f out.txt; review prepare talk mocks > /dev/null
assert_contains "審査する物の名前" "$(cat out.txt)" "items=mock-a・mock-b"
assert_contains "審査する画像がある" "$(cat out.txt)" "ok=true"
assert_eq "PC とスマホの、下の欄まで" "8" "$(find .judge/made -name '*.png' | wc -l | tr -d ' ')"
assert_eq "比べる実例は6枚まで（スクロールの続きは入れない）" "6" "$(find .judge/refs -name '*.png' | wc -l | tr -d ' ')"
assert_eq "関門が通った" "true" "$(jq .ok .judge/gate.json)"
assert_contains "紙にオーナーの答え" "$(cat .judge/brief.md)" "本物の古い地形図を重ねる"
for k in 1 2 3; do echo '<html><img src="img/a.jpg"></html>' > "talk/look-$k.html"; printf 'png' > "talk/look-$k-1440.png"; done
rm -f out.txt; review prepare talk looks > /dev/null
assert_contains "方向の板" "$(cat out.txt)" "items=look-1・look-2・look-3"
assert_contains "方向の種類" "$(cat out.txt)" "mode=looks"
rm -f out.txt; review prepare talk mocks > /dev/null
echo "$all_ok" | jq '{items:[{name:"mock-a", checks:., scores:{design:8,use:8,idea:8,content:8}}]}' > .judge/verdict.json
rm -f out.txt; review verdict screen 1 > /dev/null
assert_contains "合格を出力に書く" "$(cat out.txt)" "pass=true"
review summary judge.md
assert_contains "まとめの行をファイルに" "$(cat judge.md)" "✅ mock-a 8.0 点"
mkdir -p mocks; cp talk/mock-a.html mocks/; cp -R talk/img mocks/img
{ echo "場合: 追加"; cat talk/concept.md; } > mocks/concept.md; echo "Issue の本文：一覧を表にして" > mocks/issue.txt
printf '#!/usr/bin/env bash\necho %s\nexit 1\n' "'{\"files\":1,\"findings\":[{\"level\":\"FAIL\",\"id\":\"mono\",\"file\":\"x\",\"line\":1,\"match\":\"m\"}]}'" > bin/lint
rm -f out.txt; BRIEF_FILE=mocks/issue.txt review prepare mocks > /dev/null
assert_contains "画面案：Issue を紙に入れる" "$(cat .judge/brief.md)" "一覧を表にして"
assert_eq "今ある見た目への追加は、lint の FAIL では止めない（docs/design.md が上）" "true" "$(jq .ok .judge/gate.json)"
sed -i 's/^場合: 追加/場合: 作り直し/' mocks/concept.md
rm -f out.txt; BRIEF_FILE=mocks/issue.txt review prepare mocks > /dev/null
assert_eq "作り直しは、lint の FAIL で止める" "false" "$(jq .ok .judge/gate.json)"

finish
