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
  */reel.png) { printf '\x89PNG\r\n\x1a\n'; head -c 2000 /dev/zero; } > "$out" ;;
  */site.jpg) { printf '\xff\xd8\xff\xe0'; head -c 2000 /dev/zero; } > "$out" ;;
  */anim.gif) { printf 'GIF89a'; head -c 2000 /dev/zero; } > "$out" ;;
  */page.html) { printf '<html>'; head -c 2000 /dev/zero; } > "$out" ;;
  *) exit 22 ;;
esac
SH
chmod +x "$T/bin/curl"
run() { (cd "$T/work" && env PATH="$T/bin:$PATH" FT="$T" GH_TOKEN=secret-token BODY="$1" bash "$SCRIPTS_DIR/fetch-issue-images.sh" 2>&1); }

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

finish
