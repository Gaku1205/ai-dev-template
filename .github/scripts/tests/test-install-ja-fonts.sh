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
finish
