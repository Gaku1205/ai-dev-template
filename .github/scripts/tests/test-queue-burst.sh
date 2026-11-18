#!/usr/bin/env bash
# 順番待ち：進行中が無いとき上限まで並べて始める／企画が同時に終わったときの数え直し（yield_if_crowded）
source "$(dirname "$0")/lib.sh"
setup_mock
next() { run_script queue-next.sh; }
body() { printf '本文\\n<!-- ai-touches: %s -->' "$1"; } # JSON に入れるので、改行は \n の文字のまま

echo "== 進行中が無く、触るファイルが重ならない順番待ち3件・上限3：1回で3件始まる"
init_state '{"labels":{"2":["ai:queue"],"3":["ai:queue"],"4":["ai:queue"],"5":["ai:queue"]},"issues_meta":{"2":{"body":"'"$(body src/a.ts)"'"},"3":{"body":"'"$(body src/b.ts)"'"},"4":{"body":"'"$(body src/c.ts)"'"},"5":{"body":"'"$(body src/d.ts)"'"}}}'
MAX_PARALLEL=3 next > /dev/null
assert_eq "#2" "ai:implement" "$(labels_of 2)"
assert_eq "#3" "ai:implement" "$(labels_of 3)"
assert_eq "#4" "ai:implement" "$(labels_of 4)"
assert_eq "#5 は上限で待つ" "ai:queue" "$(labels_of 5)"

echo "== 上限1なら1件"
init_state '{"labels":{"2":["ai:queue"],"3":["ai:queue"]},"issues_meta":{"2":{"body":"'"$(body src/a.ts)"'"},"3":{"body":"'"$(body src/b.ts)"'"}}}'
MAX_PARALLEL=1 next > /dev/null
assert_eq "#2" "ai:implement" "$(labels_of 2)"
assert_eq "#3 は待つ" "ai:queue" "$(labels_of 3)"

echo "== 進行中が無くても、触るファイルが重なる物は待つ"
init_state '{"labels":{"2":["ai:queue"],"3":["ai:queue"]},"issues_meta":{"2":{"body":"'"$(body src/a.ts)"'"},"3":{"body":"'"$(body src/a.ts)"'"}}}'
MAX_PARALLEL=3 next > /dev/null
assert_eq "#2" "ai:implement" "$(labels_of 2)"
assert_eq "#3 は重なるので待つ" "ai:queue" "$(labels_of 3)"

echo "== 印の無い物は、1回の実行で1つだけ（今までどおり）"
init_state '{"labels":{"2":["ai:queue"],"3":["ai:queue"],"4":["ai:queue"]},"issues_meta":{"4":{"body":"'"$(body src/c.ts)"'"}}}'
MAX_PARALLEL=3 next > /dev/null
assert_eq "#2（印なし）は始まる" "ai:implement" "$(labels_of 2)"
assert_eq "#3（印なし）は待つ" "ai:queue" "$(labels_of 3)"
assert_eq "#4 も、印の無い物のあとは待つ" "ai:queue" "$(labels_of 4)"

echo "== 企画が同時に終わった：上限1で互いの ai:implement を見た。番号の大きい方が ai:queue に引く"
crowd() { run_lib "if yield_if_crowded $1 $2 '$3'; then echo rc=0; else echo rc=1; fi"; }
init_state '{"labels":{"7":["ai:implement"],"8":["ai:implement"]}}'
out=$(crowd 8 1 "")
assert_contains "引く" "$out" "rc=0"
assert_eq "#8 は ai:queue だけ" "ai:queue" "$(labels_of 8)"
assert_eq "#7 はそのまま" "ai:implement" "$(labels_of 7)"
init_state '{"labels":{"7":["ai:implement"],"8":["ai:implement"]}}'
out=$(crowd 7 1 "")
assert_contains "番号の小さい方は引かない" "$out" "rc=1"
assert_eq "#7 はそのまま" "ai:implement" "$(labels_of 7)"
init_state '{"labels":{"7":["ai:implement"],"8":["ai:implement"],"9":["ai:implement"]}}'
out=$(crowd 9 3 "")
assert_contains "上限3で自分より小さいのが2件：引かない" "$out" "rc=1"
init_state '{"labels":{"7":["ai:implement"],"8":["ai:implement"],"9":["ai:implement"]}}'
out=$(crowd 9 2 "")
assert_contains "上限2で自分より小さいのが2件：引く" "$out" "rc=0"
assert_eq "#9 は ai:queue" "ai:queue" "$(labels_of 9)"

echo "== 同時に付いた相手と触るファイルが重なるなら引く／重ならなければ引かない"
init_state '{"labels":{"7":["ai:implement"],"8":["ai:implement"]},"issues_meta":{"7":{"body":"'"$(body src/a.ts)"'"}}}'
out=$(crowd 8 3 "src/a.ts")
assert_contains "重なる：引く" "$out" "rc=0"
assert_eq "#8 は ai:queue" "ai:queue" "$(labels_of 8)"
init_state '{"labels":{"7":["ai:implement"],"8":["ai:implement"]},"issues_meta":{"7":{"body":"'"$(body src/a.ts)"'"}}}'
out=$(crowd 8 3 "src/b.ts")
assert_contains "重ならない：引かない" "$out" "rc=1"
assert_eq "#8 はそのまま" "ai:implement" "$(labels_of 8)"

finish
