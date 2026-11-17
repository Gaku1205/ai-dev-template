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

echo "== 見張り役の保険：受付が拾わなかったIssue（ラベル無しで10分以上）を企画に回し、知らせる"
init_state '{"labels":{"12":[],"13":[],"14":["ai:skip"]},"authors":{"12":"o","13":"o","14":"stranger"}}'
state_py "s['issue_updated']['12']='$(ago 20)'; s['issue_updated']['13']='$(ago 2)'; s['issue_updated']['14']='$(ago 20)'"
run_script watchdog.sh > /dev/null
assert_eq "10分以上たった物は ai:plan が付く" "ai:plan" "$(labels_of 12)"
assert_eq "出来たばかりの物は、まだ触らない" "" "$(labels_of 13)"
assert_eq "ai:skip の物は触らない" "ai:skip" "$(labels_of 14)"
assert_contains "知らせが出る" "$(cat "$MOCK_DIR/curl.log")" "頼まれていないIssueがありました"
assert_eq "知らせは1件だけ" "1" "$(notify_count)"

echo "== テンプレート本体の「新サービス：〜」は工場が受け持つので、企画に回さない（アプリのリポジトリでは今まで通り）"
init_state '{"labels":{"9":[]},"authors":{"9":"o"},"is_template":true,"issues_meta":{"9":{"title":"新サービス：毎朝の天気","state":"open"}}}'
NUMBER=9 ACTION=opened run_script intake.sh > /dev/null
assert_eq "テンプレート：ラベルを付けない" "" "$(labels_of 9)"
init_state '{"labels":{"9":[]},"authors":{"9":"o"},"is_template":false,"issues_meta":{"9":{"title":"新サービス：毎朝の天気","state":"open"}}}'
NUMBER=9 ACTION=opened run_script intake.sh > /dev/null
assert_eq "テンプレートでない所：企画に回さず ai:skip で止める" "ai:skip" "$(labels_of 9)"
assert_contains "理由（Template repository のチェック）をコメントする" "$(comments_of 9)" "Template repository"
init_state '{"labels":{"9":["ai:plan"]},"authors":{"9":"o"},"is_template":false,"issues_meta":{"9":{"title":"新サービス：毎朝の天気","state":"open"}}}'
NUMBER=9 ACTION=opened run_script intake.sh > /dev/null
assert_eq "雛形の ai:plan も外す" "ai:skip" "$(labels_of 9)"
init_state '{"labels":{"9":[]},"authors":{"9":"o"},"is_template":false,"issues_meta":{"9":{"title":"毎朝の天気","state":"open"}}}'
NUMBER=9 ACTION=opened run_script intake.sh > /dev/null
assert_eq "ふつうの題名は、今まで通り企画に回す" "ai:plan" "$(labels_of 9)"


echo "== オーナー以外が雛形（メモ）から作ると ai:plan が付く：外して ai:skip で止める（やり直しで他人の Issue を企画しない）"
init_state '{"labels":{"20":["ai:plan"]},"authors":{"20":"stranger"}}'
NUMBER=20 ACTION=opened run_script intake.sh > /dev/null
assert_eq "ai:plan を外して ai:skip" "ai:skip" "$(labels_of 20)"
# AIのアクションが断って失敗 → やり直し待ちになっていても、見張り役は ai:plan を付け直さない
state_py "s['labels']['20']=['ai:skip','ai:retry']"
run_lib "write_retry_record 20 0 plan '企画AIがエラーで止まりました'" > /dev/null
age_retry_comments 40
out=$(run_script watchdog.sh)
assert_eq "やり直さず、印だけ外す" "ai:skip" "$(labels_of 20)"
assert_contains "理由をログに出す" "$out" "ai:skip が付いているので、やり直しません"
# 受付より先にやり直しの印が付き、ai:plan が残っていても、見張り役は「止まった企画」としてやり直さない
init_state '{"labels":{"21":["ai:plan","ai:skip"]},"authors":{"21":"stranger"}}'
state_py "s['issue_updated']['21']='$(ago 90)'"
run_script watchdog.sh > /dev/null
assert_eq "ai:retry を付けない" "ai:plan,ai:skip" "$(labels_of 21)"

echo "== 仕組み（App のボット）がラベルを付けて作った Issue（使ってみる役・監査役）は、ai:skip を付けずに進める"
init_state '{"labels":{"22":["ai:found","ai:plan"]},"authors":{"22":"my-pipeline[bot]"}}'
NUMBER=22 ACTION=opened run_script intake.sh > /dev/null
assert_eq "ラベルは変わらない" "ai:found,ai:plan" "$(labels_of 22)"

echo "== ほかのボットが、ラベル無しで作った Issue は止める"
init_state '{"labels":{"23":[]},"authors":{"23":"renovate[bot]"}}'
NUMBER=23 ACTION=opened run_script intake.sh > /dev/null
assert_eq "ai:skip が付く" "ai:skip" "$(labels_of 23)"

echo "== 見張り役の保険も、オーナー以外の Issue は企画に回さない。企画AIが分けて作った Issue は、知らせずに企画へ"
init_state '{"labels":{"30":[],"31":[]},"authors":{"30":"stranger","31":"github-actions[bot]"}}'
state_py "s['issue_updated']['30']='$(ago 20)'; s['issue_updated']['31']='$(ago 20)'"
: > "$MOCK_DIR/curl.log"
run_script watchdog.sh > /dev/null
assert_eq "オーナー以外は ai:skip" "ai:skip" "$(labels_of 30)"
assert_eq "分けて作った Issue は ai:plan" "ai:plan" "$(labels_of 31)"
assert_eq "いつもの流れなので、知らせない" "0" "$(notify_count)"

finish
