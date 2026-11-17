#!/usr/bin/env bash
# exe などの配布物を GitHub Releases に置く。deploy.yml の「配布物を作る」が OS ごとに作った物（build-<OS> のフォルダ）を集める。
# ファイル名には OS を付ける（hello.exe → hello-windows.exe、hello → hello-macos）。同じ名前がぶつからないように。
# 同じ OS の中で同じ名前が別のフォルダにあれば、フォルダの名前を頭に付ける（上書きしない）。
# タグは build-<日時>-<コミット7文字>。もうあれば -2・-3 … を付ける。最新のリリースにする。
# 使い方：deploy-release.sh 集めたフォルダ
# 環境変数：REPO か GITHUB_REPOSITORY、SHA、RELEASE_OS（作った OS の JSON の並び。OS が1つのとき使う）、GH_TOKEN（contents: write）、GITHUB_OUTPUT（url を書く）、NOW（テスト用。YYYYmmdd-HHMM）
set -euo pipefail
# shellcheck source=deploy-lib.sh
source "$(dirname "$0")/deploy-lib.sh"
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

# 同じ名前のファイルが別のフォルダにあると（dist/README.txt と dist/sub/README.txt）、後の物が前の物を上書きして、片方が黙って消える。
# 浅いフォルダの物（同じ深さなら名前順で先）は、今までどおりの名前。ぶつかった物は、フォルダの名前を頭に付ける
# （sub/README.txt → sub-README-windows.txt）。それでもぶつかれば、-2・-3 を付ける。上書きはしない
asset_name() { # 名前 OS → OS を付けた名前
  case "$1" in
    *.*) printf '%s-%s.%s' "${1%.*}" "$2" "${1##*.}" ;;
    *) printf '%s-%s' "$1" "$2" ;;
  esac
}
count=0
for i in "${!dirs[@]}"; do
  dir="${dirs[$i]%/}"
  os="${oses[$i]%%-*}"   # windows-latest → windows、macos-14 → macos
  while IFS= read -r -d '' entry; do
    rel="${entry#*$'\t'}"
    name="$(asset_name "$(basename "$rel")" "$os")"
    if [ -e "$stage/$name" ]; then
      flat="${rel//\//-}"
      name="$(asset_name "$flat" "$os")"
      k=2
      while [ -e "$stage/$name" ]; do
        name="$(asset_name "$flat" "$os-$k")"
        k=$((k + 1))
      done
      echo "同じ名前のファイルがあるので、フォルダの名前を付けて置きます：$rel → $name"
    fi
    cp "$dir/$rel" "$stage/$name"
    count=$((count + 1))
  done < <(
    # 深さ（/ の数）を頭に付けて並べる。浅い物・名前順で先の物から名前を取る（どの環境でも同じ順になるように LC_ALL=C）
    find "$dir" -type f -print0 | while IFS= read -r -d '' f; do
      rel="${f#"$dir"/}"
      slashes="${rel//[!\/]/}"
      printf '%03d\t%s\0' "${#slashes}" "$rel"
    done | LC_ALL=C sort -z
  )
done
if [ "$count" -eq 0 ]; then
  echo "::error::置く物がありません（pipeline.json の github-release の files に合うファイルが、どの OS でも作られていない）"
  exit 1
fi

# タグは分までなので、同じコミットの公開を同じ分にやり直すと、タグがもうある。そのまま作ると失敗するか、前のリリースの物に混ざる。
# もうあるタグには -2・-3 … を付けて、別のリリースにする（前のリリースは書き換えない）
base_tag="build-${NOW:-$(date -u +%Y%m%d-%H%M)}-${SHA:0:7}"
tag="$base_tag"
k=2
while gh api "repos/$REPO/git/ref/tags/$tag" > /dev/null 2>&1; do
  if [ "$k" -gt 9 ]; then
    echo "::error::タグ ${base_tag} が -9 まで全部あります（同じ分に何度もやり直している）。1分待ってからやり直してください"
    exit 1
  fi
  tag="${base_tag}-${k}"
  k=$((k + 1))
done
[ "$tag" = "$base_tag" ] || echo "タグ ${base_tag} はもうあるので、${tag} で置きます"
title=$(commit_title "$(gh api "repos/$REPO/commits/$SHA" -q '.commit.message' 2> /dev/null || true)")
notes="自動で作った配布物です（コミット ${SHA:0:7}）。${title}"
gh release create "$tag" "$stage"/* --repo "$REPO" --target "$SHA" --title "${tag}${title:+ $title}" --notes "$notes" --latest > /dev/null
url="https://github.com/${REPO}/releases/tag/${tag}"
echo "url=$url" >> "$out"
echo "GitHub Releases に置きました（${count}個）：$url"
