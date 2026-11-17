#!/usr/bin/env bash
# 工場：Issue に貼られた画像を、デザイン担当の参考として取ってくる（fetch-issue-images.sh）
# 画像のサイトは、このテストの中の疑似 curl で真似る（本物のネットワークには出ない）
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/work"
cat > "$T/bin/curl" <<'SH'
#!/usr/bin/env bash
echo "curl $*" >> "$FT/calls.log"
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; https://*) url="$1"; shift ;; *) shift ;; esac
done
case "$url" in
  "https://api.github.com/repos/me/app/contents/images/2026-11/abc.png?ref=issue-images") { printf '\x89PNG\r\n\x1a\n'; head -c 2000 /dev/zero; } > "$out" ;;
  "https://api.github.com/repos/me/app/contents/images/2026-11/s%20p.jpg?ref=issue-images") { printf '\xff\xd8\xff\xe0'; head -c 2000 /dev/zero; } > "$out" ;;
  *"site.jpg?size[w]=1") { printf '\xff\xd8\xff\xe0'; head -c 2000 /dev/zero; } > "$out" ;;
  */reel.png) { printf '\x89PNG\r\n\x1a\n'; head -c 2000 /dev/zero; } > "$out" ;;
  */site.jpg) { printf '\xff\xd8\xff\xe0'; head -c 2000 /dev/zero; } > "$out" ;;
  */anim.gif) { printf 'GIF89a'; head -c 2000 /dev/zero; } > "$out" ;;
  */page.html) { printf '<html>'; head -c 2000 /dev/zero; } > "$out" ;;
  *) exit 22 ;;
esac
SH
chmod +x "$T/bin/curl"
run() { (cd "$T/work" && env PATH="$T/bin:$PATH" FT="$T" GH_TOKEN=secret-token GITHUB_REPOSITORY=me/app BODY="$1" bash "$SCRIPTS_DIR/fetch-issue-images.sh" 2>&1); }

echo "== 貼られた画像を順に取る。github.com にだけ鍵を付ける"
body='こういう雰囲気にしたい
![reel](https://github.com/user-attachments/assets/reel.png)
<img width="300" src="https://cdn.example.com/site.jpg" alt="x">
同じ物をもう一度 ![again](https://github.com/user-attachments/assets/reel.png)
![gif](https://github.com/user-attachments/assets/anim.gif)
![not image](https://example.com/page.html)
![gone](https://example.com/missing.png)
ただのリンク https://example.com/inspiration は画像ではない
![http](http://example.com/site.jpg)'
out=$(run "$body")
assert_contains "枚数を書く" "$out" "3 枚取りました"
assert_eq "入った画像" "01.png 02.jpg 03.gif" "$(cd "$T/work/factory-refs/issue" && ls -- *.png *.jpg *.gif | sort | paste -sd ' ')"
assert_contains "出どころを残す" "$(cat "$T/work/factory-refs/issue/INDEX.md")" '`02.jpg`：https://cdn.example.com/site.jpg'
assert_eq "github.com には鍵を付ける" "1" "$(grep 'user-attachments/assets/reel.png' "$T/calls.log" | grep -c 'secret-token')"
assert_eq "ほかのサイトには鍵を送らない" "0" "$(grep 'cdn.example.com' "$T/calls.log" | grep -c 'secret-token')"
assert_eq "http は取らない" "0" "$(grep -c 'http://example.com' "$T/calls.log")"
assert_contains "画像でない物は入れない" "$out" "画像ではありません：https://example.com/page.html"

echo "== 画像が無い・10 枚まで"
rm -rf "$T/work/factory-refs"
out=$(run "画像なしのメモ"); code=$?
assert_eq "画像が無くても成功" "0" "$code"
assert_eq "置き場を作らない" "no" "$([ -d "$T/work/factory-refs" ] && echo yes || echo no)"
many=""; for i in $(seq 1 14); do many="$many ![a](https://github.com/user-attachments/assets/$i/reel.png)"; done
out=$(run "$many")
assert_contains "10 枚まで" "$out" "10 枚取りました"

echo "== このリポジトリのファイルの画像（issue-images ブランチ）は Contents API で取る（非公開でも取れる）"
rm -rf "$T/work/factory-refs"; : > "$T/calls.log"
body='![スクショ](https://github.com/me/app/raw/issue-images/images/2026-11/abc.png)
![b](https://raw.githubusercontent.com/me/app/issue-images/images/2026-11/s%20p.jpg)
![blob](https://github.com/me/app/blob/issue-images/images/2026-11/abc.png?raw=true)
![other](https://github.com/someone/else/raw/main/x.png)
![up](https://github.com/me/app/raw/issue-images/../secret.png)'
out=$(run "$body")
assert_contains "3 枚取れる（同じ画像も URL が違えば取る）" "$out" "3 枚取りました"
assert_eq "Contents API で取る（鍵は api.github.com へ）" "3" "$(grep 'https://api.github.com/repos/me/app/contents/' "$T/calls.log" | grep -c 'Bearer secret-token')"
assert_eq "このリポジトリの画像は、貼られた URL を直接は取らない" "0" "$(grep '^curl' "$T/calls.log" | grep -v secret.png | grep -c 'github.com/me/app\|raw.githubusercontent.com/me/app')"
assert_eq "ほかのリポジトリの画像は今までどおり curl" "1" "$(grep '^curl' "$T/calls.log" | grep -c 'someone/else')"
assert_eq "../ を含む道は Contents API に渡さない" "0" "$(grep 'api.github.com' "$T/calls.log" | grep -c 'secret.png')"
: > "$T/calls.log"
out=$(run '![x](https://github.com/me/app/raw/issue-images/images/2026-11/missing.png)'); code=$?
assert_eq "取れなくても成功" "0" "$code"
assert_contains "取れなかったと書く" "$out" "取れませんでした：https://github.com/me/app/raw/issue-images/images/2026-11/missing.png"

echo "== 題つきの画像・[ ] を含む URL も取る"
rm -rf "$T/work/factory-refs"; : > "$T/calls.log"
out=$(run '![t](https://github.com/user-attachments/assets/reel.png "題") ![q](https://cdn.example.com/x/site.jpg?size[w]=1)')
assert_contains "2 枚" "$out" "2 枚取りました"
assert_eq "curl は -g（[ ] を範囲と読まない）" "2" "$(grep -c '^curl -gsSL' "$T/calls.log")"

finish
