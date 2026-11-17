#!/usr/bin/env bash
# 配り先の形でテストを全部動かす：配布（sync-to-apps.sh）が配る物を、形の違う見本のアプリ（app-fixtures/）に置き、そこで
# run-all.sh と shellcheck を動かす。
# テストは .github/scripts/tests/ ごと全部のアプリに配られ、アプリの CI でも動く。テンプレートにしか無い物（examples/・src/・
# README など）や、アプリごとに形の違う物（vercel.json・package.json・pipeline.json・CLAUDE.md）に頼るテストが混ざると、
# 配ったとたんに全部のアプリの CI が落ちる。配る前（テンプレートの CI）に、ここで見つける。
# 使い方：.github/scripts/tests/run-as-app.sh [見本の名前 ...]（テンプレート本体で動かす。rsync が要る。名前を省くと全部の見本）
# 環境変数 SYNC_CANARY（空白区切りの owner/repo）があれば、その公開リポジトリを clone（トークンなし）して、同じ手順も回す。空なら何もしない。
# 1つ落ちても残りは回し、最後に落ちた名前を出して失敗で終わる。
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 配り先のフォルダ $1 に、配ったあとの形を作ってコミットし、run-all.sh と shellcheck を動かす
run_in_app() {
  local app="$1"
  git -C "$app" init -q -b main 2> /dev/null || git -C "$app" init -q || return 1
  # clone した物は既に git のリポジトリ（init は何もしない）
  bash "$here/../sync-to-apps.sh" --local "$app" || return 1
  git -C "$app" add -A
  git -C "$app" -c user.name=t -c user.email=t@t commit -qm "配り先の形" --allow-empty || return 1
  bash "$app/.github/scripts/tests/run-all.sh" || return 1
  if command -v shellcheck > /dev/null 2>&1; then
    (cd "$app" && shellcheck -S warning -x -P SCRIPTDIR .github/scripts/*.sh .github/scripts/tests/*.sh) || return 1
  else
    echo "shellcheck が無いので、静的チェックは飛ばします"
  fi
}

failed=()

fixtures=("$@")
if [ ${#fixtures[@]} -eq 0 ]; then
  for d in "$here"/app-fixtures/*/; do
    [ -d "$d" ] && fixtures+=("$(basename "$d")")
  done
fi

for name in "${fixtures[@]}"; do
  echo "===== 見本：$name"
  app="$work/fixture-$name"
  mkdir -p "$app"
  if [ ! -d "$here/app-fixtures/$name" ]; then
    echo "見本 $name がありません"; failed+=("$name"); continue
  fi
  cp -R "$here/app-fixtures/$name/." "$app/"
  if ! run_in_app "$app"; then failed+=("$name"); fi
done

for repo in ${SYNC_CANARY:-}; do
  echo "===== 配り先の実物：$repo"
  app="$work/canary-${repo//\//_}"
  if ! git clone -q --depth 1 "https://github.com/$repo.git" "$app"; then
    echo "$repo を clone できません"; failed+=("$repo"); continue
  fi
  if ! run_in_app "$app"; then failed+=("$repo"); fi
done

if [ ${#failed[@]} -ne 0 ]; then
  echo "落ちた見本：${failed[*]}"
  exit 1
fi
echo "全部の見本で通りました"
