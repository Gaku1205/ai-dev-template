#!/usr/bin/env bash
# 工場：ai-dev-template に書いた1行のIssue（「新サービス：〜」）から、新しいサービスのリポジトリを作って、パイプラインに渡す。
# factory.yml の build ジョブから呼ぶ（AIが決めた名前と言語は、ここで形を確かめてから使う）。
#   1. テンプレートからリポジトリを作る（同じ名前があれば -2, -3 … を付ける）
#   2. パイプラインの秘密と変数を、テンプレートの物から写す
#   3. Vercel のプロジェクトを作ってつなぐ（Next.js か Web のゲームで、VERCEL_TOKEN があるとき）
#   4. 中身を整えて main に push する（CLAUDE.md・仕様書の説明、デザイン担当が作った画面とデザイン仕様と道具、Python なら見本に切り替え）。この push で Bootstrap が動く
#   5. main を守る（PRとCIの check を必須にする。管理者は通れる）
#   6. Bootstrap がラベルを作るのを待って、最初のIssueを作る（そこから先はいつものパイプライン）。
#      デザイン担当が画面を作れていれば、作れなかった残り（todo）だけをIssueにする。作れていなければ、1行のメモを最初のIssueにする
#   7. 元のIssueに結果を書いて閉じる
#
# 環境変数：
#   GH_TOKEN（FACTORY_TOKEN：リポジトリを作れる鍵）、TEMPLATE（owner/repo）、ISSUE（元のIssueの番号）、MEMO（1行のメモ）
#   MEMO_DETAIL（任意）：元のIssueの本文（詳しいメモ：載せたい中身・見た目のスタイルなど）。最初のIssueの本文に添える
#   APP_NAME・APP_STACK（nextjs・saas・python・game・webgame）・APP_DESC（1行の説明）：AIが決めた物
#   saas のとき：SUPABASE_ACCESS_TOKEN・STRIPE_SECRET_KEY（Environment「factory」）、PRICE_FILE（任意。デザイン担当が決めた月額の円）
#   S_<名前>：写す秘密の値（S_CLAUDE_CODE_OAUTH_TOKEN など）、V_<名前>：写す変数の値（V_PIPELINE_APP_ID など）
#   DESIGN_FILE・CONTEXT_FILE・LIBS_FILE（任意）：デザイン担当が書いたデザイン仕様・使う人と場面・入れた道具（1行1つ）
#   SITE_DIR（任意）：デザイン担当が作った画面（src/ と public/）。確認コマンドが通った印（.checks-ok）があり、形が正しいときだけ入れる
#   DESIGN_REF_DIR（任意）：デザイン担当が作った画面を最後に撮った画像（PNG）。docs/design-ref/ に入れ、あとの Issue の目標の絵にする
#   IDEA_FILE（任意）：ゲームのデザイン担当が選んだ遊び方のアイデア（board.md の「## アイデア」）。結果のコメントに畳んで載せる
#   TODO_FILE（任意）：デザイン担当が作れなかった残り（1行1つ「- 」、最大3個）。画面を入れたときだけ、1つずつ Issue にする
#   VERCEL_TOKEN・VERCEL_TEAM_ID（任意）、COMMENT_TOKEN（元のIssueにコメントする鍵。無ければ GH_TOKEN）
#   テスト用：FACTORY_GIT_URL（clone 先の書式。%s にリポジトリ名）、VERCEL_API、FACTORY_WAIT_SEC
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=factory-libs.sh
source "$HERE/factory-libs.sh"
OWNER="${TEMPLATE%%/*}"
WAIT="${FACTORY_WAIT_SEC:-5}"
GIT_URL="${FACTORY_GIT_URL:-https://x-access-token:${GH_TOKEN}@github.com/%s.git}"
VERCEL_API="${VERCEL_API:-https://api.vercel.com}"
COPY_SECRETS="CLAUDE_CODE_OAUTH_TOKEN PIPELINE_APP_PRIVATE_KEY PIPELINE_TOKEN NTFY_TOPIC VERCEL_TOKEN"
COPY_VARS="PIPELINE_APP_ID NOTIFY_EVENTS AGENT_DESK_URL VERCEL_TEAM_ID"
report=()
gallery=""
note() { report+=("$1"); echo "$1"; }
fail() {
  note "❌ $1"
  say_result "⚠️ 新しいサービスを作る途中で止まりました"
  exit 1
}
say_result() {
  local body
  body="$1

$(printf -- '- %s\n' "${report[@]}")${gallery}"
  GH_TOKEN="${COMMENT_TOKEN:-$GH_TOKEN}" gh api "repos/$TEMPLATE/issues/$ISSUE/comments" -f body="$body" > /dev/null 2>&1 || true
}

# ---- 0. AIが決めた物の形を確かめる（ここで使う値は、この形の物だけ） ----
valid_plan() {
  [[ "$APP_NAME" =~ ^[a-z][a-z0-9-]{2,38}$ ]] || { echo "名前「$APP_NAME」は小文字の英数字と - で3〜39文字にする"; return 1; }
  case "$APP_STACK" in nextjs | saas | python | game | webgame) ;; *) echo "言語「$APP_STACK」は nextjs・saas・python・game・webgame のどれか"; return 1 ;; esac
  [ -n "$APP_DESC" ] && [ "${#APP_DESC}" -le 120 ] || { echo "説明は1〜120文字"; return 1; }
  case "$APP_DESC" in *$'\n'* | *'`'* | *'$('*) echo "説明に改行・記号（\` \$( ）は使わない"; return 1 ;; esac
}
why=$(valid_plan) || fail "AIが決めた名前・言語・説明の形が正しくありません：$why"

# ---- 1. リポジトリを作る ----
name="$APP_NAME"
for i in 2 3 4 5 6 7 8 9; do
  gh api "repos/$OWNER/$name" > /dev/null 2>&1 || break
  name="${APP_NAME}-$i"
done
gh api "repos/$OWNER/$name" > /dev/null 2>&1 && fail "同じ名前のリポジトリがもうあります（$OWNER/$APP_NAME から -9 まで）"
NEW="$OWNER/$name"
if ! out=$(gh api -X POST "repos/$TEMPLATE/generate" -f owner="$OWNER" -f name="$name" -f description="$APP_DESC" -F private=false 2>&1); then
  fail "リポジトリを作れませんでした（$(printf '%s' "$out" | tail -1 | cut -c1-160)）。FACTORY_TOKEN に、全部のリポジトリへの Administration（Read and write）が要ります"
fi
note "✅ リポジトリを作った：https://github.com/$NEW（${APP_STACK}）"
ready=no
for _ in $(seq 1 30); do
  if gh api "repos/$NEW/branches/main" > /dev/null 2>&1; then ready=yes; break; fi
  sleep "$WAIT"
done
[ "$ready" = yes ] || fail "作ったリポジトリの main が用意できません"

# ---- 2. 秘密と変数を写す ----
copied=()
for n in $COPY_SECRETS; do
  v="S_$n"; val="${!v:-}"
  [ -z "$val" ] && continue
  # Vercel の鍵は、Vercel で公開する物（Next.js・Web のゲーム）にだけ入れる（公開をまとめて頼む deploy-vercel.yml が使う）
  [ "$n" = VERCEL_TOKEN ] && [ "$APP_STACK" != nextjs ] && [ "$APP_STACK" != saas ] && [ "$APP_STACK" != webgame ] && continue
  if printf '%s' "$val" | gh secret set "$n" --repo "$NEW" > /dev/null 2>&1; then copied+=("$n"); else note "⚠️ 秘密 $n を写せませんでした（FACTORY_TOKEN に Secrets（Read and write）が要ります）"; fi
done
for n in $COPY_VARS; do
  v="V_$n"; val="${!v:-}"
  [ -z "$val" ] && continue
  if gh variable set "$n" --repo "$NEW" --body "$val" > /dev/null 2>&1; then copied+=("$n"); else note "⚠️ 変数 $n を写せませんでした（FACTORY_TOKEN に Variables（Read and write）が要ります）"; fi
done
[ "${#copied[@]}" -gt 0 ] && note "✅ 秘密と変数を写した：${copied[*]}"

# ---- 3. Vercel ----
vercel_note=""
if [ "$APP_STACK" = nextjs ] || [ "$APP_STACK" = saas ] || [ "$APP_STACK" = webgame ]; then
  framework=nextjs; [ "$APP_STACK" = webgame ] && framework=vite
  if vout=$(REPO_FULL="$NEW" PROJECT="$name" FRAMEWORK="$framework" "$HERE/factory-vercel.sh" 2>&1); then
    note "✅ Vercel のプロジェクトを作ってつないだ"
    vercel_note="Vercel：$vout"
  else
    note "⚠️ $vout"
  fi
fi

# ---- 3b. 会員と課金（saas）：Supabase のプロジェクト・Stripe の商品と値段・Vercel の環境変数（最初の公開より前に入れる） ----
saas_state=$(mktemp); saas_notes=$(mktemp)
vproject="${vercel_note#Vercel：}"; [ -n "$vproject" ] || vproject="$name"
if [ "$APP_STACK" = saas ]; then
  price=500
  if [ -n "${PRICE_FILE:-}" ] && [ -f "$PRICE_FILE" ] && [ ! -L "$PRICE_FILE" ]; then
    p=$(head -c 20 "$PRICE_FILE" | tr -dc '0-9'); [ -n "$p" ] && [ "$p" -ge 100 ] && [ "$p" -le 10000 ] && price="$p"
  fi
  STATE_FILE="$saas_state" NOTES_FILE="$saas_notes" PROJECT="$vproject" REPO_FULL="$NEW" PRICE_YEN="$price" APP_TITLE="$name" \
    "$HERE/factory-saas-provision.sh" init || true
  while IFS= read -r line; do [ -n "$line" ] && note "$line"; done < "$saas_notes"
  : > "$saas_notes"
fi

# ---- 4. 中身を整えて push ----
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck disable=SC2059
if ! git clone -q "$(printf "$GIT_URL" "$NEW")" "$work/app" 2> /dev/null; then fail "作ったリポジトリを clone できません"; fi
(
  cd "$work/app" || exit 1
  # CLAUDE.md の1行目の説明と、仕様書の「目的」を書く（説明やメモの記号で壊れないよう、置き換えは python で文字のまま行う）
  NAME="$name" python3 - <<'PY2'
import os
name, desc, memo = os.environ["NAME"], os.environ["APP_DESC"], os.environ["MEMO"]
def swap(path, old, new):
    s = open(path, encoding="utf-8").read()
    open(path, "w", encoding="utf-8").write(s.replace(old, new, 1))
swap("CLAUDE.md", "（アプリの説明を1〜2行で書く）。", f"{name}：{desc.rstrip('。')}。")
# テンプレート本体だけの物を消す：「ai-dev-template 自身の作業」の節（自分のスクリプトを自動でマージしてよい印を含む）、その但し書き、
# Next.js 以外の言語への案内（工場が言語を決めて切り替えるので要らない）。Bootstrap も消すが、作った直後の Bootstrap は
# 鍵が写される前に動いてコミットできないことがあるので、ここで確実に消す
import re
s = open("CLAUDE.md", encoding="utf-8").read()
s = re.sub(r"\n## ai-dev-template 自身の作業.*?(?=\n## )", "\n", s, count=1, flags=re.S)
s = s.replace("。ただし ai-dev-template 自身だけ、下の「ai-dev-template 自身の作業」で許した物は触ってよい", "")
s = s.replace("（パイプラインの説明。ai-dev-template 自身だけ、`docs/pipeline.md` は下の節で触ってよい）", "（パイプラインの説明）")
s = re.sub(r"（Next\.js 以外で作るなら[^）]*）", "", s, count=1)
open("CLAUDE.md", "w", encoding="utf-8").write(s)
swap("docs/spec.md", "（誰の、どんな困りごとを、どう減らすか）", f"{desc}（元のメモ：{memo}）")
# README は、テンプレートの説明ではなく、このサービスの説明にする
template = os.environ["TEMPLATE"]
open("README.md", "w", encoding="utf-8").write(f"""# {name}

{desc}

- 仕様：[docs/spec.md](docs/spec.md)
- 見た目：[docs/design.md](docs/design.md)

[{template.split('/')[1]}](https://github.com/{template}) の工場で、1行のメモ（{memo}）から作ったサービスです。Issue を書くと、AI が清書・実装・レビュー・マージまで進めます（[docs/pipeline.md](docs/pipeline.md)）。
""")
PY2
  if [ "$APP_STACK" = python ]; then
    "$HERE/factory-python.sh" . || exit 1
  fi
  # 会員と月額課金：Next.js に、ログイン（Supabase）と有料プラン（Stripe）の土台を入れる（examples/saas）
  if [ "$APP_STACK" = saas ]; then
    "$HERE/factory-saas.sh" . lock || exit 1
  fi
  # ゲーム：ブラウザの技術で作り、Electron で Windows の exe にする雛形（examples/game）に切り替える
  if [ "$APP_STACK" = game ]; then
    "$HERE/factory-game.sh" . exe || exit 1
  fi
  # Web のゲーム：同じくブラウザの技術で作り、Vercel で公開してブラウザ（スマホも）で遊ぶ雛形（examples/webgame）に切り替える
  if [ "$APP_STACK" = webgame ]; then
    "$HERE/factory-game.sh" . web || exit 1
  fi
  # デザイン担当が書いた「使う人・使う場面」を、仕様書の「前提」の「使う人：」に入れる（短い箇条書きだけ）
  if [ -n "${CONTEXT_FILE:-}" ] && [ -f "$CONTEXT_FILE" ] && [ ! -L "$CONTEXT_FILE" ] && [ "$(wc -c < "$CONTEXT_FILE")" -le 2000 ]; then
    CONTEXT_FILE="$CONTEXT_FILE" python3 - <<'PY3'
import os
ctx = [l.rstrip() for l in open(os.environ["CONTEXT_FILE"], encoding="utf-8") if l.strip().startswith(("-", "*"))][:6]
if ctx:
    body = "\n".join("  " + l.lstrip().replace("* ", "- ", 1) for l in ctx)
    s = open("docs/spec.md", encoding="utf-8").read()
    s = s.replace("- 使う人：\n", "- 使う人・使う場面（デザイン担当の分析。推定を含む）：\n" + body + "\n", 1)
    open("docs/spec.md", "w", encoding="utf-8").write(s)
PY3
  fi
  # デザイン担当が書いたデザイン仕様（形が正しいときだけ。だめなら雛形のまま）
  if [ -n "${DESIGN_FILE:-}" ] && [ -f "$DESIGN_FILE" ] && [ ! -L "$DESIGN_FILE" ]; then
    size=$(wc -c < "$DESIGN_FILE")
    if [ "$(head -1 "$DESIGN_FILE")" = "# デザイン仕様" ] && [ "$size" -ge 800 ] && [ "$size" -le 60000 ]; then
      cp "$DESIGN_FILE" docs/design.md
      echo "DESIGN=yes" > "$work/design.flag"
    else
      echo "DESIGN=bad" > "$work/design.flag"
    fi
  fi
  # デザイン担当が作った画面（src/ と public/）。デザイン仕様を使うときで、確認コマンドが通った印があり、形が正しいときだけ入れる
  if [ "$(cat "$work/design.flag" 2> /dev/null)" = DESIGN=yes ] && [ "$APP_STACK" != python ] && [ -n "${SITE_DIR:-}" ] &&
    [ -d "$SITE_DIR" ] && [ ! -L "$SITE_DIR" ] && [ -f "$SITE_DIR/.checks-ok" ]; then
    entry=src/app/page.tsx
    case "$APP_STACK" in game | webgame) entry=src/main.ts ;; esac
    if result=$(SITE_DIR="$SITE_DIR" SITE_ENTRY="$entry" python3 "$HERE/factory-site.py" . 2>&1); then
      echo "SITE=yes $result" > "$work/site.flag"
      # デザイン担当の画面で src/ が置き換わるので、会員と課金の土台のうち無くなった物を戻す（作り直した見た目は残す）
      [ "$APP_STACK" = saas ] && "$HERE/factory-saas.sh" . keep > /dev/null
    else
      echo "SITE=bad $(printf '%s' "$result" | tail -1 | cut -c1-200)" > "$work/site.flag"
    fi
  fi
  # 最後に撮った画像（目標の絵）。決まった形の物だけ（名前は英小文字・数字・-、本物の PNG で 3MB まで、合わせて 40 枚・25MB まで）
  if [ "$(cat "$work/design.flag" 2> /dev/null)" = DESIGN=yes ] && [ -n "${DESIGN_REF_DIR:-}" ] && [ -d "$DESIGN_REF_DIR" ] && [ ! -L "$DESIGN_REF_DIR" ]; then
    count=0; total=0
    for f in "$DESIGN_REF_DIR"/*; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      base=$(basename "$f")
      [[ "$base" =~ ^[a-z0-9][a-z0-9-]{0,60}\.png$ ]] || continue
      size=$(wc -c < "$f")
      [ "$size" -le 3145728 ] && [ "$(head -c 8 "$f" | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ] || continue
      [ "$count" -lt 40 ] && [ $((total + size)) -le 26214400 ] || continue
      mkdir -p docs/design-ref
      cp "$f" "docs/design-ref/$base"
      count=$((count + 1)); total=$((total + size))
    done
    [ "$count" -gt 0 ] && echo "REF=$count" > "$work/ref.flag"
  fi
  # デザイン担当が入れた動き・3D の道具（GSAP・Lenis・three.js など）。デザイン仕様を使うときだけ、決まった物の中からだけ入れる（factory-libs.sh）
  # （アプリの AI は依存パッケージを足せないので、作るときに工場が入れておく）
  if [ "$APP_STACK" != python ] && [ "$(cat "$work/design.flag" 2> /dev/null)" = DESIGN=yes ] &&
    [ -n "${LIBS_FILE:-}" ] && [ -f "$LIBS_FILE" ] && [ ! -L "$LIBS_FILE" ] && [ "$(wc -c < "$LIBS_FILE")" -le 200 ]; then
    pkgs=()
    while IFS= read -r lib; do
      lib="$(printf '%s' "$lib" | tr -d '[:space:]')"
      [ -z "$lib" ] && continue
      if got=$(lib_pkgs "$lib"); then
        mapfile -t -O "${#pkgs[@]}" pkgs <<< "$got"
      else
        echo "LIBS_SKIPPED=yes" >> "$work/libs.flag"
      fi
    done < "$LIBS_FILE"
    if [ "${#pkgs[@]}" -gt 0 ]; then
      mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | sort -u)
      if npm install --package-lock-only --no-audit --no-fund --ignore-scripts --save "${pkgs[@]}" > "$work/npm.log" 2>&1; then
        echo "LIBS=${pkgs[*]}" >> "$work/libs.flag"
      else
        git checkout -q -- package.json package-lock.json 2> /dev/null || true
        echo "LIBS_FAILED=yes" >> "$work/libs.flag"
      fi
    fi
  fi
  # Vercel の鍵を入れたら、Vercel がマージのたびに自分で公開するのを止め、deploy-vercel.yml が落ち着いてから1回だけ公開する
  # （無料プランの「1日100回まで」に当たらないように）。鍵が無いときは今までどおり Vercel が自分で公開する
  if { [ "$APP_STACK" = nextjs ] || [ "$APP_STACK" = saas ] || [ "$APP_STACK" = webgame ]; } && [ -n "${S_VERCEL_TOKEN:-}" ] && [ -f vercel.json ]; then
    # ignoreCommand（直前のコミットとの差だけを見る）は消す。まとめて公開すると、間のコミットの変更を見落として公開が飛ばされるため。
    # パイプラインの物しか変わっていない時に公開しないのは、deploy-vercel.sh が決める
    jq '.git.deploymentEnabled = false | del(.ignoreCommand)' vercel.json > vercel.json.new && mv vercel.json.new vercel.json
  fi
  # 工場は テンプレートの例（examples/）を新しいサービスには持ち込まない
  rm -rf examples
  # 工場のIssueの雛形も、テンプレート本体だけの物
  rm -f .github/ISSUE_TEMPLATE/new-service.yml
  git add -A
  git -c user.name="pipeline-factory" -c user.email="noreply@github.com" commit -q -m "工場：${name} の最初の準備（${APP_STACK}）"
  git push -q origin HEAD:main
) || fail "最初の準備を push できませんでした"
note "✅ CLAUDE.md・仕様書・README に説明を書いて push した（Bootstrap が動く）"
# Vercel が自分で公開しない形（上の deploymentEnabled: false）にしたので、最初の公開はここで頼む（あとは deploy-vercel.yml）
if [ -n "$vercel_note" ] && [ -n "${S_VERCEL_TOKEN:-}" ]; then
  if dout=$(GITHUB_REPOSITORY="$NEW" VERCEL_TOKEN="$S_VERCEL_TOKEN" VERCEL_TEAM_ID="${VERCEL_TEAM_ID:-}" "$HERE/deploy-vercel.sh" 2>&1); then
    note "✅ 最初の公開を頼んだ（このあとは、マージが落ち着いてから最新の main を1回だけ公開する）"
  else
    note "⚠️ 最初の公開を頼めませんでした（$(printf '%s' "$dout" | tail -1 | sed 's/^::error:://' | cut -c1-160)）。次のマージのあとに公開されます"
  fi
fi
site_flag=$(cat "$work/site.flag" 2> /dev/null)
[ "$APP_STACK" = game ] && note "🎮 ゲームは Windows の exe（1ファイル）にして、公開のたびに GitHub Releases に置く：https://github.com/$NEW/releases/latest（最初の公開が終わると出る）"
case "$(cat "$work/design.flag" 2> /dev/null)" in
  DESIGN=yes) note "✅ デザイン担当：実例を集めて撮り、方向を決めて、デザイン仕様（docs/design.md）を書いた" ;;
  DESIGN=bad) note "⚠️ デザイン担当が書いたデザイン仕様の形が違ったので、雛形のままにした" ;;
esac
case "$site_flag" in
  "SITE=yes "*) note "✅ デザイン担当が本物の画面を作り、撮って実例と見比べて直した。確認コマンドも通った（${site_flag#SITE=yes }）" ;;
  "SITE=bad "*) note "⚠️ デザイン担当が作った画面の形が正しくなかったので入れなかった（${site_flag#SITE=bad }）。最初のIssueで作り直す" ;;
esac
ref_line=$(grep '^REF=' "$work/ref.flag" 2> /dev/null | head -1)
[ -n "$ref_line" ] && note "✅ 最後に撮った画面の画像 ${ref_line#REF=} 枚を、目標の絵として docs/design-ref/ に入れた"
# 結果のコメントに画面の画像を貼る（公開を待たずに、どんな画面かを見られるように）。PC の最初の1画面とスクロールした所、スマホの最初の1画面
if [ -n "$ref_line" ]; then
  shots=""
  for want in top-1440.png top-1440-s2.png top-1440-s3.png top-1440-s4.png scene-play-1440.png top-390.png top-390-s2.png scene-play-390.png; do
    [ -f "$work/app/docs/design-ref/$want" ] || continue
    case "$want" in *-390*) width=260 ;; *) width=720 ;; esac
    shots="${shots}<img src=\"https://raw.githubusercontent.com/${NEW}/main/docs/design-ref/${want}\" width=\"${width}\" alt=\"${want%.png}\"> "
  done
  [ -n "$shots" ] && gallery="

## できた画面（デザイン担当が作って撮った物。ほかの画像は [docs/design-ref/](https://github.com/${NEW}/tree/main/docs/design-ref)）

${shots}"
fi
# ゲームの遊び方のアイデア（ありきたりにしないために、デザイン担当が案を出して選んだ物）。AIが書いた物なので、畳んで載せ、人への呼びかけ（@）は効かなくする
if [ -n "${IDEA_FILE:-}" ] && [ -f "$IDEA_FILE" ] && [ ! -L "$IDEA_FILE" ] && [ "$(wc -c < "$IDEA_FILE")" -le 12000 ]; then
  idea=$(head -c 6000 "$IDEA_FILE" | sed 's/@/@\&#8203;/g; s#</details>##g')
  [ -n "$idea" ] && gallery="${gallery}

<details><summary>遊び方のアイデア（デザイン担当が 10 個出して、ありきたりな物を捨てて選んだ物）</summary>

${idea}

</details>"
fi
libs_line=$(grep '^LIBS=' "$work/libs.flag" 2> /dev/null | head -1)
[ -n "$libs_line" ] && note "✅ デザイン担当が使った道具を入れた：${libs_line#LIBS=}"
grep -q '^LIBS_FAILED=' "$work/libs.flag" 2> /dev/null && note "⚠️ 動き・3D の道具を入れられませんでした（npm install が失敗。入れずに進めた）"
grep -q '^LIBS_SKIPPED=' "$work/libs.flag" 2> /dev/null && note "⚠️ デザイン担当が、決まった物（${FACTORY_LIB_NAMES// /・}）以外の道具を書いていたので、それは入れなかった"

# ---- 5. main を守る ----
ruleset=$(jq -nc '{
  name: "main を守る", target: "branch", enforcement: "active",
  conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
  rules: [
    {type: "pull_request", parameters: {required_approving_review_count: 0, dismiss_stale_reviews_on_push: false, require_code_owner_review: false, require_last_push_approval: false, required_review_thread_resolution: false}},
    {type: "required_status_checks", parameters: {strict_required_status_checks_policy: false, required_status_checks: [{context: "check"}]}}
  ],
  bypass_actors: [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always"}]
}')
if printf '%s' "$ruleset" | gh api -X POST "repos/$NEW/rulesets" --input - > /dev/null 2>&1; then
  note "✅ main を守った（PRと CI の check が必須。管理者は通れる）"
else
  note "⚠️ main を守る設定を作れませんでした（Settings → Rules → Rulesets で作る。README の手順6）"
fi

# ---- 6. 最初のIssue ----
labels=no
for _ in $(seq 1 36); do
  if gh api "repos/$NEW/labels?per_page=100" -q '.[].name' 2> /dev/null | grep -qx "ai:plan"; then labels=yes; break; fi
  sleep "$WAIT"
done
[ "$labels" = yes ] || note "⚠️ Bootstrap のラベルがまだできていません（Actions の Bootstrap を見る）。Issue は先に作ります"
if [ "${site_flag%% *}" = SITE=yes ]; then
  # 画面はもうある。作れなかった残りだけを Issue にする（1行1つ「- 」、最大3個、1つ 200 文字まで）
  todos=()
  if [ -n "${TODO_FILE:-}" ] && [ -f "$TODO_FILE" ] && [ ! -L "$TODO_FILE" ] && [ "$(wc -c < "$TODO_FILE")" -le 4000 ]; then
    while IFS= read -r line; do
      item=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[-*][[:space:]]+//' | tr -d '`' | cut -c1-200)
      [ -n "$item" ] && [ "${#todos[@]}" -lt 3 ] && todos+=("$item")
    done < <(grep -E '^[[:space:]]*[-*][[:space:]]+' "$TODO_FILE")
  fi
  made=()
  for item in "${todos[@]}"; do
    body="工場（${TEMPLATE}#${ISSUE}）のデザイン担当が最初の画面を作ったときに、時間が足りず残った作業です。見た目は docs/design.md と docs/design-ref/ の画像に合わせてください（作った画面を撮って見比べる）。

元のメモ：${MEMO}"
    if n=$(gh api "repos/$NEW/issues" -f title="$(printf '%s' "$item" | cut -c1-80)" -f body="$body" -q .number 2>&1); then made+=("#$n"); fi
  done
  if [ "${#made[@]}" -gt 0 ]; then
    note "✅ 作りきれなかった残りを Issue にした：${made[*]}（自動で企画に回る）"
  else
    note "✅ 最初の画面はもうできているので、最初のIssueは作っていない（足したい物は、そのリポジトリにIssueを書く）"
  fi
else
  look="見た目は docs/design.md のとおりに作ってください。"
  [ -n "$ref_line" ] && look="見た目は docs/design.md のとおりに作り、docs/design-ref/ の画像を目標の絵にしてください（作った画面を撮って、見比べて直す）。"
  body="工場（${TEMPLATE}#${ISSUE}）で作ったサービスの、最初のメモです。企画AIが清書して、そのまま実装まで進めます。最初の画面を一から作る大きい作業なので size:L（強いモデル）にしています。${look}"
  if [ -n "$(printf '%s' "${MEMO_DETAIL:-}" | tr -d '[:space:]')" ]; then
    body="${body}

## 詳しいメモ（元のIssueの本文）

${MEMO_DETAIL}"
  fi
  first=$(gh api "repos/$NEW/issues" -f title="$MEMO" -f "labels[]=size:L" \
    -f body="$body" -q .number 2>&1) \
    || fail "最初のIssueを作れませんでした"
  note "✅ 最初のIssue：https://github.com/$NEW/issues/$first（自動で企画に回る）"
fi
# 公開アドレス：Vercel が最初の公開でアドレスを決めるまで待って調べる（同じ名前がほかの人に使われていると、名前の後ろに文字が付く）
if [ -n "$vercel_note" ]; then
  if site=$(PROJECT="${vercel_note#Vercel：}" REPO_FULL="$NEW" "$HERE/factory-vercel-url.sh"); then
    if [ "${site_flag%% *}" = SITE=yes ]; then
      note "🌐 公開アドレス：$site（リポジトリの Website 欄にも入れた。最初の画面は、公開が終わるとすぐ見られる）"
    else
      note "🌐 公開アドレス：$site（リポジトリの Website 欄にも入れた。最初の画面は、最初のIssueがマージされると出る）"
    fi
    # 会員と課金：公開アドレスが決まったので、Stripe の通知の受け口とログインの戻り先を入れ、環境変数を効かせるため公開をやり直す
    if [ "$APP_STACK" = saas ] && [ -s "$saas_state" ]; then
      STATE_FILE="$saas_state" NOTES_FILE="$saas_notes" PROJECT="$vproject" REPO_FULL="$NEW" \
        "$HERE/factory-saas-provision.sh" url "$site" || true
      while IFS= read -r line; do [ -n "$line" ] && note "$line"; done < "$saas_notes"
      if [ -n "${S_VERCEL_TOKEN:-}" ] && GITHUB_REPOSITORY="$NEW" VERCEL_TOKEN="$S_VERCEL_TOKEN" VERCEL_TEAM_ID="${VERCEL_TEAM_ID:-}" VERCEL_FORCE=1 "$HERE/deploy-vercel.sh" > /dev/null 2>&1; then
        note "✅ 環境変数を効かせるため、公開をやり直した"
      else
        note "⚠️ 公開をやり直せませんでした（次のマージのあとの公開で、Stripe の通知が効く）"
      fi
    fi
  else
    note "⚠️ 公開アドレスがまだ決まっていません（Vercel の画面の Domains で確かめる）"
  fi
fi

# ---- 7. 結果 ----
say_result "🏭 新しいサービス **${name}** を作りました。ここから先は、いつものパイプラインが進めます。"
GH_TOKEN="${COMMENT_TOKEN:-$GH_TOKEN}" gh api -X PATCH "repos/$TEMPLATE/issues/$ISSUE" -f state=closed > /dev/null 2>&1 || true
echo "NEW_REPO=$NEW" >> "${GITHUB_OUTPUT:-/dev/null}"
