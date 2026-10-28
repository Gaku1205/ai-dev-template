#!/usr/bin/env bash
# CIが終わったあと（after-ci.sh）：レビューに進む／AIに直させる／3回目は opus／上限で人間に回る／
# 見た目の基準の画像を自動で撮り直す
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_BRANCH="claude/issue-3-foo"

# Issue #3 と PR #5（先頭コミット abc）を用意する。引数：PRのラベル、PRの説明
setup_pr() {
  seed_issue 3 "テスト用のIssue" owner "ai:implement" 60
  seed_pr 5 "$PR_BRANCH" abc "${1:-}" "${2:-Closes #3}" 60
}

# after-ci.sh を動かす。引数：success か failure、あとは追加の環境変数
after_ci() {
  local conclusion="$1"
  shift
  run env CONCLUSION="$conclusion" HEAD_SHA=abc HEAD_BRANCH="$PR_BRANCH" "$@" "$SCRIPTS/after-ci.sh"
}

# ---- CIが通ったとき ----

scene "CIが通って main に追いついている：レビューAI（ai:review）を付け直す"
setup_pr "ai:review"
after_ci success
assert_rc 0
assert_label 5 "ai:review"
assert_out "レビューを依頼しました"

scene "CIが通ったが main が進んでいる：先に取り込む（レビューにはまだ進まない）"
setup_pr ""
st '.behind.abc = 3'
after_ci success
assert_rc 0
assert_event "update-branch 5"
assert_no_label 5 "ai:review"

scene "main を取り込めない（コンフリクト）：AIに解消させる"
setup_pr ""
st '.behind.abc = 3 | .update_branch_fails = true'
after_ci success
assert_rc 0
assert_comment 5 "コンフリクト"
assert_comment 5 "自動の依頼 1/3"
assert_no_label 5 "ai:review"

scene "このCIのあとに新しいコミットが来ている：何もしない"
setup_pr ""
run env CONCLUSION=success HEAD_SHA=old HEAD_BRANCH="$PR_BRANCH" "$SCRIPTS/after-ci.sh"
assert_rc 0
assert_no_label 5 "ai:review"

scene "人間の確認待ち（ai:stuck）のPR：何もしない"
setup_pr "ai:stuck"
after_ci failure
assert_rc 0
assert_no_comment 5 "@claude"

# ---- 直す依頼の回数（3回目は opus）と、上限で人間に回る ----

scene "直す依頼 1回目：普通のモデル（opus の印は無い）"
setup_pr ""
after_ci failure
assert_rc 0
assert_comment 5 "@claude"
assert_comment 5 "自動の依頼 1/3"
assert_no_comment 5 "auto-fix-model: opus"
assert_comment 5 "$AUTO_FIX_MARK"

scene "直す依頼 2回目：まだ普通のモデル"
setup_pr ""
seed_auto_fixes 5 1
after_ci failure
assert_comment 5 "自動の依頼 2/3"
assert_no_comment 5 "auto-fix-model: opus"

scene "直す依頼 3回目（最後の1回）：いちばん強いモデル opus を指定する"
setup_pr ""
seed_auto_fixes 5 2
after_ci failure
assert_rc 0
assert_comment 5 "自動の依頼 3/3"
assert_comment 5 "<!-- auto-fix-model: opus -->"
assert_comment 5 "いちばん強いモデル"
assert_no_label 5 "ai:stuck"

scene "MAX_AUTO_FIX を変えると、opus になる回数も変わる（1回直したら次が opus）"
setup_pr ""
seed_auto_fixes 5 1
after_ci failure MAX_AUTO_FIX=1
assert_comment 5 "自動の依頼 2/2"
assert_comment 5 "<!-- auto-fix-model: opus -->"

scene "上限（opus の分も含めて3回）を超えた：直す依頼は出さず、人間に回る"
setup_pr ""
seed_auto_fixes 5 3
after_ci failure
assert_rc 0
assert_label 5 "ai:stuck"
assert_label 3 "ai:stuck"
assert_comment 5 "自動で進めるのを止めました"
assert_comment_count 5 "自動の依頼 4" 0
assert_no_comment 5 "<!-- auto-fix-sha:"

scene "人間が再開（RESUME_MARK）したあとは、直す回数を数え直す"
setup_pr ""
seed_auto_fixes 5 3
seed_comment 5 "再開しました

$RESUME_MARK" 50
after_ci failure
assert_no_label 5 "ai:stuck"
assert_comment 5 "自動の依頼 1/3"

# ---- 見た目の基準の画像の自動の撮り直し ----

VISUAL_ONLY='[{"name":"型チェック","conclusion":"success"},{"name":"見た目のテスト","conclusion":"failure"}]'
VISUAL_AND_BUILD='[{"name":"ビルド","conclusion":"failure"},{"name":"見た目のテスト","conclusion":"failure"}]'

scene "見た目のテストだけが落ちて、PRに visual:update と書いてある：AIに直させず、基準の画像を撮り直す"
setup_pr "" "見た目を変えた（visual:update）
Closes #3"
seed_steps 100 "$VISUAL_ONLY"
after_ci failure RUN_ID=100
assert_rc 0
assert_label 5 "visual:update"
assert_comment 5 "$VISUAL_MARK"
assert_comment 5 "1回目"
assert_no_comment 5 "@claude"

scene "撮り直しは1つのPRで2回まで：2回済みなら、AIに直させる"
setup_pr "" "見た目を変えた（visual:update）
Closes #3"
seed_steps 100 "$VISUAL_ONLY"
seed_comment 5 "撮り直し 1回目

$VISUAL_MARK" 40
seed_comment 5 "撮り直し 2回目

$VISUAL_MARK" 20
after_ci failure RUN_ID=100
assert_no_label 5 "visual:update"
assert_comment 5 "@claude"

scene "1回済み：もう1回は撮り直す（2回目）"
setup_pr "" "見た目を変えた（visual:update）
Closes #3"
seed_steps 100 "$VISUAL_ONLY"
seed_comment 5 "撮り直し 1回目

$VISUAL_MARK" 40
after_ci failure RUN_ID=100
assert_label 5 "visual:update"
assert_comment 5 "2回目"

scene "見た目のテスト以外も落ちている：撮り直さず、AIに直させる"
setup_pr "" "見た目を変えた（visual:update）
Closes #3"
seed_steps 100 "$VISUAL_AND_BUILD"
after_ci failure RUN_ID=100
assert_no_label 5 "visual:update"
assert_comment 5 "@claude"

scene "PRに visual:update と書いていない（意図していない崩れ）：AIに直させる"
setup_pr "" "Closes #3"
seed_steps 100 "$VISUAL_ONLY"
after_ci failure RUN_ID=100
assert_no_label 5 "visual:update"
assert_comment 5 "@claude"

scene "実行の番号が無い：見た目の判定はせず、AIに直させる"
setup_pr "" "見た目を変えた（visual:update）
Closes #3"
seed_steps 100 "$VISUAL_ONLY"
after_ci failure
assert_no_label 5 "visual:update"
assert_comment 5 "@claude"

finish
