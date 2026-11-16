#!/usr/bin/env bash
# 配り先の形でテストを全部動かす：配布（sync-to-apps.sh）が配る物だけを空のリポジトリに置き、そこで run-all.sh を動かす。
# テストは .github/scripts/tests/ ごと全部のアプリに配られ、アプリの CI でも動く。テンプレートにしか無い物（examples/・src/・
# README など）に頼るテストが混ざると、配ったとたんに全部のアプリの CI が落ちる。配る前（テンプレートの CI）に、ここで見つける。
# 使い方：.github/scripts/tests/run-as-app.sh（テンプレート本体で動かす。rsync が要る）
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
app="$(mktemp -d)"
trap 'rm -rf "$app"' EXIT
git -C "$app" init -q -b main
bash "$here/../sync-to-apps.sh" --local "$app"
git -C "$app" add -A
git -C "$app" -c user.name=t -c user.email=t@t commit -qm "配り先の形"
echo "配り先の形（$app）でテストを動かします"
bash "$app/.github/scripts/tests/run-all.sh"
