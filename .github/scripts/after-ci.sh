#!/usr/bin/env bash
# CIが終わったあと（PRのとき）：
#   通った → main が先に進んでいれば取り込む（CIがもう一度走る）。最新なら、レビューAIを動かす（ai:review を付け直す）
#   落ちた → AIに直させる（上限を超えたら人間に回す）
#
# 環境変数：CONCLUSION、HEAD_SHA、HEAD_BRANCH、RUN_ID・READ_TOKEN（CIの実行の番号と読み取り用トークン。あれば見た目のテストの失敗を見分ける）
source "$(dirname "$0")/pipeline-lib.sh"
set -e

has_pipeline_token || { echo "PIPELINE_TOKEN が無いので何もしません"; exit 0; }

read -r pr head < <(find_open_pr "$HEAD_BRANCH") || true
if [ -z "${pr:-}" ]; then
  echo "openのPRがありません"
  exit 0
fi
if [ "$head" != "$HEAD_SHA" ]; then
  echo "このCIのあとに新しいコミットが来ているので、何もしません"
  exit 0
fi
if has_label "$pr" "ai:stuck"; then
  echo "人間の確認待ち（ai:stuck）なので、何もしません"
  exit 0
fi

case "$CONCLUSION" in
  success)
    # main が先に進んでいたら、先にPRのブランチへ取り込む（取り込むとCIがもう一度走り、通ったらここに戻ってくる）。
    # レビューAIのワークフローは、PRのブランチの版が main と同じでないと動かないので、これが要る
    behind=$(gh api "repos/$REPO/compare/$HEAD_SHA...main" -q .ahead_by)
    if [ "${behind:-0}" -gt 0 ]; then
      if gh api -X PUT "repos/$REPO/pulls/$pr/update-branch" -f expected_head_sha="$HEAD_SHA" > /dev/null 2>&1; then
        echo "PR #$pr：main の変更（${behind} コミット）を取り込みました。CIが終わったらレビューに進みます"
      else
        # コンフリクトは、AIに解消させる（直す回数に数える。直らなければ人間に回る）
        request_fix_or_stop "$pr" "$HEAD_SHA" "main の変更を取り込もうとしたら、コンフリクトで取り込めませんでした。\`git fetch origin main\` のあと \`git merge origin/main\` でコンフリクトを解消してください。両方の変更の意図を残し、どちらかを捨てるときはPRにコメントで理由を書いてください。解消したら型チェック・リント・テスト・ビルドを通して push してください。"
      fi
      exit 0
    fi
    # 付け直すと labeled イベントが起きて、レビューAIが動く
    remove_label "$pr" "ai:review"
    add_label "$pr" "ai:review"
    echo "PR #$pr：CIが通ったのでレビューを依頼しました"
    ;;
  failure)
    # 見た目のテストだけが落ちていて、PRに「見た目を変えた」（visual:update）と書いてあるなら、
    # 意図した変更なので、AIに直させず基準の画像を撮り直す（visual-update.yml が動き、終わるとCIがもう一度走る）。
    # 意図していない見た目の崩れは、今まで通りAIに直させる。撮り直しは1つのPRで2回まで
    if [ -n "${RUN_ID:-}" ] && [ -n "${READ_TOKEN:-}" ]; then
      failed_steps=$(GH_TOKEN="$READ_TOKEN" gh api "repos/$REPO/actions/runs/$RUN_ID/jobs?per_page=50" \
        -q '[.jobs[].steps[] | select(.conclusion == "failure") | .name]' 2> /dev/null || echo '[]')
      only_visual=$(printf '%s' "$failed_steps" | jq 'length > 0 and all(.[]; . == "見た目のテスト")')
      pr_body=$(gh api "repos/$REPO/pulls/$pr" -q '.body // ""')
      updated=$(all_comments "$pr" | jq --arg m "$VISUAL_MARK" '[.[] | select(.body | contains($m))] | length')
      if [ "$only_visual" = "true" ] && printf '%s' "$pr_body" | grep -q 'visual:update' && [ "$updated" -lt 2 ]; then
        comment "$pr" "見た目のテストだけが落ちていて、見た目を変えたPRなので、基準の画像をCIの環境で撮り直します（自動、$((updated + 1))回目）。

${VISUAL_MARK}"
        add_label "$pr" "visual:update"
        echo "PR #$pr：見た目のテストだけが落ちたので、基準の画像の撮り直しを依頼しました"
        exit 0
      fi
    fi
    notify ci_failed "CIが失敗しました" "PR #${pr} $(issue_title "$pr")：AIに直してもらいます" 3
    request_fix_or_stop "$pr" "$HEAD_SHA" "CIが失敗しました。失敗したチェックのログを確認して、原因を直してください。"
    echo "PR #$pr：CIが落ちたので直すよう依頼しました"
    ;;
esac
