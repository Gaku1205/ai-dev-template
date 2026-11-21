#!/usr/bin/env bash
# 撮影の準備：日本語のフォントが無ければ入れる（install-ja-fonts.sh）。疑似の fc-list・sudo で確かめる
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/fc-list" <<'SH'
#!/usr/bin/env bash
[ -f "$FT/has-ja" ] && echo "/usr/share/fonts/NotoSansCJK-Regular.ttc: Noto Sans CJK JP"
exit 0
SH
cat > "$T/bin/sudo" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FT/sudo.log"
[ -n "${APT_FAIL:-}" ] && exit 1
exit 0
SH
chmod +x "$T/bin/fc-list" "$T/bin/sudo"
run() { : > "$T/sudo.log"; env PATH="$T/bin:$PATH" FT="$T" "$@" bash "$SCRIPTS_DIR/install-ja-fonts.sh" 2>&1; }

echo "== もう入っていれば、何もしない"
touch "$T/has-ja"
out=$(run)
assert_contains "入っていると書く" "$out" "入っています"
assert_eq "apt を呼ばない" "" "$(cat "$T/sudo.log")"

echo "== 無ければ Noto CJK を入れる"
rm "$T/has-ja"
out=$(run)
assert_contains "入れた" "$out" "入れました"
assert_contains "fonts-noto-cjk" "$(cat "$T/sudo.log")" "install -y -qq --no-install-recommends fonts-noto-cjk"

echo "== 入れられなくても止めない（注意だけ出す）"
out=$(run APT_FAIL=1); rc=$?
assert_eq "終了コード 0" "0" "$rc"
assert_contains "注意を出す" "$out" "入れられませんでした"
echo "== JA_FONTS_CACHE：.deb を別のフォルダに置かせ、入れた後に人の物へ戻して、キャッシュに残す印を書く"
C="$T/cache"; rm -rf "$C"; : > "$T/out"
out=$(run JA_FONTS_CACHE="$C" GITHUB_OUTPUT="$T/out")
assert_contains "apt に置き場を渡す" "$(cat "$T/sudo.log")" "Dir::Cache::Archives=$C/"
assert_contains "入れた後も .deb を消させない" "$(cat "$T/sudo.log")" "APT::Keep-Downloaded-Packages=true"
assert_contains "人の物に戻す" "$(cat "$T/sudo.log")" "chown -R"
assert_eq "partial を作っておく" "yes" "$([ -d "$C/partial" ] && echo yes || echo no)"
assert_eq ".deb が無ければ、残す印は書かない" "" "$(cat "$T/out")"

echo "== キャッシュに .deb があれば、ミラーから取らないと書き、残す印を書く"
touch "$C/fonts-noto-cjk_1%3a20230817_all.deb" "$C/lock"; : > "$T/out"
out=$(run JA_FONTS_CACHE="$C" GITHUB_OUTPUT="$T/out")
assert_contains "キャッシュを使うと書く" "$out" "キャッシュにある"
assert_eq "残す印" "ja_fonts_deb=true" "$(cat "$T/out")"
assert_eq "apt の lock は残さない" "no" "$([ -f "$C/lock" ] && echo yes || echo no)"

echo "== JA_FONTS_CACHE が無ければ、今までどおり（置き場を渡さない）"
out=$(run)
assert_not_contains "置き場を渡さない" "$(cat "$T/sudo.log")" "Dir::Cache::Archives"
assert_not_contains "chown しない" "$(cat "$T/sudo.log")" "chown"

echo "== キャッシュがあっても、入れられなければ止めない"
out=$(run JA_FONTS_CACHE="$C" GITHUB_OUTPUT="$T/out" APT_FAIL=1); rc=$?
assert_eq "終了コード 0" "0" "$rc"
assert_contains "注意を出す" "$out" "入れられませんでした"
finish
