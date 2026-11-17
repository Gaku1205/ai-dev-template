#!/usr/bin/env bash
# run-as-app.sh：形の違う見本のアプリ（app-fixtures/）それぞれで、配布→run-all.sh→shellcheck を回し、落ちた見本の名前を出すことを確かめる。
# 配り先には app-fixtures も run-as-app.sh も配らない（配り先で動くと再帰するので、無ければ飛ばす）
source "$(dirname "$0")/lib.sh"
if [ ! -d "$TESTS_DIR/app-fixtures" ] || [ ! -f "$TESTS_DIR/run-as-app.sh" ]; then echo "app-fixtures か run-as-app.sh が無いので（配り先）、飛ばします"; finish; exit $?; fi
if ! command -v rsync > /dev/null 2>&1; then echo "rsync が無いので、見本のテストは飛ばします"; finish; exit $?; fi
if ! command -v git > /dev/null 2>&1; then echo "git が無いので、見本のテストは飛ばします"; finish; exit $?; fi
ROOT="$(cd "$SCRIPTS_DIR/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

echo "== 見本が5つあり、それぞれ指定のファイルを持つ"
FX="$TESTS_DIR/app-fixtures"
names=$(cd "$FX" && find . -mindepth 1 -maxdepth 1 -type d | sed 's|^\./||' | sort | tr '\n' ' ')
assert_eq "見本は5つ" "electron next-vercel python visual-keep webgame " "$names"
assert_eq "next-vercel の vercel.json" '{"git":{"deploymentEnabled":false}}' "$(cat "$FX/next-vercel/vercel.json")"
assert_eq "next-vercel に pipeline.json は無い" "no" "$([ -f "$FX/next-vercel/pipeline.json" ] && echo yes || echo no)"
assert_contains "webgame は typecheck を持つ" "$(cat "$FX/webgame/pipeline.json")" "npm run typecheck"
assert_not_contains "webgame に lint は無い" "$(cat "$FX/webgame/pipeline.json")" "lint"
assert_contains "electron は github-release" "$(cat "$FX/electron/pipeline.json")" "github-release"
assert_eq "electron に vercel.json は無い" "no" "$([ -f "$FX/electron/vercel.json" ] && echo yes || echo no)"
assert_eq "python に package.json は無い" "no" "$([ -f "$FX/python/package.json" ] && echo yes || echo no)"
assert_eq "python に requirements.txt" "yes" "$([ -f "$FX/python/requirements.txt" ] && echo yes || echo no)"
assert_contains "visual-keep は test:visual を持つ" "$(cat "$FX/visual-keep/package.json")" "test:visual"
assert_eq "visual-keep に tests/visual/a.png" "yes" "$([ -f "$FX/visual-keep/tests/visual/a.png" ] && echo yes || echo no)"
assert_contains "visual-keep の sync-keep" "$(cat "$FX/visual-keep/.github/sync-keep")" "workflows/my-job.yml"
assert_eq "visual-keep に .github/workflows/my-job.yml" "yes" "$([ -f "$FX/visual-keep/.github/workflows/my-job.yml" ] && echo yes || echo no)"

# テンプレートの写し（配る物だけ）を作る。run-as-app.sh はこの写しの中の物を動かす
make_copy() {
  local c="$1"
  mkdir -p "$c/docs"
  rsync -a "$ROOT/.github/" "$c/.github/"
  cp "$ROOT/docs/pipeline.md" "$ROOT/docs/pipeline-setup.md" "$c/docs/"
  [ -d "$ROOT/.claude/skills" ] && mkdir -p "$c/.claude" && cp -R "$ROOT/.claude/skills" "$c/.claude/"
  # 全部のテストを見本ごとに回すと時間がかかるので、写しのテストは軽い2つだけにする（仕組みを確かめるのが目的。全部を回すのは run-as-app.sh 自身の仕事）
  local t
  for t in "$c"/.github/scripts/tests/test-*.sh; do
    case "$(basename "$t")" in test-pipeline-paths.sh|test-pr-trust.sh) ;; *) rm -f "$t" ;; esac
  done
  return 0
}

echo "== 偽のテスト（vercel.json に ignoreCommand が無ければ失敗）を入れた写し：next-vercel の名前を出して失敗する"
make_copy "$T/bad"
cat > "$T/bad/.github/scripts/tests/test-fake-vercel.sh" <<'FAKE'
#!/usr/bin/env bash
v="$(dirname "$0")/../../../vercel.json"
if [ -f "$v" ] && ! grep -q ignoreCommand "$v"; then echo "ignoreCommand が無い"; exit 1; fi
echo "成功 1 / 失敗 0"
FAKE
out=$(bash "$T/bad/.github/scripts/tests/run-as-app.sh" 2>&1); rc=$?
assert_eq "失敗で終わる" "1" "$rc"
assert_contains "落ちた見本の名前を出す" "$out" "落ちた見本：next-vercel"
assert_contains "残りの見本も回す" "$out" "===== 見本：webgame"
assert_not_contains "ほかの見本は落ちない" "$out" "落ちた見本：next-vercel "

echo "== 偽のテストが無い写し：全部の見本で通る"
make_copy "$T/good"
out=$(bash "$T/good/.github/scripts/tests/run-as-app.sh" 2>&1); rc=$?
assert_eq "成功で終わる" "0" "$rc"
assert_contains "全部通ったと言う" "$out" "全部の見本で通りました"
for n in electron next-vercel python visual-keep webgame; do
  assert_contains "見本 $n を回した" "$out" "===== 見本：$n"
done

echo "== SYNC_CANARY が空なら何もしない（clone しない）"
assert_not_contains "実物を回さない" "$out" "配り先の実物"

echo "== sync-keep に書いた物は、配布後も残り、配り先には app-fixtures を配らない"
app="$T/keep"; mkdir -p "$app"
cp -R "$FX/visual-keep/." "$app/"
bash "$SCRIPTS_DIR/sync-to-apps.sh" --local "$app" > /dev/null
assert_eq "workflows/my-job.yml が残る" "yes" "$([ -f "$app/.github/workflows/my-job.yml" ] && echo yes || echo no)"
assert_eq "自分の物の中身はそのまま" "$(cat "$FX/visual-keep/.github/workflows/my-job.yml")" "$(cat "$app/.github/workflows/my-job.yml")"
assert_eq "app-fixtures は配らない" "no" "$([ -d "$app/.github/scripts/tests/app-fixtures" ] && echo yes || echo no)"

finish
