#!/usr/bin/env bash
# AIへの指示（--append-system-prompt）を、部品（prompts/*.md）から組んで標準出力に出す。
# 要る部品だけを順に連結する。意味は元のワークフローの指示と同じ（分けただけ）。
#
# 使い方：
#   compose-prompt.sh --mode implement|mention [--visual-tests] [--docs]
#   compose-prompt.sh --mode mention --auto      作業フォルダ（カレント）から自分で判定する
#
# 部品の選び方：
#   base            常に入れる
#   read-sections   --docs のとき（長い仕様書があるとき）
#   merge-main      常に入れる
#   visual-tests    --visual-tests のとき
#   visual-diff     mention かつ --visual-tests のとき
#   pr-body         mention のとき
#
# source すると、判定の関数だけ使える：
#   compose_has_visual_tests   見た目のテスト（package.json の test:visual、または pipeline.json の checks）があるか
#   compose_has_long_docs      docs/spec.md が 200 行以上あるか（企画AIの「短い」の基準と同じ）
COMPOSE_PROMPTS_DIR="${COMPOSE_PROMPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/prompts}"
COMPOSE_DOCS_MIN_LINES=200

compose_has_visual_tests() {
  if [ -f package.json ] && [ "$(jq -r '.scripts["test:visual"] != null' package.json 2> /dev/null)" = true ]; then return 0; fi
  local f="${STACK_FILE:-pipeline.json}"
  if [ -f "$f" ] && jq -e '[.checks // [] | .[] | .run // "" | select(type == "string" and test("test:visual"))] | length > 0' "$f" > /dev/null 2>&1; then return 0; fi
  return 1
}

compose_has_long_docs() {
  [ -f docs/spec.md ] || return 1
  local n
  n=$(wc -l < docs/spec.md)
  [ "$n" -ge "$COMPOSE_DOCS_MIN_LINES" ]
}

# 組む部品の名前を、順に1行ずつ出す。引数：mode visual(0/1) docs(0/1)
compose_parts() {
  local mode="$1" visual="$2" docs="$3"
  echo base
  [ "$docs" = 1 ] && echo read-sections
  echo merge-main
  [ "$visual" = 1 ] && echo visual-tests
  [ "$mode" = mention ] && [ "$visual" = 1 ] && echo visual-diff
  [ "$mode" = mention ] && echo pr-body
  return 0
}

compose_prompt() {
  local out="" part text
  while IFS= read -r part; do
    text=$(< "$COMPOSE_PROMPTS_DIR/$part.md")
    out+="$text"
  done < <(compose_parts "$@")
  printf '%s\n' "$out"
}

compose_main() {
  local mode="" visual=0 docs=0 auto=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode) mode="${2:-}"; shift ;;
      --visual-tests) visual=1 ;;
      --docs) docs=1 ;;
      --auto) auto=1 ;;
      *) echo "知らない引数：$1" >&2; return 2 ;;
    esac
    shift
  done
  case "$mode" in implement | mention) ;; *) echo "--mode は implement か mention" >&2; return 2 ;; esac
  if [ "$auto" = 1 ]; then
    if compose_has_visual_tests; then visual=1; fi
    if compose_has_long_docs; then docs=1; fi
  fi
  compose_prompt "$mode" "$visual" "$docs"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then compose_main "$@"; fi
