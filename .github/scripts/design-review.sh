#!/usr/bin/env bash
# デザインの関門と審査の、前後の作業（docs/pipeline.md「デザインの仕組み」）。AIは動かさない（ワークフローが動かす）。
#   design-review.sh prepare talk looks|mocks   工場の相談：talk/ の板・ざっくり画面を審査に出す
#   design-review.sh prepare mocks              既存アプリの画面案：mocks/ のざっくり画面を審査に出す
#   design-review.sh prepare site               工場のデザイン担当が作った本物の画面（ビルド済み）を撮って審査に出す
#   design-review.sh verdict MODE ROUND         審査役の答え（.judge/verdict.json）から合格かどうかを決める（MODE：looks・screen・change）
#   design-review.sh summary [FILE]             オーナーに見せる行（.judge-results/ の1回目・2回目から）
# prepare が作る物：.judge/made/（審査する画像）・.judge/refs/（比べる実在のサイトの画像。6枚まで）・.judge/brief.md（審査役に渡す紙）・
#                   .judge/gate.json（関門：設計メモの形・本物の絵の枚数・lint.mjs の FAIL）
# 出力（GITHUB_OUTPUT）：prepare → ok=true|false（審査する画像があるか）・items（審査する物の名前）・mode。verdict → pass=true|false|none・score
# 環境変数：BRIEF_TEXT か BRIEF_FILE（mocks・site のとき、審査役に渡す紙に入れる文。Issue やメモ）、
#           SHOT（テスト用。撮るコマンド。既定 node .github/scripts/shot.mjs）、LINT（テスト用。既定 node .claude/skills/taste-skill/scripts/lint.mjs）
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
OUT="${GITHUB_OUTPUT:-/dev/null}"
judge() { python3 "$here/design-judge.py" "$@"; }
read -r -a SHOT_CMD <<< "${SHOT:-node $here/shot.mjs}"
read -r -a LINT_CMD <<< "${LINT:-node .claude/skills/taste-skill/scripts/lint.mjs}"

# 実在のサイトの画像（最初の1画面だけ。-s2 などの続きは入れない）を、6枚まで .judge/refs/ に入れる
copy_refs() {
  local dir="$1" n=0 f
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  for f in "$dir"/*-1440.png; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    [ "$n" -lt 6 ] || break
    cp "$f" .judge/refs/ && n=$((n + 1))
  done
}

# lint.mjs を --json で動かして .judge/lint.json に書く（動かせなければ、ファイルを作らない＝測れていない）
run_lint() {
  "${LINT_CMD[@]}" "$@" --json > .judge/lint.json 2> /dev/null
  [ -s .judge/lint.json ] || rm -f .judge/lint.json
}

prepare() {
  local where="${1:-}" stage="${2:-}" mode=screen items="" dir="" concept="" f k
  local gate_args=() targets=()
  rm -rf .judge
  mkdir -p .judge/made .judge/refs
  case "$where" in
    talk | mocks)
      dir="$where"
      if [ "$where" = talk ] && [ "$stage" = looks ]; then
        mode=looks
        for k in 1 2 3; do
          f="$dir/look-$k-1440.png"
          if [ -f "$f" ] && [ ! -L "$f" ] && [ -f "$dir/look-$k.html" ] && [ ! -L "$dir/look-$k.html" ]; then
            cp "$f" .judge/made/ && items="$items look-$k" && targets+=("$dir/look-$k.html")
          fi
        done
        gate_args+=(--part looks)
      else
        for k in a b; do
          [ -f "$dir/mock-$k.html" ] && [ ! -L "$dir/mock-$k.html" ] || continue
          targets+=("$dir/mock-$k.html"); items="$items mock-$k"
        done
        if [ "${#targets[@]}" -gt 0 ]; then
          # 下の欄まで審査する：PC は4画面ぶん、スマホは3画面ぶん
          "${SHOT_CMD[@]}" --out .judge/made --widths 1440 --scrolls 4 "${targets[@]}" > /dev/null 2>&1 || echo "::warning::PC の幅で撮れなかった物があります"
          "${SHOT_CMD[@]}" --out .judge/made --widths 390 --scrolls 3 "${targets[@]}" > /dev/null 2>&1 || echo "::warning::スマホの幅で撮れなかった物があります"
        fi
      fi
      copy_refs "$dir/refs"
      concept="$dir/concept.md"
      [ -f "$dir/img/credits.json" ] && gate_args+=(--credits "$dir/img/credits.json")
      if [ "$where" = talk ]; then
        judge brief --state talk/state.json --concept talk/concept.md --stage "$stage" > .judge/brief.md 2> /dev/null || : > .judge/brief.md
      fi
      ;;
    site)
      local pages=(/) p
      if [ -f factory-pages.txt ] && [ ! -L factory-pages.txt ]; then
        while IFS= read -r p; do
          [[ "$p" =~ ^/([a-z0-9][a-z0-9/-]{0,60})?(\?[a-z0-9=\&_-]{1,40})?$ ]] && [ "$p" != / ] && [ "${#pages[@]}" -lt 3 ] && pages+=("$p")
        done < <(head -n 10 factory-pages.txt | tr -d '\r')
      fi
      "${SHOT_CMD[@]}" --serve --out .judge/made --widths 1440 --scrolls 4 "${pages[@]}" > /dev/null 2>&1 || echo "::warning::PC の幅で撮れなかった物があります"
      "${SHOT_CMD[@]}" --serve --out .judge/made --widths 390 --scrolls 3 / > /dev/null 2>&1 || echo "::warning::スマホの幅で撮れなかった物があります"
      items=" site"
      targets=(src)
      copy_refs factory-refs/shots
      # 本物の画面は、ページなら本物の絵を4枚以上（taste-skill の critique.md の線）
      concept=factory-refs/concept.md
      gate_args+=(--min-real 4)
      [ -f public/photos/credits.json ] && gate_args+=(--credits public/photos/credits.json)
      ;;
    *)
      echo "使い方：design-review.sh prepare talk looks|mocks ｜ prepare mocks ｜ prepare site" >&2
      return 2
      ;;
  esac
  if [ "$where" != talk ]; then
    if [ -n "${BRIEF_FILE:-}" ] && [ -f "$BRIEF_FILE" ] && [ ! -L "$BRIEF_FILE" ]; then BRIEF_TEXT=$(head -c 6000 "$BRIEF_FILE"); fi
    {
      echo "# 審査役に渡す紙（何のサービスか・オーナーが決めた事）"
      echo
      printf '%s\n' "${BRIEF_TEXT:-（説明が無い）}" | head -c 6000
      echo
      echo "## オーナーが決めた事（絵に出ていなければ owner は「いいえ」）"
      echo
      echo "- 上の文の中の、オーナーの注文・見た目の答え・「本物の〇〇を使う」のような決め（無ければ owner は「はい」にする）"
      echo "- 「（中身の決まり）」と付いた答えと、押した後の動き・確認・書き出し・設定・明暗の切り替え・お金のような静止画に出せない決めは、owner の判定に使わない（絵に無くても「はい」）"
      if [ -f "$concept" ] && [ ! -L "$concept" ]; then
        echo
        echo "## 作った側が書いた設計メモ（絵を見て「見えた物」を書き終えてから読む。書いてあっても、絵に出ていなければ無いのと同じ）"
        echo
        head -c 6000 "$concept"
      fi
    } > .judge/brief.md
  fi
  if [ "${#targets[@]}" -gt 0 ]; then
    local lint_extra=()
    # 道具の画面は、表の線などを許す測り方にする
    if grep -qE '^種類[:：].*(道具|アプリ|管理|app)' "$concept" 2> /dev/null; then lint_extra=(--app); fi
    # 今ある見た目への追加は、docs/design.md の決まりが lint より上なので、lint の FAIL では止めない
    if ! grep -qE '^場合[:：].*追加' "$concept" 2> /dev/null; then
      run_lint "${targets[@]}" "${lint_extra[@]}"
      [ -f .judge/lint.json ] && gate_args+=(--lint .judge/lint.json)
    fi
    GITHUB_OUTPUT=/dev/null judge gate --concept "$concept" "${gate_args[@]}" --out .judge/gate.json "${targets[@]}" > /dev/null || true
  fi
  local n
  n=$(find .judge/made -maxdepth 1 -type f -name '*.png' | wc -l)
  echo "審査する画像：$n 枚・審査する物：${items# }・種類：$mode"
  [ -f .judge/gate.json ] && jq -r '.problems[]? | "関門：" + .' .judge/gate.json
  if [ "$n" -gt 0 ] && [ -n "$items" ]; then echo "ok=true" >> "$OUT"; else echo "ok=false" >> "$OUT"; fi
  { echo "items=$(printf '%s' "${items# }" | sed 's/ /・/g')"; echo "mode=$mode"; } >> "$OUT"
}

verdict() {
  local mode="${1:-}" round="${2:-1}"
  mkdir -p .judge-results
  local gate_args=()
  [ -f .judge/gate.json ] && gate_args=(--gate .judge/gate.json)
  judge verdict --mode "$mode" .judge/verdict.json "${gate_args[@]}" --out ".judge-results/r$round.json" --fix .judge/fix.md
}

summary() {
  local files=()
  [ -f .judge-results/r1.json ] && files+=(.judge-results/r1.json)
  [ -f .judge-results/r2.json ] && files+=(.judge-results/r2.json)
  [ "${#files[@]}" -gt 0 ] || return 0
  if [ -n "${1:-}" ]; then judge summary "${files[@]}" > "$1"; else judge summary "${files[@]}"; fi
}

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
  prepare) prepare "$@" ;;
  verdict) verdict "$@" ;;
  summary) summary "$@" ;;
  *) echo "使い方：design-review.sh prepare|verdict|summary …（ファイルの先頭を読む）" >&2; exit 2 ;;
esac
