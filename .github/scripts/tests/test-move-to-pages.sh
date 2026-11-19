#!/usr/bin/env bash
# move-to-pages.sh：サーバーで動くファイルがあれば止まる。無ければ PR（pipeline.json・next.config）を作り、Pages を有効にする
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/remotes/o"
# 疑似 gh：呼ばれた物を calls.log に残す。PAGES_ON があれば Pages はもう有効
cat > "$T/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "$FT/calls.log"
case "$*" in
  *"-q .default_branch"*) echo main ;;
  *"-X POST"*"/pulls"*) for a in "$@"; do case "$a" in body=*) printf '%s' "${a#body=}" > "$FT/pr-body.txt" ;; esac; done; echo "https://github.com/o/app/pull/1" ;;
  *"-X POST"*"/pages"*) : ;;
  *"/pages"*) [ -n "${PAGES_ON:-}" ] || exit 1 ;;
esac
exit 0
SH
chmod +x "$T/bin/gh"

mk_repo() { # 名前（作ったあと、$T/work/名前 に置いて足す）
  rm -rf "$T/work/$1" "$T/remotes/o/$1.git"; mkdir -p "$T/work/$1/src/app"
  git -C "$T/work/$1" init -q -b main
  echo '{"scripts":{"build":"next build"}}' > "$T/work/$1/package.json"
  printf 'export default function P() { return <main><a href="/about">x</a><img src="/logo.png" alt="" /></main>; }\n' > "$T/work/$1/src/app/page.tsx"
  echo 'const nextConfig = {}; export default nextConfig;' > "$T/work/$1/next.config.ts"
  echo '{"checks":[{"name":"リント","run":"npm run lint"}],"deploy":[{"kind":"vercel"}]}' > "$T/work/$1/pipeline.json"
}
commit_repo() {
  git -C "$T/work/$1" add -A && git -C "$T/work/$1" -c user.name=t -c user.email=t@t commit -qm init
  git clone -q --bare "$T/work/$1" "$T/remotes/o/$1.git"
}
run_move() { # 名前 [環境変数...]
  rm -f "$T/calls.log" "$T/pr-body.txt"
  env PATH="$T/bin:$PATH" FT="$T" GH_TOKEN=x MOVE_GIT_URL="$T/remotes/%s.git" "${@:2}" bash "$SCRIPTS_DIR/move-to-pages.sh" "o/$1" 2>&1
}
file_in() { git --git-dir="$T/remotes/o/$1.git" show "move-to-pages:$2" 2> /dev/null; }

echo "== サーバーで動くファイルがあれば止まる（PR も Pages も作らない）"
check_stop() { # 名前 期待する理由
  commit_repo "$1"
  out=$(run_move "$1"); rc=$?
  assert_eq "$1：失敗で止まる" "1" "$rc"
  assert_contains "$1：理由" "$out" "$2"
  assert_not_contains "$1：PR を作らない" "$(cat "$T/calls.log" 2> /dev/null)" "/pulls"
  assert_not_contains "$1：Pages を有効にしない" "$(cat "$T/calls.log" 2> /dev/null)" "/pages"
}
mk_repo api; mkdir -p "$T/work/api/src/app/api/hello"; echo 'export const GET = () => 1;' > "$T/work/api/src/app/api/hello/route.ts"
check_stop api "src/app/api/hello/route.ts"
mk_repo route; mkdir -p "$T/work/route/src/app/feed.xml"; echo 'export const GET = () => 1;' > "$T/work/route/src/app/feed.xml/route.ts"
check_stop route "feed.xml/route.ts"
mk_repo mw; echo 'export function middleware() {}' > "$T/work/mw/middleware.ts"
check_stop mw "middleware.ts"
mk_repo action; printf '"use server";\nexport async function save() {}\n' > "$T/work/action/src/app/actions.ts"
check_stop action "actions.ts（サーバーアクション）"
mk_repo mig; mkdir -p "$T/work/mig/supabase/migrations"; echo 'select 1;' > "$T/work/mig/supabase/migrations/0001.sql"
check_stop mig "supabase/migrations/0001.sql"

echo "== 無ければ PR を作り、Pages を有効にする"
mk_repo ok; commit_repo ok
out=$(run_move ok); rc=$?
assert_eq "成功で終わる" "0" "$rc"
calls=$(cat "$T/calls.log")
assert_contains "PR を作る" "$calls" "-X POST repos/o/ok/pulls"
assert_contains "Pages を有効にする（build_type=workflow）" "$calls" "-X POST repos/o/ok/pages -f build_type=workflow"
assert_contains "PR の出力" "$out" "PR を作った"
assert_eq "pipeline.json：deploy" '[{"kind":"github-pages","build":"PAGES_BASE_PATH=/ok npm run build"}]' "$(file_in ok pipeline.json | jq -c .deploy)"
assert_eq "pipeline.json：確認コマンドは元のまま" '[{"name":"リント","run":"npm run lint"}]' "$(file_in ok pipeline.json | jq -c .checks)"
nc=$(file_in ok next.config.ts)
assert_contains "next.config：export" "$nc" 'output: "export"'
assert_contains "next.config：trailingSlash" "$nc" "trailingSlash: true"
assert_contains "next.config：画像" "$nc" "unoptimized: true"
assert_contains "next.config：basePath" "$nc" "basePath"
body=$(cat "$T/pr-body.txt")
assert_contains "本文：素の a href" "$body" 'src/app/page.tsx:1:'
assert_contains "本文：素の a href の中身" "$body" '<a href="/about">'
assert_contains "本文：素の img src" "$body" '<img src="/logo.png"'
echo "== Pages がもう有効なら飛ばす"
out=$(run_move ok PAGES_ON=1)
assert_not_contains "有効にする呼び出しをしない" "$(cat "$T/calls.log")" "-X POST repos/o/ok/pages"
assert_contains "もう有効と書く" "$out" "もう有効になっている"
echo "== 付け忘れが無ければ「見つからなかった」と書く"
mk_repo clean; echo 'export default function P() { return <main>hi</main>; }' > "$T/work/clean/src/app/page.tsx"; commit_repo clean
run_move clean > /dev/null
assert_contains "見つからなかった" "$(cat "$T/pr-body.txt")" "見つからなかった"
echo "== 形が違う入力は断る"
out=$(env PATH="$T/bin:$PATH" bash "$SCRIPTS_DIR/move-to-pages.sh" "bad" 2>&1); rc=$?
assert_eq "owner/repo でなければ 2" "2" "$rc"
finish
