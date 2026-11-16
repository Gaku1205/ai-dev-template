#!/usr/bin/env bash
# AIの工程のあと：実行記録（claude-code-action の execution_file）から、結果の種類・手数・拒否された操作・AIが最後に言ったことを、
# ジョブのログと実行の Summary の両方に出す。「正常に終わったのに何も残さなかった」ときに、あとから理由を追えるようにする。
#
# 使い方：ai-report.sh [--title 見出し] FILE
# ファイルが無い・壊れているときは、その旨を1行出すだけ。いつも終了コード 0（パイプラインを止めない）。

: "${GITHUB_REPOSITORY:=local/local}"
# shellcheck source=pipeline-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/pipeline-lib.sh" || exit 0
trap - ERR
set +e

title="AIの実行の結果"
if [ "${1:-}" = "--title" ]; then title="${2:-$title}"; shift 2; fi
f="${1:-}"

if [ -z "$f" ] || [ ! -s "$f" ] || [ -L "$f" ]; then
  echo "${title}：実行記録がありません（AIが動く前に止まった、など）"
  exit 0
fi

meta=$(jq -r 'if type == "array" then . else [.] end | map(select(type == "object" and .type == "result")) | last // {}
  | "\(.subtype // "不明")\t\(.num_turns // "?")\t\(.permission_denials_count // (.permission_denials // [] | length))"' "$f" 2> /dev/null) || meta=""
IFS=$'\t' read -r subtype turns denials <<< "$meta"
# 使った量（あれば）：入力・出力のトークンと、キャッシュから読んだ分。読む量を減らす工夫が効いているかを、実行ごとに比べられるようにする
usage=$(jq -r 'if type == "array" then . else [.] end | map(select(type == "object" and .type == "result")) | last // {} | .usage // {}
  | select((.input_tokens // .output_tokens // null) != null)
  | "入力 \((.input_tokens // 0) + (.cache_creation_input_tokens // 0))・キャッシュから \(.cache_read_input_tokens // 0)・出力 \(.output_tokens // 0) トークン"' "$f" 2> /dev/null) || usage=""
raw=$(denied_raw "$f")
words=$(ai_last_words "$f" 1200)

{
  echo "### ${title}"
  echo
  echo "- 結果：${subtype:-不明}（手数 ${turns:-?}・拒否 ${denials:-0} 件）"
  if [ -n "$usage" ]; then
    echo "- 使った量：${usage}"
  fi
  if [ -n "$raw" ]; then
    echo "- 拒否された操作（最大5件）："
    printf '%s\n' "$raw" | sed 's/`/'"'"'/g; s/^/  - `/; s/$/`/'
  fi
  if [ -n "$words" ]; then
    echo "- AIが最後に言ったこと：${words}"
  fi
  echo
} > "${RUNNER_TEMP:-/tmp}/ai-report.$$"
cat "${RUNNER_TEMP:-/tmp}/ai-report.$$"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat "${RUNNER_TEMP:-/tmp}/ai-report.$$" >> "$GITHUB_STEP_SUMMARY" 2> /dev/null; fi
rm -f "${RUNNER_TEMP:-/tmp}/ai-report.$$"
exit 0
