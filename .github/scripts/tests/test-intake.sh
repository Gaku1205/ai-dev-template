#!/usr/bin/env bash
# 受付（intake.sh）：オーナーのラベル無しIssueは企画へ、オーナー以外は ai:skip で止める
source "$(dirname "$0")/lib.sh"
setup_mock

echo "== オーナー（o）のラベル無しIssue → ai:plan"
init_state '{"labels":{"4":[]},"authors":{"4":"o"}}'
NUMBER=4 ACTION=opened run_script intake.sh > /dev/null
assert_eq "ai:plan が付く" "ai:plan" "$(labels_of 4)"

echo "== オーナー以外のIssue → ai:skip（AIを動かさない）"
init_state '{"labels":{"5":[]},"authors":{"5":"stranger"}}'
NUMBER=5 ACTION=opened run_script intake.sh > /dev/null
assert_eq "ai:skip が付く" "ai:skip" "$(labels_of 5)"

echo "== 作った人が大文字小文字ちがいのオーナー → オーナー扱い"
init_state '{"labels":{"6":[]},"authors":{"6":"O"}}'
NUMBER=6 ACTION=opened run_script intake.sh > /dev/null
assert_eq "ai:plan が付く" "ai:plan" "$(labels_of 6)"

echo "== すでに ai: のラベルがあるIssueは触らない"
init_state '{"labels":{"7":["ai:implement"]},"authors":{"7":"o"}}'
NUMBER=7 ACTION=opened run_script intake.sh > /dev/null
assert_eq "変わらない" "ai:implement" "$(labels_of 7)"

echo "== PIPELINE_TOKEN が無いときは何もしない"
init_state '{"labels":{"8":[]},"authors":{"8":"o"}}'
GH_TOKEN="" NUMBER=8 ACTION=opened run_script intake.sh > /dev/null
assert_eq "ラベルが付かない" "" "$(labels_of 8)"

finish
