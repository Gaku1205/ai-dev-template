#!/usr/bin/env bash
# 工場（factory.sh）：1行のメモから、新しいサービスのリポジトリを作ってパイプラインに渡す。
# GitHub と Vercel は、このテストの中の疑似 gh・疑似 curl で真似る（呼ばれた物を calls.log に残す）。clone 先は手元の git
source "$(dirname "$0")/lib.sh"
ROOT="$(cd "$SCRIPTS_DIR/../.." && pwd)"
# 工場はテンプレート本体の物。見本（examples/python）の無いリポジトリ（工場で作ったアプリなど）では確かめない
if [ ! -d "$ROOT/examples/python" ]; then echo "見本が無いので、工場のテストは飛ばします"; finish; exit $?; fi
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/remotes"

# テンプレートの中身（いまの作業中の物）を、作るリポジトリの元にする
mkdir -p "$T/seed"
(cd "$ROOT" && git ls-files -co --exclude-standard | grep -v '^node_modules/' | tar -cf - -T -) | tar -xf - -C "$T/seed"
git -C "$T/seed" init -q -b main && git -C "$T/seed" add -A && git -C "$T/seed" -c user.name=t -c user.email=t@t commit -qm seed

cat > "$T/bin/gh" <<'PY'
#!/usr/bin/env python3
import sys, os, json, subprocess, shutil, re
T = os.environ["FT"]; log = open(f"{T}/calls.log", "a")
st_path = f"{T}/state.json"
st = json.load(open(st_path)) if os.path.exists(st_path) else {"repos": [], "issues": 0}
a = sys.argv[1:]
def save(): json.dump(st, open(st_path, "w"))
def arg(flag):
    return a[a.index(flag) + 1] if flag in a else None
def fields():
    out = {}
    for i, x in enumerate(a):
        if x in ("-f", "-F"): k, v = a[i + 1].split("=", 1); out[k] = v
    return out
if a[0] in ("secret", "variable"):
    val = sys.stdin.read() if a[0] == "secret" else arg("--body")
    log.write(f"{a[0]} {a[2]} {arg('--repo')} len={len(val)}\n")
    # 変数は覚えておく（作りかけのリポジトリの印 FACTORY_ISSUE を、やり直しの実行が読む）。VAR_FAIL：その名前の変数は付けられない
    if a[0] == "variable":
        if a[2] in os.environ.get("VAR_FAIL", "").split(): sys.exit(1)
        st.setdefault("vars", {}).setdefault(arg("--repo"), {})[a[2]] = val; save()
    sys.exit(0)
assert a[0] == "api"
method = arg("-X") or ("POST" if ("-f" in a or "-F" in a) else "GET")
path = [x for x in a[1:] if x.startswith("repos/")][0]
q = arg("-q")
def out(o):
    if q: sys.stdout.write(subprocess.run(["jq", "-r", q], input=json.dumps(o), capture_output=True, text=True).stdout)
    else: print(json.dumps(o))
base = path.split("?")[0]
log.write(f"{method} {base} {json.dumps(fields(), ensure_ascii=False)}\n")
m = re.match(r"repos/([^/]+/[^/]+)/actions/variables/(\w+)$", base)
if m:
    v = st.get("vars", {}).get(m.group(1), {}).get(m.group(2)) or os.environ.get("VAR_" + m.group(2) + "_" + re.sub(r"\W", "_", m.group(1)))
    if v is None: sys.stderr.write("gh: Not Found (HTTP 404)\n"); sys.exit(1)
    out({"name": m.group(2), "value": v}); sys.exit(0)
m = re.match(r"repos/([^/]+/[^/]+)/contents/(.+)$", base)
if m:
    r = subprocess.run(["git", "--git-dir", f"{T}/remotes/{m.group(1)}.git", "show", f"main:{m.group(2)}"], capture_output=True, text=True)
    if r.returncode: sys.stderr.write("gh: Not Found (HTTP 404)\n"); sys.exit(1)
    sys.stdout.write(r.stdout); sys.exit(0)
m = re.match(r"repos/([^/]+)/([^/]+)$", base)
if m and method == "PATCH":
    open(f"{T}/homepage.txt", "w").write(fields().get("homepage", "")); print("{}"); sys.exit(0)
if m and method == "GET":
    name = f"{m.group(1)}/{m.group(2)}"
    sys.exit(0 if name in st["repos"] or name in os.environ.get("EXISTING", "").split() else 1)
if base.endswith("/generate"):
    if os.environ.get("GENERATE_FAIL"): sys.stderr.write("gh: Resource not accessible (HTTP 403)\n"); sys.exit(1)
    f = fields(); new = f"{f['owner']}/{f['name']}"
    st["repos"].append(new); save()
    dst = f"{T}/remotes/{new}.git"; os.makedirs(os.path.dirname(dst), exist_ok=True)
    subprocess.run(["git", "clone", "-q", "--bare", f"{T}/seed", dst], check=True); print("{}"); sys.exit(0)
m = re.match(r"repos/([^/]+/[^/]+)/branches/main$", base)
if m: sys.exit(0 if m.group(1) in st["repos"] else 1)
if base.endswith("/pages") and method == "POST":
    r = os.environ.get("PAGES_RESULT", "ok")
    if r == "409": sys.stderr.write("gh: Pages is already enabled. (HTTP 409)\n"); sys.exit(1)
    if r == "403": sys.stderr.write("gh: Resource not accessible (HTTP 403)\n"); sys.exit(1)
    print("{}"); sys.exit(0)
if base.endswith("/rulesets"):
    open(f"{T}/ruleset.json", "w").write(sys.stdin.read()); print("{}"); sys.exit(0)
if base.endswith("/labels"):
    out([] if os.environ.get("NO_LABELS") else [{"name": "ai:plan"}]); sys.exit(0)
m = re.match(r"repos/([^/]+/[^/]+)/issues$", base)
if m and method == "POST":
    if os.environ.get("ISSUE_FAIL"): sys.stderr.write("gh: Validation Failed (HTTP 422)\n"); sys.exit(1)
    st["issues"] += 1; save(); out({"number": st["issues"]}); sys.exit(0)
if re.search(r"/issues/\d+/comments$", base):
    open(f"{T}/comment.txt", "a").write(fields().get("body", "") + "\n----\n"); print("{}"); sys.exit(0)
if re.search(r"/issues/\d+$", base) and method == "PATCH":
    print("{}"); sys.exit(0)
sys.stderr.write(f"UNHANDLED {method} {path}\n"); sys.exit(1)
PY
cat > "$T/bin/curl" <<'SH'
#!/usr/bin/env bash
echo "curl $*" >> "$FT/calls.log"
case "$*" in
  *ntfy.sh*) cat >> "$FT/ntfy.log"; exit 0 ;;
  */domains*) echo '{"domains":[{"name":"made-git-x.vercel.app","gitBranch":"x"},{"name":"made-abc.vercel.app","gitBranch":null}]}'; exit 0 ;;
esac
cat > "$FT/vercel-body.json"
if [ -n "${VERCEL_FAIL:-}" ]; then echo '{"error":{"message":"repo not found"}}'; else echo '{"name":"made"}'; fi
SH
# 疑似 npm：呼ばれた引数を残し、package.json に入れたことにする（NPM_FAIL があれば失敗する）
cat > "$T/bin/npm" <<'SH'
#!/usr/bin/env bash
echo "npm $*" >> "$FT/calls.log"
[ -n "${NPM_FAIL:-}" ] && { echo "npm ERR! network" >&2; echo '{"broken":1}' > package.json; exit 1; }
for a in "$@"; do case "$a" in -*|install) ;; *) echo "// $a" >> package.json ;; esac; done
SH
chmod +x "$T/bin/gh" "$T/bin/curl" "$T/bin/npm"

run_factory() { # 名前 言語 説明 [追加の環境変数...]
  rm -f "$T/calls.log" "$T/state.json" "$T/comment.txt" "$T/ruleset.json" "$T/vercel-body.json" "$T/ntfy.log"; rm -rf "$T/remotes"; mkdir -p "$T/remotes"
  env PATH="$T/bin:$PATH" FT="$T" GH_TOKEN=x TEMPLATE=o/ai-dev-template ISSUE=7 MEMO="毎朝の天気と予定を1枚で見たい" \
    APP_NAME="$1" APP_STACK="$2" APP_DESC="$3" FACTORY_GIT_URL="$T/remotes/%s.git" FACTORY_WAIT_SEC=0 \
    S_CLAUDE_CODE_OAUTH_TOKEN=secret1 S_PIPELINE_APP_PRIVATE_KEY=pem V_PIPELINE_APP_ID=123 "${@:4}" \
    bash "$SCRIPTS_DIR/factory.sh" 2>&1
}
file_in() { git --git-dir="$T/remotes/$1.git" show "main:$2" 2> /dev/null; }

echo "== Next.js：リポジトリを作り、秘密と変数を写し、Vercel につなぎ、main を守り、最初のIssueを作る"
run_factory morning-board nextjs "毎朝の天気と予定を1枚で見るページ。" VERCEL_TOKEN=v > /dev/null
calls=$(cat "$T/calls.log")
assert_contains "テンプレートから作る" "$calls" "POST repos/o/ai-dev-template/generate"
assert_contains "秘密を写す" "$calls" "secret CLAUDE_CODE_OAUTH_TOKEN o/morning-board len=7"
assert_contains "変数を写す" "$calls" "variable PIPELINE_APP_ID o/morning-board len=3"
assert_not_contains "空の秘密は写さない" "$calls" "secret NTFY_TOPIC"
assert_contains "Vercel のプロジェクト" "$(cat "$T/vercel-body.json")" '"repo":"o/morning-board"'
assert_contains "本番の公開アドレスを報告する（ブランチの物ではない方）" "$(cat "$T/comment.txt")" "公開アドレス：https://made-abc.vercel.app"
assert_eq "Website 欄に入れる" "https://made-abc.vercel.app" "$(cat "$T/homepage.txt")"
assert_contains "main を守る：check が必須" "$(cat "$T/ruleset.json")" '"context":"check"'
assert_contains "main を守る：PR が必須" "$(cat "$T/ruleset.json")" '"pull_request"'
assert_contains "最初のIssueはメモの1行" "$calls" '"title": "毎朝の天気と予定を1枚で見たい"'
claude=$(file_in o/morning-board CLAUDE.md)
assert_eq "CLAUDE.md の説明（句点は1つ・言語の案内は消す）" "morning-board：毎朝の天気と予定を1枚で見るページ。Next.js（App Router）＋TypeScript。" "$(printf '%s\n' "$claude" | sed -n 3p)"
assert_not_contains "テンプレート本体だけの節を消す（自動マージの印も）" "$claude" "pipeline-self-edit"
assert_not_contains "その但し書きも消す" "$claude" "ai-dev-template 自身"
assert_contains "仕様書の目的に説明とメモ" "$(file_in o/morning-board docs/spec.md)" "（元のメモ：毎朝の天気と予定を1枚で見たい）"
assert_contains "README はこのサービスの説明" "$(file_in o/morning-board README.md | head -3)" "毎朝の天気と予定を1枚で見るページ"
assert_eq "工場のIssueの雛形は持ち込まない" "" "$(file_in o/morning-board .github/ISSUE_TEMPLATE/new-service.yml)"
assert_eq "見本（examples）は持ち込まない" "" "$(file_in o/morning-board examples/python/README.md)"
assert_contains "Next.js のまま" "$(file_in o/morning-board package.json)" '"next"'
assert_contains "元のIssueに結果を書く" "$(cat "$T/comment.txt")" "新しいサービス **morning-board** を作りました"
assert_contains "元のIssueを閉じる" "$calls" "PATCH repos/o/ai-dev-template/issues/7"

echo "== Vercel が断ったら、理由を書いて先へ進む"
run_factory vercel-ng nextjs "説明" VERCEL_TOKEN=v VERCEL_FAIL=1 > /dev/null
assert_contains "理由を書く" "$(cat "$T/comment.txt")" "repo not found"
assert_contains "最初のIssueまでは作る" "$(cat "$T/calls.log")" "POST repos/o/vercel-ng/issues"

echo "== 同じ名前があれば -2 を付ける。VERCEL_TOKEN が無ければ、つながずに知らせる"
run_factory morning-board nextjs "説明" EXISTING="o/morning-board" > /dev/null
assert_contains "-2 で作る" "$(cat "$T/calls.log")" '"name": "morning-board-2"'
assert_contains "Vercel につないでいないと書く" "$(cat "$T/comment.txt")" "VERCEL_TOKEN が無い"

echo "== Python：見本に切り替える（Next.js の物を消し、公開先は none、CLAUDE.md と仕様書も Python に）"
run_factory receipt-api python "レシートの写真から金額を取り出すAPI" > /dev/null
r=o/receipt-api
assert_eq "package.json は消える" "" "$(file_in $r package.json)"
assert_contains "app/ が来る" "$(file_in $r app/main.py)" "FastAPI"
assert_contains ".dockerignore も来る" "$(file_in $r .dockerignore)" ".venv"
assert_eq "公開先は none" '[{"kind":"none"}]' "$(file_in $r pipeline.json | jq -c .deploy)"
assert_contains "cli.py はテストが使うので残す" "$(file_in $r cli.py)" "def main"
assert_not_contains "pyinstaller は入れない" "$(file_in $r requirements-dev.txt)" "pyinstaller"
assert_eq "AGENTS.md は空で残る" "0" "$(file_in $r AGENTS.md | wc -c | tr -d ' ')"
claude=$(file_in $r CLAUDE.md)
assert_contains "CLAUDE.md：Python（FastAPI）" "$claude" "receipt-api：レシートの写真から金額を取り出すAPI。Python（FastAPI）。"
assert_not_contains "CLAUDE.md：テンプレート本体だけの節を消す" "$claude" "pipeline-self-edit"
assert_not_contains "CLAUDE.md：Next.js の注意の行は消す" "$claude" "Next.js固有の注意"
assert_contains "CLAUDE.md：コードの書き方も Python" "$claude" "ロジックは \`app/\`、テストは \`tests/\`"
assert_contains "仕様書の技術の欄" "$(file_in $r docs/spec.md)" "Python（FastAPI）、テストは pytest"
assert_not_contains "Python では Vercel を呼ばない" "$(cat "$T/calls.log")" "curl"

echo "== ゲーム：雛形（TypeScript・Vite・Electron の exe）に切り替え、公開先は GitHub Releases の Windows の exe。Vercel は使わない"
run_factory star-drift game "流れ星を集める短いアクションゲーム" VERCEL_TOKEN=v S_VERCEL_TOKEN=vt > /dev/null
r=o/star-drift
assert_contains "package.json はゲームの物" "$(file_in $r package.json)" '"dist": "npm run build && electron-builder --win portable --publish never"'
assert_contains "入口は src/main.ts" "$(file_in $r src/main.ts)" "canvas"
assert_contains "exe のウィンドウ" "$(file_in $r electron/main.cjs)" "loadFile"
assert_eq "公開先は Windows の exe" '[{"kind":"github-release","os":["windows-latest"],"build":"npm run dist","files":"release/*.exe"}]' "$(file_in $r pipeline.json | jq -c .deploy)"
assert_eq "Next.js の物は消える" "" "$(file_in $r next.config.ts)"
assert_eq "見本は持ち込まない" "" "$(file_in $r examples/game/package.json)"
assert_contains "dist・release は入れない" "$(file_in $r .gitignore)" "release/"
claude=$(file_in $r CLAUDE.md)
assert_contains "CLAUDE.md：ゲーム" "$claude" "Electron で Windows の exe にして配るゲーム。"
assert_not_contains "CLAUDE.md：Next.js の注意の行は消す" "$claude" "Next.js固有の注意"
assert_contains "AGENTS.md：撮り方" "$(file_in $r AGENTS.md)" "/?scene=play"
assert_contains "仕様書の技術の欄" "$(file_in $r docs/spec.md)" "Electron で Windows の exe にして GitHub Releases で配る"
assert_not_contains "Vercel を呼ばない" "$(cat "$T/calls.log")" "curl"
assert_not_contains "Vercel の鍵も写さない" "$(cat "$T/calls.log")" "secret VERCEL_TOKEN"
assert_contains "結果に exe の置き場を書く" "$(cat "$T/comment.txt")" "https://github.com/o/star-drift/releases/latest"

echo "== Web のゲーム：雛形（TypeScript・Vite）に切り替え、Vercel（Vite）で公開する。Electron は入れない"
run_factory tap-rush webgame "タップで光を弾く30秒のゲーム" VERCEL_TOKEN=v > /dev/null
r=o/tap-rush
assert_contains "Vercel のプロジェクトは Vite" "$(cat "$T/vercel-body.json")" '"framework":"vite"'
assert_contains "入口は src/main.ts" "$(file_in $r src/main.ts)" "canvas"
assert_not_contains "Electron は入れない" "$(file_in $r package.json)" "electron"
assert_eq "exe のウィンドウも無い" "" "$(file_in $r electron/main.cjs)"
assert_eq "公開先は Vercel" '[{"kind":"vercel"}]' "$(file_in $r pipeline.json | jq -c .deploy)"
assert_contains "スマホで勝手に動かない" "$(file_in $r index.html)" "touch-action: none"
assert_eq "Next.js の物は消える" "" "$(file_in $r next.config.ts)"
assert_eq "見本は持ち込まない" "" "$(file_in $r examples/webgame/package.json)"
claude=$(file_in $r CLAUDE.md)
assert_contains "CLAUDE.md：Web のゲーム" "$claude" "Vercel で公開して、スマホでも PC でもブラウザで遊ぶ Web のゲーム。"
assert_contains "CLAUDE.md：注意は公開のしかた" "$claude" "AGENTS.md（公開のしかた・画面の撮り方）"
assert_contains "AGENTS.md：スマホ" "$(file_in $r AGENTS.md)" "スマホ（縦の画面・タッチ）"
assert_contains "仕様書の技術の欄" "$(file_in $r docs/spec.md)" "Vercel で公開する（スマホ・PC のブラウザで遊ぶ）"
assert_contains "Vercel につないだと書く" "$(cat "$T/comment.txt")" "Vercel のプロジェクトを作ってつないだ"
run_factory tap-rush webgame "説明" VERCEL_TOKEN=v S_VERCEL_TOKEN=vt > /dev/null
assert_contains "Vercel の鍵を写す" "$(cat "$T/calls.log")" "secret VERCEL_TOKEN o/tap-rush"
assert_eq "Vercel が自分で公開しない（まとめて公開する）" "false" "$(file_in o/tap-rush vercel.json | jq -c .git.deploymentEnabled)"

echo "== 会員と課金（saas）：Next.js に Supabase と Stripe の土台を入れ、表の変更の公開を足す。鍵が無ければ外の準備を飛ばして知らせる"
run_factory paid-notes saas "有料で使えるメモのサービス" VERCEL_TOKEN=v S_VERCEL_TOKEN=vt > /dev/null
r=o/paid-notes
assert_contains "Vercel は Next.js" "$(cat "$T/vercel-body.json")" '"framework":"nextjs"'
assert_contains "Vercel の鍵を写す" "$(cat "$T/calls.log")" "secret VERCEL_TOKEN o/paid-notes"
assert_contains "Next.js のまま" "$(file_in $r package.json)" '"next"'
assert_contains "依存を入れる" "$(cat "$T/calls.log")" "@supabase/ssr"
assert_contains "ログインの画面" "$(file_in $r src/app/login/page.tsx)" "LoginForm"
assert_contains "課金の受け口" "$(file_in $r src/app/api/stripe/webhook/route.ts)" "constructEvent"
assert_contains "見る人を調べる" "$(file_in $r src/lib/viewer.ts)" "getViewer"
assert_contains "テンプレートのトップは残る" "$(file_in $r src/app/page.tsx)" "greeting"
assert_contains "最初の表（RLS）" "$(file_in $r supabase/migrations/0001_billing.sql)" "enable row level security"
assert_eq "公開先は Vercel と表の変更" '[{"kind":"vercel"},{"kind":"supabase"}]' "$(file_in $r pipeline.json | jq -c .deploy)"
assert_contains "決まりの説明" "$(file_in $r docs/billing.md)" "getViewer()"
claude=$(file_in $r CLAUDE.md)
assert_contains "CLAUDE.md：Supabase と Stripe" "$claude" "会員登録・ログインは Supabase、月額の有料プランは Stripe。"
assert_contains "CLAUDE.md：決まりの場所" "$claude" "docs/billing.md"
assert_contains "仕様書：無料と有料" "$(file_in $r docs/spec.md)" "## 無料と有料"
assert_contains "鍵が無いと知らせる（Supabase）" "$(cat "$T/comment.txt")" "SUPABASE_ACCESS_TOKEN が無い"
assert_contains "鍵が無いと知らせる（Stripe）" "$(cat "$T/comment.txt")" "STRIPE_SECRET_KEY が無い"
assert_contains "作るのは止めない" "$(cat "$T/comment.txt")" "新しいサービス **paid-notes** を作りました"

echo "== ゲーム：デザイン担当が選んだ遊び方のアイデアを、結果のコメントに畳んで載せる（@ は効かなくする）"
printf '1. 影を踏む遊び（近い物：無し）\n選んだ：影踏み @someone\n' > "$T/idea.md"
run_factory idea-game webgame "説明" IDEA_FILE="$T/idea.md" > /dev/null
assert_contains "畳んで載せる" "$(cat "$T/comment.txt")" "<details><summary>遊び方のアイデア"
assert_contains "中身" "$(cat "$T/comment.txt")" "選んだ：影踏み"
assert_not_contains "@ で人を呼ばない" "$(cat "$T/comment.txt")" "@someone"

echo "== 審査役の点の行を、結果のコメントに載せる（@ は効かなくする）"
printf '審査役：1回目 ⚠️ site 6.5 点 → 直した後 ✅ site 7.8 点 @someone\n' > "$T/judge.md"
run_factory judged-site nextjs "説明" JUDGE_FILE="$T/judge.md" > /dev/null
assert_contains "点の行" "$(cat "$T/comment.txt")" "🧐 審査役：1回目 ⚠️ site 6.5 点 → 直した後 ✅ site 7.8 点"
assert_not_contains "@ で人を呼ばない（審査）" "$(cat "$T/comment.txt")" "@someone"

echo "== ゲーム：デザイン担当が作ったゲーム（入口は src/main.ts、index.html も）を入れる"
{ echo "# デザイン仕様"; for i in $(seq 1 60); do echo "- 色や文字の決まり その$i：夜の地に光る数字"; done; } > "$T/design-ok.md"
G="$T/game-site"; rm -rf "$G"; mkdir -p "$G/src/lib" "$G/public"
echo 'import "./lib/stars";' > "$G/src/main.ts"
echo 'export const n = 1;' > "$G/src/lib/stars.ts"
echo '<!doctype html><title>STAR DRIFT</title><canvas id="game"></canvas>' > "$G/index.html"
touch "$G/.checks-ok"
run_factory star-site game "説明" DESIGN_FILE="$T/design-ok.md" SITE_DIR="$G" > /dev/null
assert_contains "ゲームの本体が入る" "$(file_in o/star-site src/lib/stars.ts)" "export const n"
assert_contains "index.html も入る" "$(file_in o/star-site index.html)" "STAR DRIFT"
assert_eq "雛形の src/lib は置き換わる" "" "$(file_in o/star-site src/lib/clamp.ts)"
assert_contains "入れたと書く" "$(cat "$T/comment.txt")" "確認コマンドも通った"
rm "$G/src/main.ts"
run_factory star-noentry game "説明" DESIGN_FILE="$T/design-ok.md" SITE_DIR="$G" > /dev/null
assert_contains "入口が無ければ入れない" "$(cat "$T/comment.txt")" "src/main.ts がありません"

echo "== 説明に記号があっても壊れない（& / | \\ など）"
run_factory odd-chars nextjs 'A&B / C|D \ E' > /dev/null
assert_contains "そのまま書かれる" "$(file_in o/odd-chars CLAUDE.md | sed -n 3p)" 'odd-chars：A&B / C|D \ E。'

echo "== AIが決めた形が違えば、何も作らずに止める"
run_factory "Bad_Name" nextjs "x" > /dev/null
assert_not_contains "作らない" "$(cat "$T/calls.log" 2> /dev/null)" "generate"
assert_contains "理由を書く" "$(cat "$T/comment.txt")" "名前「Bad_Name」"
run_factory good-name ruby "x" > /dev/null
assert_contains "知らない言語" "$(cat "$T/comment.txt")" "nextjs・saas・python・game・webgame のどれか"
run_factory good-name nextjs 'x $(id)' > /dev/null
assert_contains "危ない記号" "$(cat "$T/comment.txt")" "記号"

echo "== デザイン担当：形が正しいデザイン仕様は docs/design.md に、使う人・場面は仕様書の前提に入る。最初のIssueは size:L"
{ echo "# デザイン仕様"; for i in $(seq 1 60); do echo "- 色や文字の決まり その$i：夜の地に光る数字"; done; } > "$T/design-ok.md"
printf '%s\n' "# 使う人" "- 推定：シフト制のバイトをしている学生" "- 推定：バイト帰りの電車で、スマホを片手に30秒" "前置きの文は入れない" > "$T/context.md"
run_factory design-ok nextjs "説明" DESIGN_FILE="$T/design-ok.md" CONTEXT_FILE="$T/context.md" > /dev/null
spec=$(file_in o/design-ok docs/spec.md)
assert_contains "仕様書の前提に、使う人・場面" "$spec" "  - 推定：バイト帰りの電車で、スマホを片手に30秒"
assert_not_contains "箇条書き以外は入れない" "$spec" "前置きの文"
assert_contains "docs/design.md に入る" "$(file_in o/design-ok docs/design.md)" "夜の地に光る数字"
assert_contains "結果に書く" "$(cat "$T/comment.txt")" "デザイン仕様（docs/design.md）を書いた"
assert_contains "最初のIssueは size:L" "$(cat "$T/calls.log")" '"labels[]": "size:L"'
printf '%s\n' "ちがう見出し" "短い" > "$T/design-bad.md"
run_factory design-bad nextjs "説明" DESIGN_FILE="$T/design-bad.md" > /dev/null
assert_not_contains "形が違えば雛形のまま" "$(file_in o/design-bad docs/design.md)" "ちがう見出し"
assert_contains "そう書く" "$(cat "$T/comment.txt")" "雛形のままにした"

echo "== デザイン担当が入れた GSAP・Lenis：決まった物だけ、デザイン仕様を使うときだけ入れる"
printf '%s\n' "gsap" "lenis" "left-pad" "" > "$T/libs.txt"
run_factory libs-ok nextjs "説明" DESIGN_FILE="$T/design-ok.md" LIBS_FILE="$T/libs.txt" > /dev/null
calls=$(cat "$T/calls.log")
assert_contains "lock だけ更新して入れる（GSAP は React 用も一緒に）" "$calls" "npm install --package-lock-only --no-audit --no-fund --ignore-scripts --save @gsap/react@^2 gsap@^3 lenis@^1"
assert_not_contains "決まった物以外は入れない" "$calls" "left-pad"
pkg=$(file_in o/libs-ok package.json)
assert_contains "package.json に入って push される" "$pkg" "// lenis@^1"
assert_contains "結果に書く" "$(cat "$T/comment.txt")" "使った道具を入れた：@gsap/react@^2 gsap@^3 lenis@^1"
assert_contains "入れなかった物も書く" "$(cat "$T/comment.txt")" "決まった物（gsap・@gsap/react・lenis・motion・three・@react-three/fiber・@react-three/drei・pixi.js）以外"
run_factory libs-nodesign nextjs "説明" DESIGN_FILE="$T/design-bad.md" LIBS_FILE="$T/libs.txt" > /dev/null
assert_not_contains "デザイン仕様が雛形のままなら入れない" "$(cat "$T/calls.log")" "npm install"
run_factory libs-py python "説明" LIBS_FILE="$T/libs.txt" > /dev/null
assert_not_contains "Python では入れない" "$(cat "$T/calls.log")" "npm install"
: > "$T/libs-empty.txt"
run_factory libs-empty nextjs "説明" DESIGN_FILE="$T/design-ok.md" LIBS_FILE="$T/libs-empty.txt" > /dev/null
assert_not_contains "空なら入れない（検査役が消した）" "$(cat "$T/calls.log")" "npm install"
run_factory libs-fail nextjs "説明" DESIGN_FILE="$T/design-ok.md" LIBS_FILE="$T/libs.txt" NPM_FAIL=1 > /dev/null
assert_not_contains "失敗したら package.json を元に戻す" "$(file_in o/libs-fail package.json)" "broken"
assert_contains "失敗しても止めずに書く" "$(cat "$T/comment.txt")" "入れられませんでした"
assert_contains "失敗してもサービスは作る" "$(cat "$T/comment.txt")" "新しいサービス **libs-fail** を作りました"

echo "== Vercel の鍵（S_VERCEL_TOKEN）があるとき：Next.js にだけ写し、Vercel が自分で公開するのを止めて、最初の公開を頼む"
run_factory vt-next nextjs "説明" VERCEL_TOKEN=v S_VERCEL_TOKEN=vt V_VERCEL_TEAM_ID=team_1 > /dev/null
calls=$(cat "$T/calls.log")
assert_contains "VERCEL_TOKEN を写す" "$calls" "secret VERCEL_TOKEN o/vt-next len=2"
assert_contains "VERCEL_TEAM_ID を写す" "$calls" "variable VERCEL_TEAM_ID o/vt-next"
assert_eq "vercel.json で自分の公開を止める" "false" "$(file_in o/vt-next vercel.json | jq -c .git.deploymentEnabled)"
assert_eq "ignoreCommand は消す（まとめて公開すると間の変更を見落とすため）" "null" "$(file_in o/vt-next vercel.json | jq -c .ignoreCommand)"
assert_contains "最初の公開について書く" "$(cat "$T/comment.txt")" "最初の公開"
run_factory vt-py python "説明" S_VERCEL_TOKEN=vt > /dev/null
assert_not_contains "Python には写さない" "$(cat "$T/calls.log")" "secret VERCEL_TOKEN"
run_factory vt-none nextjs "説明" VERCEL_TOKEN=v > /dev/null
assert_contains "鍵が無ければ vercel.json は今までどおり" "$(file_in o/vt-none vercel.json | jq -c .git.deploymentEnabled)" "claude/*"

echo "== 最後に撮った画像（目標の絵）：決まった形の PNG だけを docs/design-ref/ に入れ、最初のIssueで見比べるよう頼む"
R="$T/ref"; rm -rf "$R"; mkdir -p "$R"
printf '\x89PNG\r\n\x1a\nrest' > "$R/01-empty-390.png"
printf '\x89PNG\r\n\x1a\nrest' > "$R/01-empty-1440.png"
printf '<!doctype html><title>試作</title>' > "$R/01-empty.html"
printf 'not a png' > "$R/02-fake-390.png"
printf '\x89PNG\r\n\x1a\nrest' > "$R/Bad_Name.png"
printf 'x' > "$R/notes.txt"
ln -s /etc/hostname "$R/03-link.html"
run_factory ref-ok nextjs "説明" DESIGN_FILE="$T/design-ok.md" DESIGN_REF_DIR="$R" > /dev/null
assert_eq "本物の PNG だけが入る" "01-empty-1440.png 01-empty-390.png" \
  "$(git --git-dir="$T/remotes/o/ref-ok.git" ls-tree --name-only main docs/design-ref/ | xargs -n1 basename | sort | xargs)"
assert_contains "結果に書く（枚数は画像だけ）" "$(cat "$T/comment.txt")" "画面の画像 2 枚を、目標の絵として docs/design-ref/ に入れた"
assert_contains "最初のIssueで、目標の絵と見比べるよう頼む" "$(cat "$T/calls.log")" "docs/design-ref/ の画像を目標の絵に"
assert_not_contains "名前が top- でない画像はコメントに貼らない" "$(cat "$T/comment.txt")" "<img"
R2="$T/ref-top"; rm -rf "$R2"; mkdir -p "$R2"
for f in top-1440 top-1440-s1 top-1440-s2 top-390 top-1920; do printf '\x89PNG\r\n\x1a\nrest' > "$R2/$f.png"; done
run_factory ref-top nextjs "説明" DESIGN_FILE="$T/design-ok.md" DESIGN_REF_DIR="$R2" > /dev/null
comment=$(cat "$T/comment.txt")
assert_contains "結果のコメントに PC の最初の1画面を貼る" "$comment" '<img src="https://raw.githubusercontent.com/o/ref-top/main/docs/design-ref/top-1440.png" width="720"'
assert_contains "スクロールした所も" "$comment" "top-1440-s2.png"
assert_contains "スマホは小さく" "$comment" 'top-390.png" width="260"'
assert_not_contains "選んだ物だけ（1920 は貼らない）" "$comment" "top-1920.png"
assert_contains "ほかの画像の場所も書く" "$comment" "https://github.com/o/ref-top/tree/main/docs/design-ref"
run_factory ref-nodesign nextjs "説明" DESIGN_FILE="$T/design-bad.md" DESIGN_REF_DIR="$R" > /dev/null
assert_eq "デザイン仕様が雛形のままなら入れない" "" "$(file_in o/ref-nodesign docs/design-ref/01-empty-390.png)"
assert_not_contains "そのときは目標の絵を頼まない" "$(cat "$T/calls.log")" "design-ref"

echo "== 元のIssueの本文（詳しいメモ）は、最初のIssueの本文に添える"
run_factory detail-ok nextjs "説明" MEMO_DETAIL="載せる作品：agent-desk と工場" > /dev/null
assert_contains "詳しいメモが入る" "$(cat "$T/calls.log")" "載せる作品：agent-desk と工場"
run_factory detail-none nextjs "説明" > /dev/null
assert_not_contains "無ければ節を作らない" "$(cat "$T/calls.log")" "詳しいメモ"

echo "== three.js（3D）も決まった物として入れる"
printf '%s\n' "@react-three/drei" > "$T/libs3d.txt"
run_factory libs-3d nextjs "説明" DESIGN_FILE="$T/design-ok.md" LIBS_FILE="$T/libs3d.txt" > /dev/null
assert_contains "three・型・fiber・drei を一緒に入れる" "$(cat "$T/calls.log")" "--save @react-three/drei@^10 @react-three/fiber@^9 @types/three@^0 three@^0"

echo "== デザイン担当が作った画面：確認コマンドが通った物を src/・public/ に入れ、作れなかった残りだけを Issue にする"
mk_site() { # 場所
  rm -rf "$1"; mkdir -p "$1/src/app" "$1/src/components" "$1/src/app/(works)/[slug]" "$1/public/photos"
  printf '%s\n' 'import Hero from "@/components/Hero";' 'export default function Page() { return <Hero src="/photos/01-river.jpg" />; }' > "$1/src/app/page.tsx"
  echo 'export default function Hero() { return null; }' > "$1/src/components/Hero.tsx"
  echo 'export default function Work() { return null; }' > "$1/src/app/(works)/[slug]/page.tsx"
  echo ':root { --ink: #111; }' > "$1/src/app/globals.css"
  printf '\xff\xd8\xff\xe0jpeg' > "$1/public/photos/01-river.jpg"
  printf '\xff\xd8\xff\xe0jpeg' > "$1/public/photos/02-unused.jpg"
  printf '%s\n' '- `01-river.jpg`：River（A、CC0、2400×1600）https://src.test/1' '- `02-unused.jpg`：Unused（B、CC0）' > "$1/public/photos/CREDITS.md"
  printf '\x89PNG\r\n\x1a\nrest' > "$1/public/og.png"
  echo 'curl evil' > "$1/public/run.sh"
  ln -s /etc/hostname "$1/public/link.txt"
  touch "$1/.checks-ok" "$1/src/components/.gitkeep"
}
S="$T/site"; mk_site "$S"
printf '%s\n' "# 残り" "- 作品の詳しいページ" "- お問い合わせの \`フォーム\`" "* 夜の見た目" "- 4つめは入れない" > "$T/todo.md"
run_factory site-ok nextjs "説明" DESIGN_FILE="$T/design-ok.md" SITE_DIR="$S" TODO_FILE="$T/todo.md" > /dev/null
assert_contains "作った画面が入る" "$(file_in o/site-ok src/app/page.tsx)" "/photos/01-river.jpg"
assert_contains "Next.js の (グループ)・[slug] の名前も入る" "$(file_in o/site-ok 'src/app/(works)/[slug]/page.tsx')" "Work"
assert_eq "テンプレートの src/ は置き換える" "" "$(file_in o/site-ok src/lib/greeting.ts)"
assert_eq "使った写真だけ・形が正しい素材だけ" "public/og.png public/photos/01-river.jpg public/photos/CREDITS.md" \
  "$(git --git-dir="$T/remotes/o/site-ok.git" ls-tree -r --name-only main public/ | sort | xargs)"
assert_contains "出どころは使った写真だけ" "$(file_in o/site-ok public/photos/CREDITS.md)" "River（A、CC0"
assert_not_contains "使っていない写真の出どころは入れない" "$(file_in o/site-ok public/photos/CREDITS.md)" "Unused"
comment=$(cat "$T/comment.txt")
assert_contains "結果に書く" "$comment" "本物の画面を作り、撮って実例と見比べて直した。確認コマンドも通った（画面のファイル 4 個・写真 1 枚"
assert_contains "入れなかった素材も書く" "$comment" "形が違うので入れなかった素材 2 個"
calls=$(cat "$T/calls.log")
assert_contains "残りを Issue に（1つめ）" "$calls" '"title": "作品の詳しいページ"'
assert_contains "残りを Issue に（記号は消す）" "$calls" '"title": "お問い合わせの フォーム"'
assert_contains "残りを Issue に（* の行も）" "$calls" '"title": "夜の見た目"'
assert_not_contains "3つまで" "$calls" "4つめ"
assert_not_contains "メモの1行は Issue にしない（画面はもうある）" "$calls" '"title": "毎朝の天気と予定を1枚で見たい"'
assert_contains "結果に Issue を書く" "$comment" "作りきれなかった残りを Issue にした：#1 #2 #3"
run_factory site-notodo nextjs "説明" DESIGN_FILE="$T/design-ok.md" SITE_DIR="$S" > /dev/null
assert_contains "残りが無ければ Issue を作らない" "$(cat "$T/comment.txt")" "最初の画面はもうできているので、最初のIssueは作っていない"
assert_not_contains "Issue を作らない" "$(cat "$T/calls.log")" "POST repos/o/site-notodo/issues "

echo "== 画面を入れない時：確認コマンドが通っていない・形が違う・デザイン仕様が雛形のまま。そのときはメモの1行を最初のIssueにする"
rm -f "$S/.checks-ok"
run_factory site-nocheck nextjs "説明" DESIGN_FILE="$T/design-ok.md" SITE_DIR="$S" TODO_FILE="$T/todo.md" > /dev/null
assert_contains "テンプレートの画面のまま" "$(file_in o/site-nocheck src/app/page.tsx)" "greeting"
assert_contains "メモの1行が最初のIssue" "$(cat "$T/calls.log")" '"title": "毎朝の天気と予定を1枚で見たい"'
assert_not_contains "残りは Issue にしない" "$(cat "$T/calls.log")" "作品の詳しいページ"
mk_site "$S"; echo '#!/bin/sh' > "$S/src/app/run.sh"
run_factory site-bad nextjs "説明" DESIGN_FILE="$T/design-ok.md" SITE_DIR="$S" > /dev/null
assert_contains "決まっていない種類が1つでもあれば、src/ は1つも入れない" "$(file_in o/site-bad src/app/page.tsx)" "greeting"
assert_contains "理由を書く" "$(cat "$T/comment.txt")" "src/app/run.sh は入れられない名前か種類です"
mk_site "$S"; ln -s /etc/passwd "$S/src/lib-link.ts"
run_factory site-link nextjs "説明" DESIGN_FILE="$T/design-ok.md" SITE_DIR="$S" > /dev/null
assert_contains "リンクがあれば入れない" "$(cat "$T/comment.txt")" "リンクです"
mk_site "$S"; mkdir -p "$S/src/.hidden"; echo 'x' > "$S/src/.hidden/a.ts"
run_factory site-dot nextjs "説明" DESIGN_FILE="$T/design-ok.md" SITE_DIR="$S" > /dev/null
assert_contains ". で始まる名前は入れない" "$(cat "$T/comment.txt")" "入れられない名前か種類です"
mk_site "$S"
run_factory site-nodesign nextjs "説明" DESIGN_FILE="$T/design-bad.md" SITE_DIR="$S" > /dev/null
assert_contains "デザイン仕様が雛形のままなら入れない" "$(file_in o/site-nodesign src/app/page.tsx)" "greeting"

echo "== GitHub Pages：公開先に github-pages があれば FACTORY_TOKEN で有効にする（無ければ呼ばない）"
run_factory no-pages nextjs "説明" > /dev/null
assert_not_contains "github-pages が無ければ Pages を呼ばない" "$(cat "$T/calls.log")" "/pages"
echo '{"checks":[{"run":"npm run lint"}],"deploy":[{"kind":"github-pages"}]}' > "$T/seed/pipeline.json"
git -C "$T/seed" add pipeline.json && git -C "$T/seed" -c user.name=t -c user.email=t@t commit -qm pages
out=$(run_factory pages-ok nextjs "説明")
assert_contains "Pages を有効にする（build_type=workflow）" "$(cat "$T/calls.log")" 'POST repos/o/pages-ok/pages {"build_type": "workflow"}'
assert_contains "成功の ✅" "$out" "✅ GitHub Pages を有効にした"
out=$(run_factory pages-409 nextjs "説明" PAGES_RESULT=409)
assert_contains "もう有効（409）なら成功として扱う" "$out" "✅ GitHub Pages はもう有効になっている"
assert_not_contains "409 は ⚠️ にしない" "$out" "⚠️ GitHub Pages"
out=$(run_factory pages-ng nextjs "説明" PAGES_RESULT=403)
assert_contains "失敗は ⚠️ と直し方（URL 付き）" "$out" "⚠️ GitHub Pages を有効にできませんでした（https://github.com/o/pages-ng/settings/pages を開いて、Source を GitHub Actions にする）"
assert_contains "失敗しても先へ進む" "$(cat "$T/calls.log")" "POST repos/o/pages-ng/issues"
assert_contains "結果のコメントにも出る" "$(cat "$T/comment.txt")" "⚠️ GitHub Pages を有効にできませんでした"

echo "== 途中で止まったとき：何が残っているか・次にどうするかを書き、スマホに知らせる（黙って半端なリポジトリを残さない）"
out=$(run_factory half-made nextjs "説明" FACTORY_GIT_URL="$T/nowhere/%s.git" S_NTFY_TOPIC=topic); rc=$?
assert_eq "clone できない：失敗で終わる" "1" "$rc"
c=$(cat "$T/comment.txt")
assert_contains "止まったと書く" "$c" "⚠️ 新しいサービスを作る途中で止まりました"
assert_contains "理由" "$c" "❌ 作ったリポジトリを clone できません"
assert_contains "作りかけのリポジトリを知らせる" "$c" "🧹 作りかけのリポジトリが残っています：https://github.com/o/half-made"
assert_contains "スマホに知らせる" "$(cat "$T/ntfy.log" 2> /dev/null)" "工場：作る途中で止まりました"
assert_eq "コメントは1回だけ" "1" "$(grep -c '^----$' "$T/comment.txt")"
assert_contains "やり直すと続きから作ると書く" "$c" "このリポジトリの続きから作ります"

echo "== 同じ Issue でやり直した：前の実行が残した作りかけ（印があり、中身がテンプレートのまま）の続きから作る（-2 を増やさない）"
# 前の状態（作りかけのリポジトリ・印）を消さずに、もう一度動かす
again_factory() { rm -f "$T/calls.log" "$T/comment.txt"; env PATH="$T/bin:$PATH" FT="$T" GH_TOKEN=x TEMPLATE=o/ai-dev-template ISSUE="${AGAIN_ISSUE:-7}" MEMO="毎朝の天気と予定を1枚で見たい" \
    APP_NAME="$1" APP_STACK="$2" APP_DESC="$3" FACTORY_GIT_URL="$T/remotes/%s.git" FACTORY_WAIT_SEC=0 S_CLAUDE_CODE_OAUTH_TOKEN=secret1 "${@:4}" bash "$SCRIPTS_DIR/factory.sh" 2>&1; }
out=$(again_factory half-made nextjs "説明"); rc=$?
assert_eq "続きから：成功で終わる" "0" "$rc"
calls=$(cat "$T/calls.log")
assert_not_contains "新しいリポジトリは作らない" "$calls" "generate"
assert_contains "続きから作ると書く" "$(cat "$T/comment.txt")" "♻️ 前に作りかけたリポジトリの続きから作る：https://github.com/o/half-made"
assert_contains "同じリポジトリに中身を入れる" "$(file_in o/half-made CLAUDE.md)" "half-made：説明。"
assert_contains "最初のIssueも同じリポジトリに" "$calls" "POST repos/o/half-made/issues"
assert_not_contains "-2 は作らない" "$calls" "half-made-2"
echo "== もう中身が入ったリポジトリ（最初の準備を push 済み）は、印があっても続きにしない（-2 で作る）"
out=$(again_factory half-made nextjs "説明")
calls=$(cat "$T/calls.log")
assert_contains "別の名前で作る" "$calls" '"name": "half-made-2"'
assert_not_contains "続きとは書かない" "$out" "♻️"
assert_contains "元のリポジトリの中身はそのまま" "$(file_in o/half-made CLAUDE.md)" "half-made：説明。"
echo "== 別の Issue が作った作りかけ・印の無いリポジトリ（人が作った物）は、続きにしない"
run_factory other-issue nextjs "説明" FACTORY_GIT_URL="$T/nowhere/%s.git" > /dev/null
out=$(AGAIN_ISSUE=8 again_factory other-issue nextjs "説明")
assert_contains "別の Issue：別の名前で作る" "$(cat "$T/calls.log")" '"name": "other-issue-2"'
run_factory no-mark nextjs "説明" FACTORY_GIT_URL="$T/nowhere/%s.git" VAR_FAIL=FACTORY_ISSUE > "$T/out.txt"
assert_contains "印を付けられなかったら、-2 になると書く" "$(cat "$T/comment.txt")" "名前の後ろに -2 が付いた別のリポジトリになります"
assert_not_contains "続きから作るとは書かない" "$(cat "$T/comment.txt")" "続きから作ります"
out=$(again_factory no-mark nextjs "説明")
assert_contains "印が無い：別の名前で作る" "$(cat "$T/calls.log")" '"name": "no-mark-2"'
echo "== saas は続きにしない（Supabase・Stripe の物を二重に作らないため）"
run_factory half-saas saas "説明" FACTORY_GIT_URL="$T/nowhere/%s.git" > /dev/null
assert_contains "saas：-2 になると書く" "$(cat "$T/comment.txt")" "名前の後ろに -2 が付いた別のリポジトリになります"
out=$(again_factory half-saas saas "説明")
assert_contains "saas：別の名前で作る" "$(cat "$T/calls.log")" '"name": "half-saas-2"'
echo "== -9 まで全部あれば、作らずに止まる"
out=$(run_factory full nextjs "説明" EXISTING="o/full o/full-2 o/full-3 o/full-4 o/full-5 o/full-6 o/full-7 o/full-8 o/full-9"); rc=$?
assert_eq "失敗で終わる" "1" "$rc"
assert_contains "理由" "$out" "同じ名前のリポジトリがもうあります"
assert_not_contains "作らない" "$(cat "$T/calls.log")" "generate"

run_factory no-repo nextjs "説明" GENERATE_FAIL=1 > /dev/null
assert_not_contains "リポジトリを作れなかったときは、残っているとは書かない" "$(cat "$T/comment.txt")" "🧹"
assert_eq "トピックが無ければ知らせない" "no" "$([ -f "$T/ntfy.log" ] && echo yes || echo no)"
run_factory issue-ng nextjs "説明" ISSUE_FAIL=1 > /dev/null; rc=$?
assert_eq "最初のIssueを作れない：失敗で終わる" "1" "$rc"
c=$(cat "$T/comment.txt")
assert_contains "中身まで入っているので、作り直さなくてよいと書く" "$c" "🧹 リポジトリ https://github.com/o/issue-ng は、中身まで入っています。作り直さなくて大丈夫です"
assert_not_contains "消してとは書かない" "$c" "Delete this repository"

echo "== 時間切れ・取り消しで止められたとき：結果を書かないまま終わらない"
# ラベルができるのを待っている間（中身は push 済み）に、止められる
run_factory cut-off nextjs "説明" NO_LABELS=1 FACTORY_WAIT_SEC=1 S_NTFY_TOPIC=topic timeout -s TERM 10 > /dev/null; rc=$?
assert_eq "失敗で終わる" "yes" "$([ "$rc" -ne 0 ] && echo yes || echo no)"
c=$(cat "$T/comment.txt" 2> /dev/null)
assert_contains "止まったと書く" "$c" "❌ 途中で止まりました（時間切れ・取り消し・スクリプトのエラー"
assert_contains "できた所までを書く" "$c" "✅ リポジトリを作った：https://github.com/o/cut-off"
assert_contains "残っている物を書く" "$c" "https://github.com/o/cut-off は、中身まで入っています"
assert_contains "スマホに知らせる" "$(cat "$T/ntfy.log" 2> /dev/null)" "工場：作る途中で止まりました"
out=$(run_factory fine nextjs "説明"); rc=$?
assert_eq "うまくいったとき：成功で終わる" "0" "$rc"
assert_not_contains "うまくいったときは、止まったと書かない" "$(cat "$T/comment.txt")" "止まりました"

finish
