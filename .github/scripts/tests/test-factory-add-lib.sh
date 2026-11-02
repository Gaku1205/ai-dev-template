#!/usr/bin/env bash
# 工場のデザイン担当が、動き・3D の道具をその場で入れる（factory-add-lib.sh）
# npm はこのテストの中の疑似 npm で真似る（本物のネットワークには出ない）
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/work"
cat > "$T/npm" <<'SH'
#!/usr/bin/env bash
echo "npm $*" >> "$FT/npm.log"
[ -f "$FT/npm.fail" ] && exit 1
exit 0
SH
chmod +x "$T/npm"
run() { (cd "$T/work" && env FT="$T" NPM="$T/npm" bash "$SCRIPTS_DIR/factory-add-lib.sh" "$@" 2>&1); }

echo "== 決まった物だけを、インストール時のスクリプトを動かさずに入れ、factory-libs.txt に名前を残す"
out=$(run @react-three/drei gsap); code=$?
assert_eq "入れられた" "0" "$code"
assert_contains "書く" "$out" "入れました"
log=$(cat "$T/npm.log")
assert_contains "スクリプトを動かさない" "$log" "--ignore-scripts"
assert_contains "3D は three と型も入る" "$log" "@react-three/drei@^10 @react-three/fiber@^9 @types/three@^0 gsap@^3 three@^0"
assert_eq "名前を残す" "@react-three/drei gsap" "$(paste -sd ' ' "$T/work/factory-libs.txt")"
run gsap > /dev/null
assert_eq "同じ名前は二度書かない" "2" "$(wc -l < "$T/work/factory-libs.txt" | tr -d ' ')"

echo "== 決まった物以外・使い方の間違い・失敗"
: > "$T/npm.log"
out=$(run left-pad); code=$?
assert_eq "知らない名前は入れない" "2" "$code"
assert_contains "入れられる物を書く" "$out" "gsap・@gsap/react・lenis・motion"
assert_eq "npm を呼ばない" "" "$(cat "$T/npm.log")"
out=$(run "gsap; rm -rf /"); assert_eq "名前に混ぜた物も入れない" "2" "$?"
out=$(run); assert_eq "名前が無い" "2" "$?"
touch "$T/npm.fail"
out=$(run lenis); code=$?
assert_eq "npm が失敗したら 1" "1" "$code"
assert_eq "失敗したら名前を残さない" "no" "$(grep -qx lenis "$T/work/factory-libs.txt" && echo yes || echo no)"

finish
