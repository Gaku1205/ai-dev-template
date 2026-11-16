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

has_label() {
  gh api "repos/$REPO/issues/$1/labels" -q '.[].name' | grep -qx "$2"
}

comment() {
  gh api "repos/$REPO/issues/$1/comments" -f body="$2" > /dev/null
}

# コメントを全部（ページをまたいで）1つの配列で出す
all_comments() {
  gh api "repos/$REPO/issues/$1/comments?per_page=100" --paginate --slurp | jq 'add // []'
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
  gh api "repos/$REPO/issues?state=open&per_page=100&labels=$(urlencode "$1")" \
    -q '[.[] | select(.pull_request | not)] | length'
}

count_open_prs() {
  gh api "repos/$REPO/pulls?state=open&per_page=100" -q 'length'
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

# Issue を作った人を、そのまま自動で動かしてよいか：オーナーと、このパイプラインのワークフロー（企画AIが分けて作る Issue は
# github-actions[bot]、AI自身は claude[bot]）だけ。公開リポジトリでは誰でも Issue を作れるので、ほかの人・ほかのボットの Issue は
# オーナーが ai:skip を外すまで動かさない（intake.sh・watchdog.sh）
trusted_author() {
  case "${1,,}" in
    "${OWNER,,}" | "claude[bot]" | "github-actions[bot]") return 0 ;;
  esac
  return 1
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
#   使い方：merge_or_handle PR番号 先頭コミット 種類（mark_for_retry に渡す）。マージできたら 0、できなければ 1
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
    mark_for_retry "$pr" "$kind" "自動でマージできませんでした（状態：${state}。$(printf '%s' "$out" | tail -n 1 | cut -c1-160)）"
    echo "PR #$pr：マージできなかったので、やり直し待ちにしました（状態：${state}）"
  fi
  return 1
}

# ---- 順番待ち（ai:queue）を進める ----
# 企画AIが本文に書く「触るファイル」の印：<!-- ai-touches: src/lib/a.ts, src/components/ --> （/ で終わる物はフォルダ）
TOUCHES_MARK_RE='<!-- ai-touches: ([^>]*) -->'
# 同時に動かす実装の上限（after-plan.sh と同じ）
MAX_PARALLEL="${MAX_PARALLEL:-2}"
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

# 進行中の作業が触っているファイル。1行目に「unknown」が出たら、分からない物がある（並列にしない）
# 実装中の Issue は本文の印、open のPRは変えたファイル（AI以外のPR＝配布・依存の更新なども含む）
inflight_touches() {
  local n body t pr files impl pulls
  # 一覧を読めなかったら、分からない物があるとして待つ（空の一覧とみなさない）
  impl=$(gh api "repos/$REPO/issues?state=open&per_page=100&labels=ai%3Aimplement" -q '.[] | select(.pull_request | not) | .number' 2> /dev/null) || { echo unknown; return 0; }
  pulls=$(gh api "repos/$REPO/pulls?state=open&per_page=100" -q '.[] | "\(.number) \(.head.ref)"' 2> /dev/null) || { echo unknown; return 0; }
  for n in $impl; do
    # PRがもうあれば、PRの変えたファイルで数える（下）
    if printf '%s\n' "$pulls" | grep -q " claude/issue-$n-"; then continue; fi
    body=$(gh api "repos/$REPO/issues/$n" -q '.body // ""' 2> /dev/null) || { echo unknown; continue; }
    t=$(touches_from_body "$body")
    if [ -z "$t" ]; then echo unknown; else printf '%s\n' "$t"; fi
  done
  for pr in $(printf '%s\n' "$pulls" | cut -d' ' -f1); do
    files=$(gh api "repos/$REPO/pulls/$pr/files?per_page=100" -q '.[].filename' 2> /dev/null) || { echo unknown; continue; }
    printf '%s\n' "$files"
  done
}

# 順番待ち（ai:queue）から、次に実装に回す物を選んで始める。
# - 進行中の物が無ければ、先頭の1つ（priority:high が付いた物を先に、その中は番号の小さい順）
# - 進行中の物があっても、上限（MAX_PARALLEL）に達しておらず、触るファイルが進行中の物と重ならない物は、並べて始める
#   （触るファイルが分からない物・進行中の物に分からない物があるときは、今までどおり待つ。見た目のテストがあれば画面どうしも待つ）
# 止まっている物（ai:stuck）は数えない（企画で止まった物はコードに触れていない）
start_next_in_queue() {
  local busy stuck prs inflight queue n body t rc started=0 screen=0
  busy=$(count_open_issues_with_label "ai:implement") || return 1
  stuck=$(count_open_issues_with_label "ai:stuck") || return 1
  prs=$(count_open_prs) || return 1
  echo "実装中 ${busy} / 停止中 ${stuck}（数えない） / openのPR ${prs}（並列の上限 ${MAX_PARALLEL}）"
  queue=$(gh api "repos/$REPO/issues?state=open&per_page=100&labels=ai%3Aqueue" \
    -q '[.[] | select(.pull_request | not) | {n: .number, p: ([.labels[].name] | index("priority:high") != null)}] | sort_by((if .p then 0 else 1 end), .n) | .[].n') || return 1
  if [ -z "$queue" ]; then
    echo "順番待ちはありません"
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
  if repo_has_visual_tests; then screen=1; fi
  for n in $queue; do
    if [ $((busy + started)) -ge "$MAX_PARALLEL" ]; then
      echo "並列の上限（${MAX_PARALLEL}）なので、ここまでにします"
      break
    fi
    body=$(gh api "repos/$REPO/issues/$n" -q '.body // ""') || continue
    t=$(touches_from_body "$body")
    if [ -z "$t" ]; then
      echo "#$n：触るファイルが分からないので、進行中の物が終わるまで待ちます"
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
      inflight="$inflight
$t"
    fi
  done
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
# 上限（MAX_RETRY）を超えたら人間に回す。kind：plan / implement（Issue）、review / mention（PR）

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

# 許可の不足を、記録用のIssue（閉じたまま）にコメントで残し、同じ不足が2回目なら、直すためのIssueを自動で作る
#   使い方：report_permission_gap 番号 "許可の書き方（改行区切り）"
report_permission_gap() {
  local from="$1" keys key ledger n title existing created
  # 1回に記録するのは最初の PERM_REPORT_MAX 件まで（多すぎると、1件ずつのAPI呼び出しでジョブが時間切れになる）
  keys=$(printf '%s\n' "$2" | awk 'NF' | head -n "${PERM_REPORT_MAX:-3}")
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    ledger=$(gh api "repos/$REPO/issues?state=all&per_page=100" -q ".[] | select(.title == \"$PERM_LEDGER_TITLE\") | .number" | head -1) || return 0
    if [ -z "$ledger" ]; then
      ledger=$(gh api -X POST "repos/$REPO/issues" -f title="$PERM_LEDGER_TITLE" \
        -f body="AIが「許可されていない操作」で止まったときの記録です（自動）。同じ不足が2回起きたら、直すためのIssueを自動で作ります。このIssueは閉じたままにしてください。" -q .number) || return 0
      gh api -X PATCH "repos/$REPO/issues/$ledger" -f state=closed > /dev/null || true
    fi
    comment "$ledger" "<!-- perm-gap: ${key} -->
#${from} で、AIが許可されていない操作を試して止まりました：\`${key}\`" || true
    n=$(all_comments "$ledger" | jq --arg k "<!-- perm-gap: ${key} -->" '[.[] | select(.body | contains($k))] | length')
    if [ "${n:-0}" -ge 2 ]; then
      title="AIの許可が足りない：${key}"
      existing=$(gh api "repos/$REPO/issues?state=open&per_page=100" -q ".[] | select(.title == \"$title\") | .number" | head -1)
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
      plan | implement) stop_issue_for_human "$num" "${reason}。自動でやり直しても${MAX_RETRY}回解決しませんでした" ;;
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
  for n in $(gh api "repos/$REPO/issues?state=open&labels=ai%3Aretry&per_page=100" -q '.[].number' 2> /dev/null); do
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
# 基準の画像の撮り直しを頼んでいる言い方（AIの返事・レビューの指摘・PRの説明のどれかにあれば、撮り直しが要る）
VISUAL_HINT_RE='visual:update|基準の?画像.{0,60}(古|撮り直|更新|差し替)|(撮り直|更新|差し替).{0,60}基準の?画像|スナップショット.{0,60}(古|撮り直|更新)|update-snapshots'
# 「指摘が間違い・直す必要が無い」と返している言い方
DISAGREE_HINT_RE='指摘は.{0,40}(誤り|間違|当たら|該当しな|不要)|(前回|前の|これまで)の?(対応|修正|直し)で.{0,30}(直し|対応|修正)?(済み|ずみ|ました)|(すでに|既に).{0,20}(直し|対応|修正|書かれ|入っ)(て|済)|(直し|対応|修正)済み|already (fixed|addressed|done)|(直す|修正の?|変更の?)必要(は|が|も)(ない|無い|ありません)|(修正|変更|対応)(は)?不要|直さず|直しません|直さない|false positive|not (a )?(real )?(bug|issue|problem)'
# 許可の拒否で、1回だけ自動でやり直した印（2回目は人間に回す）
# shellcheck disable=SC2034  # after-mention.sh で使う
PERM_RETRY_MARK="<!-- auto-perm-retry -->"

# 修正AIが変更なしで終わった理由を、1語で出す。標準入力：AIの返事（この依頼のあとの claude[bot] のコメント）
#   引数1：撮り直しの依頼を探すほかの文（この先頭コミットへのレビューの指摘と、PRの説明）
#   引数2：実行記録で拒否された操作（denied_tools の出力。無ければ空）
# 出力（上から順に見る。撮り直しは、それだけで先へ進めるので先に見る）：
#   visual      人間のラベル作業が要る（基準の画像の撮り直し）
#   permission  ツールの許可が拒否された
#   disagree    指摘が間違いと返して直さなかった
#   unknown     分類できない
classify_no_change() {
  local ai other="${1:-}" denied="${2:-}"
  ai=$(cat)
  if printf '%s\n%s\n' "$ai" "$other" | grep -qiE "$VISUAL_HINT_RE"; then
    echo visual
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
  local pr="$1" sha="$2" branch="$3" runs="[]"
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
