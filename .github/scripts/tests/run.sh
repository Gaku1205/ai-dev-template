#!/usr/bin/env bash
# パイプラインのスクリプトのテストを全部動かす。使い方：bash .github/scripts/tests/run.sh [test-名前.sh …]
# 必要な物：bash・jq・python3（どれもGitHubのランナーに入っている）
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  files=("$DIR"/test-*.sh)
fi

failed=0
for f in "${files[@]}"; do
  echo "== $(basename "$f")"
  bash "$f" || failed=$((failed + 1))
done

if [ "$failed" -gt 0 ]; then
  echo "テストが落ちたファイル：${failed} 個"
  exit 1
fi
echo "すべてのテストが通りました"
