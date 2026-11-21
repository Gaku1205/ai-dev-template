#!/usr/bin/env bash
# 見張り役（3.9）：ラベルの矛盾を直す。人間待ち（ai:skip）と ai:implement／ai:queue が両方付いた形
source "$(dirname "$0")/lib.sh"
setup_mock

echo "== ai:skip と ai:implement・ai:queue が両方付いた Issue は、後ろの2つを外す"
init_state '{"labels":{"9":["ai:skip","ai:implement","ai:queue","audit"]}}'
run_script watchdog.sh > /dev/null
assert_eq "ai:skip と audit だけ残る" "ai:skip,audit" "$(labels_of 9)"
assert_contains "人間待ちなので外したと書く" "$(comments_of 9)" "人間待ち（ai:skip）なので"
assert_not_contains "始めますとは言わない" "$(comments_of 9)" "始めます"

echo "== ai:skip だけなら何もしない"
init_state '{"labels":{"9":["ai:skip"]}}'
run_script watchdog.sh > /dev/null
assert_eq "そのまま" "ai:skip" "$(labels_of 9)"
assert_not_contains "矛盾のコメントは付かない" "$(comments_of 9)" "ラベルの矛盾"

finish
