#!/usr/bin/env bash
# 人間が ai:stuck を外したとき：止まった所から自動で続ける（resume.yml から呼ぶ）。
#   PR    → AIに直させる回数をリセットして、いまのCIの状態から続ける
#           （通っていればレビューへ、落ちていれば直す、承認待ちなら動かし直す）
#   Issue → PRがまだなら、企画・実装・画面案をやり直す（作業のラベルが無ければ企画から）。PRが止まっていれば、PRの続きを始める
#
# 環境変数：NUMBER、IS_PR（true/false）、READ_TOKEN（ワークフローのトークン、actions: read）
source "$(dirname "$0")/pipeline-lib.sh"
set -e

has_pipeline_token || { echo "PIPELINE_TOKEN が無いので何もしません"; exit 0; }

# 外されたあとに、また付け直されていたら何もしない
if has_label "$NUMBER" "ai:stuck"; then
  echo "#$NUMBER：ai:stuck がまた付いているので何もしません"
  exit 0
fi

# やり直しの回数もリセットする（記録のコメントがあれば 0 に戻す）
record=$(retry_comment "$NUMBER")
if [ -n "$record" ]; then
  kind=$(printf '%s' "$record" | jq -r .body | sed -nE 's/.*kind=([a-z]+).*/\1/p' | tail -1)
  write_retry_record "$NUMBER" 0 "${kind:-implement}" "$RESUMED_REASON"
fi
remove_label "$NUMBER" "ai:retry"

if [ "$IS_PR" = "true" ]; then
  pr_json=$(gh api "repos/$REPO/pulls/$NUMBER")
  if [ "$(printf '%s' "$pr_json" | jq -r .state)" != "open" ]; then
    echo "PR #$NUMBER は閉じているので何もしません"
    exit 0
  fi
  head=$(printf '%s' "$pr_json" | jq -r .head.sha)
  ref=$(printf '%s' "$pr_json" | jq -r .head.ref)

  # 紐づくIssueの ai:stuck も外す（残っていると順番待ちが進まない）
  issue=$(linked_issue "$NUMBER")
  if [ -n "$issue" ]; then
    remove_label "$issue" "ai:stuck"
  fi

  comment "$NUMBER" "▶ 人間の確認が済んだので、止まった所から自動で続けます（AIに自動で直させる回数もリセットしました）。

${RESUME_MARK}"

  # いまの先頭コミットの「CI」ワークフロー（このResumeや順番待ちなど、ほかのワークフローは数えない）の状態
  ci=$(GH_TOKEN="$READ_TOKEN" gh api "repos/$REPO/actions/runs?head_sha=$head&event=pull_request&per_page=50" \
    -q '[.workflow_runs[] | select(.name == "CI")] | sort_by(.created_at) | last // empty')
  status=$(printf '%s' "$ci" | jq -r '.status // ""')
  conclusion=$(printf '%s' "$ci" | jq -r '.conclusion // ""')

  if [ -z "$ci" ] || [ "$conclusion" = "action_required" ]; then
    # CIが無い／承認待ち。動かし直す
    rerun_ci_if_waiting_approval "$NUMBER" "$head" "$ref"
    echo "PR #$NUMBER：CIが終われば、そこから自動で続きます"
  elif [ "$status" != "completed" ]; then
    echo "PR #$NUMBER：CIが実行中です。終われば、そこから自動で続きます"
  elif [ "$conclusion" = "success" ]; then
    CONCLUSION=success HEAD_SHA="$head" HEAD_BRANCH="$ref" .github/scripts/after-ci.sh
  else
    CONCLUSION=failure HEAD_SHA="$head" HEAD_BRANCH="$ref" RUN_ID="$(printf '%s' "$ci" | jq -r .id)" .github/scripts/after-ci.sh
  fi
else
  state=$(gh api "repos/$REPO/issues/$NUMBER" -q .state)
  [ "$state" = "open" ] || exit 0
  if has_label "$NUMBER" "ai:plan"; then
    remove_label "$NUMBER" "ai:plan"
    add_label "$NUMBER" "ai:plan"
    echo "#$NUMBER：企画をやり直しました"
  elif has_label "$NUMBER" "ai:implement"; then
    pr=$(gh api "repos/$REPO/pulls?state=open&per_page=100" -q ".[] | select(.head.ref | startswith(\"claude/issue-${NUMBER}-\")) | .number" | head -1)
    if [ -n "$pr" ]; then
      # PRが止まると、PRと Issue の両方に ai:stuck が付く。Issue の方だけ外されたときも、PRの続きを始める
      # （パイプラインの鍵で外すので、PRの方の再開（このワークフロー）が動く）
      if take_label "$pr" "ai:stuck"; then
        echo "#$NUMBER：PR #$pr の ai:stuck も外しました。PRの止まった所から続けます"
      else
        echo "#$NUMBER：PRがあるので、実装はやり直しません"
      fi
    else
      remove_label "$NUMBER" "ai:implement"
      add_label "$NUMBER" "ai:implement"
      echo "#$NUMBER：実装をやり直しました"
    fi
  elif has_label "$NUMBER" "ai:mocks"; then
    # 画面案のまま止まって人間に回った物（見張り役の 2.5）：画面案をもう一度作る。
    # 画面案のジョブが動いている・待っている間は、付け直さない（同じ画面案を2つ作らない）
    running=0
    for st in in_progress queued; do
      c=$(GH_TOKEN="${READ_TOKEN:-$GH_TOKEN}" gh api "repos/$REPO/actions/workflows/claude-mocks.yml/runs?status=$st&per_page=30" \
        -q '[.workflow_runs[] | select(.status != "completed")] | length' 2> /dev/null) || c=0
      running=$(( running + ${c:-0} ))
    done
    if [ "$running" -gt 0 ]; then
      echo "#$NUMBER：画面案の実行が動いているので、何もしません"
    else
      comment "$NUMBER" "▶ 人間の確認が済んだので、画面案をもう一度作ります。

${RESUME_MARK}"
      remove_label "$NUMBER" "ai:mocks"
      add_label "$NUMBER" "ai:mocks"
      echo "#$NUMBER：画面案をやり直しました"
    fi
  else
    # 企画で止まった物（人間にしかできない作業の依頼・許可の不足・やり直しの上限）は、止めるときに ai:plan を外してある。
    # 作業のラベルが1つも無ければ、企画からやり直す（何もしないと、見張り役が「頼まれていない Issue」として拾うまで10分以上待つ）。
    # 待っている物（順番待ち・質問・ほかの作業待ち）と、まだ動かさない物（ai:skip）は、そのまま
    for l in ai:queue ai:question ai:blocked ai:skip; do
      if has_label "$NUMBER" "$l"; then
        echo "#$NUMBER：${l} が付いているので、何もしません"
        exit 0
      fi
    done
    # この Issue を閉じるPRが開いていれば、作業はPRの側で進んでいる（PRを再開すると、紐づく Issue の ai:stuck も外れてここに来る）。企画し直さない
    linked=$(gh api "repos/$REPO/pulls?state=open&per_page=100" | jq --arg n "$NUMBER" \
      '[.[] | select((.head.ref | startswith("claude/issue-" + $n + "-")) or ((.body // "") | test("(close[sd]?|fix(e[sd])?|resolve[sd]?) #" + $n + "([^0-9]|$)"; "i")))] | length')
    if [ "${linked:-0}" -gt 0 ]; then
      echo "#$NUMBER：この Issue のPRが開いているので、企画はやり直しません"
      exit 0
    fi
    add_label "$NUMBER" "ai:plan"
    echo "#$NUMBER：作業のラベルが無いので、企画からやり直しました"
  fi
fi
