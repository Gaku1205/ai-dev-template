#!/usr/bin/env bash
# パイプラインのスクリプトのテストを全部動かす（疑似 gh を使うので、本物のGitHubには触らない）
# 使い方：.github/scripts/tests/run-all.sh
# 通ったテストは1行（成功の数）だけ出し、失敗したテストだけ、中身を全部出す（出力が長すぎて失敗が埋もれないように）
# テストのファイルは並べて動かす（1本ずつだと CI の時間切れ（10分）に届くため）。並べる数は CPU の数。環境変数 TEST_JOBS で変えられる（1 なら1本ずつ）
# 結果は、終わった順ではなく、ファイル名の順に出す（前のテストが終わるまで、後ろの結果は出さずに待つ）
# 並べて動かすので、テストは固定の場所（/tmp/決まった名前、このフォルダの中）に書かない。mktemp -d か setup_mock の MOCK_DIR を使う
set -u
cd "$(dirname "$0")" || exit 1

jobs="${TEST_JOBS:-}"
[ -n "$jobs" ] || jobs=$(nproc 2> /dev/null || getconf _NPROCESSORS_ONLN 2> /dev/null || echo 2)
case "$jobs" in '' | *[!0-9]* | 0) echo "TEST_JOBS は1以上の数にしてください：$jobs" >&2; exit 1 ;; esac

tests=(test-*.sh)
if [ ! -f "${tests[0]}" ]; then echo "テストがありません" >&2; exit 1; fi

# 始める順：時間のかかるテストを先に始める（後ろで始めると、ほかが全部終わったあと、それ1本を待つ時間が丸ごと足される）。無い物は飛ばす
SLOW_FIRST="test-run-as-app.sh test-factory.sh"
order=()
for t in $SLOW_FIRST; do [ -f "$t" ] && order+=("$t"); done
for t in "${tests[@]}"; do
  case " $SLOW_FIRST " in *" $t "*) ;; *) order+=("$t") ;; esac
done

out_dir="$(mktemp -d)"
runner=""
cleanup() {
  [ -n "$runner" ] && kill "$runner" 2> /dev/null
  rm -rf "$out_dir"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# 1本動かして、出力を <名前>.out、終了コードを <名前>.rc に残す（.rc は書き終えてから名前を変えるので、途中の物を読まない）
# shellcheck disable=SC2016  # $1・$2 は、xargs が起こす bash の中で開く
printf '%s\0' "${order[@]}" | xargs -0 -n 1 -P "$jobs" bash -c '
  bash "$2" > "$1/$2.out" 2>&1
  echo $? > "$1/$2.rc.tmp"
  mv "$1/$2.rc.tmp" "$1/$2.rc"
' _ "$out_dir" &
runner=$!

fail=0
for t in "${tests[@]}"; do
  # このテストが終わるまで待つ。動かす側が先に終わったのに結果が無ければ（途中で止められたなど）、失敗にする
  while [ ! -f "$out_dir/$t.rc" ]; do
    if ! kill -0 "$runner" 2> /dev/null; then
      [ -f "$out_dir/$t.rc" ] || echo "終了コードが残っていません（途中で止まりました）" >> "$out_dir/$t.out"
      break
    fi
    sleep 0.2
  done
  rc=$(cat "$out_dir/$t.rc" 2> /dev/null || echo 1)
  out=$(cat "$out_dir/$t.out" 2> /dev/null)
  if [ "$rc" = 0 ]; then
    echo "### $t：$(printf '%s\n' "$out" | tail -1)"
  else
    echo "### $t（失敗）"
    printf '%s\n' "$out"
    fail=1
  fi
done
wait "$runner" 2> /dev/null
runner=""
if [ "$fail" -ne 0 ]; then
  echo "テストに失敗した物があります"
  exit 1
fi
echo "全部のテストが通りました"
