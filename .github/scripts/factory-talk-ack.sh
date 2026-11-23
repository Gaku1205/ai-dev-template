#!/usr/bin/env bash
# 工場の相談（factory-talk.yml の route のあと）：返事を受け取って作り始めたことを、すぐ Issue に知らせる。
# 次の選択肢が出るまで十数分かかるので、止まったように見えないため。この知らせは、結果のコメントを出すとき
# factory-talk-publish.sh が消す（印 <!-- factory-talk-ack --> で見つける）。clarify・go では出さない。
#   環境変数：GH_TOKEN、GITHUB_REPOSITORY、ISSUE、NEXT（ideas・looks・mocks・confirm のときだけ出す）
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
msg=$(python3 "$here/factory-talk.py" ack "${NEXT:-}")
[ -n "$msg" ] || exit 0
gh api "repos/$GITHUB_REPOSITORY/issues/$ISSUE/comments" -f body="⏳ ${msg}

<!-- factory-talk-ack -->" > /dev/null || echo "::warning::作り始めた知らせを書けませんでした"
exit 0
