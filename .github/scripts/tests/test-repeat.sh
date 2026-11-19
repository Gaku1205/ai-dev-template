#!/usr/bin/env bash
# repeat.sh（テストを続けて何回も回す）のテスト
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
R="$TESTS_DIR/repeat.sh"

echo "== 全部通る =="
printf 'echo run >> "%s/count"\n' "$W" > "$W/ok.sh"
out=$(bash "$R" "$W/ok.sh" 3); rc=$?
assert_eq "終了コード 0" 0 "$rc"
assert_contains "回数を1行で出す" "$out" "3回中3回通った"
assert_eq "3回動かした" 3 "$(grep -c run "$W/count")"

echo "== 途中で落ちる =="
# 2回目で落ちる（落ちた回の出力を出し、後ろは動かさない）
cat > "$W/ng.sh" <<EOF
echo run >> "$W/count2"
n=\$(grep -c run "$W/count2")
echo "これは\${n}回目の出力"
[ "\$n" -lt 2 ]
EOF
out=$(bash "$R" "$W/ng.sh" 5); rc=$?
assert_eq "終了コード 1" 1 "$rc"
assert_contains "何回目で落ちたかを出す" "$out" "5回中 2回目で落ちた"
assert_contains "落ちた回の出力を出す" "$out" "これは2回目の出力"
assert_eq "落ちた所で止まる" 2 "$(grep -c run "$W/count2")"

echo "== 使い方の間違い =="
bash "$R" "$W/ok.sh" > /dev/null 2>&1; rc=$?
assert_eq "引数が足りない" 2 "$rc"
bash "$R" "$W/none.sh" 3 > /dev/null 2>&1; rc=$?
assert_eq "ファイルが無い" 2 "$rc"
bash "$R" "$W/ok.sh" x > /dev/null 2>&1; rc=$?
assert_eq "回数が数でない" 2 "$rc"
bash "$R" "$W/ok.sh" 0 > /dev/null 2>&1; rc=$?
assert_eq "回数が 0" 2 "$rc"

finish
