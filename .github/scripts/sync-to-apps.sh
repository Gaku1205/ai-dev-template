#!/usr/bin/env bash
# ai-dev-template の .github と docs/pipeline.md を、アプリのリポジトリへ配る。
# 使い方: sync-to-apps.sh owner/repo [owner/repo ...]
# 必要な環境変数: GH_TOKEN（配る先に push できるトークン。ワークフローも配るなら Workflows 権限が要る）
# 配る先に .github/sync-keep があれば、そこに書かれたファイル名（1行1つ）は消さずに残す。
# CLAUDE.md / AGENTS.md / docs/spec.md / docs/design.md は配らない。
set -euo pipefail

src_root="$(cd "$(dirname "$0")/../.." && pwd)"
src_sha="$(git -C "$src_root" rev-parse --short HEAD)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

for repo in "$@"; do
  echo "== $repo"
  dir="$work/${repo//\//_}"
  if ! git clone -q --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/${repo}.git" "$dir"; then
    echo "::error::$repo を取得できません"; fail=1; continue
  fi
  excludes=(--exclude=sync-keep --exclude=sync-targets)
  if [ -f "$dir/.github/sync-keep" ]; then
    while IFS= read -r name; do
      [ -n "$name" ] && excludes+=("--exclude=$name")
    done < "$dir/.github/sync-keep"
  fi
  rsync -a --delete "${excludes[@]}" "$src_root/.github/" "$dir/.github/"
  mkdir -p "$dir/docs"
  cp "$src_root/docs/pipeline.md" "$dir/docs/pipeline.md"
  if [ -z "$(git -C "$dir" status --porcelain)" ]; then
    echo "変更なし"; continue
  fi
  git -C "$dir" add -A
  git -C "$dir" -c user.name="pipeline-sync" -c user.email="noreply@github.com" \
    commit -q -m "パイプラインの更新を ai-dev-template から取り込む（${src_sha}）"
  if git -C "$dir" push -q origin HEAD:main; then
    echo "配った: $repo"
  else
    echo "::error::$repo へ push できません（トークンの Workflows 権限を確認）"; fail=1
  fi
done
exit "$fail"
