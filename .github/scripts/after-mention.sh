#!/usr/bin/env bash
# 「@claude 直して」の対応が終わったあと：コミットが増えていなければ（直さなかった・止まった）、
# このままだと誰も動かないので人間に回す。コミットが増えていれば、CIが走って続きが進む。
# コミットは増えていなくても、PRの説明だけを直した（指摘がPRの説明のとき）なら、もう一度レビューに回す。
#
# 環境変数：RUN_STARTED（対応が始まった時刻）、CONCLUSION（対応のワークフローの結果）、READ_TOKEN（ワークフローのトークン、actions: read）
# 直してpushされていれば、そのCIが承認待ちで止まっていないかも確かめる
source "$(dirname "$0")/pipeline-lib.sh"
set -e

has_pipeline_token || { echo "PIPELINE_TOKEN が無いので何もしません"; exit 0; }

started=$(date -d "$RUN_STARTED" +%s)

for pr in $(gh api "repos/$REPO/pulls?state=open&per_page=100" -q '.[].number'); do
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
      mark_for_retry "$pr" mention "$(failure_reason "AIに直すよう頼みましたが、AIがエラーで終わりました（ログは、Claude Mention の実行の方を見てください）")"
    else
      # AIが「許可されていない」と報告していたら、足りない許可を書く（人間が何を足せばいいか分かるように）
      hints=$(all_comments "$pr" | jq -r '[.[] | select(.user.login == "claude[bot]")] | last | .body // ""' | permission_hints_from_text)
      if [ -n "$hints" ]; then
        report_permission_gap "$pr" "$(printf '%s\n' "$hints" | sed -n 's/^KEY: //p')"
        stop_for_human "$pr" "AIが許可されていない操作で止まったようです。AIの報告：$(printf '%s\n' "$hints" | grep -v '^KEY: ' | tr '\n' ' ')／足りない許可の候補：$(printf '%s\n' "$hints" | sed -n 's/^KEY: //p' | paste -sd, - | sed 's/,/、/g')（docs/pipeline.md の「AIの許可」の表を見てください）"
      else
        stop_for_human "$pr" "AIに直すよう頼みましたが、変更が入りませんでした（AIのコメントを確認してください）"
      fi
    fi
  else
    # AIが直してpushした。そのCIが承認待ちで止まっていたら動かし直す
    branch=$(gh api "repos/$REPO/pulls/$pr" -q .head.ref)
    rerun_ci_if_waiting_approval "$pr" "$head" "$branch"
  fi
done
