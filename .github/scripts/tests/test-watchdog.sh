#!/usr/bin/env bash
# 見張り役（watchdog.sh）：止まった物を見つけて、時間をおいてやり直す／上限で人間に回す／順番待ちを進める
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

watchdog() { run "$SCRIPTS/watchdog.sh"; }

# ---- 1. ai:retry が付いた物のやり直し ----

scene "企画のやり直し：待ち時間が過ぎていれば、ai:plan を付け直して回数を増やす"
seed_issue 7 "企画が止まった物" owner "ai:plan,ai:retry" 40
seed_retry_record 7 2 plan 40
watchdog
assert_rc 0
assert_label 7 "ai:plan"
assert_no_label 7 "ai:retry"
assert_comment 7 "count=3 kind=plan"
assert_comment_count 7 "$RETRY_MARK" 1

scene "待ち時間が過ぎていない：まだやり直さない"
seed_issue 7 "企画が止まった物" owner "ai:plan,ai:retry" 5
seed_retry_record 7 2 plan 5
watchdog
assert_rc 0
assert_label 7 "ai:retry"
assert_comment 7 "count=2 kind=plan"
assert_out "まだ早いです"

scene "実装のやり直し：PRが無ければ ai:implement を付け直す"
seed_issue 8 "実装が止まった物" owner "ai:implement,ai:retry" 40
seed_retry_record 8 0 implement 40
watchdog
assert_label 8 "ai:implement"
assert_no_label 8 "ai:retry"
assert_comment 8 "count=1 kind=implement"

scene "実装のやり直し：PRができていれば、実装はやり直さない（印だけ外す）"
seed_issue 8 "実装が止まった物" owner "ai:implement,ai:retry" 40
seed_retry_record 8 0 implement 40
seed_pr 9 "claude/issue-8-foo" abc "" "Closes #8" 1
watchdog
assert_no_label 8 "ai:retry"
assert_out "実装はやり直しません"

scene "レビューのやり直し：ai:review を付け直す"
seed_pr 9 "claude/issue-8-foo" abc "ai:review,ai:retry" "Closes #8" 40
seed_retry_record 9 1 review 40
watchdog
assert_label 9 "ai:review"
assert_no_label 9 "ai:retry"
assert_comment 9 "count=2 kind=review"

scene "AIへの直す依頼のやり直し：前の依頼（opus の印も）をそのままもう一度出す"
seed_pr 9 "claude/issue-8-foo" abc "ai:retry" "Closes #8" 40
seed_comment 9 "@claude CIが失敗しました。直してください。

${AUTO_FIX_MARK}
<!-- auto-fix-sha: abc -->
<!-- auto-fix-model: opus -->" 90
seed_retry_record 9 1 mention 40
watchdog
assert_no_label 9 "ai:retry"
assert_comment 9 "同じ依頼をもう一度出します"
assert_comment 9 "CIが失敗しました。直してください。"
assert_comment 9 "<!-- auto-fix-retry -->"
assert_comment 9 "<!-- auto-fix-model: opus -->"

scene "人間の確認待ち（ai:stuck）の物は、やり直さずに ai:retry の印だけ外す"
seed_issue 7 "止まっている物" owner "ai:plan,ai:retry,ai:stuck" 100
seed_retry_record 7 2 plan 100
watchdog
assert_label 7 "ai:stuck"
assert_no_label 7 "ai:retry"
assert_comment 7 "count=2 kind=plan"

# ---- 2. 失敗の知らせも無いまま止まっている物 ----

scene "企画AIが30分以上動きが無い：ai:retry を付けて記録を残す"
seed_issue 7 "動きが無い物" owner "ai:plan" 60
watchdog
assert_rc 0
assert_label 7 "ai:retry"
assert_comment 7 "count=0 kind=plan"

scene "企画AIが動いてまだ短い：何もしない"
seed_issue 7 "動いたばかりの物" owner "ai:plan" 10
watchdog
assert_no_label 7 "ai:retry"

scene "実装AIが45分以上動きが無く、PRも無い：ai:retry を付ける"
seed_issue 8 "動きが無い物" owner "ai:implement" 60
watchdog
assert_label 8 "ai:retry"
assert_comment 8 "kind=implement"

scene "実装AIの物でも、PRができていれば何もしない"
seed_issue 8 "PRがある物" owner "ai:implement" 60
seed_pr 9 "claude/issue-8-foo" abc "" "Closes #8" 1
watchdog
assert_no_label 8 "ai:retry"

scene "レビューAIの結果が出ないまま30分以上：ai:retry を付ける"
seed_pr 9 "claude/issue-8-foo" abc "ai:review" "Closes #8" 40
st '.commit_dates.abc = "'"$(ago 120)"'"'
watchdog
assert_label 9 "ai:retry"
assert_comment 9 "kind=review"

scene "レビューAIの結果（## Code review）がもう出ている：何もしない"
seed_pr 9 "claude/issue-8-foo" abc "ai:review" "Closes #8" 40
st '.commit_dates.abc = "'"$(ago 120)"'"'
seed_comment 9 "## Code review
指摘なし" 10 "claude[bot]"
watchdog
assert_no_label 9 "ai:retry"

scene "人間の確認待ち（ai:stuck）の物は、動きが無くても触らない"
seed_issue 7 "確認待ち" owner "ai:plan,ai:stuck" 300
watchdog
assert_no_label 7 "ai:retry"
assert_no_comment 7 "$RETRY_MARK"

# ---- 上限で人間に回る ----

scene "10回やり直しても直らない：ai:stuck で人間に回す"
seed_issue 7 "何度やっても止まる物" owner "ai:plan" 60
seed_retry_record 7 10 plan 60
watchdog
assert_rc 0
assert_label 7 "ai:stuck"
assert_no_label 7 "ai:plan"
assert_no_label 7 "ai:retry"
assert_comment 7 "自動でやり直しても10回解決しませんでした"

scene "PRで10回やり直しても直らない：PRと紐づくIssueの両方を ai:stuck にする"
seed_issue 8 "実装済み" owner "ai:implement" 5
seed_pr 9 "claude/issue-8-foo" abc "ai:review" "Closes #8" 40
st '.commit_dates.abc = "'"$(ago 120)"'"'
seed_retry_record 9 10 review 60
watchdog
assert_label 9 "ai:stuck"
assert_label 8 "ai:stuck"

# ---- 3. CIの承認待ち ----

scene "CIが承認待ちで止まっている：空のコミットで動かし直す"
seed_pr 9 "claude/issue-8-foo" abc "" "Closes #8" 10
seed_run "CI" abc completed action_required 10 1
watchdog
assert_rc 0
assert_event "empty-commit parent=abc"
assert_event "ref-update claude/issue-8-foo"

scene "CIがふつうに動いている：動かし直さない"
seed_pr 9 "claude/issue-8-foo" abc "" "Closes #8" 10
seed_run "CI" abc in_progress "" 10 1
watchdog
assert_no_event "empty-commit"

# ---- 3.5 ラベルが無いまま放置されたIssue ----

scene "ラベルが無いまま10分以上：企画に回す"
seed_issue 11 "見落とされたIssue" owner "" 20
watchdog
assert_label 11 "ai:plan"

scene "ラベルが無くても作った直後（10分未満）は、受付に任せる"
seed_issue 11 "作ったばかりのIssue" owner "" 2
watchdog
assert_no_label 11 "ai:plan"

scene "ai:skip で止めているIssueは、企画に回さない"
seed_issue 11 "止めているIssue" stranger "ai:skip" 600
watchdog
assert_no_label 11 "ai:plan"

# ---- 3.8 古いブランチの掃除 ----

scene "古い claude/* ブランチだけを消す（新しい物・openのPRがある物・人間の物は残す）"
st --arg old "$(ago 4000)" --arg new "$(ago 60)" \
  '.branches = {"claude/old": $old, "claude/new": $new, "claude/issue-8-foo": $old, "feature/mine": $old, "main": $old}'
seed_pr 9 "claude/issue-8-foo" abc "" "Closes #8" 1
watchdog
assert_event "delete-branch claude/old"
assert_no_event "delete-branch claude/new"
assert_no_event "delete-branch claude/issue-8-foo"
assert_no_event "delete-branch feature/mine"
assert_no_event "delete-branch main"

# ---- 4. 順番待ち ----

scene "順番待ち：進行中・停止中・openのPRが無ければ、番号がいちばん小さい物を実装に回す"
seed_issue 21 "二番目" owner "ai:queue" 1
seed_issue 20 "一番目" owner "ai:queue" 1
watchdog
assert_rc 0
assert_label 20 "ai:implement"
assert_no_label 20 "ai:queue"
assert_label 21 "ai:queue"
assert_no_label 21 "ai:implement"
assert_comment 20 "順番が来たので実装を始めます"

scene "順番待ち：実装中の物があれば進めない"
seed_issue 30 "実装中" owner "ai:implement" 1
seed_issue 20 "順番待ち" owner "ai:queue" 1
seed_pr 31 "claude/issue-30-foo" abc "" "Closes #30" 1
watchdog
assert_no_label 20 "ai:implement"
assert_label 20 "ai:queue"

scene "順番待ち：止まっている物（ai:stuck）があれば進めない"
seed_issue 30 "止まっている" owner "ai:stuck" 1
seed_issue 20 "順番待ち" owner "ai:queue" 1
watchdog
assert_no_label 20 "ai:implement"
assert_label 20 "ai:queue"

scene "順番待ち：openのPRがあれば進めない"
seed_issue 30 "PRになった物" owner "" 1
seed_pr 31 "claude/issue-30-foo" abc "" "Closes #30" 1
seed_issue 20 "順番待ち" owner "ai:queue" 1
watchdog
assert_no_label 20 "ai:implement"

scene "PIPELINE_TOKEN が無いときは、何もしない"
seed_issue 20 "順番待ち" owner "ai:queue" 1
run env GH_TOKEN= "$SCRIPTS/watchdog.sh"
assert_rc 0
assert_no_label 20 "ai:implement"

finish
