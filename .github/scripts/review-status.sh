#!/usr/bin/env bash
# コミットのステータス「AIレビュー」を付ける小さな部品。main の保護で必須にすると、レビューが通るまで人間もマージできない。
# 使い方：review-status.sh <sha> <pending|success|failure> "<説明（140字まで）>"
# 環境変数：STATUS_TOKEN（ワークフローのトークン。statuses: write が付いたもの）、GITHUB_REPOSITORY
# STATUS_TOKEN が無い・書けなかったときは、警告を出すだけで失敗にしない（ワークフローに権限が入るまでは今までどおり動く）
set -u

sha="${1:-}"
state="${2:-}"
desc="${3:-}"
repo="${GITHUB_REPOSITORY:-}"

case "$state" in
  pending | success | failure) ;;
  *) echo "::warning::review-status.sh：状態は pending / success / failure のどれか（${state}）"; exit 0 ;;
esac
if [ -z "$sha" ] || [ -z "$repo" ]; then
  echo "::warning::review-status.sh：コミットかリポジトリが分からないので、ステータスを付けません"
  exit 0
fi
if [ -z "${STATUS_TOKEN:-}" ]; then
  echo "::warning::STATUS_TOKEN が無いので、コミットのステータス「AIレビュー」を付けません（ワークフローに statuses: write を足すと付きます）"
  exit 0
fi

# 説明は140字まで（超えると GitHub が断る）
desc="${desc:0:140}"
if GH_TOKEN="$STATUS_TOKEN" gh api -X POST "repos/$repo/statuses/$sha" \
  -f state="$state" -f context="AIレビュー" -f description="$desc" > /dev/null 2>&1; then
  echo "コミット ${sha:0:7} にステータス「AIレビュー」（${state}）を付けました"
else
  echo "::warning::コミットのステータス「AIレビュー」を付けられませんでした（statuses: write の権限が無いなど）"
fi
exit 0
