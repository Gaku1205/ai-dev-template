#!/usr/bin/env bash
# run-all.sh：テストのファイルを並べて動かしても、結果はファイル名の順に、今までと同じ形で出す。
# （1本ずつ動かしていたときは、CI の時間切れ（10分）に届いて、PRが止まった）
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# 偽のテストを置いたフォルダを作り、そこに run-all.sh の写しを置いて動かす（本物のテストは動かさない）
new_dir() { rm -rf "$T/t"; mkdir -p "$T/t"; cp "$TESTS_DIR/run-all.sh" "$T/t/"; }
fake() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$T/t/$1"; }
run_all() { out=$(env "$@" bash "$T/t/run-all.sh" 2>&1); rc=$?; }

echo "== 全部通る：1本1行（最後の行）を、ファイル名の順に出す"
new_dir
# a は b が始まるまで終わらない（並べて動かしていなければ、ここで時間切れになって落ちる）
fake test-a.sh "for _ in \$(seq 1 100); do [ -f '$T/b-started' ] && break; sleep 0.1; done; [ -f '$T/b-started' ] || { echo 'b が始まらない'; exit 1; }; echo 途中の行; echo 'a：成功 1 / 失敗 0'"
fake test-b.sh "touch '$T/b-started'; echo 'b：成功 2 / 失敗 0'"
fake test-c.sh "echo 'c：成功 3 / 失敗 0'"
run_all TEST_JOBS=2
assert_eq "終了コード 0" "0" "$rc"
assert_eq "出力の形と順番（先に終わった b・c を、a より前に出さない）" "### test-a.sh：a：成功 1 / 失敗 0
### test-b.sh：b：成功 2 / 失敗 0
### test-c.sh：c：成功 3 / 失敗 0
全部のテストが通りました" "$out"

echo "== 1つ落ちる：落ちた物だけ中身を全部出し、残りも動かして、失敗で終わる"
new_dir
fake test-a.sh "echo 'a：成功 1 / 失敗 0'"
fake test-b.sh "echo '  FAIL 何か'; echo 'b：成功 0 / 失敗 1'; exit 1"
fake test-c.sh "echo 途中の行; echo 'c：成功 3 / 失敗 0'"
run_all TEST_JOBS=2
assert_eq "終了コード 1" "1" "$rc"
assert_eq "出力の形" "### test-a.sh：a：成功 1 / 失敗 0
### test-b.sh（失敗）
  FAIL 何か
b：成功 0 / 失敗 1
### test-c.sh：c：成功 3 / 失敗 0
テストに失敗した物があります" "$out"

echo "== TEST_JOBS=1 なら1本ずつ（結果は同じ）"
run_all TEST_JOBS=1
assert_eq "終了コード 1" "1" "$rc"
assert_contains "落ちた物の中身" "$out" "  FAIL 何か"
assert_contains "後ろのテストも動く" "$out" "### test-c.sh：c：成功 3 / 失敗 0"

echo "== TEST_JOBS が無ければ CPU の数で動く"
fake test-b.sh "echo 'b：成功 2 / 失敗 0'"
run_all -u TEST_JOBS
assert_eq "終了コード 0" "0" "$rc"
assert_contains "全部通る" "$out" "全部のテストが通りました"

echo "== TEST_JOBS が数でなければ、動かさずに失敗で終わる"
for bad in 0 abc 2x; do
  run_all TEST_JOBS="$bad"
  assert_eq "TEST_JOBS=$bad：終了コード 1" "1" "$rc"
  assert_contains "TEST_JOBS=$bad：理由を言う" "$out" "TEST_JOBS は1以上の数にしてください"
done

echo "== 何本も同時に動いても、出力が混ざらない（1本ごとに別のファイルに受ける）"
new_dir
for i in 1 2 3 4 5 6; do fake "test-n$i.sh" "for k in 1 2 3; do echo 行\$k; done; echo 'n$i：成功 1 / 失敗 0'"; done
run_all TEST_JOBS=6
assert_eq "6本とも1行ずつ、順に" "### test-n1.sh：n1：成功 1 / 失敗 0
### test-n2.sh：n2：成功 1 / 失敗 0
### test-n3.sh：n3：成功 1 / 失敗 0
### test-n4.sh：n4：成功 1 / 失敗 0
### test-n5.sh：n5：成功 1 / 失敗 0
### test-n6.sh：n6：成功 1 / 失敗 0
全部のテストが通りました" "$out"

echo "== 並べて動かすので、pipefail のスクリプトは、変数の中身を printf | grep -q で探さない（混むと、書く側が切られて「無い」になる）"
bad_lines=""
for f in "$SCRIPTS_DIR"/*.sh; do
  grep -qE '^set -[a-z]*o pipefail' "$f" || continue
  hits=$(grep -nE "printf '%s(\\\\n)?' \"[^\"]*\" \| grep -[a-zA-Z]*q" "$f" || true)
  [ -n "$hits" ] && bad_lines="$bad_lines$(basename "$f")：$hits"$'\n'
done
assert_eq "pipefail のスクリプトに printf | grep -q が無い（grep -q … <<< \"\$変数\" にする）" "" "$bad_lines"

finish
