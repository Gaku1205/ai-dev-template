#!/usr/bin/env bash
# 受付（intake.sh）：新しいIssueを企画AIに回す／オーナー以外のIssueは止める
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

scene "オーナーが作ったラベルの無いIssue：企画（ai:plan）に回す"
seed_issue 1 "メモ" owner "" 0
run env NUMBER=1 ACTION=opened INTAKE_WAIT_SEC=0 "$SCRIPTS/intake.sh"
assert_rc 0
assert_label 1 "ai:plan"

scene "オーナー以外が作ったIssue：自動で動かさず ai:skip で止める"
seed_issue 2 "知らない人のIssue" stranger "" 0
run env NUMBER=2 ACTION=opened INTAKE_WAIT_SEC=0 "$SCRIPTS/intake.sh"
assert_rc 0
assert_label 2 "ai:skip"
assert_no_label 2 "ai:plan"

scene "パイプライン自身（claude[bot]）が作ったIssue：企画に回す"
seed_issue 3 "分割されたIssue" "claude[bot]" "" 0
run env NUMBER=3 ACTION=opened INTAKE_WAIT_SEC=0 "$SCRIPTS/intake.sh"
assert_rc 0
assert_label 3 "ai:plan"

scene "すでに ai: のラベルが付いている物は、何もしない（ai:queue）"
seed_issue 4 "順番待ち" owner "ai:queue" 0
run env NUMBER=4 ACTION=opened INTAKE_WAIT_SEC=0 "$SCRIPTS/intake.sh"
assert_rc 0
assert_no_label 4 "ai:plan"

scene "ai:skip を付けて作った物は、何もしない"
seed_issue 5 "人間の下準備が先の物" owner "ai:skip" 0
run env NUMBER=5 ACTION=opened INTAKE_WAIT_SEC=0 "$SCRIPTS/intake.sh"
assert_rc 0
assert_no_label 5 "ai:plan"

scene "ラベルが全部外された（unlabeled）Issue：作った人に関係なく企画に回す"
seed_issue 6 "ai:skip を外した物" stranger "" 0
run env NUMBER=6 ACTION=unlabeled INTAKE_WAIT_SEC=0 "$SCRIPTS/intake.sh"
assert_rc 0
assert_label 6 "ai:plan"

scene "PIPELINE_TOKEN が無いときは、何もしない"
seed_issue 7 "メモ" owner "" 0
run env GH_TOKEN= NUMBER=7 ACTION=opened INTAKE_WAIT_SEC=0 "$SCRIPTS/intake.sh"
assert_rc 0
assert_no_label 7 "ai:plan"

finish
