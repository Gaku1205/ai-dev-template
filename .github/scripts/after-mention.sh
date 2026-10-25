#!/usr/bin/env bash
# 「@claude 直して」の対応が終わったあと：コミットが増えていなければ（直さなかった・止まった）、
# このままだと誰も動かないので人間に回す。コミットが増えていれば、CIが走って続きが進む。
#
# 環境変数：RUN_STARTED（対応が始まった時刻）、READ_TOKEN（ワークフローのトークン、actions: read）
# 直してpushされていれば、そのCIが承認待ちで止まっていないかも確かめる
source "$(dirname "$0")/pipeline-lib.sh"
set -e

has_pipeline_token || { echo "PIPELINE_TOKEN が無いので何もしません"; exit 0; }

started=$(date -d "$RUN_STARTED" +%s)

for pr in $(gh api "repos/$REPO/pulls?state=open&per_page=100" -q '.[].number'); do
  has_label "$pr" "ai:stuck" && continue
  last=$(all_comments "$pr" | jq -c --arg mark "$AUTO_FIX_MARK" 'map(select(.body | contains($mark))) | last // empty')
  [ -z "$last" ] && continue

  created=$(date -d "$(printf '%s' "$last" | jq -r .created_at)" +%s)
  # この対応のきっかけになった依頼か（依頼の直後に始まった対応か）
  if [ "$created" -gt "$started" ] || [ $((started - created)) -gt 180 ]; then
    continue
  fi

  asked_sha=$(printf '%s' "$last" | jq -r .body | sed -nE 's/.*auto-fix-sha: ([0-9a-f]+).*/\1/p')
  head=$(gh api "repos/$REPO/pulls/$pr" -q .head.sha)
  if [ -n "$asked_sha" ] && [ "$head" = "$asked_sha" ]; then
    stop_for_human "$pr" "AIに直すよう頼みましたが、変更が入りませんでした（AIのコメントを確認してください）"
  else
    # AIが直してpushした。そのCIが承認待ちで止まっていたら動かし直す
    branch=$(gh api "repos/$REPO/pulls/$pr" -q .head.ref)
    rerun_ci_if_waiting_approval "$pr" "$head" "$branch"
  fi
done
