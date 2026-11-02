#!/usr/bin/env bash
# 工場の design ジョブ：デザイン担当が作った画面で、確認コマンドをもう一度動かす（factory-checks.sh）
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
W="$T/work"; mkdir -p "$W/src/app"
(cd "$W" && git init -q && echo 'export default 1' > src/app/page.tsx && git add -A && git -c user.name=t -c user.email=t@t commit -q -m init)
cat > "$T/npm" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FT/npm.log"
[ "$2" = "${FAIL_AT:-none}" ] && { echo "Type error: src/app/page.tsx"; exit 1; }
exit 0
SH
chmod +x "$T/npm"
run() { : > "$T/out"; : > "$T/npm.log"; (cd "$W" && env FT="$T" NPM="$T/npm" GITHUB_OUTPUT="$T/out" "$@" bash "$SCRIPTS_DIR/factory-checks.sh" 2>&1); }

echo "== src/ が雛形のままなら、作れなかった扱い（確認コマンドも動かさない）"
run > /dev/null
assert_eq "出力" "site=false ok=false" "$(paste -sd ' ' "$T/out")"
assert_eq "動かさない" "" "$(cat "$T/npm.log")"

echo "== 作り変えて全部通れば ok"
echo 'export default 2' > "$W/src/app/page.tsx"
mkdir -p "$W/src/components" && echo 'x' > "$W/src/components/Hero.tsx"
out=$(run)
assert_eq "出力" "site=true ok=true" "$(paste -sd ' ' "$T/out")"
assert_eq "4つを順に" "run typecheck run lint run test run build" "$(paste -sd ' ' "$T/npm.log")"
assert_eq "記録は残さない" "no" "$([ -f "$W/factory-checks.log" ] && echo yes || echo no)"

echo "== 通らなければ止めて、直す AI のために出力を残す"
out=$(run FAIL_AT=lint)
assert_eq "出力" "site=true ok=false" "$(paste -sd ' ' "$T/out")"
assert_eq "失敗した所で止める" "run typecheck run lint" "$(paste -sd ' ' "$T/npm.log")"
assert_contains "記録を残す" "$(cat "$W/factory-checks.log")" "Type error: src/app/page.tsx"
assert_contains "何が通らなかったか書く" "$out" "npm run lint が通りませんでした"

finish
