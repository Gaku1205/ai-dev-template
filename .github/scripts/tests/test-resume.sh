#!/usr/bin/env bash
# 再開（resume.sh）：人間が ai:stuck を外したとき、止まった所から続ける
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_BRANCH="claude/issue-3-foo"

# 紐づくIssue #3 と、そのPR #5 を用意する。引数：PRのラベル
setup_pr() {
  seed_issue 3 "テスト用のIssue" owner "ai:implement,ai:stuck" 60
  seed_pr 5 "$PR_BRANCH" abc "$1" "Closes #3" 60
}

scene "CIが通っているPR：再開するとレビューに進む（Resumeワークフロー自身が動いていても、CIとは数えない）"
setup_pr ""
seed_run "CI" abc completed success 10 1
seed_run "Resume" abc in_progress "" 0 2
run env NUMBER=5 IS_PR=true "$SCRIPTS/resume.sh"
assert_rc 0
assert_label 5 "ai:review"
assert_no_label 3 "ai:stuck"
assert_comment 5 "$RESUME_MARK"
assert_out "レビューを依頼しました"

scene "別のワークフロー（順番待ちなど）が動いていても、CIの結果で続ける"
setup_pr ""
seed_run "CI" abc completed success 10 1
seed_run "Queue" abc in_progress "" 0 2
seed_run "Pipeline" abc queued "" 0 3
run env NUMBER=5 IS_PR=true "$SCRIPTS/resume.sh"
assert_label 5 "ai:review"

scene "CIがまだ実行中：何もせず、終わるのを待つ"
setup_pr ""
seed_run "CI" abc in_progress "" 1 1
run env NUMBER=5 IS_PR=true "$SCRIPTS/resume.sh"
assert_rc 0
assert_no_label 5 "ai:review"
assert_no_comment 5 "@claude"
assert_out "CIが実行中です"

scene "CIが落ちているPR：再開すると、AIに直させる回数がリセットされて、また直す依頼が出る"
setup_pr ""
seed_run "CI" abc completed failure 10 1
seed_auto_fixes 5 3
run env NUMBER=5 IS_PR=true "$SCRIPTS/resume.sh"
assert_rc 0
assert_no_label 5 "ai:stuck"
assert_comment 5 "自動の依頼 1/3"

scene "CIがまだ無い／承認待ち：空のコミットで動かし直す"
setup_pr ""
seed_run "CI" abc completed action_required 10 1
run env NUMBER=5 IS_PR=true "$SCRIPTS/resume.sh"
assert_rc 0
assert_event "empty-commit"
assert_event "ref-update $PR_BRANCH"

scene "ai:stuck がまた付いていたら、何もしない"
setup_pr "ai:stuck"
seed_run "CI" abc completed success 10 1
run env NUMBER=5 IS_PR=true "$SCRIPTS/resume.sh"
assert_rc 0
assert_no_label 5 "ai:review"
assert_no_comment 5 "$RESUME_MARK"

scene "閉じているPRは、何もしない"
setup_pr ""
st '.pulls["5"].state = "closed"'
seed_run "CI" abc completed success 10 1
run env NUMBER=5 IS_PR=true "$SCRIPTS/resume.sh"
assert_rc 0
assert_no_label 5 "ai:review"

scene "やり直し（ai:retry）の回数もリセットされる"
setup_pr "ai:retry"
seed_retry_record 5 4 mention 60
seed_run "CI" abc completed success 10 1
run env NUMBER=5 IS_PR=true "$SCRIPTS/resume.sh"
assert_rc 0
assert_no_label 5 "ai:retry"
assert_comment 5 "count=0 kind=mention"
assert_comment 5 "人間が再開しました"

scene "Issue：企画で止まっていた物は、企画をやり直す"
seed_issue 8 "企画で止まった物" owner "ai:plan" 60
run env NUMBER=8 IS_PR=false "$SCRIPTS/resume.sh"
assert_rc 0
assert_label 8 "ai:plan"
assert_out "企画をやり直しました"

scene "Issue：実装で止まっていてPRが無い物は、実装をやり直す"
seed_issue 9 "実装で止まった物" owner "ai:implement" 60
run env NUMBER=9 IS_PR=false "$SCRIPTS/resume.sh"
assert_rc 0
assert_label 9 "ai:implement"
assert_out "実装をやり直しました"

scene "Issue：PRができている物は、実装をやり直さない"
seed_issue 3 "PRがある物" owner "ai:implement" 60
seed_pr 5 "$PR_BRANCH" abc "" "Closes #3" 60
run env NUMBER=3 IS_PR=false "$SCRIPTS/resume.sh"
assert_rc 0
assert_out "PRがあるので、実装はやり直しません"

finish
