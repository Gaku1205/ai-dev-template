#!/usr/bin/env bash
# 「@claude 直して」の対応が終わったあと：コミットが増えていなければ（直さなかった・止まった）、
# このままだと誰も動かないので人間に回す。コミットが増えていれば、CIが走って続きが進む。
# コミットは増えていなくても、PRの説明だけを直した（指摘がPRの説明のとき）なら、もう一度レビューに回す。
#
# コミットが増えず、PRの説明も変わっていなければ、理由を分けて動く（classify_no_change）：
#   基準の画像の撮り直しが要る → visual:update を付ける（main を最後に取り込んだ後で2回まで）
#   ツールの許可が拒否された   → 拒否された操作を書いて、1回だけ同じ依頼を出し直す（2回目は人間に回す）
#   指摘は誤りと返した         → もう一度レビューに回す（直す回数の上限に数える）
#   撮り直しを頼まれたが、main とのコンフリクトが残っている → 撮り直しは動かないので付けない。拒否された操作があれば出し直し、無ければ人間に回す
#   分類できない               → 人間に回す（ai:stuck）
#
# 環境変数：RUN_STARTED（対応が始まった時刻）、CONCLUSION（対応のワークフローの結果）、READ_TOKEN（ワークフローのトークン、actions: read）、
#           EXECUTION_FILE（あれば。修正AIの実行記録。拒否された操作を読む）
# 直してpushされていれば、そのCIが承認待ちで止まっていないかも確かめる
source "$(dirname "$0")/pipeline-lib.sh"
set -e

has_pipeline_token || { echo "PIPELINE_TOKEN が無いので何もしません"; exit 0; }

started=$(date -d "$RUN_STARTED" +%s)

for pr in $(gh api "repos/$REPO/pulls?state=open&per_page=100" --paginate -q '.[].number'); do
  has_label "$pr" "ai:stuck" && continue
  # やり直しの依頼（auto-fix-retry）も含めて、いちばん新しい依頼を見る
  last=$(all_comments "$pr" | jq -c 'map(select(.body | test("<!-- auto-fix(-retry)? -->"))) | last // empty')
  [ -z "$last" ] && continue

  created=$(date -d "$(printf '%s' "$last" | jq -r .created_at)" +%s)
  # この対応のきっかけになった依頼か（依頼の直後に始まった対応か）
  if [ "$created" -gt "$started" ] || [ $((started - created)) -gt 180 ]; then
    continue
  fi

  asked_sha=$(printf '%s' "$last" | jq -r .body | sed -nE 's/.*auto-fix-sha: ([0-9a-f]+).*/\1/p')
  asked_body=$(printf '%s' "$last" | jq -r .body | sed -nE 's/.*auto-fix-body: ([0-9a-f]+).*/\1/p')
  head=$(gh api "repos/$REPO/pulls/$pr" -q .head.sha)
  if [ -n "$asked_sha" ] && [ "$head" = "$asked_sha" ]; then
    if [ "${CONCLUSION:-success}" = "success" ] && [ -n "$asked_body" ] && [ "$(pr_body_hash "$pr")" != "$asked_body" ]; then
      # PRの説明だけを直した。CIは走らないので、ここでレビューを付け直す（直す回数は依頼のたびに数えるので、無限には回らない）
      remove_label "$pr" "ai:review"
      add_label "$pr" "ai:review"
      echo "PR #$pr：PRの説明が直ったので、もう一度レビューを依頼しました"
    elif [ "${CONCLUSION:-success}" != "success" ]; then
      # AIがエラーで終わったとき（使用量の上限など）は、自動でやり直す（watchdog.sh）
      # 実行記録（EXECUTION_FILE）があれば、原因に合わせる：使用量の上限ならリセットまで待ち（回数を使わない）、
      # 作業回数の上限が続くなら、やり直さず人間に回す（retry_ai_failure）
      retry_ai_failure "$pr" mention "AIに直すよう頼みましたが、AIがエラーで終わりました（ログは、Claude Mention の実行の方を見てください）" "${EXECUTION_FILE:-}"
    else
      # 変更が入らなかった。AIの返事・レビューの指摘・PRの説明・実行記録から理由を分け（classify_no_change）、
      # 人間の手が要らない物は先へ進める。分類できないときだけ人間に回す
      comments=$(all_comments "$pr")
      since=$(printf '%s' "$last" | jq -r .created_at)
      # AIの返事：この依頼のあとの claude[bot] のコメント（前の回の返事を読まないように）
      ai_text=$(printf '%s' "$comments" | jq -r --arg since "$since" '[.[] | select(.user.login == "claude[bot]" and .created_at >= $since)] | last | .body // ""')
      # レビューの指摘：いまの先頭コミットより後のまとめと、このコミットに付いた行への指摘（古いコミットへの指摘は見ない）
      head_date=$(gh api "repos/$REPO/commits/$head" -q .commit.committer.date)
      review_text=$(printf '%s' "$comments" | jq -r --arg since "$head_date" \
        '[.[] | select((.user.login == "claude[bot]" or .user.login == "github-actions[bot]") and (.body | startswith("## Code review")) and .created_at >= $since) | .body] | join("\n")')
      inline_text=$(gh api "repos/$REPO/pulls/$pr/comments?per_page=100" --paginate --slurp 2> /dev/null \
        | jq -r --arg sha "$head" 'add // [] | map(select(.user.login == "claude[bot]" and .original_commit_id == $sha) | .body) | join("\n")') || inline_text=""
      pr_body=$(gh api "repos/$REPO/pulls/$pr" -q '.body // ""')
      # 拒否された操作：実行記録（EXECUTION_FILE。あれば）と、AIの報告の文から
      denied=$(denied_tools "${EXECUTION_FILE:-}")
      hints=$(printf '%s' "$ai_text" | permission_hints_from_text)
      keys=$({ printf '%s\n' "$denied"; printf '%s\n' "$hints" | sed -n 's/^KEY: //p'; } | awk 'NF' | sort -u)
      denied_note=""
      [ -n "$denied" ] && denied_note="（この実行で拒否された操作：$(permission_list_short "$(denied_raw "${EXECUTION_FILE:-}")")）"
      failed=$(ci_failed_steps "$head")
      kind=$(printf '%s' "$ai_text" | classify_no_change "$(printf '%s\n%s\n%s' "$review_text" "$inline_text" "$pr_body")" "$denied")
      # main とのコンフリクトが残っているPRでは、撮り直し（visual-update.yml は pull_request で動く）もCIも、GitHub が動かさない。
      # visual:update を付けても何も起きず、誰も動かなくなる。撮り直しにはせず、コンフリクトの解消を先にさせる：
      # 拒否された操作があれば、それを手がかりに1回だけ出し直す（permission）。無ければ、理由を書いて人間に回す（conflict）
      conflict_note=""
      if [ "$kind" = visual ] && [ "$(pr_merge_state "$pr")" = dirty ]; then
        conflict_note="main とのコンフリクトが残っています。画像など、中身を混ぜられないファイルは、git checkout --theirs -- パス で main の側を取って git add してください（見た目のテストの基準の画像は main の側を取り、PR に「visual:update で撮り直してください」と書く）。"
        if [ -n "$keys" ]; then kind=permission; else kind=conflict; fi
      fi
      echo "PR #$pr：変更なしで終わった理由：${kind}"
      case "$kind" in
        visual)
          # 人間のラベル作業が要る（基準の画像の撮り直し）：パイプラインが visual:update を付ける。
          # CIが通っていても（レビューだけが指摘した）撮り直す。見た目のテスト以外も落ちているときは、撮り直しでは直らないので人間に回す
          updated=$(visual_update_count "$pr" "$comments")
          others=$(printf '%s' "$failed" | jq -r '[.[] | select(. != "見た目のテスト")] | join("、")')
          if [ -n "$others" ]; then
            stop_for_human "$pr" "AIに直すよう頼みましたが、変更が入りませんでした。基準の画像の撮り直しを頼まれていますが、見た目のテスト以外のチェック（${others}）も落ちているので、撮り直しでは直りません（AIのコメントを確認してください）${denied_note}"
          elif [ "$updated" -ge 2 ]; then
            stop_for_human "$pr" "基準の画像を${updated}回撮り直しても、まだ「基準の画像の撮り直し」を頼まれています（撮り直しは、main を取り込んだ後で2回まで）。見た目の差が意図した物か確かめてください${denied_note}"
          else
            comment "$pr" "修正AIは変更を入れずに終わりましたが、AIの返事・レビューの指摘・PRの説明に「基準の画像の撮り直し」の依頼があるので、基準の画像をCIの環境で撮り直します（自動、$((updated + 1))/2回目）。撮り直しのコミットが入ると、CIとレビューを最初からやり直します。${denied_note}

${VISUAL_MARK}"
            add_label "$pr" "visual:update"
            echo "PR #$pr：基準の画像の撮り直しを依頼しました"
          fi
          ;;
        permission)
          # ツールの許可が拒否された：拒否された操作を書いて、1回だけ同じ依頼を出し直す。2回目は、足りない許可を書いて人間に回す
          what=$(permission_list_short "$keys")
          [ -z "$what" ] && what="（実行記録・AIの報告から読み取れませんでした）"
          # AIへの依頼には、拒否されたそのままの形を書く（何が悪かったか分かるように）。無ければ許可の書き方
          raw=$(denied_raw "${EXECUTION_FILE:-}")
          tried="$what"
          [ -n "$raw" ] && tried=$(permission_list_short "$raw")
          report=$(printf '%s\n' "$hints" | grep -v '^KEY: ' | tr '\n' ' ' || true)
          retried=$(printf '%s' "$comments" | jq --arg m "$PERM_RETRY_MARK" --arg resume "$RESUME_MARK" '
            (map(select(.body | contains($resume)) | .created_at) | max // "") as $since
            | [.[] | select((.body | contains($m)) and .created_at > $since)] | length')
          if [ "$retried" -lt 1 ]; then
            last_body=$(printf '%s' "$last" | jq -r .body)
            request=$(printf '%s' "$last_body" | sed -e '/^<!--/d' -e '/^（前回は/d')
            model_mark=""
            if printf '%s' "$last_body" | grep -q 'auto-fix-model: opus'; then
              model_mark="
<!-- auto-fix-model: opus -->"
            fi
            comment "$pr" "${request}

（前回は、許可されていない操作が拒否されて、変更が入りませんでした。拒否された操作：${tried}。${conflict_note}コマンドは1つずつ動かし、; && | でつながず、cd や 2>&1 も付けないでください。確認コマンドは pipeline.json の checks（無ければ npm run typecheck・npm run lint・npm run test・npm run build）を、書かれたとおりの形で動かせば許可されています。許可の拒否による自動のやり直し 1/1）

${PERM_RETRY_MARK}
<!-- auto-fix-retry -->
<!-- auto-fix-sha: ${head} -->
<!-- auto-fix-body: $(pr_body_hash "$pr") -->${model_mark}"
            echo "PR #$pr：許可の拒否（${tried}）で止まったので、1回だけ同じ依頼を出し直しました"
          else
            # 先に人間に回し、記録は後（記録が遅くて時間切れになっても宙に浮かないように）
            stop_for_human "$pr" "AIが許可されていない操作で止まったようです（1回自動でやり直しても同じでした）。AIの報告：${report:-（なし）}／足りない許可の候補：${what}（docs/pipeline.md の「AIの許可」の表を見てください）"
            report_permission_gap "$pr" "$keys"
          fi
          ;;
        conflict)
          stop_for_human "$pr" "AIに直すよう頼みましたが、main とのコンフリクトを解消できず、変更が入りませんでした。コンフリクトが残っている間は、CIも基準の画像の撮り直しも動きません（AIのコメントを確認してください）${denied_note}"
          ;;
        disagree)
          # 指摘が間違いと返した：理由はAIのコメントに残っているので、もう一度レビューに回して先へ進める。
          # 同じ指摘が続けば、レビューのたびに直す依頼が数えられ、直す回数の上限で人間に回る（無限には回らない）
          if [ "$failed" != "[]" ]; then
            stop_for_human "$pr" "修正AIは「指摘は誤り（直す必要は無い）」と返して変更を入れませんでしたが、CIが落ちたまま（$(printf '%s' "$failed" | jq -r 'join("、")')）なので先へ進めません（AIのコメントを確認してください）${denied_note}"
          else
            comment "$pr" "修正AIは「指摘は誤り（直す必要は無い）」と理由をコメントして、変更を入れませんでした。人間に回さず、もう一度レビューに回します（同じ指摘が続けば、直す回数の上限で人間に回ります）。${denied_note}" || true
            remove_label "$pr" "ai:review"
            add_label "$pr" "ai:review"
            echo "PR #$pr：指摘は誤りと返したので、もう一度レビューを依頼しました"
          fi
          ;;
        *)
          stop_for_human "$pr" "AIに直すよう頼みましたが、変更が入りませんでした（AIのコメントを確認してください）${denied_note}"
          ;;
      esac
    fi
  else
    # AIが直してpushした。そのCIが承認待ちで止まっていたら動かし直す
    branch=$(gh api "repos/$REPO/pulls/$pr" -q .head.ref)
    rerun_ci_if_waiting_approval "$pr" "$head" "$branch"
  fi
done
