#!/usr/bin/env bash
# AIの実行記録（claude-execution-output.json）から、許可されず拒否された操作の中身を取り出す。
#
# 使い方：
#   denials.sh FILE             拒否の数と、拒否された tool_name と引数の一覧（テキスト）
#   denials.sh --summary FILE   実行の Summary 用（Markdown）。GITHUB_STEP_SUMMARY があればそこへ追記し、無ければ標準出力
#   denials.sh --comment FILE   コメント用の短い1文（例：拒否されたツール：Write、Bash）。拒否が無ければ何も出さない
#   denials.sh --check FILE     拒否が1以上なら終了コード 0、無い・ファイルが無い・壊れているなら 1（やり直しの判断に使う）
# --check 以外は、ファイルが無い・壊れているときも何も出さず、終了コード 0。
# 引数は1件あたり約 200 文字で切り詰める（DENIAL_ARG_MAX で変えられる）。

: "${GITHUB_REPOSITORY:=local/local}"
# shellcheck source=pipeline-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/pipeline-lib.sh" || exit 0
# 共通関数の ERR の罠は、失敗を画面に error として出す。ここでは静かに終わりたいので外す
trap - ERR
set +e

mode=text
case "${1:-}" in
  --summary) mode=summary; shift ;;
  --comment) mode=comment; shift ;;
  --check) mode=check; shift ;;
esac
f="${1:-}"
max="${DENIAL_ARG_MAX:-200}"

# 実行記録の最後の result から拒否の一覧を TSV（tool_name<TAB>引数）で出す。1行目は件数
extract() {
  jq -r --argjson max "$max" '
    (if type == "array" then . else [.] end | map(select(type == "object" and .type == "result")) | last // {}) as $r
    | ($r.permission_denials // []) as $d
    | ($r.permission_denials_count // ($d | length)),
      ($d[] | "\(.tool_name // "?" | tostring | gsub("[\t\r\n]"; " "))\t\(.tool_input // {} | tojson | gsub("[\t\r\n]"; " ") | if length > $max then .[0:$max] + "…" else . end)")' "$f" 2> /dev/null
}

rows=""
count=0
if [ -n "$f" ] && [ -s "$f" ] && [ ! -L "$f" ]; then
  rows=$(extract) || rows=""
  count=$(printf '%s\n' "$rows" | head -n 1)
  case "$count" in '' | *[!0-9]*) count=0; rows="" ;; esac
  rows=$(printf '%s\n' "$rows" | tail -n +2)
fi

case "$mode" in
  check)
    [ "$count" -ge 1 ]
    exit $?
    ;;
  text)
    [ "$count" -ge 1 ] || exit 0
    echo "permission_denials_count: $count"
    printf '%s\n' "$rows" | awk 'NF' | while IFS=$'\t' read -r name arg; do echo "- ${name}: ${arg}"; done
    ;;
  summary)
    [ "$count" -ge 1 ] || exit 0
    {
      echo "### 🚫 AIの操作が許可されず拒否されました（${count}件）"
      echo ""
      echo "| ツール | 引数 |"
      echo "| --- | --- |"
      printf '%s\n' "$rows" | awk 'NF' | while IFS=$'\t' read -r name arg; do
        echo "| \`${name}\` | \`$(printf '%s' "$arg" | sed 's/|/\\|/g; s/`/'"'"'/g')\` |"
      done
      echo ""
    } >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
    ;;
  comment)
    [ "$count" -ge 1 ] || exit 0
    names=$(printf '%s\n' "$rows" | awk 'NF' | cut -f1 | sort -u | paste -sd, - | sed 's/,/、/g')
    echo "拒否されたツール（${count}件）：${names}"
    ;;
esac
exit 0
