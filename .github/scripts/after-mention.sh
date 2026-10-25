#!/usr/bin/env bash
# 「@claude 直して」の対応が終わったあと：コミットが増えていなければ（直さなかった・止まった）、
# このままだと誰も動かないので人間に回す。コミットが増えていれば、CIが走って続きが進む。
#
# 環境変数：RUN_STARTED（対応が始まった時刻）
source "$(dirname "$0")/pipeline-lib.sh"

has_pipeline_token || { echo "PIPELINE_TOKEN が無いので何もしません"; exit 0; }

started=$(date -d "$RUN_STARTED" +%s)

for pr in $(gh pr list -R "$REPO" --state open --json number -q '.[].number'); do
  pr_has_label "$pr" "ai:stuck" && continue
  last=$(gh api "repos/$REPO/issues/$pr/comments" --paginate --slurp \
    | jq -c --arg mark "$AUTO_FIX_MARK" 'add | map(select(.body | contains($mark))) | last // empty')
  [ -z "$last" ] && continue

  created=$(date -d "$(printf '%s' "$last" | jq -r .created_at)" +%s)
  # この対応のきっかけになった依頼か（依頼の直後に始まった対応か）
  if [ "$created" -gt "$started" ] || [ $((started - created)) -gt 180 ]; then
    continue
  fi

  asked_sha=$(printf '%s' "$last" | jq -r .body | sed -nE 's/.*auto-fix-sha: ([0-9a-f]+).*/\1/p')
  head=$(gh pr view "$pr" -R "$REPO" --json headRefOid -q .headRefOid)
  if [ -n "$asked_sha" ] && [ "$head" = "$asked_sha" ]; then
    stop_for_human "$pr" "AIに直すよう頼みましたが、変更が入りませんでした（AIのコメントを確認してください）"
  fi
done
