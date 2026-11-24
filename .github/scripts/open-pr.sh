#!/usr/bin/env bash
# 実装AIのあと：ブランチ claude/issue-<番号>-... から main へのPRを自動で作る。
# PRの本文は、実装AIがIssueに書いた「Create PR」リンクの中身を使う（無ければ Closes #番号 だけ）。
#
# 環境変数：ISSUE（番号）、ISSUE_TITLE、AI_OUTCOME（実装AIの結果 success/failure）、EXECUTION_FILE（AIの実行記録。失敗の原因の分類に使う）、
#   CRITIQUE_FILE（任意：審査役が画面の画像だけを見て書いた採点。PRの本文に添える）、
#   UNTRUSTED_COUNT（任意：信頼できない人の本文・コメントの数。1以上なら実装AIは動いていないので、人間に回す。trusted-comments.sh --count-untrusted）
source "$(dirname "$0")/pipeline-lib.sh"
set -e

# 作業中に Issue が閉じられたときは、PRを作らない（同じ作業のPRが2つになるのを防ぐ。ai-dev-template #84）
if [ -n "${ISSUE:-}" ] && [ "$(gh api "repos/$GITHUB_REPOSITORY/issues/$ISSUE" --jq .state 2> /dev/null || echo open)" = closed ]; then
  echo "#$ISSUE は閉じられているので、PRは作りません"
  remove_label "$ISSUE" "ai:implement" 2> /dev/null || true
  exit 0
fi

if ! has_pipeline_token; then
  # トークンが無い間は、今までどおり人間がPRを作る
  if [ "$AI_OUTCOME" = "success" ]; then
    notify manual "PRを作れます" "#${ISSUE} ${ISSUE_TITLE}：AIの作業が終わりました" 4
  else
    notify manual "AIが止まりました" "#${ISSUE} ${ISSUE_TITLE}：結果を確認してPRを作ってください" 4
  fi
  exit 0
fi

# 信頼できない人の本文・コメントがあったので、実装AIを動かさなかった（claude-implement.yml）。やり直さず人間に回す。
# 中身を確かめて消し（または問題ないと判断して）、ai:stuck を外すと、もう一度数えてから実装が始まる
if [[ "${UNTRUSTED_COUNT:-0}" =~ ^[0-9]+$ ]] && [ "${UNTRUSTED_COUNT:-0}" -gt 0 ]; then
  stop_issue_for_human "$ISSUE" "オーナー・共同作業者・このパイプライン以外の人の書き込みが ${UNTRUSTED_COUNT} 件あるので、実装AIを動かしませんでした（AIは Issue の本文とコメントを全部読むので、他人の指示がAIに届くのを防ぐため）。中身を確かめて、要らなければそのコメントを消してください。残したまま外すと、また止まります"
  exit 0
fi

# 実装AIは正常に終わったのに、変更が残っていないとき。理由を書かずに止めない：
#   許可されていない操作が拒否されていた → 拒否された操作を書いて、1回だけ実装をやり直す（コメントが、やり直す実装AIへの手がかりになる）。
#     やり直しても同じなら、足りない許可を書いて人間に回す。人間が ai:stuck を外して再開すると、また1回やり直せる
#   拒否が無い → AIが最後に言ったことを書いて人間に回す（AIが「できない」と判断した、など）
stop_or_retry_no_change() {
  local what="$1" raw words full note="" retried log
  raw=$(denied_raw "${EXECUTION_FILE:-}")
  words=$(ai_last_words "${EXECUTION_FILE:-}")
  [ -n "$words" ] && note="AIが最後に言ったこと：「${words}」"
  log="ログ：${GITHUB_SERVER_URL:-https://github.com}/${REPO}/actions/runs/${GITHUB_RUN_ID:-0}"
  # 実装AIが「もう直っている」と確かめて終わった（ほかの Issue のPRで先に直った・前のPRで直った）：
  # 人間に回さず、確かめた中身を残して Issue を閉じる（tochi-rirekisho #9：#10 のPRで先に直り、実装AIは2回とも
  # 「このブランチでは既に直っていた」と返したのに、人間待ちで止まった）。違っていれば、開き直すとまた企画から進む
  # 一部だけ直っている・直せなかった返事は閉じない。打ち消しが300字より後ろにあっても見えるよう、長いほうで見る
  full=$(ai_last_words "${EXECUTION_FILE:-}" 5000)
  if [ -n "$words" ] && grep -qiE "$ALREADY_FIXED_RE" <<< "$full" && ! grep -qiE "$NOT_FIXED_RE" <<< "$full"; then
    comment "$ISSUE" "✅ 実装AIが確かめたところ、この Issue の不具合・作業は、すでに main に入っていました（ほかのPRで先に直った、など）。変更は要らないので、この Issue を閉じます。
${note}（${log}）

まだ直っていなければ、この Issue を開き直してください（開き直すと、企画からもう一度進みます）。

<!-- auto-already-fixed -->" || true
    for l in ai:implement ai:retry; do remove_label "$ISSUE" "$l" 2> /dev/null || true; done
    gh api -X PATCH "repos/$REPO/issues/$ISSUE" -f state=closed -f state_reason=completed > /dev/null
    echo "#$ISSUE：実装AIが「すでに直っている」と確かめたので、閉じました"
    return 0
  fi
  if [ -n "$raw" ]; then
    retried=$(all_comments "$ISSUE" | jq --arg m "$PERM_RETRY_MARK" --arg resume "$RESUME_MARK" '
      (map(select(.body | contains($resume)) | .created_at) | max // "") as $since
      | [.[] | select((.body | contains($m)) and .created_at > $since)] | length')
    if [ "${retried:-0}" -lt 1 ]; then
      comment "$ISSUE" "🔁 実装AIは正常に終わりましたが、${what}。許可されていない操作が拒否されていたので、1回だけ自動でやり直します（${log}）。

実装AIへ：前回は、次の操作が拒否されました：$(permission_list_short "$raw")。同じ操作は使わないでください。コマンドは1つずつ動かし、; や && や | でつながず、cd や 2>&1 も付けない。ファイルを読む・探すのは Read・Grep・Glob を使う。確認コマンドは、pipeline.json の checks（無ければ npm run typecheck・npm run lint・npm run test・npm run build）を、書かれたとおりの形で動かす。作業が終わったら、必ずコミットして push する。${note}

${PERM_RETRY_MARK}"
      remove_label "$ISSUE" "ai:implement"
      add_label "$ISSUE" "ai:implement"
      echo "#$ISSUE：${what}。拒否された操作（$(permission_list_short "$raw")）を書いて、1回だけ実装をやり直します"
      return 0
    fi
    keys=$(denied_tools "${EXECUTION_FILE:-}")
    reason_text="$(permission_reason_text "$keys")"
    # 開けない操作だけのときも、拒否された操作そのものは見せる
    if [ -z "$reason_text" ]; then
      reason_text="許可されていない操作が拒否されました：$(permission_list_short "$raw")（docs/pipeline.md の「AIの許可」の表と、ワークフローの --allowedTools を見てください）"
    else
      reason_text="許可されていない操作が拒否されました（$(permission_list_short "$raw")）。${reason_text}"
    fi
    stop_issue_for_human "$ISSUE" "実装AIは正常に終わりましたが、${what}。1回自動でやり直しても、${reason_text}。${note}（${log}）"
    report_permission_gap "$ISSUE" "$keys"
    return 0
  fi
  stop_issue_for_human "$ISSUE" "実装AIは正常に終わりましたが、${what}（拒否された操作はありません）。${note:-AIが最後に言ったことは、実行記録にありません}（${log}）"
}

# いちばん新しいコミットがある claude/issue-<番号>- ブランチを探す
branch=""
latest=""
# 一覧の読み取りは一時的に失敗することがある（途中で切れた JSON・502）ので3回まで試す。
# 1つのブランチが読めない（一覧のあとに消えた・名前が壊れて返った）ときは、そのブランチだけ飛ばす（agent-desk #456 で、Branch not found で止まった）
branches=""
list_ok=false
for _try in 1 2 3; do
  if branches=$(gh api "repos/$REPO/branches?per_page=100" --paginate -q ".[].name | select(startswith(\"claude/issue-${ISSUE}-\"))" 2> /dev/null); then list_ok=true; break; fi
  branches=""
  sleep "${BRANCH_LIST_RETRY_SLEEP:-5}"
done
# 3回とも読めなかったときは、「ブランチが無い」と取り違えて人間に回さず、失敗として止まる
if [ "$list_ok" != true ]; then
  echo "::error::ブランチの一覧を3回試しても読めませんでした。ブランチが無いのかは分かりません"
  exit 1
fi
for b in $branches; do
  date=$(gh api "repos/$REPO/branches/$b" -q .commit.commit.committer.date 2> /dev/null) || { echo "::warning::ブランチ $b を読めなかったので飛ばします"; continue; }
  if [[ "$date" > "$latest" ]]; then
    latest="$date"
    branch="$b"
  fi
done

# 実装AIがエラーで終わって何も作れなかったときは、使用量の上限などの一時的な失敗かもしれないので、
# 人間に回す前に自動でやり直す（watchdog.sh）。AIが正常に終わったのに変更が無いときは、AIの判断なので人間に回す
if [ -z "$branch" ]; then
  if [ "$AI_OUTCOME" != "success" ]; then
    handle_ai_failure "$ISSUE" implement "実装AIが途中で止まり、変更が作られませんでした" "${EXECUTION_FILE:-}"
  else
    stop_or_retry_no_change "変更が作られませんでした（作業ブランチがありません）"
  fi
  exit 0
fi

ahead=$(gh api "repos/$REPO/compare/main...$branch" -q .ahead_by)
if [ "${ahead:-0}" -eq 0 ]; then
  if [ "$AI_OUTCOME" != "success" ]; then
    handle_ai_failure "$ISSUE" implement "実装AIが途中で止まり、ブランチに変更がありません" "${EXECUTION_FILE:-}"
  else
    stop_or_retry_no_change "作業ブランチに変更がありません"
  fi
  exit 0
fi

existing=$(find_open_pr "$branch" || true)
if [ -n "$existing" ]; then
  echo "PRはもうあります：$existing"
  remove_label "$ISSUE" "ai:retry"
  exit 0
fi

# 実装AIの最後のコメントの「Create PR」リンクから、本文を取り出す
comment=$(all_comments "$ISSUE" | jq -r 'map(select(.user.login == "claude[bot]")) | last | .body // ""')
body=$(printf '%s' "$comment" | python3 -c '
import re, sys, urllib.parse
text = sys.stdin.read()
m = re.search(r"quick_pull=1[^)\s]*", text)
if m:
    q = urllib.parse.parse_qs(m.group(0))
    print(q.get("body", [""])[0])
')
if ! grep -qiE "(close[sd]?|fix(e[sd])?|resolve[sd]?) #${ISSUE}\b" <<< "$body"; then
  body="Closes #${ISSUE}

${body}"
fi
if [ -n "${CRITIQUE_FILE:-}" ] && [ -f "$CRITIQUE_FILE" ] && [ ! -L "$CRITIQUE_FILE" ]; then
  body="${body}

## 審査役（画面の画像だけを見る別のAI）の採点

$(head -n 40 "$CRITIQUE_FILE" | cut -c1-500)"
fi
body="${body}

---
_実装AIの作業が終わったので、自動で作ったPRです。CIとレビューAIが同時に確かめ、両方とも問題がなければ自動でマージします。_"

created=$(gh api "repos/$REPO/pulls" -f title="$ISSUE_TITLE" -f head="$branch" -f base=main -f body="$body" -q .html_url)
echo "PRを作りました：$created"
# CIを待たずに、レビューAIも同時に始める（#119。CIが通ったら、先に出たレビューの結果でマージへ進む）
#   ただし見た目のテストがあり本文に visual:update があるPRは、必ず撮り直しで捨てられるので、CIのあとに回す
if ! defer_review_for_visual "${created##*/}"; then
  request_review "${created##*/}" || true
fi
# 「人間にお願いしたいこと」の節があれば、マージしてもIssueを閉じないようにする
defer_close_for_human_request "${created##*/}" || true
remove_label "$ISSUE" "ai:retry"

if [ "$AI_OUTCOME" != "success" ]; then
  echo "実装AIは途中で止まりましたが（作業回数の上限など）、変更があるのでPRにしました。CIで確かめます"
fi
