#!/usr/bin/env bash
# 企画AI・実装AIの前に、Issue の本文の画像を取ってきて、AIへの一言を作る（issue-images-prompt.sh）
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/work/.git/info"
cat > "$T/bin/curl" <<'SH'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; https://*) url="$1"; shift ;; *) shift ;; esac; done
case "$url" in
  *"contents/images/a.png?ref=issue-images") { printf '\x89PNG\r\n\x1a\n'; head -c 2000 /dev/zero; } > "$out" ;;
  *) exit 22 ;;
esac
SH
chmod +x "$T/bin/curl"
run() { # body dir role
  rm -f "$T/out"
  (cd "$T/work" && env PATH="$T/bin:$PATH" GH_TOKEN=x GITHUB_REPOSITORY=me/app GITHUB_OUTPUT="$T/out" BODY="$1" bash "$SCRIPTS_DIR/issue-images-prompt.sh" "$2" "$3" > /dev/null 2>&1)
  cat "$T/out"
}

echo "== 画像があれば、置き場所と枚数を伝える。企画には本文に画像を残すよう頼む"
out=$(run '直したい ![s](https://github.com/me/app/raw/issue-images/images/a.png)' issue-images plan)
assert_contains "置き場所と枚数" "$out" "Issue の本文に貼られた画像（1枚）を issue-images/ に置いた"
assert_contains "企画：本文に画像を残す" "$out" "画像の行（![..](..)）を消さずに残す"
assert_eq "画像が入る" "yes" "$([ -f "$T/work/issue-images/01.png" ] && echo yes || echo no)"
assert_contains "コミットしない" "$(cat "$T/work/.git/info/exclude")" "/issue-images/"
assert_eq "1行だけ（GITHUB_OUTPUT が壊れない）" "1" "$(wc -l < "$T/out" | tr -d ' ')"
assert_not_contains "URL を指示に混ぜない" "$out" "https://"

echo "== 実装：残す頼みは無い。取れなかった画像は枚数だけ伝え、止めない"
out=$(run '![s](https://github.com/me/app/raw/issue-images/images/a.png) ![x](https://github.com/me/app/raw/issue-images/images/gone.png)' .shots/issue implement); code=$?
assert_eq "止めない" "0" "$code"
assert_contains "置き場所" "$out" "を .shots/issue/ に置いた"
assert_not_contains "実装には残す頼みは無い" "$out" "消さずに残す"
assert_contains "取れなかった枚数" "$out" "1枚は取れなかった"

echo "== 画像が無ければ、何も言わない"
out=$(run '画像なしのメモ' issue-images2 plan)
assert_eq "空の一言" "prompt=" "$out"
assert_eq "置き場所を作らない" "no" "$([ -d "$T/work/issue-images2" ] && echo yes || echo no)"

finish
