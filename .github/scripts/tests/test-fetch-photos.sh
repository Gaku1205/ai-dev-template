#!/usr/bin/env bash
# 工場のデザイン担当が写真を取ってくる（fetch-photos.sh）
# Openverse は、このテストの中の疑似 curl で真似る（本物のネットワークには出ない）
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/work"
cat > "$T/bin/curl" <<'SH'
#!/usr/bin/env bash
echo "curl $*" >> "$FT/calls.log"
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; https://*|http://*) url="$1"; shift ;; *) shift ;; esac
done
case "$url" in
  */v1/images/) [ -f "$FT/ov.fail" ] && exit 7; cat "$FT/api.json" ;;
  */w/api.php) cat "$FT/commons.json" ;;
  */good*.jpg) { printf '\xff\xd8\xff\xe0'; head -c 20000 /dev/zero; } > "$out" ;;
  */good*.png) { printf '\x89PNG\r\n\x1a\n'; head -c 20000 /dev/zero; } > "$out" ;;
  */fake.jpg) { printf '<html>not an image</html>'; head -c 20000 /dev/zero; } > "$out" ;;
  */tiny.jpg) printf '\xff\xd8\xff\xe0tiny' > "$out" ;;
  *) exit 22 ;;
esac
SH
chmod +x "$T/bin/curl"
run() { (cd "$T/work" && env PATH="$T/bin:$PATH" FT="$T" OPENVERSE_API=https://api.test COMMONS_API=https://commons.test/w/api.php bash "$SCRIPTS_DIR/fetch-photos.sh" "$@" 2>&1); }
api() { printf '%s' "$1" > "$T/api.json"; }

echo "== CC0・パブリックドメインで、横幅 1200px 以上の本物の画像だけを入れ、出どころを残す"
api '{"results":[
 {"url":"https://img.test/good1.jpg","title":"Night river","creator":"A","license":"cc0","foreign_landing_url":"https://src.test/1","width":2400,"height":1600},
 {"url":"https://img.test/small.jpg","title":"Small","creator":"B","license":"cc0","width":800,"height":600},
 {"url":"https://img.test/byncsa.jpg","title":"NC","creator":"C","license":"by-nc-sa","width":3000,"height":2000},
 {"url":"https://img.test/fake.jpg","title":"Fake","creator":"D","license":"pdm","width":3000,"height":2000},
 {"url":"https://img.test/tiny.jpg","title":"Tiny","creator":"E","license":"pdm","width":3000,"height":2000},
 {"url":"http://img.test/good-http.jpg","title":"Plain http","creator":"F","license":"cc0","width":3000,"height":2000},
 {"url":"https://img.test/good2.png","title":"Lanterns","creator":"G","license":"pdm","foreign_landing_url":"https://src.test/2","width":1600,"height":1200}]}'
out=$(run "Night Street, Fukuoka!" 4)
assert_contains "取った枚数を書く" "$out" "2 枚取りました"
assert_eq "入った写真" "01-night-street-fukuoka.jpg 02-night-street-fukuoka.png" "$(cd "$T/work/public/photos" && find . -maxdepth 1 \( -name "*.jpg" -o -name "*.png" \) -printf "%f\n" | sort | paste -sd " ")"
credits=$(cat "$T/work/public/photos/CREDITS.md")
assert_contains "出どころ（CC0）" "$credits" '`01-night-street-fukuoka.jpg`：Night river（A、CC0、2400×1600）https://src.test/1'
assert_contains "出どころ（パブリックドメイン）" "$credits" "パブリックドメイン"
assert_contains "ライセンスを絞って探す" "$(cat "$T/calls.log")" "license=cc0,pdm"

echo "== 続けて取ると番号が続く。合わせて 20 枚まで"
api '{"results":[{"url":"https://img.test/good3.jpg","title":"x","creator":"x","license":"cc0","width":2000,"height":1000}]}'
run "lantern" 1 > /dev/null
assert_eq "番号が続く" "yes" "$([ -f "$T/work/public/photos/03-lantern.jpg" ] && echo yes || echo no)"
for i in $(seq 4 20); do printf 'x' > "$T/work/public/photos/$(printf %02d "$i")-x.jpg"; done
out=$(run "more" 1); code=$?
assert_eq "20 枚あれば取らない" "1" "$code"
assert_contains "そう書く" "$out" "もう 20 枚あります"

echo "== 使い方の間違い・見つからない"
rm -rf "$T/work/public"
out=$(run "" 2); assert_eq "検索語が無い" "2" "$?"
run "x" 9 > /dev/null; assert_eq "枚数は 1〜6" "2" "$?"
api '{"results":[]}'
out=$(run "nothing" 2); code=$?
assert_eq "見つからなければ失敗" "1" "$code"
assert_contains "検索語を変えるよう書く" "$out" "検索語を変えてください"

echo "== Openverse に届かない・見つからないときは、Wikimedia Commons で CC0・パブリックドメインの物だけを取る"
rm -rf "$T/work/public"
printf '%s' '{"query":{"pages":[
 {"index":2,"title":"File:Linen weave.jpg","imageinfo":[{"url":"https://upload.test/good5.jpg","thumburl":"https://upload.test/thumb/good5.jpg","descriptionurl":"https://commons.test/wiki/File:Linen_weave.jpg","width":4000,"height":3000,"mime":"image/jpeg","extmetadata":{"LicenseShortName":{"value":"CC0"},"Artist":{"value":"<a href=\"x\">Mori</a>"}}}]},
 {"index":1,"title":"File:Old harbor.png","imageinfo":[{"url":"https://upload.test/good6.png","descriptionurl":"https://commons.test/wiki/File:Old_harbor.png","width":1600,"height":900,"mime":"image/png","extmetadata":{"LicenseShortName":{"value":"Public domain"}}}]},
 {"index":3,"title":"File:By-sa.jpg","imageinfo":[{"url":"https://upload.test/good7.jpg","width":4000,"height":3000,"mime":"image/jpeg","extmetadata":{"LicenseShortName":{"value":"CC BY-SA 4.0"}}}]},
 {"index":4,"title":"File:Small.jpg","imageinfo":[{"url":"https://upload.test/good8.jpg","width":800,"height":600,"mime":"image/jpeg","extmetadata":{"LicenseShortName":{"value":"CC0"}}}]},
 {"index":5,"title":"File:Map.svg","imageinfo":[{"url":"https://upload.test/good9.jpg","width":4000,"height":3000,"mime":"image/svg+xml","extmetadata":{"LicenseShortName":{"value":"CC0"}}}]}]}}' > "$T/commons.json"
touch "$T/ov.fail"
: > "$T/calls.log"
out=$(run "linen" 6)
assert_contains "Commons から取った" "$out" "2 枚取りました"
assert_eq "並びは検索の順、縮めた物（thumburl）を取る" "01-linen.png 02-linen.jpg" "$(cd "$T/work/public/photos" && find . -maxdepth 1 -type f ! -name CREDITS.md -printf "%f\n" | sort | paste -sd ' ')"
assert_contains "縮めた物を取る" "$(cat "$T/calls.log")" "https://upload.test/thumb/good5.jpg"
credits=$(cat "$T/work/public/photos/CREDITS.md")
assert_contains "出どころ（パブリックドメイン）" "$credits" '`01-linen.png`：Old harbor（不明、パブリックドメイン、1600×900）https://commons.test/wiki/File:Old_harbor.png'
assert_contains "出どころ（CC0、作者の HTML は消す）" "$credits" '`02-linen.jpg`：Linen weave（Mori、CC0、4000×3000）'
assert_not_contains "CC BY-SA は取らない" "$(cat "$T/calls.log")" "good7"
rm -f "$T/ov.fail"
rm -rf "$T/work/public"
api '{"results":[]}'
out=$(run "linen" 1)
assert_contains "Openverse で見つからなくても Commons で探す" "$out" "1 枚取りました"

finish
