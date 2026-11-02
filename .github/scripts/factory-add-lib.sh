#!/usr/bin/env bash
# 工場のデザイン担当が、動き・3D の道具をその場で入れる（factory.yml の design ジョブで、AIが動かしてよいコマンド）。
#   .github/scripts/factory-add-lib.sh <名前>...   名前は gsap・@gsap/react・lenis・motion・three・@react-three/fiber・@react-three/drei
# 決まった物だけを npm install し（インストール時のスクリプトは動かさない）、factory-libs.txt に名前を足す。
# 新しいリポジトリには、factory.sh が factory-libs.txt を見て同じ物を入れる。
# 環境変数（テスト用）：NPM（既定 npm）
set -uo pipefail
# shellcheck source=factory-libs.sh
source "$(dirname "$0")/factory-libs.sh"
NPM="${NPM:-npm}"

if [ "$#" -eq 0 ]; then
  echo "使い方：.github/scripts/factory-add-lib.sh <名前>...（${FACTORY_LIB_NAMES// /・}）" >&2
  exit 2
fi
pkgs=()
for name in "$@"; do
  mapfile -t got < <(lib_pkgs "$name" || true)
  if [ "${#got[@]}" -eq 0 ]; then
    echo "「$name」は入れられません。入れられるのは：${FACTORY_LIB_NAMES// /・}" >&2
    exit 2
  fi
  pkgs+=("${got[@]}")
done
mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | sort -u)
if ! "$NPM" install --no-audit --no-fund --ignore-scripts --save "${pkgs[@]}"; then
  echo "npm install が失敗しました" >&2
  exit 1
fi
for name in "$@"; do
  grep -qxF "$name" factory-libs.txt 2> /dev/null || echo "$name" >> factory-libs.txt
done
echo "入れました：${pkgs[*]}（新しいリポジトリにも同じ物が入ります）"
