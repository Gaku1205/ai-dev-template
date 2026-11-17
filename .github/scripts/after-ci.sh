#!/usr/bin/env bash
# CIが終わったあと（PRのとき）：
#   通った → main が先に進んでいれば取り込む（CIがもう一度走る）。最新なら：
#            レビューAIの結果がもう出ていれば、その結果でマージへ進める（after-review.sh）。動いていれば待つ（終わったら after-review.sh が進める）。
#            どちらでもなければ、レビューAIを動かす（ai:review を付け直す）。レビューAIは、PRができた・push された時点でCIと同時に始まる（#119）
#   落ちた → 動いているレビューAIを取り消し、AIに直させる（上限を超えたら人間に回す）
#   取り消された → 1回だけやり直す。また取り消されたら人間に回す
#
# 環境変数：CONCLUSION、HEAD_SHA、HEAD_BRANCH、RUN_ID・READ_TOKEN（CIの実行の番号と読み取り用トークン。あれば見た目のテストの失敗を見分ける）
source "$(dirname "$0")/pipeline-lib.sh"
set -e
CI_CANCEL_MARK="<!-- auto-ci-cancel-rerun -->"

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

# CIが取り消された（時間切れ・手で取り消した・実行環境が落ちた）：結果が出ていないので、成功とも失敗とも扱えない。
# 何もしないと、PRがずっと ai:review のまま止まる（PR #161：スクリプトのテストが10分の時間切れで取り消された）。
# 新しいコミットが来て取り消された物は、上の「新しいコミットが来ている」で終わっている。
# 1回だけ取り消されたジョブをやり直し、2回目も取り消されたら人間に回す（AIに直させても、直す物が分からない）
if [ "$CONCLUSION" = cancelled ]; then
  cancels=$(all_comments "$pr" | jq --arg m "$CI_CANCEL_MARK" --arg s "$HEAD_SHA" '[.[] | select(.body | contains($m)) | select(.body | contains($s))] | length')
  if [ "${cancels:-0}" -lt 1 ] && [ -n "${RUN_ID:-}" ] &&
    GH_TOKEN="${READ_TOKEN:-$GH_TOKEN}" gh api -X POST "repos/$REPO/actions/runs/$RUN_ID/rerun-failed-jobs" > /dev/null 2>&1; then
    comment "$pr" "CIが途中で取り消されました（時間切れなど）。結果が出ていないので、取り消されたジョブを1回だけやり直します（コミット ${HEAD_SHA}）。

${CI_CANCEL_MARK}"
    echo "PR #$pr：CIが取り消されたので、やり直しました"
    exit 0
  fi
  stop_for_human "$pr" "CIが続けて取り消されました（時間切れなど）。CIのログで、どのジョブが時間切れになったかを確かめて、直してから CI をやり直し、ai:stuck を外してください"
  echo "PR #$pr：CIが続けて取り消されたので、人間に回しました"
  exit 0
fi

# パイプラインの更新を配るPR（テンプレートの sync-to-apps.sh が作る）：AIのレビューは通さず、CIだけで決める。
#   通った → main に追いついていればマージ（追いついていなければ取り込んで、CIのやり直しを待つ）
#   落ちた → 配られた更新がこのアプリで動かないので、人間に回す
sync_pr=no
case "$HEAD_BRANCH" in
  pipeline-sync/*)
    # 印のある本文で、AI（claude[bot]）以外が作ったPRだけを、配布のPRとして扱う（AIがこの近道でレビューを飛ばせないように）
    pr_info=$(gh api "repos/$REPO/pulls/$pr" -q '"\(.user.login)|\(.body // "" | contains("<!-- pipeline-sync -->"))"')
    case "$pr_info" in "claude[bot]|"*) ;; *"|true") sync_pr=yes ;; esac
    ;;
esac
case "$sync_pr" in
  yes)
    if [ "$CONCLUSION" = success ]; then
      behind=$(gh api "repos/$REPO/compare/$HEAD_SHA...main" -q .ahead_by)
      if [ "${behind:-0}" -gt 0 ]; then
        gh api -X PUT "repos/$REPO/pulls/$pr/update-branch" -f expected_head_sha="$HEAD_SHA" > /dev/null 2>&1 || true
        echo "PR #$pr（パイプラインの更新）：main を取り込みました。CIが終わったらマージします"
      else
        # 一時的なエラー（502 など）は、少し待って3回まで試す（merge_pr）
        if ! out=$(merge_pr "$pr" "$HEAD_SHA"); then
          # 配られた更新は AI に直させない（マネージャーが見る）
          add_label "$pr" "ai:stuck"
          comment "$pr" "⚠️ テンプレートから配られたパイプラインの更新を、マージできませんでした（$(printf '%s' "$out" | tail -n 1 | cut -c1-160)）。マネージャーに確認してもらってください。"
          notify stuck "パイプラインの更新が入りません" "PR #${pr}：配られた更新をマージできませんでした" 4
          echo "PR #$pr（パイプラインの更新）：マージできなかったので人間に回しました"
          exit 0
        fi
        gh api -X DELETE "repos/$REPO/git/refs/heads/$HEAD_BRANCH" > /dev/null 2>&1 || true
        echo "PR #$pr（パイプラインの更新）：CIが通ったのでマージしました"
      fi
    else
      add_label "$pr" "ai:stuck"
      comment "$pr" "⚠️ テンプレートから配られたパイプラインの更新で、このリポジトリのCIが落ちました。マネージャーに確認してもらってください（AIには直させません）。"
      notify stuck "パイプラインの更新が入りません" "PR #${pr}：配られた更新でCIが落ちました" 4
      echo "PR #$pr（パイプラインの更新）：CIが落ちたので人間に回しました"
    fi
    exit 0
    ;;
esac

case "$CONCLUSION" in
  success)
    # レビューの指摘で、もうこのコミットに直すよう頼んであれば、main を取り込まない（修正AIの作業中のブランチを動かさない。直した push のあとに CI がもう一度走り、そのときに取り込む）
    if fix_requested_for "$pr" "$HEAD_SHA"; then
      echo "PR #$pr：CIが通りましたが、このコミットにはもう直すよう頼んであるので、直した push を待ちます"
      exit 0
    fi
    # main が先に進んでいたら、先にPRのブランチへ取り込む（取り込むとCIがもう一度走り、通ったらここに戻ってくる）。
    # レビューAIのワークフローは、PRのブランチの版が main と同じでないと動かないので、これが要る
    behind=$(gh api "repos/$REPO/compare/$HEAD_SHA...main" -q .ahead_by)
    if [ "${behind:-0}" -gt 0 ]; then
      if gh api -X PUT "repos/$REPO/pulls/$pr/update-branch" -f expected_head_sha="$HEAD_SHA" > /dev/null 2>&1; then
        echo "PR #$pr：main の変更（${behind} コミット）を取り込みました。CIが終わったらレビューに進みます"
      else
        # コンフリクトは、AIに解消させる（直す回数に数える。直らなければ人間に回る）
        request_fix_or_stop "$pr" "$HEAD_SHA" "main の変更を取り込もうとしたら、コンフリクトで取り込めませんでした。\`git fetch origin main\` のあと \`git merge origin/main\` でコンフリクトを解消してください。両方の変更の意図を残し、どちらかを捨てるときはPRにコメントで理由を書いてください。解消したら確認コマンド（pipeline.json の checks。無ければ型チェック・リント・テスト・ビルド）を全部通して push してください。"
      fi
      exit 0
    fi
    # レビューAIは CI と同時に始めている（#119）。結果が出ていれば、その結果でマージへ進める
    case "$(review_state "$pr" "$HEAD_SHA")" in
      done)
        echo "PR #$pr：CIが通り、レビューの結果も出ているので、マージへ進めます"
        CONCLUSION=success exec bash "$(dirname "$0")/after-review.sh"
        ;;
      running)
        echo "PR #$pr：CIが通りました。レビューAIが動いているので、終わったらマージへ進めます"
        ;;
      *)
        # 付け直すと labeled イベントが起きて、レビューAIが動く
        remove_label "$pr" "ai:review"
        add_label "$pr" "ai:review"
        echo "PR #$pr：CIが通ったのでレビューを依頼しました"
        ;;
    esac
    ;;
  failure)
    # 同じコミットに CI と同時に動いているレビューAIは、取り消す（直したあとに両方がもう一度動く。AIの使用量を無駄にしない）
    cancel_running_review "$pr" "$HEAD_SHA"
    # 見た目のテストだけが落ちていて、PRに「見た目を変えた」（visual:update）と書いてあるなら、
    # 意図した変更なので、AIに直させず基準の画像を撮り直す（visual-update.yml が動き、終わるとCIがもう一度走る）。
    # 意図していない見た目の崩れは、今まで通りAIに直させる。撮り直しは、main を最後に取り込んだ後で2回まで（visual_update_count）
    if [ -n "${RUN_ID:-}" ] && [ -n "${READ_TOKEN:-}" ]; then
      failed_steps=$(GH_TOKEN="$READ_TOKEN" gh api "repos/$REPO/actions/runs/$RUN_ID/jobs?per_page=50" \
        -q '[.jobs[].steps[] | select(.conclusion == "failure") | .name]' 2> /dev/null || echo '[]')
      only_visual=$(printf '%s' "$failed_steps" | jq 'length > 0 and all(.[]; . == "見た目のテスト")')
      pr_body=$(gh api "repos/$REPO/pulls/$pr" -q '.body // ""')
      updated=$(visual_update_count "$pr")
      if [ "$only_visual" = "true" ] && printf '%s' "$pr_body" | grep -q 'visual:update' && [ "$updated" -lt 2 ]; then
        comment "$pr" "見た目のテストだけが落ちていて、見た目を変えたPRなので、基準の画像をCIの環境で撮り直します（自動、$((updated + 1))回目）。

${VISUAL_MARK}"
        add_label "$pr" "visual:update"
        echo "PR #$pr：見た目のテストだけが落ちたので、基準の画像の撮り直しを依頼しました"
        exit 0
      fi
      # パイプライン自体の確認（shellcheck・スクリプトのテスト）だけが落ちていて、PRが .github/ を触っていない：
      # 落ちた原因はこのPRの変更ではなく、AIは .github/ を直せない（直させても「直す物が無い」で止まる）。
      # 一時的な揺れ（実行環境の入れ替わりなど）のことがあるので、1回だけ落ちたジョブをやり直す。それでも落ちたら人間に回す
      only_pipeline=$(printf '%s' "$failed_steps" | jq 'length > 0 and all(.[]; . == "スクリプトのテスト" or . == "shellcheck")')
      if [ "$only_pipeline" = "true" ] &&
        files=$(gh api "repos/$REPO/pulls/$pr/files?per_page=100" --paginate -q '.[].filename' 2> /dev/null) &&
        ! printf '%s\n' "$files" | grep -q '^\.github/'; then
        reruns=$(all_comments "$pr" | jq --arg m "$PIPELINE_TEST_MARK" '[.[] | select(.body | contains($m))] | length')
        if [ "$reruns" -lt 1 ] && GH_TOKEN="${READ_TOKEN:-$GH_TOKEN}" gh api -X POST "repos/$REPO/actions/runs/$RUN_ID/rerun-failed-jobs" > /dev/null 2>&1; then
          comment "$pr" "パイプライン自体のテスト（スクリプトのテスト・shellcheck）だけが落ちました。このPRの変更（.github/ の外）が原因ではないので、AIには直させず、落ちたジョブを1回だけやり直します。

${PIPELINE_TEST_MARK}"
          echo "PR #$pr：パイプライン自体のテストだけが落ちたので、CIをやり直しました"
          exit 0
        fi
        stop_for_human "$pr" "パイプライン自体のテスト（スクリプトのテスト・shellcheck）が落ちています。このPRの変更（.github/ の外）が原因ではなく、AIは .github/ を直せないので止めました。テンプレート（ai-dev-template）の側で確かめて、直ったら CI をやり直してから ai:stuck を外してください"
        echo "PR #$pr：パイプライン自体のテストが続けて落ちたので、人間に回しました"
        exit 0
      fi
    fi
    # レビューの指摘で、もうこのコミットに直すよう頼んであれば、二重に頼まない（修正AIが2つ同時に動かないように。直した push のあとに CI がもう一度走る）
    if fix_requested_for "$pr" "$HEAD_SHA"; then
      echo "PR #$pr：CIが落ちましたが、このコミットにはもう直すよう頼んであるので、重ねて頼みません"
      exit 0
    fi
    notify ci_failed "CIが失敗しました" "PR #${pr} $(issue_title "$pr")：AIに直してもらいます" 3
    request_fix_or_stop "$pr" "$HEAD_SHA" "CIが失敗しました。失敗したチェックのログを確認して、原因を直してください。"
    echo "PR #$pr：CIが落ちたので直すよう依頼しました"
    ;;
esac
