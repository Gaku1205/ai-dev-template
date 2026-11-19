#!/usr/bin/env bash
# テストを続けて何回も回す。1回でも落ちたら、そこで止まって落ちた回の出力を出す。
# 使い方：bash .github/scripts/tests/repeat.sh <テストのファイル> <回数>
set -uo pipefail

if [ "$#" -ne 2 ]; then
  echo "使い方: $0 <テストのファイル> <回数>" >&2
  exit 2
fi
test_file="$1"
count="$2"
if [ ! -f "$test_file" ]; then
  echo "テストのファイルがありません: $test_file" >&2
  exit 2
fi
case "$count" in
  '' | *[!0-9]*) echo "回数は1以上の数で書いてください: $count" >&2; exit 2 ;;
esac
if [ "$count" -lt 1 ]; then
  echo "回数は1以上の数で書いてください: $count" >&2
  exit 2
fi

out="$(mktemp)"
trap 'rm -f "$out"' EXIT
i=1
while [ "$i" -le "$count" ]; do
  if ! bash "$test_file" > "$out" 2>&1; then
    echo "== ${count}回中 ${i}回目で落ちた: $test_file =="
    cat "$out"
    exit 1
  fi
  i=$((i + 1))
done
echo "${count}回中${count}回通った: $test_file"
