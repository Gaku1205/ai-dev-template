#!/usr/bin/env bash
# パイプラインのスクリプトのテストを全部動かす（疑似 gh を使うので、本物のGitHubには触らない）
# 使い方：.github/scripts/tests/run-all.sh
# 通ったテストは1行（成功の数）だけ出し、失敗したテストだけ、中身を全部出す（出力が長すぎて失敗が埋もれないように）
set -u
cd "$(dirname "$0")" || exit 1
fail=0
for t in test-*.sh; do
  if out=$(bash "$t" 2>&1); then
    echo "### $t：$(printf '%s\n' "$out" | tail -1)"
  else
    echo "### $t（失敗）"
    printf '%s\n' "$out"
    fail=1
  fi
done
if [ "$fail" -ne 0 ]; then
  echo "テストに失敗した物があります"
  exit 1
fi
echo "全部のテストが通りました"
