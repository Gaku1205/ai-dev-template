#!/usr/bin/env bash
# exe などの配布物を GitHub Releases に置く。deploy.yml の「配布物を作る」が OS ごとに作った物（build-<OS> のフォルダ）を集める。
# ファイル名には OS を付ける（hello.exe → hello-windows.exe、hello → hello-macos）。同じ名前がぶつからないように。
# タグは build-<日時>-<コミット7文字>。最新のリリースにする。
# 使い方：deploy-release.sh 集めたフォルダ
# 環境変数：REPO か GITHUB_REPOSITORY、SHA、RELEASE_OS（作った OS の JSON の並び。OS が1つのとき使う）、GH_TOKEN（contents: write）、GITHUB_OUTPUT（url を書く）、NOW（テスト用。YYYYmmdd-HHMM）
set -euo pipefail
src="${1:?集めたフォルダを指定}"
REPO="${REPO:-${GITHUB_REPOSITORY:?}}"
SHA="${SHA:?SHA が要ります}"
out="${GITHUB_OUTPUT:-/dev/stdout}"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

dirs=() oses=()
for dir in "$src"/build-*; do
  [ -d "$dir" ] || continue
  os="${dir##*/build-}"
  dirs+=("$dir") oses+=("$os")
done
# download-artifact は、合う物が1つだけだと build-<OS> のフォルダを作らず、中身をそのまま置く。OS が1つなら、その名前を使う
if [ "${#dirs[@]}" -eq 0 ] && [ -n "${RELEASE_OS:-}" ] && [ "$(jq 'length' <<< "$RELEASE_OS" 2> /dev/null)" = 1 ]; then
  dirs=("$src") oses=("$(jq -r '.[0]' <<< "$RELEASE_OS")")
fi

count=0
for i in "${!dirs[@]}"; do
  dir="${dirs[$i]}"
  os="${oses[$i]%%-*}"   # windows-latest → windows、macos-14 → macos
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    case "$base" in
      *.*) name="${base%.*}-${os}.${base##*.}" ;;
      *) name="${base}-${os}" ;;
    esac
    cp "$f" "$stage/$name"
    count=$((count + 1))
  done < <(find "$dir" -type f -print0)
done
if [ "$count" -eq 0 ]; then
  echo "::error::置く物がありません（pipeline.json の github-release の files に合うファイルが、どの OS でも作られていない）"
  exit 1
fi

tag="build-${NOW:-$(date -u +%Y%m%d-%H%M)}-${SHA:0:7}"
title=$(gh api "repos/$REPO/commits/$SHA" -q '.commit.message' 2> /dev/null | sed -n '3p' || true)
[ -z "$title" ] && title=$(gh api "repos/$REPO/commits/$SHA" -q '.commit.message' 2> /dev/null | head -n 1 || true)
notes="自動で作った配布物です（コミット ${SHA:0:7}）。${title}"
gh release create "$tag" "$stage"/* --repo "$REPO" --target "$SHA" --title "${tag}${title:+ $title}" --notes "$notes" --latest > /dev/null
url="https://github.com/${REPO}/releases/tag/${tag}"
echo "url=$url" >> "$out"
echo "GitHub Releases に置きました（${count}個）：$url"
