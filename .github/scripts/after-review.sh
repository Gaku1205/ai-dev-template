#!/usr/bin/env bash
# レビューAIが終わったあと：
#   指摘なし → CIも全部通っていれば自動でマージ（ai:hold が付いていたら、マージは人間に任せて通知）
#   指摘あり → AIに直させる（上限を超えたら人間に回す）
#
#   CI 以外のチェック（Vercel など）が通っていない → 名前と理由をPRに書き、時間をおいて確かめ直す。続くなら人間に回す
# 見張り役（watchdog.sh）も、マージのやり直し（種類 merge）のときに、CONCLUSION=success でここを呼ぶ
#
# 環境変数：CONCLUSION、HEAD_SHA、HEAD_BRANCH、READ_TOKEN（ワークフローのトークン。checks: read・statuses: read）、EXECUTION_FILE（あれば。レビューAIの実行記録。失敗の原因を見分ける）
source "$(dirname "$0")/pipeline-lib.sh"
set -e

has_pipeline_token || { echo "PIPELINE_TOKEN が無いので何もしません"; exit 0; }

read -r pr head < <(find_open_pr "$HEAD_BRANCH") || true
if [ -z "${pr:-}" ]; then
  echo "openのPRがありません"
  exit 0
fi
if [ "$head" != "$HEAD_SHA" ]; then
  echo "レビューのあとに新しいコミットが来ているので、何もしません"
  exit 0
fi
if has_label_or_unreadable "$pr" "ai:stuck"; then
  echo "人間の確認待ち（ai:stuck）か、ラベルを読めないので、何もしません"
  exit 0
fi
# 「人間にお願いしたいこと」の節があれば、マージ（自動でも人間でも）の前に Closes を Refs に直す（修正AIが本文を書き換えた場合も拾う）
defer_close_for_human_request "$pr" || true

if [ "$CONCLUSION" != "success" ]; then
  # レビューAIが結果のコメント（「## Code review」）を書いたあとにエラーで終わることがある（後片付けの失敗など）。
  # いまの先頭コミットより新しい結果が書けていれば、それで進める（やり直すと30分待つうえ、同じレビューをもう一度する）
  head_date=$(gh api "repos/$REPO/commits/$HEAD_SHA" -q .commit.committer.date)
  written=$(all_comments "$pr" | jq --arg since "$head_date" \
    '[.[] | select((.user.login == "claude[bot]" or .user.login == "github-actions[bot]") and (.body | startswith("## Code review")) and .created_at >= $since)] | length')
  if [ "$written" -eq 0 ]; then
    # 使用量の上限などの一時的な失敗かもしれないので、人間に回す前に自動でやり直す（watchdog.sh）
    # 実行記録（EXECUTION_FILE。pipeline.yml が渡していれば）で、原因に合わせる：使用量の上限ならリセットまで待つ（回数を使わない）
    retry_ai_failure "$pr" review "レビューAIがエラーで止まりました（ログは、レビューAIの実行の方を見てください）" "${EXECUTION_FILE:-}"
    exit 0
  fi
  echo "PR #$pr：レビューAIはエラーで終わったが、結果のコメントは書けているので、その結果で進めます"
fi

# いまの先頭コミットのあとに書かれた、最新のレビュー結果（「## Code review」で始まる）を探す。
# まとめのコメントは、レビューAIが gh で書くので github-actions[bot] の名前で付く（行への指摘は claude[bot]）。
# 「この実行で書かれた物」ではなく「先頭コミットより新しい物」を見る
head_date=$(gh api "repos/$REPO/commits/$HEAD_SHA" -q .commit.committer.date)
review=$(all_comments "$pr" | jq -r --arg since "$head_date" \
  'map(select((.user.login == "claude[bot]" or .user.login == "github-actions[bot]") and (.body | startswith("## Code review")) and .created_at >= $since)) | last | .body // ""')

# 指摘があるとき、レビューAIはまとめのコメントを書かず、コードの行への指摘（インラインコメント）だけを残すことがある。
# 数えるのは、この回のレビューで書かれた行への指摘だけ。PRの説明だけを直したときは先頭コミットが変わらないので、
# 前の回の行への指摘も同じコミットに付いたまま残る（それを数えると、直ったのにまた直すよう頼んでしまう）。
#   この回の区切り：最新のまとめがこの回の物なら、その1つ前のまとめの時刻。まとめが無ければ、最後のまとめの時刻
cutoff=$(all_comments "$pr" | jq -r --arg has "$([ -n "$review" ] && echo 1)" \
  '[.[] | select((.user.login == "claude[bot]" or .user.login == "github-actions[bot]") and (.body | startswith("## Code review"))) | .created_at] | sort
   | if $has == "1" then (.[-2] // "") else (.[-1] // "") end')
inline_json=$(gh api "repos/$REPO/pulls/$pr/comments?per_page=100" --paginate --slurp \
  | jq --arg sha "$HEAD_SHA" --arg cut "$cutoff" 'add // [] | map(select(.user.login == "claude[bot]" and .original_commit_id == $sha and .created_at > $cut))')
inline=$(printf '%s' "$inline_json" | jq 'length')

if [ "$inline" -gt 0 ] || { [ -n "$review" ] && ! printf '%s' "$review" | grep -q "No issues found"; }; then
  # CI と同時に動くので、CIが落ちて先に直すよう頼んであることがある（二重に頼まない。直した push のあとに、もう一度レビューされる）
  if fix_requested_for "$pr" "$HEAD_SHA"; then
    echo "PR #$pr：レビューに指摘がありましたが、このコミットにはもう直すよう頼んであるので、重ねて頼みません"
    exit 0
  fi
  # 指摘が指す場所：行への指摘は API の path、まとめは本文中のパスの形の語。
  # 全部ワークフローの所（AIは push できない）なら、修正AIに頼まず、すぐ人間（マネージャー）に回す
  targets=$({ printf '%s' "$inline_json" | jq -r '.[].path // empty'; printf '%s' "$review" | review_paths_from_text; } | awk 'NF' | sort -u)
  target_kind=$(printf '%s\n' "$targets" | review_paths_kind)
  if [ "$target_kind" = workflow ]; then
    review_status "$HEAD_SHA" failure "ワークフローの指摘です。マネージャーが直します"
    stop_for_human "$pr" "ワークフローの指摘なので、マネージャーが直してください（AIは .github/workflows/・.github/actions/ を直せません）。指摘の場所：$(printf '%s' "$targets" | paste -sd '、' -)"
    echo "PR #$pr：指摘が全部ワークフローの所なので、修正AIに頼まず人間に回しました"
    exit 0
  fi
  fix_message="レビューで指摘がありました。このPRの「Code review」のコメントと、コードの行に付いた指摘を読んで直してください。指摘が間違っていると判断した場合は、直さずにその理由をこのPRにコメントしてください。"
  if [ "$target_kind" = mixed ]; then
    fix_message="${fix_message}ただし、ワークフローの所（\`.github/workflows/\`・\`.github/actions/\`）は直さないでください（AIはpushできません）。その旨をこのPRにコメントしてください。"
  fi
  review_status "$HEAD_SHA" failure "指摘があります。AIが直しています"
  request_fix_or_stop "$pr" "$HEAD_SHA" "$fix_message"
  echo "PR #$pr：指摘があったので直すよう依頼しました（行への指摘 ${inline} 件）"
  exit 0
fi

# 画像など、文字で読めない変更だけのPR（README のスクショの撮り直しなど）は、レビューAIに読む差分が無く、
# 結果のコメントを書かずに終わる。そのときは、指摘なしとして進める。
# 「文字で読めない」＝差分（patch）が無く、変更の行数も 0。大きすぎて patch が省かれた文字のファイルは、行数があるので含めない
if [ -z "$review" ]; then
  if kinds=$(gh api "repos/$REPO/pulls/$pr/files?per_page=100" --paginate     -q '.[] | if (.patch == null and (.changes // 0) == 0) then "binary" else "text" end')     && [ -n "$kinds" ] && ! printf '%s\n' "$kinds" | grep -q '^text$'; then
    comment "$pr" "画像など、文字で読めない変更だけなので、レビューする差分がありません。指摘なしとして進めます。" || true
    review="No issues found"
    status_desc="画像など文字で読めない変更だけなので、レビューする差分がありません"
    echo "PR #$pr：文字で読めない変更だけなので、指摘なしとして進めます"
  fi
fi
# レビューのワークフロー自体（claude-review.yml）を変えるPRでは、レビューAIは動けない（AIのアクションは、ワークフローのファイルが
# main と同じ内容でないと、何もせず成功で終わる）。やり直しても同じなので、やり直さず、すぐ人間のマージ待ち（ai:hold）にする
# （今までは、30分おきに2回やり直してから「結果のコメントが見つかりません」で人間に回していた）
if [ -z "$review" ] && gh api "repos/$REPO/pulls/$pr/files?per_page=100" --paginate -q '.[].filename' 2> /dev/null | grep -qx '.github/workflows/claude-review.yml'; then
  has_label "$pr" "ai:hold" || add_label "$pr" "ai:hold" || true
  remove_label "$pr" "ai:retry"
  review_status "$HEAD_SHA" success "レビューAIが動けないPRなので、人間が確かめてください"
  comment "$pr" "ℹ️ このPRはレビューのワークフロー（\`.github/workflows/claude-review.yml\`）を変えるので、レビューAIは動けません（ワークフローが main と同じ内容でないと、AIのアクションは何もしません）。CIは通っています。人間が中身を確かめて、マージしてください。

<!-- ${REVIEW_UNAVAILABLE_MARK} ${HEAD_SHA} -->" || true
  notify hold "あなたが確かめてマージしてください" "PR #${pr} $(issue_title "$pr")：レビューのワークフローを変えるPRなので、レビューAIは動けません" 4
  echo "PR #$pr：レビューのワークフローを変えるPRなので、人間のマージ待ちにしました"
  exit 0
fi
if [ -z "$review" ]; then
  # レビューAIが、エラーにならずに何も書かずに終わることがある（一時的な不調）。2回までは自動でやり直し、続くなら人間に回す
  if [ "$(retry_count "$pr")" -lt 2 ]; then
    mark_for_retry "$pr" review "レビューAIが、結果のコメントを書かずに終わりました"
  else
    stop_for_human "$pr" "レビューAIの結果のコメントが見つかりませんでした（自動のやり直しでも書かれませんでした）"
  fi
  exit 0
fi

# ここまで来たら指摘なし（コメントが「No issues found」か、文字で読めない変更だけ）
review_status "$HEAD_SHA" success "${status_desc:-指摘なし}"

# CI（レビュー以外のチェック）が全部通っているか、もう一度確かめる
# チェックの読み取りはワークフロー自身のトークン（checks: read）で行う（読めなければ、パイプラインの鍵で読む。read_api）
checks=$(read_api "repos/$REPO/commits/$HEAD_SHA/check-runs?per_page=100" -q '[.check_runs[] | select(.name != "review")]')
actions_count=$(printf '%s' "$checks" | jq '[.[] | select(.app.slug == "github-actions")] | length')
not_ok=$(printf '%s' "$checks" | jq '[.[] | select(.app.slug == "github-actions") | select(.status != "completed" or (.conclusion | IN("success", "neutral", "skipped") | not))] | length')
if [ "$actions_count" -eq 0 ] || [ "$not_ok" -gt 0 ]; then
  # レビューAIは CI と同時に動くので、CIのほうが後に終わることがある。CIが通ったら after-ci.sh がこの結果でマージへ進める。
  # CIが落ちていれば、after-ci.sh が直すよう頼む
  echo "CIがまだ全部通っていないので、マージしません（CIが通れば after-ci.sh が、このレビューの結果でマージへ進めます）"
  exit 0
fi
# CI 以外のチェック（Vercel など、GitHub Actions 以外の App が付けた check run）が通っていないとき：
# CI のあとの処理は呼ばれないので、黙って終わると誰も先へ進めない。名前と理由をPRに書き、時間をおいて確かめ直す（続くなら人間に回す）。
# まだ終わっていないだけなら、少しだけ待つ（レビューのほうが先に終わった、など）
ext=$(printf '%s' "$checks" | external_check_runs_not_ok)
tries=0
while [ -n "$ext" ] && ! printf '%s\n' "$ext" | cut -f3 | grep -qx failed && [ "$tries" -lt "${EXTERNAL_CHECK_WAIT_TRIES:-3}" ]; do
  tries=$((tries + 1))
  sleep "${EXTERNAL_CHECK_WAIT_SEC:-20}"
  checks=$(read_api "repos/$REPO/commits/$HEAD_SHA/check-runs?per_page=100" -q '[.check_runs[] | select(.name != "review")]') || break
  ext=$(printf '%s' "$checks" | external_check_runs_not_ok)
done
if [ -n "$ext" ]; then
  # コミットステータスも、通っていない物があれば一緒に書く（コミットステータスだけなら、今までどおりマージを試す）
  handle_external_checks "$pr" "$HEAD_SHA" "$(external_checks_not_ok "$HEAD_SHA" "$checks")"
  exit 0
fi

title=$(issue_title "$pr")
# 仕組みそのもの（.github/・docs/pipeline.md・docs/pipeline-setup.md・CLAUDE.md・AGENTS.md・pipeline.json）を変えるPRは、AIの判断だけでは自動でマージしない。
# 普通のIssue（アプリの作業）は今までどおり全自動。これらを触るPRだけ、マージを人間に任せて通知する
# 変更ファイルの一覧を取れなかったら、マージせずに再試行へ回す（取れないまま「該当なし」と扱って自動でマージしない）
if ! files=$(gh api "repos/$REPO/pulls/$pr/files?per_page=100" --paginate -q '.[].filename'); then
  mark_for_retry "$pr" review "変更ファイルの一覧を取得できませんでした（APIエラーなどの可能性）"
  exit 0
fi
# ai-dev-template 自身（main の CLAUDE.md に「pipeline-self-edit: auto」の印がある）は、スクリプト・テスト・docs/pipeline.md の変更を自動でマージしてよい。
# ワークフロー・実行環境の部品（.github/actions/）・CLAUDE.md・AGENTS.md・pipeline.json（AIの許可とルール。pipeline.json の checks はAIに許すコマンドになる）は、どのリポジトリでも人間に任せる。印は main の物を見るので、PRの変更で印を足してもすり抜けられない
# パイプラインの物（pipeline-paths.sh と同じ場所。スキル .claude/ も、AIへの指示なので含む）と、AIのルール
hold_pattern='^(\.github/|\.claude/|docs/pipeline(-setup)?\.md$|CLAUDE\.md$|AGENTS\.md$|pipeline\.json$)'
if grep -q 'pipeline-self-edit: auto' "${CLAUDE_MD:-$(dirname "$0")/../../CLAUDE.md}" 2> /dev/null; then
  hold_pattern='^(\.github/workflows/|\.github/actions/|\.claude/|CLAUDE\.md$|AGENTS\.md$|pipeline\.json$)'
fi
if printf '%s\n' "$files" | grep -qE "$hold_pattern"; then
  # ai:hold を付けておく（画面で「マージ待ち（人間）」と分かる。人間がマージするまで、自動ではマージされない）
  has_label "$pr" "ai:hold" || add_label "$pr" "ai:hold" || true
  notify hold "マージできます" "PR #${pr} ${title}：CIもレビューもOK。パイプライン自体を変えるPRなので、マージはあなたが押してください" 4
  echo "PR #$pr：パイプライン自体を変えるので、自動でマージしません"
  exit 0
fi
if has_label "$pr" "ai:hold"; then
  notify hold "マージできます" "PR #${pr} ${title}：CIもレビューもOK。ai:hold なのでマージはあなたが押してください" 4
  exit 0
fi

# マージできなかったときのやり直しは、種類 merge（レビューは済んでいるので、見張り役はAIを動かさず、ここ（マージの判断）だけをやり直す）
merge_or_handle "$pr" "$HEAD_SHA" merge || exit 0
notify merged "マージしました" "PR #${pr} ${title}：CIもレビューもOKだったので自動でマージしました" 2
# 使い終わったブランチを消す（リポジトリの「Automatically delete head branches」が先に消していても構わない）
delete_branch_if_ai "$HEAD_BRANCH"
echo "PR #$pr：自動でマージしました（次の順番待ちは、Issueが閉じたときに queue.yml が始める）"
