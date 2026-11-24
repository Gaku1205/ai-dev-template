#!/usr/bin/env bash
# AIへの指示の組み立て（compose-prompt.sh）：mode と、リポジトリの条件で、要る部品だけが入る
source "$(dirname "$0")/lib.sh"
C="$SCRIPTS_DIR/compose-prompt.sh"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
cd "$dir" || exit 1

# 部品ごとの目印の語句
BASE="コマンドは1つずつ動かす"
READ="「読む所」の見出しがあれば"
MERGE="git merge origin/main"
VIS="visual:update ラベルで基準の画像を撮り直して"
RUN="npm run test:visual -- -g テスト名"
DIFF=".visual-diff/ に画像があるとき"
PRB=".pr-body.md"
PONY="作りすぎない（ponytail の決まり"

echo "== implement：全部入りでも pr-body と visual-diff は入らない"
out=$(bash "$C" --mode implement --visual-tests --docs)
assert_contains "base" "$out" "$BASE"
assert_contains "read-sections" "$out" "$READ"
assert_contains "merge-main" "$out" "$MERGE"
assert_contains "visual-tests" "$out" "$VIS"
assert_not_contains "pr-body は入らない" "$out" "$PRB"
assert_not_contains "visual-diff は入らない" "$out" "$DIFF"

echo "== mention：全部入りは pr-body と visual-diff も入る"
out=$(bash "$C" --mode mention --visual-tests --docs)
assert_contains "base" "$out" "$BASE"
assert_contains "read-sections" "$out" "$READ"
assert_contains "merge-main" "$out" "$MERGE"
assert_contains "visual-tests" "$out" "$VIS"
assert_contains "visual-diff" "$out" "$DIFF"
assert_contains "pr-body" "$out" "$PRB"

echo "== 全部入りに、元のワークフローの要の語句が残っている"
for w in "; や && や | でつなぐ" "ファイルを読むのは Read、探すのは Grep・Glob" "Read の offset と limit でその節だけを読む" "今までどおり全部読む" \
  "古い main のままの push は GitHub に拒否される" "両方の変更を残して解消する" "git checkout --theirs -- パス" "tests/visual/ の png" \
  ".github/ のファイルは自分では変えない" "$RUN" "基準の画像の撮り直しはしない" "〜-diff.png が違う所" "頼まれていない崩れ" \
  ".visual-diff/ はコミットしない" "gh pr edit 番号 --body-file .pr-body.md" ".pr-body.md はコミットしない" "gh issue view 番号"; do
  assert_contains "mention に「$w」" "$out" "$w"
done

echo "== 見た目のテストが無い：visual-tests / visual-diff は入らない"
for m in implement mention; do
  out=$(bash "$C" --mode "$m" --docs)
  assert_not_contains "$m：visual-tests が入らない" "$out" "$VIS"
  assert_not_contains "$m：test:visual の実行の案内が入らない" "$out" "$RUN"
  assert_not_contains "$m：visual-diff が入らない" "$out" "$DIFF"
done
assert_contains "mention でも pr-body は入る" "$(bash "$C" --mode mention)" "$PRB"

echo "== --docs が無い：read-sections は入らない"
for m in implement mention; do
  out=$(bash "$C" --mode "$m" --visual-tests)
  assert_not_contains "$m：read-sections が入らない" "$out" "$READ"
  assert_contains "$m：merge-main は入る" "$out" "$MERGE"
done

echo "== 作りすぎない決まり（ponytail）は、implement にも mention にも、条件によらず入る"
for m in implement mention; do
  assert_contains "$m：ponytail が入る" "$(bash "$C" --mode "$m")" "$PONY"
  assert_contains "$m（全部入り）：ponytail が入る" "$(bash "$C" --mode "$m" --visual-tests --docs)" "$PONY"
done
out=$(bash "$C" --mode implement)
assert_contains "削らない物に design.md の見た目が入っている" "$out" "docs/design.md に書かれた見た目"
assert_not_contains "ワークフローの引数を壊す二重引用符が無い" "$(cat "$SCRIPTS_DIR/prompts/ponytail.md")" '"'

echo "== 引数の誤り"
bash "$C" --mode other > /dev/null 2>&1
assert_eq "知らない mode は失敗" "2" "$?"
bash "$C" --mode implement --foo > /dev/null 2>&1
assert_eq "知らない引数は失敗" "2" "$?"

echo "== 作業フォルダからの判定（--auto）"
has_vis() { bash -c "source '$C'; compose_has_visual_tests && echo yes || echo no"; }
has_docs() { bash -c "source '$C'; compose_has_long_docs && echo yes || echo no"; }
assert_eq "何も無ければ見た目のテストは無い" "no" "$(has_vis)"
assert_eq "何も無ければ長い仕様書は無い" "no" "$(has_docs)"
echo '{"scripts":{"test:visual":"playwright test"}}' > package.json
assert_eq "package.json の test:visual" "yes" "$(has_vis)"
echo '{"scripts":{"test":"vitest run"}}' > package.json
assert_eq "test:visual が無ければ無い" "no" "$(has_vis)"
echo '{"checks":[{"name":"見た目","run":"npm run test:visual"}]}' > pipeline.json
assert_eq "pipeline.json の checks の test:visual" "yes" "$(has_vis)"
rm pipeline.json package.json
mkdir docs
seq 1 199 > docs/spec.md
assert_eq "仕様書が199行なら短い" "no" "$(has_docs)"
seq 1 200 > docs/spec.md
assert_eq "仕様書が200行なら長い" "yes" "$(has_docs)"
out=$(bash "$C" --mode implement --auto)
assert_contains "--auto：長い仕様書で read-sections" "$out" "$READ"
assert_not_contains "--auto：見た目のテストが無ければ visual-tests なし" "$out" "$VIS"
rm docs/spec.md
assert_not_contains "--auto：仕様書が無ければ read-sections なし" "$(bash "$C" --mode implement --auto)" "$READ"

# 書き換えはスクリプトでしない（#550：python3 で docs/spec.md を書き換えようとして止まった）
assert_contains "implement に「書き換えは Edit・Write だけ」" "$(bash "$C" --mode implement)" "ファイルの書き換えは Edit・Write だけで行う"

finish
