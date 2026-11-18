#!/usr/bin/env bash
# 全自動パイプラインの共通の関数。各スクリプトから `source` して使う。
# GitHubとのやり取りは全部 REST API（gh api）で行う。`gh issue edit` などのGraphQL経由の
# コマンドは、Fine-grained トークンだと権限の都合で黙って失敗することがあるため使わない。
#
# 必要な環境変数
#   GH_TOKEN           ：秘密の PIPELINE_TOKEN（オーナーのトークン）。これで付けたラベルや
#                        コメントは次のワークフローを動かせる（GITHUB_TOKEN だと動かない）
#   GITHUB_REPOSITORY  ：owner/repo（Actionsが自動で入れる）
#   NTFY_TOPIC         ：スマホ通知（無ければ鳴らさない）

set -Euo pipefail
# 失敗したら、どの行のどのコマンドかをActionsの画面に出す
trap 'echo "::error file=${BASH_SOURCE[0]},line=${LINENO}::失敗したコマンド: ${BASH_COMMAND}"' ERR

REPO="${GITHUB_REPOSITORY}"
OWNER="${REPO%%/*}"
# AIに自動で直させる回数の上限（CIの失敗とレビューの指摘を合わせて数える）。超えたら人間に回す
MAX_AUTO_FIX="${MAX_AUTO_FIX:-2}"
AUTO_FIX_MARK="<!-- auto-fix -->"
RESUME_MARK="<!-- auto-resume -->"
# shellcheck disable=SC2034  # after-ci.sh など、この下を読み込む側のスクリプトで使う
VISUAL_MARK="<!-- auto-visual-update -->"
# 他の Issue・PR の完了待ち（ai:blocked）で、待ち先を書くコメントの印（待ち先ごとに1つ：<!-- blocked-by: owner/repo#N -->）
# shellcheck disable=SC2034  # after-plan.sh・watchdog.sh で使う
BLOCKED_MARK_RE='<!-- blocked-by: ([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+) -->'
# レビューAIが動けないPR（レビューのワークフロー自体を変えるPR）を、人間のマージ待ちにした印（after-review.sh が書き、watchdog.sh が「待っている」と読む）
# 先頭コミットごとに書く：<!-- review-unavailable: 先頭コミット -->（新しいコミットが入れば、もう一度確かめる）
# shellcheck disable=SC2034  # after-review.sh・watchdog.sh で使う
REVIEW_UNAVAILABLE_MARK="review-unavailable:"
# shellcheck disable=SC2034  # after-ci.sh で使う
PIPELINE_TEST_MARK="<!-- auto-pipeline-test-rerun -->"
# 自動でやり直す回数の上限と、失敗してからやり直すまでの待ち時間（分）。
# 使用量の上限で止まったときは、リセットされるまで何度かやり直しながら待つ
RETRY_MARK="<!-- auto-retry -->"
# 人間が再開したとき（resume.sh）に、やり直しの記録に書く理由。write_retry_record が、この文のときだけ「回数を0に戻しました」と書く
RESUMED_REASON="人間が再開しました"
MAX_RETRY="${MAX_RETRY:-10}"
RETRY_COOLDOWN_MIN="${RETRY_COOLDOWN_MIN:-30}"
# 使用量の上限で止まったときは、回数を減らさずに待つ。リセット時刻が分からないときの待ち時間（分）と、待つのをあきらめる上限（時間）
LIMIT_UNKNOWN_WAIT_MIN="${LIMIT_UNKNOWN_WAIT_MIN:-60}"
LIMIT_MAX_WAIT_HOURS="${LIMIT_MAX_WAIT_HOURS:-24}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

notify() {
  "$SCRIPT_DIR/notify.sh" "$@" || true
}

# コミットのステータス「AIレビュー」を付ける（review-status.sh）。付けられなくても、呼んだスクリプトは止めない
review_status() { # sha 状態（pending|success|failure） 説明
  bash "$SCRIPT_DIR/review-status.sh" "$1" "$2" "$3" || true
}

has_pipeline_token() {
  [ -n "${GH_TOKEN:-}" ]
}

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# ---- Issue・PR の操作（PRもIssueと同じ番号でラベル・コメントを扱える） ----

add_label() {
  gh api "repos/$REPO/issues/$1/labels" -f "labels[]=$2" > /dev/null
}

# 付いていなくてもエラーにしない
remove_label() {
  gh api -X DELETE "repos/$REPO/issues/$1/labels/$(urlencode "$2")" > /dev/null 2>&1 || true
}

# ラベルを「取る」：自分が外せたときだけ成功（もう外れていたら失敗）。同時に動いた2つの処理の片方だけを進めるのに使う
take_label() {
  gh api -X DELETE "repos/$REPO/issues/$1/labels/$(urlencode "$2")" > /dev/null 2>&1
}

# ラベルが付いているか：付いている 0、付いていない 1、読めなかった 2（API の一時的なエラーなど）。
# 読めなかったのを「付いていない」と取り違えないように、戻り値を分ける。ai:stuck・ai:skip のように「付いていたら触らない」
# 確かめには、下の has_label_or_unreadable を使う（読めなければ、付いているものとして触らない）
has_label() {
  local labels
  labels=$(gh api "repos/$REPO/issues/$1/labels" -q '.[].name') || return 2
  grep -qxF -- "$2" <<< "$labels"
}

# 付いているか、読めなかったときに 0（読めなかったときは警告を出す）。確かに付いていないときだけ 1
has_label_or_unreadable() {
  local rc=0
  has_label "$1" "$2" || rc=$?
  [ "$rc" -eq 1 ] && return 1
  [ "$rc" -eq 2 ] && echo "::warning::#$1：ラベルを読めませんでした（${2} が付いているものとして、今回は触りません）"
  return 0
}

comment() {
  gh api "repos/$REPO/issues/$1/comments" -f body="$2" > /dev/null
}

# コメントを全部（ページをまたいで）1つの配列で出す
all_comments() {
  gh api "repos/$REPO/issues/$1/comments?per_page=100" --paginate --slurp | jq 'add // []'
}

# 一覧（配列を返す API）を全部、ページをまたいで1つの配列で出す。使い方：api_list "repos/$REPO/issues?state=open&per_page=100"
# 100件までなら API は今までどおり1回（2ページ目からは、続きがあるときだけ読む）。per_page=100 だけだと、101件目からが黙って見えなくなる。
# 全体の件数・並べ替えが要るときは、これを使う（gh api --paginate -q は、ページごとに jq を当てるので、件数や並べ替えがページごとになる）
api_list() {
  gh api "$1" --paginate --slurp | jq -c 'add // []'
}

# 基準の画像を自動で撮り直した回数（上限の数え方）。
# 数えるのは、PRに main を最後に取り込んだ後（と、人間が ai:stuck を外して続きを頼んだ後）の撮り直しだけ。
# main を取り込むとき、基準の画像のコンフリクトは main の側を取る決まりなので、それより前の撮り直しは消えている。
# 前の撮り直しまで数えると、消えた分で上限に届き、一度も撮り直していない画像のまま人間に回してしまう（agent-desk #316）
visual_update_count() { # PR番号 [コメントのJSON（無ければ取る）]
  local pr=$1 comments=${2:-} since
  [ -z "$comments" ] && comments=$(all_comments "$pr")
  since=$(gh api "repos/$REPO/pulls/$pr/commits?per_page=100" --paginate --slurp 2> /dev/null \
    | jq -r 'add // [] | map(select((.parents // [] | length) > 1) | .commit.committer.date) | max // ""' 2> /dev/null) || since=""
  printf '%s' "$comments" | jq --arg m "$VISUAL_MARK" --arg resume "$RESUME_MARK" --arg since "$since" '
    ((map(select(.body | contains($resume)) | .created_at) + [$since]) | max) as $from
    | [.[] | select((.body | contains($m)) and .created_at > $from)] | length'
}

issue_title() {
  gh api "repos/$REPO/issues/$1" -q .title
}

# ラベルが付いたopenのIssue（PRを除く）の数
count_open_issues_with_label() {
  api_list "repos/$REPO/issues?state=open&per_page=100&labels=$(urlencode "$1")" \
    | jq '[.[] | select(.pull_request | not)] | length'
}

count_open_prs() {
  api_list "repos/$REPO/pulls?state=open&per_page=100" | jq 'length'
}

# ブランチ名からopenのPRを1つ探す。見つかれば「番号 先頭コミット」を出す
find_open_pr() {
  gh api "repos/$REPO/pulls?state=open&head=$OWNER:$1" \
    -q '.[0] | select(. != null) | "\(.number) \(.head.sha)"'
}

# PRに紐づくIssue番号（本文の Closes #N か、ブランチ名 claude/issue-N-）
linked_issue() {
  local pr_json body branch n
  pr_json=$(gh api "repos/$REPO/pulls/$1")
  body=$(printf '%s' "$pr_json" | jq -r '.body // ""')
  branch=$(printf '%s' "$pr_json" | jq -r .head.ref)
  n=$(printf '%s' "$body" | grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  if [ -z "$n" ]; then
    n=$(printf '%s' "$branch" | sed -nE 's#^claude/issue-([0-9]+)-.*#\1#p')
  fi
  printf '%s' "$n"
}

# PRの本文に「人間にお願いしたいこと」の節（## か ### の見出し）があるあいだは、マージしても元のIssueを閉じない。
# 本文の Closes/Fixes/Resolves #N を Refs #N に書き換え（GitHub は Refs ではIssueを閉じない）、Issueに人間への頼みごとを1回だけ書く
# （1行目 <!-- human-request -->、2行目に要点の1文。同じPRには、印 <!-- human-request-pr: #PR番号 --> で2回書かない）。
# ワークフローの差分のように、AIが触れない物を人間が当てるまでIssueを開けておくため。当てたら人間がIssueを閉じる。
# 節が無ければ何もしない。使い方：defer_close_for_human_request PR番号
HUMAN_REQUEST_HEADING_RE='^###? 人間にお願いしたいこと'
defer_close_for_human_request() {
  local pr="$1" body section issue new_body mark url
  body=$(gh api "repos/$REPO/pulls/$pr" -q '.body // ""') || return 0
  printf '%s\n' "$body" | grep -qE "$HUMAN_REQUEST_HEADING_RE" || return 0
  # 節：見出しから、次の見出しか区切り線（---）の手前まで
  section=$(printf '%s\n' "$body" | awk -v re="$HUMAN_REQUEST_HEADING_RE" '
    f && (/^#+ / || /^---[ \t]*$/) { exit }
    f { print; next }
    $0 ~ re { f = 1; print }')
  issue=$(printf '%s' "$body" | grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?|refs) #[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  [ -z "$issue" ] && issue=$(linked_issue "$pr")
  [ -z "$issue" ] && return 0
  if printf '%s' "$body" | grep -qiE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+'; then
    new_body=$(printf '%s' "$body" | sed -E 's/\b(close[sd]?|fix(e[sd])?|resolve[sd]?) #([0-9]+)/Refs #\3/gI') || return 0
    [ -n "$new_body" ] || return 0
    gh api -X PATCH "repos/$REPO/pulls/$pr" -f body="$new_body" > /dev/null || return 0
  fi
  mark="<!-- human-request-pr: #${pr} -->"
  if all_comments "$issue" | jq -e --arg m "$mark" 'any(.[]; .body | contains($m))' > /dev/null; then
    return 0
  fi
  url="${GITHUB_SERVER_URL:-https://github.com}/${REPO}/pull/${pr}"
  comment "$issue" "<!-- human-request -->
PR #${pr} の『人間にお願いしたいこと』を当ててください。当てたらこのIssueを閉じてください。

PR：${url}
（この PR は『人間にお願いしたいこと』があるので、マージしても Issue は自動では閉じません）

${section}

${mark}" || return 0
  echo "PR #${pr}：『人間にお願いしたいこと』があるので、#${issue} は閉じないようにしました"
}

# 『人間にお願いしたいこと』のPRがマージされた後に、Issueの進行ラベルを外して待ちの印 ai:skip を付ける（Issue は人間が閉じるまで開いたまま）。
# PRが開いている間やマージされずに閉じられたときは呼ばない（ai:implement が残らないと、並列の数え方と見張り役のやり直しが狂う）。
# 頼みごとのコメント（PRごとの印）が無いPRでは何もしない。何度呼んでも同じ。使い方：park_issue_after_human_request_merge PR番号
park_issue_after_human_request_merge() {
  local pr="$1" body issue mark l
  body=$(gh api "repos/$REPO/pulls/$pr" -q '.body // ""') || return 0
  issue=$(printf '%s' "$body" | grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?|refs) #[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  [ -z "$issue" ] && issue=$(linked_issue "$pr")
  [ -z "$issue" ] && return 0
  mark="<!-- human-request-pr: #${pr} -->"
  all_comments "$issue" | jq -e --arg m "$mark" 'any(.[]; .body | contains($m))' > /dev/null || return 0
  # ai: のラベルが1つも無いと、見張り役が企画に回し直すので、待ちの印 ai:skip を付ける
  for l in ai:plan ai:implement ai:review ai:retry ai:queue; do remove_label "$issue" "$l"; done
  add_label "$issue" "ai:skip" || true
  echo "PR #${pr}：マージされたので、#${issue} は人間が閉じるまで ai:skip で待たせます"
}

# Issue を作った人を、そのまま自動で動かしてよいか：オーナーと、このパイプラインのワークフロー（企画AIが分けて作る Issue は
# github-actions[bot]、AI自身は claude[bot]）だけ。公開リポジトリでは誰でも Issue を作れるので、ほかの人・ほかのボットの Issue は
# オーナーが ai:skip を外すまで動かさない（intake.sh・watchdog.sh）
trusted_author() {
  case "${1,,}" in
    "${OWNER,,}" | "claude[bot]" | "github-actions[bot]") return 0 ;;
  esac
  return 1
}

# PR の JSON（pulls の1件）の head が、このリポジトリか（fork からの他人のPRでなければ 0）。pr-trust.sh と同じ決まり
pr_head_is_repo() {
  [ "$(printf '%s' "$1" | jq -r --arg r "$REPO" '((.head.repo.full_name // "") | ascii_downcase) == ($r | ascii_downcase)')" = true ]
}

# まだパイプラインに乗っていないIssueか（ai: で始まるラベルが1つも無い。ai:skip も ai: なので「まだ動かさない」になる）
needs_intake() {
  local labels title
  labels=$(gh api "repos/$REPO/issues/$1/labels" -q '.[].name') || return 1
  printf '%s\n' "$labels" | grep -q '^ai:' && return 1
  # テンプレート本体の「新サービス：〜」は、工場（factory.yml）が受け持つので企画に回さない
  title=$(gh api "repos/$REPO/issues/$1" -q '.title' 2> /dev/null)
  case "$title" in
    新サービス：* | 新サービス:*) [ "$(gh api "repos/$REPO" -q .is_template 2> /dev/null)" = "true" ] && return 1 ;;
  esac
  return 0
}

# ---- 判断 ----

# 人間に回す：PRと紐づくIssueに ai:stuck を付けて、理由をコメントし、スマホに通知
stop_for_human() {
  local pr="$1" reason="$2"
  add_label "$pr" "ai:stuck" || true
  remove_label "$pr" "ai:retry"
  comment "$pr" "⏸ 自動で進めるのを止めました：${reason}

自分で直す・マージする・閉じるときは、そのまま対応してください。AIに続きを任せるなら \`ai:stuck\` を外してください（外すと、止まった所から自動で続けます）。" || true
  local issue
  issue=$(linked_issue "$pr")
  if [ -n "$issue" ]; then
    add_label "$issue" "ai:stuck" || true
  fi
  notify stuck "確認が必要です" "PR #${pr} $(issue_title "$pr")：${reason}" 4
}

# Issue（PRではない）を人間に回す
stop_issue_for_human() {
  local n="$1" reason="$2"
  add_label "$n" "ai:stuck" || true
  remove_label "$n" "ai:retry"
  comment "$n" "⏸ 自動で進めるのを止めました：${reason}

確認して、続けるなら \`ai:stuck\` を外してください（外すと、止まった所から自動で続けます）。" || true
  notify stuck "確認が必要です" "#${n} $(issue_title "$n")：${reason}" 4
}

# 「再開」の記録（人間が ai:stuck を外したとき resume.sh が書く）より後に、AIに自動で直させた回数
count_auto_fix() {
  all_comments "$1" | jq --arg mark "$AUTO_FIX_MARK" --arg resume "$RESUME_MARK" '
    (map(select(.body | contains($resume)) | .created_at) | max // "") as $since
    | [.[] | select((.body | contains($mark)) and .created_at > $since)] | length'
}

# PRの説明の中身の目印。AIがコミットを入れず、PRの説明だけを直したかを見分けるのに使う
pr_body_hash() {
  gh api "repos/$REPO/pulls/$1" -q '.body // ""' | sha1sum | cut -c1-12
}

# AIに直させる。上限を超えていたら人間に回す
request_fix_or_stop() {
  local pr="$1" sha="$2" message="$3"
  local count total model_mark="" note=""
  count=$(count_auto_fix "$pr")
  # 普通のモデルで MAX_AUTO_FIX 回直しても駄目なら、最後に1回だけ、いちばん強いモデル（opus）で直す
  total=$((MAX_AUTO_FIX + 1))
  if [ "$count" -ge "$total" ]; then
    stop_for_human "$pr" "AIが${total}回（最後の1回は強いモデル）直しても解決しませんでした（最後の理由：${message}）"
    return
  fi
  if [ "$count" -ge "$MAX_AUTO_FIX" ]; then
    model_mark="
<!-- auto-fix-model: opus -->"
    note="（これまでの修正で直らなかったので、最後の1回は、いちばん強いモデルが直します。前の修正の内容とPRのコメントをよく読んでください）
"
  fi
  comment "$pr" "@claude ${message}
${note}
直したら、確認コマンド（pipeline.json の checks。無ければ型チェック・リント・テスト・ビルド）を全部通してから、このPRのブランチにpushしてください。（自動の依頼 $((count + 1))/${total}）

${AUTO_FIX_MARK}
<!-- auto-fix-sha: ${sha} -->
<!-- auto-fix-body: $(pr_body_hash "$pr") -->${model_mark}"
}

# PR のマージの状態（GitHub が計算し終わるまで少し待つ）：clean / dirty（main と衝突）/ blocked / behind / unknown など
# もう一度レビューに回す（ai:review を付け直すと、labeled イベントでレビューAIが動く）。
# ただし main とコンフリクトしているPRでは、GitHub が pull_request のワークフローを動かさないので、レビューAIは起きない。
# そのまま付け直すと誰も動かずに止まる（tochi-rirekisho PR #5：PRの説明を直した後のレビューが起きず、9時間止まった）。
# コンフリクトしていれば、先にAIに解消させる（直す回数に数える。解消して push されると、CIのあとでレビューに回る）
# shellcheck disable=SC2016 # 文の中の `…` はそのまま見せる（コマンドとして動かさない）
CONFLICT_FIX_MSG='main とコンフリクトしていて、このままではCIもレビューも動きません。`git fetch origin main` のあと `git merge origin/main` でコンフリクトを解消してください。両方の変更の意図を残し、どちらかを捨てるときはPRにコメントで理由を書いてください。解消したら確認コマンド（pipeline.json の checks。無ければ型チェック・リント・テスト・ビルド）を全部通して push してください。'
request_review() { # PR番号
  local pr="$1" sha
  if [ "$(pr_merge_state "$pr")" = dirty ]; then
    sha=$(gh api "repos/$REPO/pulls/$pr" -q .head.sha)
    request_fix_or_stop "$pr" "$sha" "$CONFLICT_FIX_MSG"
    echo "PR #$pr：main とコンフリクトしていてレビューが動かないので、先にAIに解消を依頼しました"
    return 0
  fi
  remove_label "$pr" "ai:review" 2> /dev/null || true
  add_label "$pr" "ai:review"
}

pr_merge_state() {
  local pr="$1" i state=""
  for i in 1 2 3 4 5; do
    state=$(gh api "repos/$REPO/pulls/$pr" -q '.mergeable_state // "unknown"' 2> /dev/null) || state="unknown"
    [ "$state" != unknown ] && break
    [ "$i" -lt 5 ] && sleep "${MERGE_STATE_WAIT_SEC:-5}"
  done
  echo "${state:-unknown}"
}

# PRをマージする。GitHub の一時的なエラー（502 などのサーバー側のエラー・通信の失敗）なら、少し待って3回まで試す
# （1回の 502 で、配られたパイプラインの更新が人間待ちになったことがある。tap-stack-rush #37）。
#   使い方：merge_pr PR番号 先頭コミット。マージできたら 0。できなければ 1 で、標準出力に最後のエラーの文
merge_pr() {
  local pr="$1" sha="$2" out="" i
  for i in 1 2 3; do
    if out=$(gh api -X PUT "repos/$REPO/pulls/$pr/merge" -f merge_method=merge -f sha="$sha" 2>&1); then
      return 0
    fi
    # エラーが返っても、マージ自体は済んでいることがある
    if [ "$(gh api "repos/$REPO/pulls/$pr" -q '.merged // false' 2> /dev/null)" = true ]; then
      return 0
    fi
    printf '%s' "$out" | grep -qiE 'HTTP 5[0-9][0-9]|server error|bad gateway|timeout|timed out|connection' || break
    [ "$i" -lt 3 ] && sleep "${MERGE_RETRY_WAIT_SEC:-10}"
  done
  printf '%s' "$out"
  return 1
}

# 自動でマージする。できなかったら黙って終わらず、main との衝突なら AI に解消させ、それ以外はやり直し待ちに回す。
#   使い方：merge_or_handle PR番号 先頭コミット 種類（mark_for_retry に渡す。merge なら、見張り役はAIを動かさずにマージだけをやり直す）。マージできたら 0、できなければ 1
merge_or_handle() {
  local pr="$1" sha="$2" kind="$3" out state
  if out=$(merge_pr "$pr" "$sha"); then
    return 0
  fi
  state=$(pr_merge_state "$pr")
  if [ "$state" = dirty ]; then
    # 同時に進めた別の PR が先にマージされ、同じファイルを触っていたとき
    request_fix_or_stop "$pr" "$sha" "レビューのあとに main が進み、コンフリクトでマージできませんでした。\`git fetch origin main\` のあと \`git merge origin/main\` でコンフリクトを解消してください。両方の変更の意図を残し（docs/spec.md・docs/design.md も両方の決まりを残す）、どちらかを捨てるときはPRにコメントで理由を書いてください。解消したら確認コマンド（pipeline.json の checks。無ければ型チェック・リント・テスト・ビルド）を全部通して push してください。"
    echo "PR #$pr：main と衝突してマージできないので、AIに解消を依頼しました"
  else
    # CI 以外のチェック（Vercel など）が落ちていて、GitHub がマージを断ったのかもしれない。落ちているチェックがあれば、名前と理由を書く
    local ext err
    err="$(printf '%s' "$out" | tail -n 1 | cut -c1-160)"
    ext=$(external_checks_not_ok "$sha")
    if [ -n "$ext" ]; then
      handle_external_checks "$pr" "$sha" "$ext" "自動でマージできませんでした（状態：${state}。${err}）"
    else
      mark_for_retry "$pr" "$kind" "自動でマージできませんでした（状態：${state}。${err}）"
      echo "PR #$pr：マージできなかったので、やり直し待ちにしました（状態：${state}）"
    fi
  fi
  return 1
}

# ---- CI 以外のチェック（Vercel などの外部のサービスが、PRの先頭コミットに付ける物） ----
# CI（GitHub Actions）もレビューも通ったのに、外部のチェックが落ちている・終わっていないと、マージできない。
# 黙って止まらないように、落ちているチェックの名前と理由をPRに書き、時間をおいてもう一度確かめる（AIは動かさない。
# やり直しの種類 merge。見張り役が after-review.sh のマージの判断だけをやり直す）。続くなら人間に回す
EXTERNAL_CHECK_MARK="external-checks:"
# 同じ先頭コミットで、確かめ直す回数（これだけ確かめても通らなければ人間に回す）
EXTERNAL_CHECK_RETRIES="${EXTERNAL_CHECK_RETRIES:-2}"

# 読むだけの API：ワークフローのトークン（READ_TOKEN。checks: read・statuses: read）で読み、読めなければパイプラインの鍵で読む
read_api() {
  if [ -n "${READ_TOKEN:-}" ] && GH_TOKEN="$READ_TOKEN" gh api "$@" 2> /dev/null; then return 0; fi
  gh api "$@" 2> /dev/null
}

# check run の一覧（JSON の配列）から、CI 以外（GitHub Actions 以外の App が付けた物）で通っていない物を出す。形は下と同じ
external_check_runs_not_ok() {
  jq -r '.[] | select((.app.slug // "") != "github-actions")
    | select(.status != "completed" or (.conclusion | IN("success", "neutral", "skipped") | not))
    | (.status != "completed") as $pending
    | ["check", (.name // "?"), (if $pending then "pending" else "failed" end),
       ((if $pending then (.status // "") else (.conclusion // "") end)
        + (if (.output.title // "") != "" then "：" + .output.title else "" end) | gsub("[\t\r\n]"; " ") | .[0:140]),
       (.details_url // .html_url // "")] | @tsv' 2> /dev/null || true
}

# 先頭コミットの「CI 以外のチェック」のうち、通っていない物を1行に1つ出す（無ければ何も出さない。読めなければ、無いとみなす）。
#   タブ区切り：種類（check＝check run／status＝コミットステータス） 名前 状態（failed／pending） 理由 URL
#   第2引数に check run の一覧（JSON の配列）を渡すと、check run は読み直さない
external_checks_not_ok() {
  local sha="$1" runs="${2:-}"
  if [ -z "$runs" ]; then
    runs=$(read_api "repos/$REPO/commits/$sha/check-runs?per_page=100" -q '[.check_runs[] | select(.name != "review")]') || runs="[]"
  fi
  printf '%s' "$runs" | external_check_runs_not_ok
  read_api "repos/$REPO/commits/$sha/status?per_page=100" -q '.statuses // [] | .[] | select(.state != "success")
    | ["status", (.context // "?"), (if .state == "pending" then "pending" else "failed" end),
       ((.state // "") + (if (.description // "") != "" then "：" + .description else "" end) | gsub("[\t\r\n]"; " ") | .[0:140]),
       (.target_url // "")] | @tsv' || true
}

# 通っていないチェックの一覧（上の形）を、コメントに書く箇条書きにする
external_checks_text() {
  local kind name state why url line
  while IFS=$'\t' read -r kind name state why url; do
    [ -z "$name" ] && continue
    line="- \`${name}\`（$([ "$kind" = status ] && echo "コミットステータス" || echo "check run")）：$([ "$state" = pending ] && echo "まだ終わっていません" || echo "落ちています")"
    [ -n "$why" ] && line="${line}（${why}）"
    [ -n "$url" ] && line="${line} ${url}"
    printf '%s\n' "$line"
  done <<< "$1"
}

# 通っていないチェックの名前を「、」でつなぐ（理由の1行用）
external_checks_names() {
  printf '%s\n' "$1" | cut -f2 | grep -v '^$' | awk '!seen[$0]++' | paste -sd, - | sed 's/,/、/g'
}

# CI 以外のチェックが通っていないとき：名前と理由をPRに書いて、やり直し待ち（種類 merge）にする。
# 同じ先頭コミットで EXTERNAL_CHECK_RETRIES 回確かめ直しても通らなければ、人間に回す（人間が再開したら、数え直す）
#   使い方：handle_external_checks PR番号 先頭コミット 一覧（external_checks_not_ok の出力） [マージの失敗の文]
handle_external_checks() {
  local pr="$1" sha="$2" list="$3" merge_err="${4:-}" names text n lead
  names=$(external_checks_names "$list")
  text=$(external_checks_text "$list")
  n=$(all_comments "$pr" | jq --arg mk "<!-- ${EXTERNAL_CHECK_MARK} ${sha} -->" --arg resume "$RESUME_MARK" '
    (map(select(.body | contains($resume)) | .created_at) | max // "") as $since
    | [.[] | select((.body | contains($mk)) and .created_at > $since)] | length')
  lead="CI（GitHub Actions）とレビューは通りましたが、CI 以外のチェックが通っていません"
  [ -n "$merge_err" ] && lead="${merge_err}。CI 以外のチェックが通っていません"
  if [ "${n:-0}" -ge "$EXTERNAL_CHECK_RETRIES" ]; then
    stop_for_human "$pr" "${lead}（${names}）。時間をおいて${n}回確かめ直しても、変わりませんでした。チェックを付けたサービスの側（Vercel などの画面）を確かめてください。直ったら \`ai:stuck\` を外すと、続きから進みます

${text}"
    echo "PR #$pr：CI 以外のチェック（${names}）が通らないままなので、人間に回しました"
    return 0
  fi
  comment "$pr" "⏳ ${lead}。まだマージしません。

${text}

一時的な失敗・まだ途中かもしれないので、時間をおいてもう一度確かめます（$((n + 1))/${EXTERNAL_CHECK_RETRIES}回目。AIは動かしません）。それでも通らなければ、人間に回します。

<!-- ${EXTERNAL_CHECK_MARK} ${sha} -->" || true
  mark_for_retry "$pr" merge "CI 以外のチェックが通っていません（${names}）"
  echo "PR #$pr：CI 以外のチェック（${names}）が通っていないので、時間をおいて確かめ直します"
}

# ---- 順番待ち（ai:queue）を進める ----
# 企画AIが本文に書く「触るファイル」の印：<!-- ai-touches: src/lib/a.ts, src/components/ --> （/ で終わる物はフォルダ）
TOUCHES_MARK_RE='<!-- ai-touches: ([^>]*) -->'
# 同時に動かす実装の上限（after-plan.sh と同じ）
MAX_PARALLEL="${MAX_PARALLEL:-3}"

# 今の並列の上限を決める（純粋な関数。gh は呼ばず、現在時刻は呼ぶ側が引数で渡す）。
# 引数：現在時刻（epoch 秒）。設定は環境変数：PARALLEL_DAY（昼。無ければ MAX_PARALLEL）・PARALLEL_NIGHT（夜。既定 1）・
#   PARALLEL_NIGHT_HOURS（"01-08"＝1時から8時になる前まで。"22-06" は日またぎ。空・形が違えば夜は無し）・
#   PARALLEL_TZ（既定 Asia/Tokyo）・PARALLEL_OVERRIDE（"night until 2026-11-18T08:00+09:00" / "day until …"。期限切れ・形が違えば無視）
# 出力：「上限の数 説明」（1行）。上限は1以上の整数で、数でない・0以下は既定値に戻す
parallel_limit_decide() {
  local now="$1" tz="${PARALLEL_TZ:-Asia/Tokyo}" day night s e h until_s is_night=0
  day="${PARALLEL_DAY:-${MAX_PARALLEL:-3}}"
  if [[ "$day" =~ ^[0-9]+$ ]] && [ "$((10#$day))" -ge 1 ]; then day=$((10#$day)); else day=3; fi
  night="${PARALLEL_NIGHT:-1}"
  if [[ "$night" =~ ^[0-9]+$ ]] && [ "$((10#$night))" -ge 1 ]; then night=$((10#$night)); else night=1; fi
  [[ "$now" =~ ^[0-9]+$ ]] || now=0
  local ov="${PARALLEL_OVERRIDE:-}"
  if [[ "$ov" =~ ^[[:space:]]*(night|day)[[:space:]]+until[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]]; then
    local which="${BASH_REMATCH[1]}" ts="${BASH_REMATCH[2]}"
    if [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?(Z|[+-][0-9]{2}:?[0-9]{2})?$ ]] \
      && until_s=$(TZ="$tz" date -d "$ts" +%s 2> /dev/null) && [ "$now" -lt "$until_s" ]; then
      if [ "$which" = night ]; then echo "$night 夜の上限（手で上書き中）"; else echo "$day 昼の上限（手で上書き中）"; fi
      return 0
    fi
  fi
  if [[ "${PARALLEL_NIGHT_HOURS:-}" =~ ^([0-9]{1,2})-([0-9]{1,2})$ ]]; then
    s=$((10#${BASH_REMATCH[1]})); e=$((10#${BASH_REMATCH[2]}))
    if [ "$s" -le 24 ] && [ "$e" -le 24 ] && [ "$s" -ne "$e" ]; then
      h=$(TZ="$tz" date -d "@$now" +%H 2> /dev/null) || h=""
      if [[ "$h" =~ ^[0-9]+$ ]]; then
        h=$((10#$h))
        if [ "$s" -lt "$e" ]; then
          if [ "$h" -ge "$s" ] && [ "$h" -lt "$e" ]; then is_night=1; fi
        else
          if [ "$h" -ge "$s" ] || [ "$h" -lt "$e" ]; then is_night=1; fi
        fi
      fi
    fi
  fi
  if [ "$is_night" = 1 ]; then echo "$night 夜の上限"; else echo "$day 昼の上限"; fi
}

# 上限の数だけ（呼ぶ側が現在時刻を渡す）
parallel_limit() { parallel_limit_decide "$1" | cut -d' ' -f1; }
# 画面は、今の時刻で上限を決める（ここだけが現在時刻を読む）
current_parallel() { parallel_limit_decide "$(date +%s)"; }
# 画面のファイル：見た目のテストがあるリポジトリでは、ここを触る物どうしは基準の画像がぶつかるので、1つずつにする
SCREEN_PATHS_RE='^(src/)?(app|components|styles|pages)/'

# 本文の印から、触るファイルを1行に1つ出す（印が無ければ何も出さない）
touches_from_body() {
  local body="$1" list
  [[ "$body" =~ $TOUCHES_MARK_RE ]] || return 0
  list="${BASH_REMATCH[1]}"
  printf '%s\n' "$list" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's#^\./##' | grep -v '^$' || true
}

# 2つの一覧（改行区切り）が重なるか。同じファイル・片方のフォルダの中にもう片方がある、を重なりとみなす。
# 第3引数が 1 なら、画面のファイルどうしも重なりとみなす（見た目のテストの基準の画像がぶつかるため）
paths_overlap() {
  local a b screen="${3:-0}"
  while IFS= read -r a; do
    [ -z "$a" ] && continue
    while IFS= read -r b; do
      [ -z "$b" ] && continue
      [ "$a" = "$b" ] && return 0
      case "$a" in */) case "$b" in "$a"*) return 0 ;; esac ;; esac
      case "$b" in */) case "$a" in "$b"*) return 0 ;; esac ;; esac
      if [ "$screen" = 1 ] && [[ "$a" =~ $SCREEN_PATHS_RE ]] && [[ "$b" =~ $SCREEN_PATHS_RE ]]; then return 0; fi
    done <<< "$2"
  done <<< "$1"
  return 1
}

# 見た目のテスト（tests/visual/）があるリポジトリか
repo_has_visual_tests() {
  gh api "repos/$REPO/contents/tests/visual?ref=main" --jq 'type' > /dev/null 2>&1
}

# ---- 人間のマージ待ち（ai:hold）が長いPRは、順番待ちを止めない ----
# 人間のマージ待ち＝ai:hold が付いていて、レビューまで済んでいる（またはレビューAIが動けないPRだと知らせてある）。watchdog.sh の判定と同じ。
# 待ち時間は ai:hold が付いた時刻から数える。HOLD_BLOCK_MIN 分を過ぎたPRは、触るファイルを「進行中」から外す。
HOLD_BLOCK_MIN="${HOLD_BLOCK_MIN:-60}"
HOLD_RELEASED_MARK="<!-- hold-released:"
HOLD_BLOCKING_MARK="<!-- hold-blocking:"

# PR（番号・先頭コミット）が、人間のマージ待ちか
pr_awaiting_human() {
  local pr="$1" sha="$2" comments head_date reviewed
  has_label "$pr" "ai:hold" || return 1
  comments=$(all_comments "$pr") || return 1
  head_date=$(gh api "repos/$REPO/commits/$sha" -q .commit.committer.date 2> /dev/null) || return 1
  reviewed=$(printf '%s' "$comments" | jq --arg since "$head_date" \
    '[.[] | select((.user.login == "claude[bot]" or .user.login == "github-actions[bot]") and (.body | startswith("## Code review")) and .created_at >= $since)] | length')
  [ "${reviewed:-0}" -gt 0 ] && return 0
  printf '%s' "$comments" | jq -e --arg mk "$REVIEW_UNAVAILABLE_MARK $sha" 'any(.[]; .body | contains($mk))' > /dev/null
}

# ai:hold が付いてから何分か。時刻が読めなければ何も出さない
hold_wait_min() {
  local at
  at=$(api_list "repos/$REPO/issues/$1/events?per_page=100" 2> /dev/null \
    | jq -r '[.[] | select(.event == "labeled" and .label.name == "ai:hold") | .created_at] | last // empty') || return 0
  [ -z "$at" ] && return 0
  at=$(date -d "$at" +%s 2> /dev/null) || return 0
  echo $((($(date +%s) - at) / 60))
}

# 人間のマージ待ちのPRを「番号 expired」（待ちが長い）か「番号 waiting」（時間内・時刻が読めない）で1行ずつ出す。読めなければ失敗
hold_prs() {
  local pulls pr sha w
  pulls=$(api_list "repos/$REPO/pulls?state=open&per_page=100") || return 1
  while IFS=' ' read -r pr sha; do
    [ -z "$pr" ] && continue
    pr_awaiting_human "$pr" "$sha" || continue
    w=$(hold_wait_min "$pr")
    if [ -n "$w" ] && [ "$w" -ge "$HOLD_BLOCK_MIN" ]; then echo "$pr expired"; else echo "$pr waiting"; fi
  done < <(printf '%s' "$pulls" | jq -r '.[] | "\(.number) \(.head.sha)"')
  return 0
}

# 進行中の作業が触っているファイル。1行目に「unknown」が出たら、分からない物がある（並列にしない）
# 実装中の Issue は本文の印、open のPRは変えたファイル（AI以外のPR＝配布・依存の更新なども含む）
# ただし、人間のマージ待ちが HOLD_BLOCK_MIN 分より長い ai:hold のPRと、ai:stuck のPRは外す
inflight_touches() {
  local n body t pr files impl pulls expired
  expired=$(hold_prs 2> /dev/null | awk '$2 == "expired" {print $1}') || expired=""
  # 一覧を読めなかったら、分からない物があるとして待つ（空の一覧とみなさない）
  impl=$(gh api "repos/$REPO/issues?state=open&per_page=100&labels=ai%3Aimplement" --paginate -q '.[] | select(.pull_request | not) | .number' 2> /dev/null) || { echo unknown; return 0; }
  pulls=$(gh api "repos/$REPO/pulls?state=open&per_page=100" --paginate -q '.[] | "\(.number) \(.head.ref)"' 2> /dev/null) || { echo unknown; return 0; }
  for n in $impl; do
    # PRがもうあれば、PRの変えたファイルで数える（下）
    if printf '%s\n' "$pulls" | grep -q " claude/issue-$n-"; then continue; fi
    body=$(gh api "repos/$REPO/issues/$n" -q '.body // ""' 2> /dev/null) || { echo unknown; continue; }
    t=$(touches_from_body "$body")
    if [ -z "$t" ]; then echo unknown; else printf '%s\n' "$t"; fi
  done
  for pr in $(printf '%s\n' "$pulls" | cut -d' ' -f1); do
    if printf '%s\n' "$expired" | grep -qx "$pr"; then continue; fi
    # 止まっている（ai:stuck）PRも数えない
    if has_label "$pr" "ai:stuck"; then continue; fi
    files=$(gh api "repos/$REPO/pulls/$pr/files?per_page=100" --paginate -q '.[].filename' 2> /dev/null) || { echo unknown; continue; }
    # 変えたファイルが無いPRも、数えるPRとして1行残す（進行中が空と見えないように）
    if [ -z "$files" ]; then echo "(変更なしのPR #$pr)"; else printf '%s\n' "$files"; fi
  done
}

# 順番待ち（ai:queue）から、次に実装に回す物を選んで始める。
# - 進行中の物が無ければ、先頭の1つ（priority:high が付いた物を先に、その中は番号の小さい順）
# - 進行中の物があっても、上限（MAX_PARALLEL）に達しておらず、触るファイルが進行中の物と重ならない物は、並べて始める
#   （触るファイルが分からない物・進行中の物に分からない物があるときは、今までどおり待つ。見た目のテストがあれば画面どうしも待つ）
# 止まっている物（ai:stuck）は数えない（企画で止まった物はコードに触れていない）
# 待ちが長くて進行中から外したPRに、外したことを1回だけ書く（印で二重に書かない）
note_hold_released() {
  local pr="$1" next="$2"
  all_comments "$pr" | jq -e --arg mk "$HOLD_RELEASED_MARK" 'any(.[]; .body | contains($mk))' > /dev/null && return 0
  comment "$pr" "${HOLD_RELEASED_MARK} #${next} -->
⏩ 人間のマージ待ちが長いので、このPRを待たずに #${next} を始めます。あとで入る変更とコンフリクトしたら、AIが解消します。" || true
}

# 順番待ちを止めている ai:hold のPRの目印。コメントは1つで、1行目の印 <!-- hold-blocking: #2,#3 --> に待つ Issue の番号を全部書く。
# 待つ Issue が変わったら書き換え、無くなったら「今は止めていません」に書き換える（目印が無ければ何もしない）
# 引数：PR番号、待つ Issue の番号（空白区切り・空でもよい）
sync_hold_blocking() {
  local pr="$1" nums="$2" list="" n first body c id
  for n in $nums; do list="${list:+${list},}#${n}"; done
  if [ -n "$list" ]; then
    first="${HOLD_BLOCKING_MARK} ${list} -->"
    body="${first}
⏸ このPRをマージすると ${list//,/、} が動き出します（触るファイルが重なるので、順番待ちで待っています）。"
  else
    first="${HOLD_BLOCKING_MARK} -->"
    body="${first}
▶ このPRは、今は順番待ちを止めていません。"
  fi
  c=$(all_comments "$pr" | jq -c --arg mk "$HOLD_BLOCKING_MARK" 'map(select(.body | startswith($mk))) | last // empty') || return 0
  if [ -z "$c" ]; then
    [ -z "$list" ] && return 0
    comment "$pr" "$body" || true
  elif [ "$(printf '%s' "$c" | jq -r '.body | split("\n")[0]')" != "$first" ]; then
    id=$(printf '%s' "$c" | jq -r .id)
    gh api -X PATCH "repos/$REPO/issues/comments/$id" -f body="$body" > /dev/null || true
  fi
}

start_next_in_queue() {
  local busy stuck prs inflight queue n body t rc started=0 screen=0 holds pr state files blocks="" startedlist=" " limit_info limit idle=0 nomark_started=0
  busy=$(count_open_issues_with_label "ai:implement") || return 1
  stuck=$(count_open_issues_with_label "ai:stuck") || return 1
  prs=$(count_open_prs) || return 1
  limit_info=$(current_parallel)
  limit="${limit_info%% *}"
  echo "実装中 ${busy} / 停止中 ${stuck}（数えない） / openのPR ${prs}（並列の上限 ${limit}：${limit_info#* }）"
  # 並べ替えは全体でする（ページごとに並べると、2ページ目の急ぎ・番号の小さい物が後ろに回る）
  queue=$(api_list "repos/$REPO/issues?state=open&per_page=100&labels=ai%3Aqueue" \
    | jq -r '[.[] | select(.pull_request | not) | {n: .number, p: ([.labels[].name] | index("priority:high") != null)}] | sort_by((if .p then 0 else 1 end), .n) | .[].n') || return 1
  if [ -z "$queue" ]; then
    echo "順番待ちはありません"
    # 待っていた Issue が無くなったPRの目印は「今は止めていません」に書き換える
    holds=$(hold_prs 2> /dev/null) || holds=""
    while read -r pr state; do
      [ -z "$pr" ] && continue
      sync_hold_blocking "$pr" ""
    done <<< "$holds"
    return 0
  fi
  if [ "$busy" -eq 0 ] && [ "$prs" -eq 0 ]; then
    # 2＝ほかの処理が先に始めた（競合は正常なので、失敗にしない）
    start_queued_issue "$(printf '%s\n' "$queue" | head -1)" || [ $? -eq 2 ] || return 1
    return 0
  fi
  inflight=$(inflight_touches) || return 1
  if printf '%s\n' "$inflight" | grep -qx unknown; then
    echo "進行中の物に、触るファイルが分からない物があるので、順番待ちは進めません"
    return 0
  fi
  # 数える進行中の物が1つも無い（数えないPRしか開いていない）なら、印の無い Issue も1つ始められる
  if [ -z "$(printf '%s\n' "$inflight" | tr -d '[:space:]')" ]; then idle=1; fi
  if repo_has_visual_tests; then screen=1; fi
  holds=$(hold_prs 2> /dev/null) || holds=""
  for n in $queue; do
    if [ $((busy + started)) -ge "$limit" ]; then
      echo "並列の上限（${limit}）なので、ここまでにします"
      break
    fi
    body=$(gh api "repos/$REPO/issues/$n" -q '.body // ""') || continue
    t=$(touches_from_body "$body")
    if [ "$nomark_started" -eq 1 ]; then
      # 印の無い物を始めたあとは、その物が触るファイルが分からないので、この実行では続けない
      echo "#$n：触るファイルが分からない物を始めたので、それが終わるまで待ちます"
      continue
    fi
    if [ -z "$t" ]; then
      if [ "$idle" -eq 0 ]; then
        echo "#$n：触るファイルが分からないので、進行中の物が終わるまで待ちます"
        continue
      fi
      rc=0
      start_queued_issue "$n" "（進行中に数える作業が無いので、始めます）" || rc=$?
      if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then
        started=$((started + 1))
        startedlist="${startedlist}${n} "
        nomark_started=1
      fi
      continue
    fi
    if paths_overlap "$t" "$inflight" "$screen"; then
      echo "#$n：進行中の作業と触るファイルが重なるので、待ちます"
      continue
    fi
    rc=0
    start_queued_issue "$n" "（進行中の作業と触るファイルが重ならないので、並べて始めます）" || rc=$?
    # 0＝始めた、2＝ほかの処理が先に始めた。どちらも進行中が1つ増えたので、数えて続きの判断に入れる
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then
      started=$((started + 1))
      startedlist="${startedlist}${n} "
      idle=0 # 印のある物を始めたので、印の無い物は待つ
      inflight="$inflight
$t"
    fi
    # 待ちが長いマージ待ちのPRを外したから始められた（そのPRと重なる）なら、そのPRに1回だけ知らせる
    if [ "$rc" -eq 0 ]; then
      while read -r pr state; do
        [ "$state" = expired ] || continue
        files=$(gh api "repos/$REPO/pulls/$pr/files?per_page=100" --paginate -q '.[].filename' 2> /dev/null) || continue
        if paths_overlap "$t" "$files" "$screen"; then note_hold_released "$pr" "$n"; fi
      done <<< "$holds"
    fi
  done
  # 止まっている（時間内の）マージ待ちのPRに、待っている Issue の番号を全部集めて目印を付ける。止めなくなったPRの目印は書き換える
  for n in $queue; do
    case "$startedlist" in *" $n "*) continue ;; esac
    body=$(gh api "repos/$REPO/issues/$n" -q '.body // ""' 2> /dev/null) || continue
    t=$(touches_from_body "$body")
    [ -z "$t" ] && continue
    while read -r pr state; do
      [ "$state" = waiting ] || continue
      files=$(gh api "repos/$REPO/pulls/$pr/files?per_page=100" --paginate -q '.[].filename' 2> /dev/null) || continue
      if paths_overlap "$t" "$files" "$screen"; then blocks="${blocks}${pr} ${n}
"; fi
    done <<< "$holds"
  done
  while read -r pr state; do
    [ -z "$pr" ] && continue
    sync_hold_blocking "$pr" "$(printf '%s' "$blocks" | awk -v p="$pr" '$1 == p {print $2}' | tr '\n' ' ')"
  done <<< "$holds"
  [ "$started" -eq 0 ] && echo "今は始められる物がありません（進行中の物が終わると、もう一度見ます）"
  return 0
}

# 順番待ちの1つを実装に回す。PRが閉じたとき（queue.yml）と見張り役が同時に進めることがあるので、ai:queue を外せた方だけが進める
start_queued_issue() {
  local next="$1" why="${2:-（前の作業は全部終わっています）}"
  if ! take_label "$next" "ai:queue"; then
    echo "#$next はほかの処理がもう始めたので、何もしません"
    return 2
  fi
  # 企画AIの「待ち」のコメントを読んだ実装AIが、前の作業が終わったか確かめられずに止まらないよう、先に伝えておく
  comment "$next" "▶ 順番が来たので実装を始めます${why}。" || true
  add_label "$next" "ai:implement" || return 1
  echo "順番待ちの #$next を実装に回しました"
}

# ---- 自動のやり直し ----
# 止まったとき、すぐ人間に回さず「あとでやり直す」印（ai:retry）と記録のコメントを付ける。
# やり直しは watchdog.sh（定期・ほかのワークフロー完了のたび）が、待ち時間（RETRY_COOLDOWN_MIN）が過ぎてから行う。
# 上限（MAX_RETRY）を超えたら人間に回す。kind：plan / implement / mocks（Issue）、review / mention（PR）

retry_comment() {
  all_comments "$1" | jq -c --arg mark "$RETRY_MARK" 'map(select(.body | contains($mark))) | last // empty'
}

retry_count() {
  local c n
  c=$(retry_comment "$1")
  if [ -z "$c" ]; then
    echo 0
    return
  fi
  n=$(printf '%s' "$c" | jq -r .body | sed -nE 's/.*count=([0-9]+) kind=.*/\1/p' | tail -1)
  echo "${n:-0}"
}

# 記録のコメントは1つだけ作り、あとは書き換える（コメントが増えないように）。
#   num 回数 kind 理由 [上限のリセット時刻（UNIX秒 か unknown）] [上限の待ちを最初に始めた時刻（UNIX秒）]
write_retry_record() {
  local num="$1" count="$2" kind="$3" reason="$4" until_at="${5:-}" first="${6:-}" c id body marks=""
  [ -n "$until_at" ] && marks="${marks}
<!-- limit-until=${until_at} -->"
  [ -n "$first" ] && marks="${marks}
<!-- limit-first=${first} -->"
  # 最初の失敗も回数は 0 なので、回数だけでは見分けない（見分けないと、最初の失敗が「回数を0に戻しました」と出て、理由の行も残らない）
  if [ "$count" -eq 0 ] && [ "$reason" = "$RESUMED_REASON" ]; then
    # 人間が再開したとき（resume.sh）：回数を0に戻しただけ。「AIが止まった」とは書かない
    body=$(printf '▶ %s。自動のやり直しの回数を0に戻しました。\n\n%s\n<!-- count=0 kind=%s -->%s' "$reason" "$RETRY_MARK" "$kind" "$marks")
  else
    body=$(printf '🔁 AIが止まったので、時間をおいて自動でやり直します（やり直し %s/%s回）。\n理由：%s\n\n%s\n<!-- count=%s kind=%s -->%s' \
      "$count" "$MAX_RETRY" "$reason" "$RETRY_MARK" "$count" "$kind" "$marks")
  fi
  c=$(retry_comment "$num")
  if [ -n "$c" ]; then
    id=$(printf '%s' "$c" | jq -r .id)
    gh api -X PATCH "repos/$REPO/issues/comments/$id" -f body="$body" > /dev/null
  else
    comment "$num" "$body"
  fi
}


# AIの実行記録から、使用量の上限かどうかと、リセット時刻を見分ける。出力：
#   （空）    上限ではない／分からない
#   unknown   上限だが、リセット時刻は読み取れない
#   <数字>    上限で、リセットされる時刻（UNIX秒）。「…limit reached|1761000000」の形で書かれているとき
limit_signal() {
  local f="${1:-}" result epoch
  { [ -n "$f" ] && [ -s "$f" ]; } || return 0
  result=$(jq -r 'if type == "array" then . else [.] end | map(select(.type == "result")) | last // {} | .result // "" | tostring' "$f" 2> /dev/null) || return 0
  printf '%s' "$result" | grep -qiE 'usage limit|rate limit|limit reached|hit your limit' || return 0
  epoch=$(printf '%s' "$result" | sed -nE 's/.*[Ll]imit reached\|([0-9]{10}).*/\1/p' | head -1)
  echo "${epoch:-unknown}"
}

# AIの実行記録（claude-code-action の execution_file）から、失敗の原因を一言に分類する
#   使用量の上限 / 許可不足 / 作業回数の上限 / その他 / 不明（記録なし）
classify_failure() {
  local f="${1:-}" info subtype denials first result
  if [ -z "$f" ] || [ ! -s "$f" ]; then
    echo "不明（AIの実行記録がありません）"
    return
  fi
  # first：許可されなかった最初の操作（例：Bash(git rebase main)）。人間がどの許可を足すか決められるように出す。
  # 中の | と改行は区切りとぶつかるので置き換え、長い物は60文字で切る
  info=$(jq -r 'if type == "array" then . else [.] end | map(select(.type == "result")) | last // {}
    | (.permission_denials // []) as $d
    | ($d[0] // {}) as $x
    | (if ($x.tool_name // "") == "" then ""
       else (($x.tool_input.command // $x.tool_input.file_path // $x.tool_input.pattern // "") | tostring) as $arg
         | if $arg == "" then $x.tool_name else ($x.tool_name + "(" + $arg + ")") end
       end | gsub("[|\n\r]"; " ") | if length > 60 then .[0:59] + "…" else . end) as $first
    | "\(.subtype // "")|\($d | length)|\($first)|\(.result // "" | tostring | .[0:300] | gsub("\n"; " "))"' "$f" 2> /dev/null) || info=""
  # 区切りは | （空白の区切りだと、先頭の項目が空のときに詰められてずれる）。result は最後なので、中に | があってもよい
  IFS='|' read -r subtype denials first result <<< "$info"
  if printf '%s' "$result" | grep -qiE 'usage limit|rate limit|limit reached|overloaded|429'; then
    echo "使用量の上限"
  elif [ "${denials:-0}" -gt 0 ]; then
    if [ -n "$first" ]; then
      echo "許可不足（AIが許可されていない操作を試した：${denials}件。最初の1件：${first}）"
    else
      echo "許可不足（AIが許可されていない操作を試した：${denials}件）"
    fi
  elif [ "$subtype" = "error_max_turns" ]; then
    echo "作業回数の上限（--max-turns）"
  elif [ -n "$subtype" ]; then
    echo "その他（${subtype}）"
  else
    echo "その他（結果が読み取れません）"
  fi
}

# AIの実行記録が「作業回数の上限（--max-turns）に届いて終わった」か
hit_max_turns() {
  local f="${1:-}" subtype
  { [ -n "$f" ] && [ -s "$f" ]; } || return 1
  subtype=$(jq -r 'if type == "array" then . else [.] end | map(select(type == "object" and .type == "result")) | last // {} | .subtype // ""' "$f" 2> /dev/null) || return 1
  [ "$subtype" = "error_max_turns" ]
}

# 失敗コメントの理由に、分類（classify_failure）と、見に行けるログのURLを足す
#   使い方：failure_reason "企画AIがエラーで止まりました" [実行記録のファイル]
failure_reason() {
  echo "$1（原因：$(classify_failure "${2:-}")。ログ：${GITHUB_SERVER_URL:-https://github.com}/${REPO}/actions/runs/${GITHUB_RUN_ID:-0}）"
}

# AIが作ったブランチ（claude/ で始まる物）だけを消す。人間のブランチやmainには触らない（無ければ何もしない）
delete_branch_if_ai() {
  local b="${1:-}"
  case "$b" in
    claude/*) gh api -X DELETE "repos/$REPO/git/refs/heads/$b" > /dev/null 2>&1 && echo "ブランチ $b を消しました" || true ;;
  esac
}

# 記録のコメントの本文から、印の値を取り出す（無ければ空）。使い方：retry_mark_value "$body" limit-until
retry_mark_value() {
  printf '%s' "$1" | sed -nE "s/.*<!-- $2=([0-9a-z]+) -->.*/\\1/p" | tail -1
}

# ---- AIの許可（--allowedTools）の不足 ----
# AIが「許可されていない操作」で止まったとき、何を足せばいいかを通知・コメントに書き、同じ不足が2回起きたらIssueにする。
# 許可の一覧は docs/pipeline.md の「AIの許可」の表（tests/test-permissions.sh が、ワークフローと食い違っていないか確かめる）

PERM_LEDGER_TITLE="AIの許可の不足（自動の記録）"

# コマンドを、許可の書き方（--allowedTools に足す形）にする。git は2語、gh・npm は3語（npm は完全一致）、ほかは1語
permission_key_for_command() {
  local cmd="$1" a b c
  read -r a b c _ <<< "$cmd"
  case "$a" in
    git) echo "Bash(${a} ${b:-}:*)" ;;
    gh) echo "Bash(${a} ${b:-} ${c:-}:*)" ;;
    npm) echo "Bash(${a} ${b:-} ${c:-})" ;;
    "") return 0 ;;
    *) echo "Bash(${a}:*)" ;;
  esac | sed -E 's/ +:\*\)/:*)/; s/ +\)/)/'
}

# AIの実行記録から、許可が無くて拒否された操作を、許可の書き方で1行ずつ出す（無ければ何も出さない）
# 複数行のコマンド（ヒアドキュメントなど）は1行目だけを見る（2行目以降を別の操作と読まない）
denied_tools() {
  local f="${1:-}" name cmd
  { [ -n "$f" ] && [ -s "$f" ]; } || return 0
  jq -r 'if type == "array" then . else [.] end | map(select(.type == "result")) | last // {} | .permission_denials // []
    | .[] | "\(.tool_name // "" | gsub("[\t\r\n]"; " "))\t\(.tool_input.command // "" | tostring | (split("\n")[0] // "") | gsub("[\t\r]"; " "))"' "$f" 2> /dev/null \
    | while IFS=$'\t' read -r name cmd; do
      if [ "$name" = "Bash" ]; then permission_key_for_command "$cmd"; else echo "$name"; fi
    done | sort -u
}

# AIの実行記録から、拒否された操作を、そのままの形（ツール名と、コマンドの1行目かファイル名）で1行ずつ出す（最大5件）。
# 許可の書き方（denied_tools）では「npm run typecheck 2>&1」が「npm run typecheck」になり、何が悪かったか分からないので、やり直しの依頼にはこちらを書く
denied_raw() {
  local f="${1:-}"
  { [ -n "$f" ] && [ -s "$f" ]; } || return 0
  jq -r 'if type == "array" then . else [.] end | map(select(.type == "result")) | last // {} | .permission_denials // []
    | .[] | ((.tool_input.command // .tool_input.file_path // "") | tostring | (split("\n")[0] // "") | gsub("[\t\r]"; " ") | .[0:120]) as $a
    | (.tool_name // "?" | tostring) + (if $a == "" then "" else "(" + $a + ")" end)' "$f" 2> /dev/null | awk 'NF && !seen[$0]++' | head -n 5 || true
}

# AIの実行記録から、AIが最後に言ったこと（result）を1行にして出す（既定で最大300文字。無ければ何も出さない）。
# 「正常に終わったのに何も残さなかった」とき、理由を人間とログに見せるのに使う
ai_last_words() {
  local f="${1:-}" max="${2:-300}"
  { [ -n "$f" ] && [ -s "$f" ] && [ ! -L "$f" ]; } || return 0
  jq -r --argjson max "$max" 'if type == "array" then . else [.] end | map(select(type == "object" and .type == "result")) | last // {}
    | (.result // "" | tostring | gsub("[\t\r\n]+"; " ") | gsub("^ +| +$"; "")) as $t
    | if ($t | length) > $max then $t[0:$max] + "…" else $t end' "$f" 2> /dev/null || true
}

# 許可の一覧を、コメント・通知に書く短い形にする（最初の3件。残りは「ほかN件」）
permission_list_short() {
  local all n
  all=$(printf '%s\n' "$1" | awk 'NF')
  n=$(printf '%s\n' "$all" | awk 'NF' | wc -l | tr -d ' ')
  printf '%s' "$(printf '%s\n' "$all" | head -n 3 | paste -sd, - | sed 's/,/、/g')"
  [ "$n" -gt 3 ] && printf '、ほか%s件' "$((n - 3))"
  return 0
}

# AIのコメントの文章から、「許可されていない」と書いてある行と、そこに出てくるコマンド（`...`）の許可の書き方を出す
#   1行目以降：許可の不足を言っている行（最大3行）。最後に「KEY: …」の行で、許可の書き方
permission_hints_from_text() {
  local text lines key
  text=$(cat)
  lines=$(printf '%s\n' "$text" | grep -iE '許可されて|許可が無|許可が足り|権限が無|権限がありません|not allowed|permission denied|requires approval|was blocked' | head -3 || true)
  [ -z "$lines" ] && return 0
  printf '%s\n' "$lines"
  printf '%s\n' "$lines" | grep -oE '`[^`]+`' | tr -d '`' | grep -E '^(git|gh|npm|npx|node|curl|python3?) ' \
    | while IFS= read -r c; do permission_key_for_command "$c"; done | sort -u | sed 's/^/KEY: /' || true
}

# 題名が完全に同じIssueの番号を、小さい順に1行ずつ出す。使い方：find_issues_by_title 題名 open|all
# search API（題名と repo: で絞る。Issueが100件を超えても見つかる）を先に使い、見つからなければ新しい一覧でも探す
# （search は作った直後に出ないことがある）。一覧が読めなかったときだけ失敗で終わる（「無い」と取り違えない）
find_issues_by_title() {
  local title="$1" state="$2" q found
  q=$(jq -rn --arg t "\"$title\" in:title repo:$REPO type:issue$([ "$state" = open ] && echo ' is:open')" '$t | @uri')
  found=$(gh api "search/issues?q=${q}&per_page=100" -q ".items[] | select(.title == \"$title\") | .number" 2> /dev/null | sort -n) || found=""
  if [ -z "$found" ]; then
    found=$(gh api "repos/$REPO/issues?state=${state}&per_page=100" -q ".[] | select(.title == \"$title\") | .number" | sort -n) || return 1
  fi
  printf '%s\n' "$found" | awk 'NF'
}

# 許可の不足を、記録用のIssue（閉じたまま）にコメントで残し、同じ不足が2回目なら、直すためのIssueを自動で作る
#   使い方：report_permission_gap 番号 "許可の書き方（改行区切り）"
report_permission_gap() {
  local from="$1" keys key ledger ledgers l n n1 title existing created
  # 1回に記録するのは最初の PERM_REPORT_MAX 件まで（多すぎると、1件ずつのAPI呼び出しでジョブが時間切れになる）
  keys=$(printf '%s\n' "$2" | awk 'NF' | head -n "${PERM_REPORT_MAX:-3}")
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    # 記録のIssueは、search API → 新しい一覧の順で探す。重なって作られた物があれば、最小の番号を正とする
    ledgers=$(find_issues_by_title "$PERM_LEDGER_TITLE" all) || return 0
    ledger=$(printf '%s\n' "$ledgers" | head -1)
    if [ -z "$ledger" ]; then
      ledger=$(gh api -X POST "repos/$REPO/issues" -f title="$PERM_LEDGER_TITLE" \
        -f body="AIが「許可されていない操作」で止まったときの記録です（自動）。同じ不足が2回起きたら、直すためのIssueを自動で作ります。このIssueは閉じたままにしてください。" -q .number) || return 0
      gh api -X PATCH "repos/$REPO/issues/$ledger" -f state=closed > /dev/null || true
      ledgers="$ledger"
    fi
    comment "$ledger" "<!-- perm-gap: ${key} -->
#${from} で、AIが許可されていない操作を試して止まりました：\`${key}\`" || true
    # 回数は、見つかった記録のIssue全部のコメントを合わせて数える（重なって作られた分を失わない）
    n=0
    while IFS= read -r l; do
      [ -z "$l" ] && continue
      n1=$(all_comments "$l" | jq --arg k "<!-- perm-gap: ${key} -->" '[.[] | select(.body | contains($k))] | length') || n1=0
      n=$((n + ${n1:-0}))
    done <<< "$ledgers"
    if [ "$n" -ge 2 ]; then
      title="AIの許可が足りない：${key}"
      existing=$(find_issues_by_title "$title" open) || return 0
      if [ -z "$existing" ]; then
        created=$(gh api -X POST "repos/$REPO/issues" -f title="$title" -f 'labels[]=ai:skip' \
          -f body="### 背景
AIが \`${key}\` を許可されておらず、${n}回止まりました（記録：#${ledger}）。

### やること（マネージャーが行う。\`.github/\` を触るのでAIには回さない）
- docs/pipeline.md の「AIの許可」の表を見て、どのAIにこの操作が要るかを決める
- 要るなら、そのワークフローの \`--allowedTools\` に足し、表にも書く（tests/test-permissions.sh が食い違いを見つける）
- 要らない操作なら、AIへの指示の方を直す" -q .number) || return 0
        notify stuck "AIの許可が足りません" "同じ不足（${key}）が${n}回起きたので、Issue #${created} を作りました" 4
      fi
    fi
  done <<< "$keys"
}

# AIがエラーで終わったときの処理：許可の不足なら、足りない物を書いて人間に回す（やり直しても直らない）。
# それ以外は、やり直す（使用量の上限なら待つ）。使い方：handle_ai_failure 番号 kind(plan|implement|review|mention) 説明 [実行記録のファイル]
handle_ai_failure() {
  local num="$1" kind="$2" label="$3" file="${4:-}" denied reason
  denied=$(denied_tools "$file")
  # 使用量の上限で止まったのなら、途中に拒否された操作があっても、許可の不足として人間に回さない（上限は待てば直る。
  # 拒否は、AIが別のやり方で先へ進めていることが多い）。上限のリセットを待ってやり直す（retry_ai_failure）
  if [ -n "$denied" ] && [ -z "$(limit_signal "$file")" ]; then
    reason="$(failure_reason "$label" "$file")。足りない許可：$(permission_list_short "$denied")（docs/pipeline.md の「AIの許可」の表と、ワークフローの --allowedTools を見てください）"
    # 先に人間に回す（ラベル・コメント・通知）。記録は後。記録が遅くてジョブが時間切れになっても、宙に浮かないように
    case "$kind" in
      plan) remove_label "$num" "ai:plan"; stop_issue_for_human "$num" "$reason" ;;
      implement) stop_issue_for_human "$num" "$reason" ;;
      *) stop_for_human "$num" "$reason" ;;
    esac
    report_permission_gap "$num" "$denied"
    return 0
  fi
  retry_ai_failure "$num" "$kind" "$label" "$file"
}

# AIがエラーで終わったとき、やり直し待ち（ai:retry）にする。実行記録があれば、原因に合わせる：
#   使用量の上限        → リセットまで待つ（やり直しの回数を使わない）
#   作業回数の上限が続く → やり直さず人間に回す（max_turns_again）
#   それ以外            → 30分あけてやり直す
# 使い方：retry_ai_failure 番号 kind(plan|implement|review|mention) 説明 [実行記録のファイル]
retry_ai_failure() {
  local num="$1" kind="$2" label="$3" file="${4:-}" limit reason
  limit=$(limit_signal "$file")
  if [ -z "$limit" ] && max_turns_again "$num" "$file"; then
    reason="$(failure_reason "$label" "$file")。やり直しても、また作業回数の上限に届きました（同じ上限で何度やり直しても、同じ所で止まります）。作業が大きすぎるかもしれません"
    case "$kind" in
      plan) remove_label "$num" "ai:plan"; stop_issue_for_human "$num" "${reason}。Issue を小さく分けてください" ;;
      implement) stop_issue_for_human "$num" "${reason}。Issue を小さく分けるか、\`size:L\` を付けてから \`ai:stuck\` を外してください" ;;
      *) stop_for_human "$num" "${reason}。PRのコメントとログを確かめてください" ;;
    esac
    return 0
  fi
  mark_for_retry "$num" "$kind" "$(failure_reason "$label" "$file")" "$limit"
}

# AIが作業回数の上限（--max-turns）で止まり、もう MAX_TURNS_RETRY 回やり直した後か。
# 同じ上限のままやり直しても同じ所で止まるので、10回やり直す前に人間に回すのに使う（やり直しのたびに、上限いっぱいまでAIを使うため）
#   使い方：max_turns_again 番号 実行記録のファイル
MAX_TURNS_RETRY="${MAX_TURNS_RETRY:-1}"
max_turns_again() {
  local num="$1" f="${2:-}" subtype
  { [ -n "$f" ] && [ -s "$f" ]; } || return 1
  subtype=$(jq -r 'if type == "array" then . else [.] end | map(select(type == "object" and .type == "result")) | last // {} | .subtype // ""' "$f" 2> /dev/null) || return 1
  [ "$subtype" = "error_max_turns" ] || return 1
  [ "$(retry_count "$num")" -ge "$MAX_TURNS_RETRY" ]
}

# 止まったことを記録して、あとで自動でやり直す。使い方：mark_for_retry 番号 kind 理由 [limit]
#   limit：使用量の上限のとき、リセット時刻（UNIX秒）か unknown（limit_signal の出力）。上限で待つあいだは、やり直しの回数を使わない
mark_for_retry() {
  local num="$1" kind="$2" reason="$3" limit="${4:-}" count now record body updated first
  now=$(date +%s)
  count=$(retry_count "$num")
  if [ -n "$limit" ]; then
    record=$(retry_comment "$num")
    body=$(printf '%s' "$record" | jq -r '.body // ""')
    first=$(retry_mark_value "$body" limit-first)
    # 前の上限の待ちから時間があいているなら、別の出来事として数え直す
    if [ -n "$record" ] && [ -n "$first" ]; then
      updated=$(date -d "$(printf '%s' "$record" | jq -r .updated_at)" +%s)
      [ $(( now - updated )) -gt $(( LIMIT_MAX_WAIT_HOURS * 3600 )) ] && first=""
    fi
    if [ -n "$first" ] && [ $(( now - first )) -gt $(( LIMIT_MAX_WAIT_HOURS * 3600 )) ]; then
      reason="${reason}（使用量の上限が${LIMIT_MAX_WAIT_HOURS}時間以上続いています）"
      limit=""
    fi
  fi
  if [ -z "$limit" ] && [ "$count" -ge "$MAX_RETRY" ]; then
    if [ "$kind" = "plan" ]; then
      remove_label "$num" "ai:plan"
    fi
    case "$kind" in
      plan | implement | mocks) stop_issue_for_human "$num" "${reason}。自動でやり直しても${MAX_RETRY}回解決しませんでした" ;;
      *) stop_for_human "$num" "${reason}。自動でやり直しても${MAX_RETRY}回解決しませんでした" ;;
    esac
    return
  fi
  if [ -n "$limit" ]; then
    first="${first:-$now}"
    write_retry_record "$num" "$count" "$kind" "$reason" "$limit" "$first"
    add_label "$num" "ai:retry"
    # 待ちに入った最初の1回だけ通知する
    if [ -z "$(retry_mark_value "$body" limit-first)" ] || [ "$(retry_mark_value "$body" limit-first)" != "$first" ]; then
      notify limit "使用量の上限で待っています" "#${num}：$(limit_until_text "$limit")に自動で再開します。回数は減りません" 2
    fi
    echo "#$num：使用量の上限なので、$(limit_until_text "$limit")まで待ちます（やり直しの回数は使いません）"
    return
  fi
  write_retry_record "$num" "$count" "$kind" "$reason"
  add_label "$num" "ai:retry"
  echo "#$num：${reason}。あとで自動でやり直します（${count}/${MAX_RETRY}回やり直し済み）"
  alert_if_repeated_failures "$num" "$reason"
}

# 静かな失敗に早く気づくため：使用量の上限以外の理由で、直近 REPEAT_WINDOW_MIN 分のうちに
# やり直し待ちになった物が REPEAT_ALERT_AT 件そろったら、1回だけ通知する（仕組みそのものが壊れているかもしれないので）
REPEAT_WINDOW_MIN="${REPEAT_WINDOW_MIN:-60}"
REPEAT_ALERT_AT="${REPEAT_ALERT_AT:-2}"
alert_if_repeated_failures() {
  local num="$1" reason="$2" now n c body updated recent=0 list=""
  now=$(date +%s)
  for n in $(gh api "repos/$REPO/issues?state=open&labels=ai%3Aretry&per_page=100" --paginate -q '.[].number' 2> /dev/null); do
    c=$(retry_comment "$n")
    [ -z "$c" ] && continue
    body=$(printf '%s' "$c" | jq -r '.body // ""')
    # 使用量の上限の待ちは、別の通知（limit）があるので数えない
    [ -n "$(retry_mark_value "$body" limit-until)" ] && continue
    updated=$(date -d "$(printf '%s' "$c" | jq -r '.updated_at')" +%s 2> /dev/null || echo 0)
    if [ $(( now - updated )) -le $(( REPEAT_WINDOW_MIN * 60 )) ]; then
      recent=$((recent + 1)); list="${list} #${n}"
    fi
  done
  if [ "$recent" -eq "$REPEAT_ALERT_AT" ]; then
    notify repeat_fail "AIの失敗が続いています" "${list# }：${reason}。仕組みの不調かもしれません。確認してください" 4
    echo "失敗が ${recent} 件続いたので通知しました"
  fi
}


# 上限の待ちの表示用（日本時間）
limit_until_text() {
  if [ "$1" = "unknown" ]; then
    echo "${LIMIT_UNKNOWN_WAIT_MIN}分後"
  else
    TZ=Asia/Tokyo date -d "@$1" +"%H:%M ごろ"
  fi
}

# やり直してよくなる時刻（エポック秒）。記録が無ければ 0（すぐ）
#   上限で待っているとき：リセット時刻の1分後か、時刻が分からないときは記録の更新から LIMIT_UNKNOWN_WAIT_MIN 分
#   それ以外：記録の更新から RETRY_COOLDOWN_MIN 分
retry_due_at() {
  local c updated until_at
  c=$(retry_comment "$1")
  if [ -z "$c" ]; then echo 0; return; fi
  until_at=$(retry_mark_value "$(printf '%s' "$c" | jq -r .body)" limit-until)
  if [ -n "$until_at" ] && [ "$until_at" != "unknown" ]; then
    echo $(( until_at + 60 ))
    return
  fi
  updated=$(date -d "$(printf '%s' "$c" | jq -r .updated_at)" +%s)
  if [ "$until_at" = "unknown" ]; then
    echo $(( updated + LIMIT_UNKNOWN_WAIT_MIN * 60 ))
  else
    echo $(( updated + RETRY_COOLDOWN_MIN * 60 ))
  fi
}

# そのコミットの、いちばん新しい CI（PRの物）で失敗したステップの名前を JSON の配列で出す。
# 通っている・まだ動いていない・見つからないときは []。失敗したのにステップが読めないときは ["（読めない）"]（通ったと間違えないように）
ci_failed_steps() {
  local sha="$1" run steps
  run=$(GH_TOKEN="${READ_TOKEN:-$GH_TOKEN}" gh api "repos/$REPO/actions/runs?head_sha=$sha&event=pull_request&per_page=20" \
    -q '[.workflow_runs[] | select(.name == "CI")] | sort_by(.created_at) | last | select(. != null and .conclusion == "failure") | .id' 2> /dev/null) || run=""
  if [ -z "$run" ]; then
    echo '[]'
    return 0
  fi
  steps=$(GH_TOKEN="${READ_TOKEN:-$GH_TOKEN}" gh api "repos/$REPO/actions/runs/$run/jobs?per_page=50" \
    -q '[.jobs[].steps[] | select(.conclusion == "failure") | .name]' 2> /dev/null) || steps=""
  if [ -z "$steps" ] || [ "$steps" = "[]" ]; then
    echo '["（読めない）"]'
  else
    echo "$steps"
  fi
}

# ---- 修正AIが変更なしで終わったときの理由の分類（after-mention.sh） ----
# 基準の画像の撮り直しを頼んでいる言い方（AIの返事・レビューの指摘のどちらかにあれば、撮り直しが要る。PRの説明は見ない：CLAUDE.md の指示で visual:update と書くので、読み違える）
VISUAL_HINT_RE='visual:update|基準の?画像.{0,60}(古|撮り直|更新|差し替)|(撮り直|更新|差し替).{0,60}基準の?画像|スナップショット.{0,60}(古|撮り直|更新)|update-snapshots'
# 「指摘が間違い・直す必要が無い」と返している言い方
# 実装AIが「もう直っている（変更は要らない）」と返したか（open-pr.sh）。直せなかった・分からなかった、は含めない
# shellcheck disable=SC2034  # open-pr.sh で使う
ALREADY_FIXED_RE='(すでに|既に).{0,30}(直って|直し済|対応済|修正済|入って|対応されて|修正されて)|直っていた(ため|ので)|(対応|修正)済みのため|already (fixed|resolved|on (this|the) branch|in main)|the fix is already|already (been )?(fixed|addressed)'
# 「もう直っている」と言いつつ、一部だけ・直せていない言い方（これがあるときは閉じない）
# shellcheck disable=SC2034  # open-pr.sh で使う
NOT_FIXED_RE='直せ(ません|なかった|ず)|できません|できなかった|分から|わから|残り|一部|まだ|ただし|しかし|ですが|コンフリクト|未対応|未修正|could not|couldn.t|can.t|cannot|unable|still|but|however|except|partial|remain'
DISAGREE_HINT_RE='指摘は.{0,40}(誤り|間違|当たら|該当しな|不要)|(前回|前の|これまで)の?(対応|修正|直し)で.{0,30}(直し|対応|修正)?(済み|ずみ|ました)|(すでに|既に).{0,20}(直し|対応|修正|書かれ|入っ)(て|済)|(直し|対応|修正)済み|already (fixed|addressed|done)|(直す|修正の?|変更の?)必要(は|が|も)(ない|無い|ありません)|(修正|変更|対応)(は)?不要|直さず|直しません|直さない|false positive|not (a )?(real )?(bug|issue|problem)'
# 許可の拒否で、1回だけ自動でやり直した印（2回目は人間に回す）
# shellcheck disable=SC2034  # after-mention.sh で使う
PERM_RETRY_MARK="<!-- auto-perm-retry -->"

# レビューの指摘が指す場所の判定（AIは .github/workflows/・.github/actions/ を push できないので、そこだけの指摘は修正AIに頼まない）
# 標準入力の文から、ファイルのパスらしい語（/ を含む語）を1行ずつ出す。URLの一部なども拾うが、
# 拾いすぎると「アプリのファイルが混ざっている」側になり、今までどおり修正AIに頼むので安全
review_paths_from_text() {
  { grep -oE '[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+' || true; } | sed -E 's/\.+$//' | awk 'NF' | sort -u
}

# 標準入力のパス（1行に1つ）が、ワークフローの所だけか：
#   workflow  全部 .github/workflows/・.github/actions/ の中（1つ以上）
#   mixed     ワークフローの所と、そのほかが混ざっている
#   other     ワークフローの所が無い（パスが無い場合も）→ 今までどおり修正AIに頼む
review_paths_kind() {
  local wf=0 other=0 p
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$p" in
      .github/workflows/* | .github/actions/*) wf=$((wf + 1)) ;;
      *) other=$((other + 1)) ;;
    esac
  done
  if [ "$wf" -gt 0 ] && [ "$other" -eq 0 ]; then
    echo workflow
  elif [ "$wf" -gt 0 ]; then
    echo mixed
  else
    echo other
  fi
}

# 修正AIが変更なしで終わった理由を、1語で出す。標準入力：AIの返事（この依頼のあとの claude[bot] のコメント）
#   引数1：撮り直しの依頼を探すほかの文（この先頭コミットへのレビューの指摘。PRの説明は渡さない）
#   引数2：実行記録で拒否された操作（denied_tools の出力。無ければ空）
#   引数3：レビューの指摘がワークフローの所を指す物を含むなら 1（review_paths_kind が workflow か mixed）
# 出力（上から順に見る。撮り直しは、それだけで先へ進めるので先に見る）：
#   visual      人間のラベル作業が要る（基準の画像の撮り直し）
#   workflow    ワークフローの指摘が残っている（AIは直せない。AIの返事が「直せない」だけでもこちらを優先）
#   permission  ツールの許可が拒否された
#   disagree    指摘が間違いと返して直さなかった
#   unknown     分類できない
classify_no_change() {
  local ai other="${1:-}" denied="${2:-}" wf="${3:-}"
  ai=$(cat)
  if printf '%s\n%s\n' "$ai" "$other" | grep -qiE "$VISUAL_HINT_RE"; then
    echo visual
  elif [ "$wf" = 1 ]; then
    echo workflow
  elif [ -n "$(printf '%s\n' "$denied" | awk 'NF')" ] || [ -n "$(printf '%s' "$ai" | permission_hints_from_text)" ]; then
    echo permission
  elif printf '%s\n' "$ai" | grep -qiE "$DISAGREE_HINT_RE"; then
    echo disagree
  else
    echo unknown
  fi
}

# 待ち時間が過ぎたか
retry_due() {
  [ "$(date +%s)" -ge "$(retry_due_at "$1")" ]
}

# AI（claude[bot]）がpushしたコミットのCIは、GitHubが「承認待ち（action_required）」で止めることがある。
# そうなっていたら、オーナーのトークンで空のコミットを1つ足して、CIを動かし直す（オーナーのpushなら承認は要らない）。
# READ_TOKEN（ワークフローのトークン、actions: read）でCIの実行を読む
rerun_ci_if_waiting_approval() {
  local pr="$1" sha="$2" branch="$3" runs="[]" pr_json
  # fork からの他人のPRは触らない（同じ名前のブランチに、他人のコミットを入れてしまうため）
  pr_json=$(gh api "repos/$REPO/pulls/$pr" 2> /dev/null) || pr_json=""
  if [ -z "$pr_json" ] || ! pr_head_is_repo "$pr_json"; then
    echo "PR #$pr：head がこのリポジトリではない（fork）か読めないので、何もしません"
    return 0
  fi
  for _ in 1 2 3 4; do
    runs=$(GH_TOKEN="$READ_TOKEN" gh api "repos/$REPO/actions/runs?head_sha=$sha&event=pull_request&per_page=50" \
      -q '[.workflow_runs[] | select(.name == "CI")]')
    [ "$(printf '%s' "$runs" | jq 'length')" -gt 0 ] && break
    sleep 15
  done
  local running waiting
  running=$(printf '%s' "$runs" | jq '[.[] | select(.conclusion != "action_required")] | length')
  waiting=$(printf '%s' "$runs" | jq '[.[] | select(.conclusion == "action_required")] | length')
  if [ "$running" -gt 0 ]; then
    echo "PR #$pr：CIはふつうに動いています"
    return 0
  fi
  echo "PR #$pr：CIが承認待ち（${waiting} 件）か、始まっていないので、空のコミットで動かし直します"
  local tree new
  tree=$(gh api "repos/$REPO/git/commits/$sha" -q .tree.sha)
  new=$(gh api "repos/$REPO/git/commits" -f message="CIを動かし直す（AIのpushでCIが承認待ちになったため）" \
    -f tree="$tree" -f "parents[]=$sha" -q .sha)
  gh api -X PATCH "repos/$REPO/git/refs/heads/$branch" -f sha="$new" > /dev/null
  echo "PR #$pr：$new を足しました"
}

# 企画AIが清書で消した、元の本文の画像（![..](https://…)・<img src="https://…">）を、本文の最後に足し直す。
# 実装AIは、ラベルが付いた時点の本文の画像を見る（issue-images-prompt.sh）ので、消えると見られない。
# 元の本文はワークフローのイベントの物（企画を始めた時点）。足したら 0、足す物が無ければ 1
keep_issue_images() { # issue 元の本文
  local issue="$1" before="$2" after missing
  [ -n "$before" ] || return 1
  after=$(gh api "repos/$REPO/issues/$issue" -q '.body // ""' 2> /dev/null) || return 1
  missing=$(BEFORE="$before" AFTER="$after" python3 -c '
import os, re
pat = re.compile(r"!\[[^\]]*\]\((https://[^\s)]+)[^)]*\)|<img[^>]*\bsrc=[\"\x27](https://[^\"\x27\s>]+)[^>]*>", re.I)
after = os.environ["AFTER"]
out = []
for m in pat.finditer(os.environ["BEFORE"]):
    url = m.group(1) or m.group(2)
    if url not in after and m.group(0) not in out:
        out.append(m.group(0))
print("\n".join(out))
')
  [ -n "$missing" ] || return 1
  gh api -X PATCH "repos/$REPO/issues/$issue" -f body="${after}

### 貼られた画像
${missing}" > /dev/null || return 1
  echo "#$issue：清書で消えた画像を、本文の最後に足し直しました"
}

# ---- レビューAIを CI と同時に動かす（#119） ----
# PRができた・AIが直して push した時点で、CIの結果を待たずにレビューAIを始める（CIの中央値 2.8分を待たない）。
# CIとレビューのどちらが後に終わっても、後の方（after-ci.sh・after-review.sh）がマージへ進める。
# 2つは同じ concurrency（pipeline-<ブランチ>）で順に動くので、二重にマージしない。

# いまの先頭コミットへのレビューの状態：running（動いている）／done（結果のコメントがある・レビューAIが動けないと知らせてある）／none
# 動いているかを先に見る。同じコミットを2回目にレビューしている間（after-mention の disagree など）に、
# 前の回の結果のコメントで done としないように（レビューは PR ごとに1つだけ動くので、動いている物がいちばん新しい）
review_state() { # PR番号 先頭コミット
  local pr="$1" sha="$2" head_date runs
  runs=$(read_api "repos/$REPO/actions/workflows/claude-review.yml/runs?head_sha=$sha&per_page=20" \
    -q '[.workflow_runs[] | select(.status != "completed")] | length') || runs=0
  if [ "${runs:-0}" -gt 0 ]; then
    echo running
    return
  fi
  head_date=$(gh api "repos/$REPO/commits/$sha" -q .commit.committer.date)
  if all_comments "$pr" | jq -e --arg since "$head_date" --arg mk "$REVIEW_UNAVAILABLE_MARK $sha" \
    'any(.[]; ((.user.login == "claude[bot]" or .user.login == "github-actions[bot]") and (.body | startswith("## Code review")) and .created_at >= $since) or (.body | contains($mk)))' > /dev/null; then
    echo "done"
  else
    echo none
  fi
}

# CIが落ちたとき、同じ先頭コミットに動いているレビューAIを取り消す（直したあとに、CIとレビューがもう一度動く）。
# 取り消しには actions: write の鍵が要る（ワークフローの鍵 READ_TOKEN。after-ci のジョブが渡す）。取り消せなくても止めない
cancel_running_review() { # PR番号 先頭コミット
  local pr="$1" sha="$2" id n=0
  for id in $(read_api "repos/$REPO/actions/workflows/claude-review.yml/runs?head_sha=$sha&per_page=20" \
    -q '.workflow_runs[] | select(.status != "completed") | .id'); do
    if GH_TOKEN="${READ_TOKEN:-${GH_TOKEN:-}}" gh api -X POST "repos/$REPO/actions/runs/$id/cancel" > /dev/null 2>&1; then
      n=$((n + 1))
    fi
  done
  # 結果を待つ印を外す（見張り役が「レビューの結果が出ない」と数えないように）
  remove_label "$pr" "ai:review" 2> /dev/null || true
  [ "$n" -gt 0 ] && echo "PR #$pr：CIが落ちたので、動いていたレビューAIを取り消しました（${n} 件）"
  return 0
}

# この先頭コミットに、直すよう頼んであって、まだ終わっていない依頼があるか（CIとレビューの両方が同じコミットに頼んで、修正AIが2つ同時に動かないように）
# 終わった依頼（その依頼のコメントより後に、修正AIの「Claude finished」の返事がある）は数えない。
# 修正AIが push せずに終わり、同じコミットをもう一度レビューする流れで、止まらないように
fix_requested_for() { # PR番号 先頭コミット
  all_comments "$1" | jq -e --arg mark "$AUTO_FIX_MARK" --arg sha "<!-- auto-fix-sha: $2 -->" \
    '. as $all | any($all[] | select((.body | contains($mark)) and (.body | contains($sha))) | .created_at as $t
      | ([$all[] | select(.user.login == "claude[bot]" and (.body | startswith("## Code review") | not)
          and (.body | contains("Claude finished")) and .created_at >= $t)] | length == 0); .)' > /dev/null
}
