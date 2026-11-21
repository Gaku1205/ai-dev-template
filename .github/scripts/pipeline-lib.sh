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
# 同じ指摘が続いた回数ではなく、直す依頼の全部の回数の上限（毎回ちがう指摘が出続けて終わらないのを防ぐ）
MAX_AUTO_FIX_TOTAL="${MAX_AUTO_FIX_TOTAL:-8}"
AUTO_FIX_MARK="<!-- auto-fix -->"
# main とのコンフリクトの解消をAIに頼める回数の上限。直す回数（MAX_AUTO_FIX＋強いモデルの1回）とは別に数える
# （並列で main が進むたびに、PRの中身と関係なく直す回数が減って、本物の指摘を直せずに止まらないように。agent-desk PR #528）
MAX_CONFLICT_FIX="${MAX_CONFLICT_FIX:-3}"
# コンフリクトの解消の依頼に付ける印（count_auto_fix が種類ごとに数える）
CONFLICT_KIND_MARK="<!-- auto-fix-kind: conflict -->"
# 基準の画像だけのコンフリクトを、AIを呼ばずにパイプラインが解いた印（先頭コミットごと。同じ先頭で2回は試さない）
CONFLICT_IMAGES_MARK="auto-conflict-images:"
RESUME_MARK="<!-- auto-resume -->"
# shellcheck disable=SC2034  # after-ci.sh など、この下を読み込む側のスクリプトで使う
VISUAL_MARK="<!-- auto-visual-update -->"
# 修正AI（claude-code-action）が、何もせずに終わったときの返事：依頼のコメントのあとに PR が更新されている（別の push が先に入った）と、
# 「PR #N was updated after the trigger (…). Mention Claude again to run on the latest version.」とだけ書いて終わる。
# その依頼は動いていないので、直す回数に数えず、最新のコミットで出し直す（reissue_stale_fix）。
# 出し直しは、人間が ai:stuck を外した後で MAX_STALE_FIX 回まで（続くなら、何かが同じブランチを動かし続けている）
STALE_FIX_RE='was updated after the trigger'
MAX_STALE_FIX="${MAX_STALE_FIX:-3}"
# jq の部品：動かなかった依頼のコメントの id の一覧（stale_ids。--arg stale に STALE_FIX_RE を渡す）。
# 返事に書かれた時刻（依頼のコメントの時刻）で依頼を見つける。見つからなければ、その返事の直前の依頼
# shellcheck disable=SC2016 # jq の式（$all などは jq の変数）
STALE_FIX_JQ='def stale_ids: . as $all
  | [$all[] | select(.user.login == "claude[bot]" and (.body | test($stale))) | . as $r
      | [$all[] | select((.body | test("<!-- auto-fix(-retry)? -->")) and .created_at <= $r.created_at)] as $reqs
      | ([$reqs[] | select(.created_at as $t | $r.body | contains($t))] | last // ($reqs | last)) | .id // empty];
'
# 他の Issue・PR の完了待ち（ai:blocked）で、待ち先を書くコメントの印（待ち先ごとに1つ：<!-- blocked-by: owner/repo#N -->）
# shellcheck disable=SC2034  # after-plan.sh・watchdog.sh で使う
BLOCKED_MARK_RE='<!-- blocked-by: ([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+) -->'
# レビューAIが動けないPR（レビューのワークフロー自体を変えるPR）を、人間のマージ待ちにした印（after-review.sh が書き、watchdog.sh が「待っている」と読む）
# 先頭コミットごとに書く：<!-- review-unavailable: 先頭コミット -->（新しいコミットが入れば、もう一度確かめる）
# shellcheck disable=SC2034  # after-review.sh・watchdog.sh で使う
REVIEW_UNAVAILABLE_MARK="review-unavailable:"
# shellcheck disable=SC2034  # after-ci.sh で使う
PIPELINE_TEST_MARK="<!-- auto-pipeline-test-rerun -->"
# パイプライン自体の確認の手順の名前（ci.yml の手順の name と同じ。食い違うと tests/test-workflows.sh が落ちる）
PIPELINE_CHECK_STEPS='["スクリプトのテスト","shellcheck","ワークフローの確認（actionlint）"]'
# 外の障害（Ubuntu のミラーなど）で落ちうる手順の名前（ブラウザ・依存を入れる所。ci.yml の手順の name と同じ。食い違うと tests/test-workflows.sh が落ちる）
NETWORK_CHECK_STEPS='["見た目のテスト用のブラウザを入れる","実行環境をそろえる"]'
# 外の障害のとき、ジョブのログに出る言葉（grep -E の形）
NETWORK_FAILURE_RE='Failed to fetch|ETIMEDOUT|ECONNRESET|Could not resolve host|Temporary failure|Could not wait for server fd'
# 外の障害で落ちたCIをやり直した印（コミットごとに数える。PIPELINE_TEST_MARK とは別。直す回数には数えない）
# shellcheck disable=SC2034  # after-ci.sh で使う
NETWORK_RERUN_MARK="<!-- auto-network-rerun -->"
# 外の障害でのやり直しの上限（コミットごと）
NETWORK_RERUN_MAX=2
# 見た目以外の失敗だけを直すよう頼んだ依頼の印（after-mention.sh。同じ依頼で変更なしが続いたら人間に回す）
# shellcheck disable=SC2034  # after-mention.sh で使う
VISUAL_OTHERS_MARK="<!-- auto-fix-nonvisual -->"
# パイプライン側のテストが落ちたとき、テンプレートに作る（足す）Issue の題名
PIPELINE_TEST_ISSUE_TITLE="パイプライン側のテストが落ちている（たまに落ちる・壊れている）"
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

# ---- 開いている Issue・PR の写し（GitHub API の回数を減らす） ----
# 見張り役・順番待ちは、1回の実行で「ai:○○ が付いた Issue の一覧」「このPRに ai:○○ が付いているか」を何十回も読む。
# どれも「開いている Issue・PR の一覧」（ラベル・本文つき）1回ぶんから分かるので、use_open_snapshot を呼んだスクリプトでは、
# 最初に一覧を1回ずつ読んで写しを持ち、その実行の間は写しから答える（パイプラインの鍵は、全部のリポジトリで1時間5000回を分け合う。
# 開いているPRが6つのリポジトリで、見張り1回が約170回 → 約30回になる）。
#   ・このスクリプト自身のラベルの付け外し（add_label・remove_label・take_label）は、写しにも反映する
#   ・ラベルを外せたか分からないとき（404 以外の失敗）は、写しを捨てて、その後は今までどおり API から読む
#   ・別のスクリプトを呼んだあと（after-ci.sh など。その中の付け外しは写しに入らない）は、use_open_snapshot で読み直す
#   ・呼んでいないスクリプト（進行役など）は、今までどおり毎回 API から読む
# 写しは実行の最初の時点の物なので、実行の途中（長くて1〜2分）に人間やほかのワークフローが付けたラベルは、次の実行で見る。
# 順番待ちを始める所（take_label）と、止まりの判定の更新時刻（issue_idle_min）は、写しを使わず毎回 API で確かめる
OPEN_ITEMS=""     # GET issues?state=open の全部（PRを含む）。空なら写しなし
OPEN_PULLS=""     # GET pulls?state=open の全部
HOLD_PRS_MEMO=""  # hold_prs の結果（写しがある間だけ使い回す）
HOLD_PRS_READY=""

# 写しを読む。読めなければ写しなし（今までどおり API から読む）で 1
use_open_snapshot() {
  local items pulls
  drop_open_snapshot
  items=$(api_list "repos/$REPO/issues?state=open&per_page=100" 2> /dev/null) || return 1
  pulls=$(api_list "repos/$REPO/pulls?state=open&per_page=100" 2> /dev/null) || return 1
  printf '%s' "$items" | jq -e 'type == "array"' > /dev/null 2>&1 || return 1
  printf '%s' "$pulls" | jq -e 'type == "array"' > /dev/null 2>&1 || return 1
  OPEN_ITEMS="$items"
  OPEN_PULLS="$pulls"
}

drop_open_snapshot() {
  OPEN_ITEMS=""
  OPEN_PULLS=""
  HOLD_PRS_MEMO=""
  HOLD_PRS_READY=""
}

# 写しの中の Issue・PR のラベルを、1行に1つ出す。写しが無い・その番号が写しに無い（閉じている・あとから作られた）なら 1
snapshot_labels() {
  [ -n "$OPEN_ITEMS" ] || return 1
  printf '%s' "$OPEN_ITEMS" | jq -er --arg n "$1" \
    'map(select((.number | tostring) == $n))[0] | if . == null then false else ((.labels // []) | map(.name) | join("\n")) end' 2> /dev/null
}

# 写しのラベルを書き換える（番号 ラベル add|remove）。書き換えられなければ写しを捨てる
snapshot_set_label() {
  [ -n "$OPEN_ITEMS" ] || return 0
  local next
  if next=$(printf '%s' "$OPEN_ITEMS" | jq -c --arg n "$1" --arg l "$2" --arg op "$3" '
      map(if (.number | tostring) == $n
          then .labels = (((.labels // []) | map(select(.name != $l))) + (if $op == "add" then [{name: $l}] else [] end))
          else . end)' 2> /dev/null) && [ -n "$next" ]; then
    OPEN_ITEMS="$next"
  else
    drop_open_snapshot
  fi
  # 人間のマージ待ち（ai:hold）の判定が変わるので、覚えた結果は捨てる
  if [ "$2" = "ai:hold" ]; then HOLD_PRS_MEMO="" HOLD_PRS_READY=""; fi
  return 0
}

# ラベルを外した結果を写しに反映する（番号 ラベル 終了コード エラーの文）。外せた・もともと付いていない（404）なら写しからも外す。
# ほかの失敗（通信・GitHub 側のエラー）は、付いているか分からないので写しを捨てる
snapshot_after_remove() {
  if [ "$3" -eq 0 ] || grep -q 'HTTP 404' <<< "$4"; then
    snapshot_set_label "$1" "$2" remove
  else
    drop_open_snapshot
  fi
  return 0
}

# 開いている Issue・PR のうち、ラベルが付いた物の配列（JSON。PRを含む）。ラベルが空なら全部。読めなければ失敗
open_items_json() {
  local label="${1:-}"
  if [ -n "$OPEN_ITEMS" ]; then
    if [ -z "$label" ]; then printf '%s\n' "$OPEN_ITEMS"; else
      printf '%s' "$OPEN_ITEMS" | jq -c --arg l "$label" 'map(select(any(.labels[]?; .name == $l)))'
    fi
    return
  fi
  if [ -z "$label" ]; then api_list "repos/$REPO/issues?state=open&per_page=100"; else
    api_list "repos/$REPO/issues?state=open&per_page=100&labels=$(urlencode "$label")"
  fi
}

# ラベルが付いた、開いている Issue の番号を1行に1つ出す。第2引数が all なら PR も含める。読めなければ失敗
open_numbers_with_label() {
  local json
  json=$(open_items_json "$1") || return 1
  if [ "${2:-}" = all ]; then
    printf '%s' "$json" | jq -r '.[].number'
  else
    printf '%s' "$json" | jq -r '.[] | select(.pull_request | not) | .number'
  fi
}

# 開いているPRの配列（JSON）。読めなければ失敗
open_pulls_json() {
  if [ -n "$OPEN_PULLS" ]; then printf '%s\n' "$OPEN_PULLS"; return; fi
  api_list "repos/$REPO/pulls?state=open&per_page=100"
}

# Issue の本文。写しにあれば写しから（無ければ API）。読めなければ失敗
issue_body() {
  if [ -n "$OPEN_ITEMS" ]; then
    printf '%s' "$OPEN_ITEMS" | jq -er --arg n "$1" \
      'map(select((.number | tostring) == $n))[0] | if . == null then false else (.body // "") end' 2> /dev/null && return 0
  fi
  gh api "repos/$REPO/issues/$1" -q '.body // ""'
}

add_label() {
  gh api "repos/$REPO/issues/$1/labels" -f "labels[]=$2" > /dev/null || return
  snapshot_set_label "$1" "$2" add
}

# 付いていなくてもエラーにしない
remove_label() {
  local err rc=0
  err=$(gh api -X DELETE "repos/$REPO/issues/$1/labels/$(urlencode "$2")" 2>&1 > /dev/null) || rc=$?
  snapshot_after_remove "$1" "$2" "$rc" "$err"
  return 0
}

# ラベルを「取る」：自分が外せたときだけ成功（もう外れていたら失敗）。同時に動いた2つの処理の片方だけを進めるのに使う
take_label() {
  local err rc=0
  err=$(gh api -X DELETE "repos/$REPO/issues/$1/labels/$(urlencode "$2")" 2>&1 > /dev/null) || rc=$?
  snapshot_after_remove "$1" "$2" "$rc" "$err"
  return "$rc"
}

# ラベルが付いているか：付いている 0、付いていない 1、読めなかった 2（API の一時的なエラーなど）。
# 読めなかったのを「付いていない」と取り違えないように、戻り値を分ける。ai:stuck・ai:skip のように「付いていたら触らない」
# 確かめには、下の has_label_or_unreadable を使う（読めなければ、付いているものとして触らない）。
# 写し（use_open_snapshot）があって、その番号が写しにあれば、API を呼ばずに写しから答える
has_label() {
  local labels
  if labels=$(snapshot_labels "$1"); then
    grep -qxF -- "$2" <<< "$labels"
    return
  fi
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
  open_items_json "$1" | jq '[.[] | select(.pull_request | not)] | length'
}

count_open_prs() {
  open_pulls_json | jq 'length'
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
  # 通知は、まだ ai:skip が付いていないとき（初めて呼ばれたとき）だけ1回鳴らす。マージの通知は既定では鳴らないので、人間の番だと分かるように
  local first=""
  has_label "$issue" "ai:skip" || first=1
  for l in ai:plan ai:implement ai:review ai:retry ai:queue; do remove_label "$issue" "$l"; done
  add_label "$issue" "ai:skip" || true
  [ -z "$first" ] || notify stuck "確認が必要です" "#${issue}：PR #${pr} の『人間にお願いしたいこと』を当ててください" 4
  echo "PR #${pr}：マージされたので、#${issue} は人間が閉じるまで ai:skip で待たせます"
}

# Issue の一部だけを直したPR（本文に Refs #N があり、Closes/Fixes/Resolves #N が無い）がマージされたら、
# Issue #N に「残り」を書いて、ai:implement・ai:retry を外し、ai:queue で順番待ちに戻す（同じ Issue の続きを次の実装AIがやる）。
# 残りは、PRの説明の受け入れ条件のうち、チェックの付いていない行（- [ ]）。取れなければ「PR の説明を見て続ける」。
# 同じ Issue で3回目の Refs のマージ（PRごとの印 <!-- refs-merge-pr: #PR番号 --> が3個目）は、続けず stop_issue_for_human で人間に回す。
# 『人間にお願いしたいこと』の節があるPR・マージされていないPR・閉じた Issue・印のあるPRでは何もしない（戻り値 1）。何度呼んでも同じ。
# 戻り値：処理した 0、何もしなかった 1。使い方：requeue_issue_after_partial_merge PR番号
REFS_MERGE_STOP_COUNT=3
requeue_issue_after_partial_merge() {
  local pr="$1" pr_json body issue mark state count rest url l
  pr_json=$(gh api "repos/$REPO/pulls/$pr") || return 1
  [ -n "$(printf '%s' "$pr_json" | jq -r '.merged_at // empty')" ] || return 1
  body=$(printf '%s' "$pr_json" | jq -r '.body // ""')
  printf '%s\n' "$body" | grep -qE "$HUMAN_REQUEST_HEADING_RE" && return 1
  printf '%s' "$body" | grep -qiE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' && return 1
  issue=$(printf '%s' "$body" | grep -oiE 'refs #[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  [ -n "$issue" ] || return 1
  state=$(gh api "repos/$REPO/issues/$issue" -q .state 2> /dev/null) || return 1
  [ "$state" = open ] || return 1
  mark="<!-- refs-merge-pr: #${pr} -->"
  local comments
  comments=$(all_comments "$issue") || return 1
  printf '%s' "$comments" | jq -e --arg m "$mark" 'any(.[]; .body | contains($m))' > /dev/null && return 1
  url="${GITHUB_SERVER_URL:-https://github.com}/${REPO}/pull/${pr}"
  # 人間待ち（ai:skip）の Issue は、順番待ちに戻さない（戻すと「始めます」と言うだけで実装が始まらず、黙って止まる）
  local skipmark="<!-- refs-merge-skip-pr: #${pr} -->" rc=0
  has_label "$issue" "ai:skip" || rc=$?
  if [ "$rc" -eq 2 ]; then return 1; fi
  if [ "$rc" -eq 0 ]; then
    printf '%s' "$comments" | jq -e --arg m "$skipmark" 'any(.[]; .body | contains($m))' > /dev/null && return 1
    comment "$issue" "PR #${pr}（${url}）がマージされました。この Issue は人間の作業待ち（ai:skip）なので、順番待ちには戻しません。

${skipmark}" || return 1
    echo "PR #${pr}：#${issue} は人間待ち（ai:skip）なので、順番待ちには戻しませんでした"
    return 0
  fi
  count=$(printf '%s' "$comments" | jq '[.[] | select(.body | test("<!-- refs-merge-pr: #[0-9]+ -->"))] | length')
  count=$((count + 1))
  if [ "$count" -ge "$REFS_MERGE_STOP_COUNT" ]; then
    comment "$issue" "PR #${pr}（${url}）がマージされました。一部だけを直すPR（Refs）が ${count} 回続きました。

${mark}" || return 1
    stop_issue_for_human "$issue" "一部だけを直すPR（Refs）のマージが ${count} 回続きました。同じ所を回り続けないよう、続けずに止めました。PR #${pr} の説明と Issue の残りを見てください"
    return 0
  fi
  rest=$(printf '%s\n' "$body" | sed -nE 's/^[[:space:]]*[-*] \[ \] (.+)$/- \1/p')
  if [ -n "$rest" ]; then
    rest="残り：
${rest}"
  else
    rest="残り：PR #${pr} の説明を見て、残りを続ける"
  fi
  comment "$issue" "前の PR #${pr}（${url}）で一部が済みました。同じ Issue の続きとして、残りを次の実装AIが進めます。

${rest}

${mark}" || return 1
  for l in ai:implement ai:retry; do remove_label "$issue" "$l"; done
  add_label "$issue" "ai:queue" || true
  echo "PR #${pr}：一部だけ直したPR（Refs）がマージされたので、#${issue} を残りつきで順番待ちに戻しました"
  return 0
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

# 「再開」の記録（人間が ai:stuck を外したとき resume.sh が書く）より後に、AIに自動で直させた回数。
# 修正AIが「PRが更新されたので動かない」と返した依頼（STALE_FIX_RE）は、何も直していないので数えない。
# 種類ごとに数える：fix（既定。CIの失敗・レビューの指摘など）と conflict（main とのコンフリクトの解消。印 CONFLICT_KIND_MARK）。
#   使い方：count_auto_fix PR番号 [fix|conflict]
count_auto_fix() {
  all_comments "$1" | count_auto_fix_in "${2:-fix}"
}

# count_auto_fix の数え方そのもの（入力から出力が決まる）。標準入力にコメントの配列（JSON）、引数に種類（fix|conflict）
count_auto_fix_in() {
  jq --arg mark "$AUTO_FIX_MARK" --arg kmark "$CONFLICT_KIND_MARK" --arg kind "${1:-fix}" \
    --arg resume "$RESUME_MARK" --arg stale "$STALE_FIX_RE" "$STALE_FIX_JQ"'
    stale_ids as $void
    | (map(select(.body | contains($resume)) | .created_at) | max // "") as $since
    | [.[] | select((.body | contains($mark)) and .created_at > $since) | select(.id as $i | $void | index($i) | not)
        | select((.body | contains($kmark)) == ($kind == "conflict"))] | length'
}

# 指摘の指紋：止めた理由の短い文（human_reason）から作る。同じ指摘なら同じ文字列（空白は1つにそろえる）
fix_key_of() {
  local r
  r=$(printf '%s' "${1:-}" | tr '\r\n' '  ' | sed 's/  */ /g; s/^ //; s/ $//')
  [ -n "$r" ] || r="AIが直せませんでした"
  printf '%s' "$r" | sha1sum | cut -c1-12
}

# 同じ指摘が続いた回数：再開の後で、いちばん新しい依頼から遡って、指紋（auto-fix-key）が引数の指紋と同じ依頼が続いている数。
# 指紋の無い古い依頼は、どの指摘とも同じとして数える。標準入力にコメントの配列（JSON）、引数に指紋（空なら全部同じ＝全部の回数）
count_same_fix_in() {
  jq --arg mark "$AUTO_FIX_MARK" --arg kmark "$CONFLICT_KIND_MARK" --arg key "${1:-}" \
    --arg resume "$RESUME_MARK" --arg stale "$STALE_FIX_RE" "$STALE_FIX_JQ"'
    stale_ids as $void
    | (map(select(.body | contains($resume)) | .created_at) | max // "") as $since
    | [.[] | select((.body | contains($mark)) and .created_at > $since) | select(.id as $i | $void | index($i) | not)
        | select((.body | contains($kmark)) | not)
        | ((.body | capture("<!-- auto-fix-key: (?<k>[0-9a-f]+) -->") | .k) // null)]
    | reverse
    | reduce .[] as $k ({n: 0, go: true};
        if .go and ($k == null or $key == "" or $k == $key) then .n += 1 else .go = false end)
    | .n'
}

count_same_fix() { # PR番号 指紋
  all_comments "$1" | count_same_fix_in "${2:-}"
}

# 見た目のテストの基準の画像の置き場所（glob。1行に1つ）。pipeline.json の visual_baseline（文字列か配列）。無ければ tests/visual/**/*.png
baseline_image_globs() {
  local f="${STACK_FILE:-pipeline.json}" g=""
  if [ -f "$f" ]; then
    g=$(jq -r '.visual_baseline // empty | if type == "array" then .[] else . end | select(type == "string" and . != "")' "$f" 2> /dev/null) || g=""
  fi
  [ -n "$g" ] || g='tests/visual/**/*.png'
  printf '%s\n' "$g"
}

# コンフリクトしたファイルが全部、基準の画像か（入力から出力が決まる）。標準入力にファイルの一覧（1行に1つ）、引数に glob（1行に1つ）。
# 全部が画像なら 0。1つでも画像でない・一覧が空なら 1。glob の ** は0個以上のフォルダ、* と ? はフォルダをまたがない
only_baseline_images() { # glob の一覧
  jq -R -s -e --arg globs "$1" '
    def glob_re: "^" + (gsub("(?<c>[.+()^$|{}\\[\\]\\\\])"; "\\\(.c)")
      | gsub("\\*\\*/"; "\u0001") | gsub("\\*\\*"; "\u0002") | gsub("\\*"; "[^/]*") | gsub("\\?"; "[^/]")
      | gsub("\u0001"; "(.*/)?") | gsub("\u0002"; ".*")) + "$";
    ($globs | split("\n") | map(select(. != "") | glob_re)) as $res
    | (split("\n") | map(select(. != ""))) as $files
    | ($files | length) > 0 and ($res | length) > 0 and all($files[]; . as $f | any($res[]; . as $r | $f | test($r)))' > /dev/null 2>&1
}

# 基準の画像だけのコンフリクトを、AIを呼ばずに解く：main を取り込むマージのコミットを API で作り（画像は main の側を取る）、
# PRのブランチに push してから visual:update で撮り直す（今の自動の撮り直しと同じ流れ）。解けたら 0（何も頼まない）。
# 画像以外も両方で変わっている・読めない・fork のPR・同じ先頭でもう試した、などは 1（呼び出し元が今までどおりAIに頼む）。
# 両方で変わったファイル（merge base からの変更の重なり）をコンフリクトとみなす（本物のコンフリクトより広いので、迷えばAIに回る）
resolve_baseline_conflict() { # PR番号
  local pr="$1" info head ref base mark base_cmp main_cmp main_sha both n tree entries base_tree new_tree new_commit
  info=$(gh api "repos/$REPO/pulls/$pr" 2> /dev/null) || return 1
  pr_head_is_repo "$info" || return 1
  head=$(printf '%s' "$info" | jq -r '.head.sha // ""')
  ref=$(printf '%s' "$info" | jq -r '.head.ref // ""')
  base=$(printf '%s' "$info" | jq -r '.base.ref // "main"')
  [ -n "$head" ] && [ -n "$ref" ] || return 1
  [[ "$ref" == pipeline-sync/* ]] && return 1
  mark="<!-- ${CONFLICT_IMAGES_MARK} ${head} -->"
  all_comments "$pr" | jq -e --arg m "$mark" 'any(.[]; .body | contains($m))' > /dev/null 2>&1 && return 1
  # 先に main の先頭を読み、一覧・木・親を同じコミットにそろえる（読む間に main が進んでも、変更を巻き戻さない）
  main_sha=$(gh api "repos/$REPO/git/ref/heads/$base" -q '.object.sha' 2> /dev/null) || return 1
  [ -n "$main_sha" ] || return 1
  # PRの側の変更（merge base → PRの先頭）と、main の側の変更（merge base → main）
  base_cmp=$(gh api "repos/$REPO/compare/$main_sha...$head" 2> /dev/null) || return 1
  main_cmp=$(gh api "repos/$REPO/compare/$head...$main_sha" 2> /dev/null) || return 1
  # 一覧は300件で切れる。切れていれば重なりが分からないので、AIに任せる
  [ "$(printf '%s' "$base_cmp" | jq '(.files // []) | length')" -lt 300 ] || return 1
  [ "$(printf '%s' "$main_cmp" | jq '(.files // []) | length')" -lt 300 ] || return 1
  both=$(jq -n -r --argjson a "$base_cmp" --argjson b "$main_cmp" '
    def names: [(.files // [])[] | .filename, (.previous_filename // empty)] | unique;
    ($a | names) - (($a | names) - ($b | names)) | .[]') || return 1
  printf '%s\n' "$both" | only_baseline_images "$(baseline_image_globs)" || return 1
  n=$(printf '%s\n' "$both" | awk 'NF' | wc -l | tr -d ' ')
  # main の側で変わったファイルを、main の木の中身（モードも）のまま、PRの先頭の木に重ねる（消えた物は消す）
  tree=$(gh api "repos/$REPO/git/trees/$main_sha?recursive=1" 2> /dev/null) || return 1
  [ "$(printf '%s' "$tree" | jq -r '.truncated // false')" = false ] || return 1
  entries=$(jq -n -c --argjson c "$main_cmp" --argjson t "$tree" '
    ([$t.tree[] | select(.type == "blob") | {key: .path, value: .}] | from_entries) as $m
    | [($c.files // [])[]
        | (if .status == "renamed" and .previous_filename then {path: .previous_filename, mode: "100644", type: "blob", sha: null} else empty end),
          (if .status == "removed" then {path: .filename, mode: "100644", type: "blob", sha: null}
           else ($m[.filename] // null) as $e | if $e then {path: .filename, mode: $e.mode, type: "blob", sha: $e.sha} else error("missing") end end)]') || return 1
  base_tree=$(gh api "repos/$REPO/git/commits/$head" -q '.tree.sha' 2> /dev/null) || return 1
  new_tree=$(jq -n -c --arg b "$base_tree" --argjson e "$entries" '{base_tree: $b, tree: $e}' |
    gh api -X POST "repos/$REPO/git/trees" --input - -q .sha 2> /dev/null) || return 1
  [ -n "$new_tree" ] || return 1
  new_commit=$(jq -n -c --arg t "$new_tree" --arg h "$head" --arg m "$main_sha" --arg base "$base" \
    '{message: ("Merge " + $base + " into PR（基準の画像のコンフリクトは " + $base + " の側を取る。自動）"), tree: $t, parents: [$h, $m]}' |
    gh api -X POST "repos/$REPO/git/commits" --input - -q .sha 2> /dev/null) || return 1
  [ -n "$new_commit" ] || return 1
  # 早送りだけ（force しない）。その間に誰かが push していたら断られるので、AIに任せる
  jq -n -c --arg s "$new_commit" '{sha: $s, force: false}' |
    gh api -X PATCH "repos/$REPO/git/refs/heads/$ref" --input - > /dev/null 2>&1 || return 1
  comment "$pr" "main とのコンフリクトが、見た目のテストの基準の画像（${n}枚）だけだったので、AIを呼ばずに main を取り込みました（画像は main の側を取りました。直す回数にもコンフリクトの回数にも数えません）。このあと基準の画像をCIの環境で撮り直します。

${mark}
${VISUAL_MARK}" || true
  add_label "$pr" "visual:update" || true
  echo "PR #$pr：基準の画像だけのコンフリクト（${n}枚）を、AIを呼ばずに解いて、撮り直しを依頼しました"
  return 0
}

# 「再開」の記録より後に、修正AIが「PRが更新されたので動かない」と返した回数
count_stale_fix() {
  all_comments "$1" | jq --arg resume "$RESUME_MARK" --arg stale "$STALE_FIX_RE" '
    (map(select(.body | contains($resume)) | .created_at) | max // "") as $since
    | [.[] | select(.user.login == "claude[bot]" and (.body | test($stale)) and .created_at > $since)] | length'
}

# PRの説明の中身の目印。AIがコミットを入れず、PRの説明だけを直したかを見分けるのに使う
pr_body_hash() {
  gh api "repos/$REPO/pulls/$1" -q '.body // ""' | sha1sum | cut -c1-12
}

# AIに直させる。上限を超えていたら人間に回す。
#   使い方：request_fix_or_stop PR番号 先頭コミット 依頼の文 [人向けの理由] [種類 fix|conflict]
#   種類 conflict（main とのコンフリクトの解消）は、直す回数ではなく、別の上限（MAX_CONFLICT_FIX）で数える（request_conflict_fix_or_stop）
request_fix_or_stop() {
  local pr="$1" sha="$2" message="$3" human_reason="${4:-}" kind="${5:-fix}"
  local count total model_mark="" note=""
  # 同じ先頭コミットに、まだ終わっていない依頼があれば、重ねて頼まない（回数にも数えない）。
  # CI・レビュー・基準の画像の撮り直し（visual-update.yml）・見張り役のどこから呼ばれても、修正AIが同じコミットで2つ同時に動かないように。
  # 2つ動くと、先に push した方のせいで、後の方は「PRが更新されたので動かない」で終わり、直す回数だけが減る（agent-desk PR #478）
  # 修正AIが終わったあとの処理（after-mention.sh。FIX_RUN_ENDED=1）からの依頼では確かめない：動いていた修正AIは、もう終わっている
  if [ -z "${FIX_RUN_ENDED:-}" ] && fix_requested_for "$pr" "$sha"; then
    echo "PR #$pr：このコミットにはもう直すよう頼んであるので、重ねて頼みません（直した push のあとに、CIとレビューがもう一度動きます）"
    return 0
  fi
  if [ "$kind" = conflict ]; then
    # 基準の画像だけのコンフリクトは、AIを呼ばずに解く（どちらの回数も使わない）
    if resolve_baseline_conflict "$pr"; then
      return 0
    fi
    count=$(count_auto_fix "$pr" conflict)
    if [ "$count" -ge "$MAX_CONFLICT_FIX" ]; then
      human_reason=$(printf '%s' "$human_reason" | tr '\r\n' '  ' | sed 's/  */ /g; s/^ //; s/ $//')
      [ -n "$human_reason" ] || human_reason="main とのコンフリクトが解けませんでした"
      stop_for_human "$pr" "main とのコンフリクトが$((count + 1))回続きました（AIに解消を頼めるのは${MAX_CONFLICT_FIX}回まで。最後の理由：${human_reason}）"
      return
    fi
    comment "$pr" "@claude ${message}

解消したら、確認コマンド（pipeline.json の checks。無ければ型チェック・リント・テスト・ビルド）を全部通してから、このPRのブランチにpushしてください。（自動の依頼・コンフリクトの解消 $((count + 1))/${MAX_CONFLICT_FIX}。直す回数には数えません）

${AUTO_FIX_MARK}
${CONFLICT_KIND_MARK}
<!-- auto-fix-sha: ${sha} -->
<!-- auto-fix-body: $(pr_body_hash "$pr") -->"
    return
  fi
  local all_count fix_key
  all_count=$(count_auto_fix "$pr")
  fix_key=$(fix_key_of "$human_reason")
  # 同じ指摘が続いた回数で数える（指摘が変わったら数え直す）。全部の回数は MAX_AUTO_FIX_TOTAL で別に止める
  count=$(count_same_fix "$pr" "$fix_key")
  # 普通のモデルで MAX_AUTO_FIX 回直しても駄目なら、最後に1回だけ、いちばん強いモデル（opus）で直す
  total=$((MAX_AUTO_FIX + 1))
  # 止めた理由には、AIへの依頼文（message）ではなく、人向けの短い1文を入れる（4番目。改行は空白にして1行にする）
  human_reason=$(printf '%s' "$human_reason" | tr '\r\n' '  ' | sed 's/  */ /g; s/^ //; s/ $//')
  [ -n "$human_reason" ] || human_reason="AIが直せませんでした"
  if [ "$all_count" -ge "$MAX_AUTO_FIX_TOTAL" ] && [ "$count" -lt "$total" ]; then
    stop_for_human "$pr" "直す依頼が${all_count}回になりました（毎回ちがう指摘。PR が大きすぎる見込み。Issue を分けることを考えてください）（最後の理由：${human_reason}）"
    return
  fi
  if [ "$count" -ge "$total" ]; then
    stop_for_human "$pr" "同じ指摘が${total}回（最後の1回は強いモデル）直りませんでした（最後の理由：${human_reason}）"
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
<!-- auto-fix-key: ${fix_key} -->
<!-- auto-fix-sha: ${sha} -->
<!-- auto-fix-body: $(pr_body_hash "$pr") -->${model_mark}"
}

# main とのコンフリクトの解消を頼む（直す回数とは別に、MAX_CONFLICT_FIX 回まで。基準の画像だけならAIを呼ばずに解く）
#   使い方：request_conflict_fix_or_stop PR番号 先頭コミット 依頼の文 [人向けの理由]
request_conflict_fix_or_stop() {
  request_fix_or_stop "$1" "$2" "$3" "${4:-main とのコンフリクトが解けませんでした}" conflict
}

# PR のマージの状態（GitHub が計算し終わるまで少し待つ）：clean / dirty（main と衝突）/ blocked / behind / unknown など
# もう一度レビューに回す（ai:review を付け直すと、labeled イベントでレビューAIが動く）。
# ただし main とコンフリクトしているPRでは、GitHub が pull_request のワークフローを動かさないので、レビューAIは起きない。
# そのまま付け直すと誰も動かずに止まる（tochi-rirekisho PR #5：PRの説明を直した後のレビューが起きず、9時間止まった）。
# コンフリクトしていれば、先にAIに解消させる（直す回数ではなく、コンフリクトの回数に数える。解消して push されると、CIのあとでレビューに回る）
# shellcheck disable=SC2016 # 文の中の `…` はそのまま見せる（コマンドとして動かさない）
CONFLICT_FIX_MSG='main とコンフリクトしていて、このままではCIもレビューも動きません。`git fetch origin main` のあと `git merge origin/main` でコンフリクトを解消してください。両方の変更の意図を残し、どちらかを捨てるときはPRにコメントで理由を書いてください。解消したら確認コマンド（pipeline.json の checks。無ければ型チェック・リント・テスト・ビルド）を全部通して push してください。'
request_review() { # PR番号
  local pr="$1" sha
  if [ "$(pr_merge_state "$pr")" = dirty ]; then
    sha=$(gh api "repos/$REPO/pulls/$pr" -q .head.sha)
    request_conflict_fix_or_stop "$pr" "$sha" "$CONFLICT_FIX_MSG" "main とのコンフリクトが解けませんでした"
    echo "PR #$pr：main とコンフリクトしていてレビューが動かないので、先にAIに解消を依頼しました"
    return 0
  fi
  remove_label "$pr" "ai:review" 2> /dev/null || true
  add_label "$pr" "ai:review"
}

# 最初のレビューをCIのあとに回すか。見た目のテストがあり、PRの本文に visual:update があるPRは、
# ほぼ必ず「CIが見た目のテストだけで落ちる → 基準の画像を撮り直す → CIとレビューを最初から」になり、1回目のレビューは捨てられるため。
# 後回しにするなら 0。見た目のテストは、PRのブランチの package.json（scripts の test:visual）か pipeline.json（checks の run）を API で読んで判断する
# （main を checkout しているので、ブランチの中身は読めない）。読めない・無いときは「無い」と扱い、今までどおり同時に始める
defer_review_for_visual() { # PR番号
  local pr="$1" info ref body pj
  info=$(gh api "repos/$REPO/pulls/$pr" 2> /dev/null) || return 1
  ref=$(printf '%s' "$info" | jq -r '.head.ref // ""') || return 1
  body=$(printf '%s' "$info" | jq -r '.body // ""') || return 1
  printf '%s' "$body" | grep -q 'visual:update' || return 1
  [ -n "$ref" ] || return 1
  pj=$(gh api "repos/$REPO/contents/package.json?ref=$ref" -H "Accept: application/vnd.github.raw" 2> /dev/null) || pj=""
  if [ -n "$pj" ] && [ "$(printf '%s' "$pj" | jq -r '.scripts["test:visual"] != null' 2> /dev/null)" = true ]; then
    echo "PR #$pr：見た目を撮り直す見込みなので、最初のレビューはCIのあとに回します"
    return 0
  fi
  pj=$(gh api "repos/$REPO/contents/pipeline.json?ref=$ref" -H "Accept: application/vnd.github.raw" 2> /dev/null) || pj=""
  if [ -n "$pj" ] && printf '%s' "$pj" | jq -e '[.checks // [] | .[] | .run // "" | select(type == "string" and test("test:visual"))] | length > 0' > /dev/null 2>&1; then
    echo "PR #$pr：見た目を撮り直す見込みなので、最初のレビューはCIのあとに回します"
    return 0
  fi
  return 1
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
    request_conflict_fix_or_stop "$pr" "$sha" "レビューのあとに main が進み、コンフリクトでマージできませんでした。\`git fetch origin main\` のあと \`git merge origin/main\` でコンフリクトを解消してください。両方の変更の意図を残し（docs/spec.md・docs/design.md も両方の決まりを残す）、どちらかを捨てるときはPRにコメントで理由を書いてください。解消したら確認コマンド（pipeline.json の checks。無ければ型チェック・リント・テスト・ビルド）を全部通して push してください。" "main とのコンフリクトが解けませんでした"
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

# いまより後で、いちばん早く並列の上限が変わる時刻（epoch 秒）を出す（純粋な関数。gh は呼ばず、現在時刻は引数）。
# parallel_limit_decide と同じ設定を読む：PARALLEL_NIGHT_HOURS の夜の始まり・終わり（PARALLEL_TZ の時計）と、PARALLEL_OVERRIDE の期限。
# 分からなければ（設定が無い・形が違う・期限切れ）何も出さない
parallel_next_change() {
  local now="$1" tz="${PARALLEL_TZ:-Asia/Tokyo}" best="" t s e b d day0 day1 ov ts
  [[ "$now" =~ ^[0-9]+$ ]] || return 0
  ov="${PARALLEL_OVERRIDE:-}"
  if [[ "$ov" =~ ^[[:space:]]*(night|day)[[:space:]]+until[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]]; then
    ts="${BASH_REMATCH[2]}"
    if [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?(Z|[+-][0-9]{2}:?[0-9]{2})?$ ]] \
      && t=$(TZ="$tz" date -d "$ts" +%s 2> /dev/null) && [ "$t" -gt "$now" ]; then
      best="$t"
    fi
  fi
  if [[ "${PARALLEL_NIGHT_HOURS:-}" =~ ^([0-9]{1,2})-([0-9]{1,2})$ ]]; then
    s=$((10#${BASH_REMATCH[1]})); e=$((10#${BASH_REMATCH[2]}))
    if [ "$s" -le 24 ] && [ "$e" -le 24 ] && [ "$s" -ne "$e" ] && [ $((s % 24)) -ne $((e % 24)) ]; then
      day0=$(TZ="$tz" date -d "@$now" +%Y-%m-%d 2> /dev/null) || day0=""
      day1=$(TZ="$tz" date -d "@$((now + 86400))" +%Y-%m-%d 2> /dev/null) || day1=""
      if [ -n "$day0" ] && [ -n "$day1" ]; then
        for b in $((s % 24)) $((e % 24)); do
          for d in "$day0" "$day1"; do
            t=$(TZ="$tz" date -d "$d $(printf '%02d' "$b"):00" +%s 2> /dev/null) || continue
            [ "$t" -gt "$now" ] || continue
            if [ -z "$best" ] || [ "$t" -lt "$best" ]; then best="$t"; fi
            break
          done
        done
      fi
    fi
  fi
  [ -z "$best" ] || echo "$best"
}

# 上限の数だけ（呼ぶ側が現在時刻を渡す）
parallel_limit() { parallel_limit_decide "$1" | cut -d' ' -f1; }
# 画面は、今の時刻で上限を決める（ここだけが現在時刻を読む）
current_parallel() { parallel_limit_decide "$(date +%s)"; }

# 本文の印から、触るファイルを1行に1つ出す（印が無ければ何も出さない）
touches_from_body() {
  local body="$1" list
  [[ "$body" =~ $TOUCHES_MARK_RE ]] || return 0
  list="${BASH_REMATCH[1]}"
  printf '%s\n' "$list" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's#^\./##' | grep -v '^$' || true
}

# 印の一覧（改行区切り）から、共有の大きなフォルダを1行に1つ出す（広い物が無ければ何も出さない）。
# 広い物＝末尾が / で、深さ（/ で区切った部品の数）が2以下のフォルダ（src/・src/components/・tests/visual/・docs/ など）。
# ファイル・深さ3以上の新しいフォルダ（src/app/(app)/lanes/）は許す。広いフォルダは中の全部と重なり扱いになり、順番待ちを止める
touches_too_broad() {
  local p parts
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$p" in */) ;; *) continue ;; esac
    parts=$(printf '%s' "${p%/}" | tr '/' '\n' | grep -c . || true)
    [ "$parts" -le 2 ] && printf '%s\n' "$p"
  done <<< "$1"
  return 0
}

export TOUCHES_TOO_BROAD_MARK="<!-- touches-too-broad -->"

# 本文から触るファイルを推し量る（印が無いときの補い）
touches_guess_from_body() {
  # 本文の `src/lib/a.ts` のような、バッククォートで囲んだ / を含むファイル名を集める（URL・空白入りは除く）
  # shellcheck disable=SC2016
  printf '%s\n' "$1" | grep -oE '`[A-Za-z0-9_.@()-]+(/[A-Za-z0-9_.@()-]+)+/?`' | tr -d '`' | grep -vE '^(https?:|\.\./)' | awk '!seen[$0]++' | head -n 20 || true
}

# READY なのに本文に ai-touches の印が無いとき、本文のファイル名から印を作って本文の最後に足す（足せたら 0）
ensure_touches_mark() {
  local issue="$1" body guess list
  body=$(gh api "repos/$REPO/issues/$issue" -q '.body // ""' 2> /dev/null) || return 1
  [[ "$body" =~ $TOUCHES_MARK_RE ]] && return 1
  guess=$(touches_guess_from_body "$body")
  [ -n "$guess" ] || { echo "#$issue：本文に触るファイルの印が無く、ファイル名からも補えませんでした（順番待ちでは待つ扱いになります）"; return 1; }
  list=$(printf '%s\n' "$guess" | paste -sd, - | sed 's/,/, /g')
  gh api -X PATCH "repos/$REPO/issues/$issue" -f body="${body}

<!-- ai-touches: ${list} -->" > /dev/null || return 1
  echo "#$issue：企画AIが触るファイルの印を書かなかったので、本文のファイル名から補いました（${list}）"
}

# 仕様書（docs/ の下の .md。サブフォルダの中も）か。仕様書は重なりに数えない
# （後からマージされる方が main を取り込むときのコンフリクトを AI が解く。文書は両方を残せば解ける）
is_doc_path() {
  local p="${1,,}"
  [[ "$p" == docs/*.md ]]
}

# 2つの一覧（改行区切り）が重なるか。同じファイル・片方のフォルダの中にもう片方がある、を重なりとみなす。
# 仕様書（is_doc_path）は数えない。画面のファイルも、同じファイルだけを重なりにする
# （見た目のテストの基準の画像のずれは、後からマージされる方の自動の撮り直し visual:update で直る）
paths_overlap() {
  local a b
  while IFS= read -r a; do
    [ -z "$a" ] && continue
    is_doc_path "$a" && continue
    while IFS= read -r b; do
      [ -z "$b" ] && continue
      is_doc_path "$b" && continue
      [ "$a" = "$b" ] && return 0
      case "$a" in */) case "$b" in "$a"*) return 0 ;; esac ;; esac
      case "$b" in */) case "$a" in "$b"*) return 0 ;; esac ;; esac
    done <<< "$2"
  done <<< "$1"
  return 1
}

# ---- 見張り役を間引く（watchdog.sh の 0） ----
# 同じ時間の枠（時計を slot_min 分ごとに区切った枠）で、自分より前に始まった見張りが、もう成功しているか（純粋な関数。gh は呼ばない）。
# 引数：見張り役の実行の一覧（GET actions/workflows/watchdog.yml/runs の返事）、自分の実行の番号、現在時刻（epoch 秒）、枠の長さ（分）。
# 成功している物があれば 0（＝今回は何もしなくてよい）。
# 枠の中でいちばん先に成功した実行は、必ず全部を見ている（自分より前に成功が無いので、間引かれない。定期・手動は、いつも全部見る）。
# 失敗・取り消し・飛ばされた実行は数えないので、見張りが落ちた枠では、次の実行が全部を見る
watchdog_slot_taken() {
  local runs="$1" me="$2" now="$3" slot_min="$4" start
  [[ "$me" =~ ^[0-9]+$ ]] && [[ "$now" =~ ^[0-9]+$ ]] && [[ "$slot_min" =~ ^[0-9]+$ ]] && [ "$slot_min" -gt 0 ] || return 1
  start=$(( now - now % (slot_min * 60) ))
  printf '%s' "$runs" | jq -e --argjson me "$me" --argjson start "$start" '
    any(.workflow_runs[]?;
      (.id | type) == "number" and .id < $me and .conclusion == "success"
      and ((.created_at // "") | (try fromdateiso8601 catch 0)) >= $start)' > /dev/null 2>&1 || return 1
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

# 人間のマージ待ちのPRを「番号 expired」（待ちが長い）か「番号 waiting」（時間内・時刻が読めない）で1行ずつ出す。読めなければ失敗。
# 写しがある間は、1回調べた結果を使い回す（remember_hold_prs で覚えた物。順番待ち・目覚ましが、同じ実行で3回調べていた）
hold_prs() {
  if [ -n "$HOLD_PRS_READY" ]; then
    [ -z "$HOLD_PRS_MEMO" ] || printf '%s\n' "$HOLD_PRS_MEMO"
    return 0
  fi
  local pulls pr sha w
  pulls=$(open_pulls_json) || return 1
  while IFS=' ' read -r pr sha; do
    [ -z "$pr" ] && continue
    pr_awaiting_human "$pr" "$sha" || continue
    w=$(hold_wait_min "$pr")
    if [ -n "$w" ] && [ "$w" -ge "$HOLD_BLOCK_MIN" ]; then echo "$pr expired"; else echo "$pr waiting"; fi
  done < <(printf '%s' "$pulls" | jq -r '.[] | "\(.number) \(.head.sha)"')
  return 0
}

# hold_prs の結果を覚える（写しがあるときだけ。$(…) の中で覚えても呼んだ側に残らないので、呼ぶ側の本体で先に呼んでおく）。
# 調べられなければ覚えない（次に hold_prs を呼んだ所が、もう一度調べる）
remember_hold_prs() {
  [ -n "$OPEN_ITEMS" ] || return 0
  [ -z "$HOLD_PRS_READY" ] || return 0
  local out
  out=$(hold_prs 2> /dev/null) || return 0
  HOLD_PRS_MEMO="$out"
  HOLD_PRS_READY=1
}

# 進行中の作業が触っているファイル。1行目に「unknown」が出たら、分からない物がある（並列にしない）
# 実装中の Issue は本文の印、open のPRは変えたファイル（AI以外のPR＝配布・依存の更新なども含む）
# ただし、人間のマージ待ちが HOLD_BLOCK_MIN 分より長い ai:hold のPRと、ai:stuck のPRは外す
inflight_touches() {
  local n body t pr files impl pulls expired
  expired=$(hold_prs 2> /dev/null | awk '$2 == "expired" {print $1}') || expired=""
  # 一覧を読めなかったら、分からない物があるとして待つ（空の一覧とみなさない）
  impl=$(open_numbers_with_label "ai:implement" 2> /dev/null) || { echo unknown; return 0; }
  pulls=$(open_pulls_json 2> /dev/null | jq -r '.[] | "\(.number) \(.head.ref)"' 2> /dev/null) || { echo unknown; return 0; }
  for n in $impl; do
    # PRがもうあれば、PRの変えたファイルで数える（下）
    if printf '%s\n' "$pulls" | grep -q " claude/issue-$n-"; then continue; fi
    body=$(issue_body "$n" 2> /dev/null) || { echo unknown; continue; }
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
#   （触るファイルが分からない物・進行中の物に分からない物があるときは、今までどおり待つ。仕様書は重なりに数えない。画面は同じファイルだけ待つ）
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

# 並列の上限と比べる「AIがいま動かしている実装の数」。ai:implement の開いている Issue から、次を除いて数える。一覧が読めなければ失敗
# - ai:stuck が付いた Issue
# - PR（head が claude/issue-N-）が ai:stuck の Issue
# - 人間のマージ待ちが HOLD_BLOCK_MIN 分を過ぎた PR（hold_prs の expired）の Issue
# 60分以内のマージ待ち（waiting）・時刻やラベルが読めない物は、数える
count_active_implementing() {
  local list
  list=$(active_implementing_numbers) || return 1
  printf '%s' "$list" | grep -c . || true
}

# 上の「数える」Issue の番号を1行ずつ出す（count_active_implementing と yield_if_crowded が同じ物を数えるための元）
active_implementing_numbers() {
  local impl pulls holds expired n pr rc
  impl=$(open_numbers_with_label "ai:implement") || return 1
  pulls=$(open_pulls_json | jq -r '.[] | "\(.number) \(.head.ref)"') || return 1
  holds=$(hold_prs 2> /dev/null) || return 1
  expired=$(printf '%s\n' "$holds" | awk '$2 == "expired" {print $1}')
  for n in $impl; do
    rc=0
    has_label "$n" "ai:stuck" || rc=$?
    [ "$rc" -eq 0 ] && continue
    pr=$(printf '%s\n' "$pulls" | awk -v p=" claude/issue-$n-" 'index($0, p) {print $1; exit}')
    if [ -n "$pr" ]; then
      printf '%s\n' "$expired" | grep -qx "$pr" && continue
      rc=0
      has_label "$pr" "ai:stuck" || rc=$?
      [ "$rc" -eq 0 ] && continue
    fi
    echo "$n"
  done
}

# 順番待ちを進める入り口。並列の上限を数える広さ（PARALLEL_SCOPE）で、全部のリポジトリ（global）か、このリポジトリだけ（repo）かを決める
start_next_in_queue() {
  parallel_scope_resolve
  if [ "$SCOPE_EFFECTIVE" = global ]; then
    start_next_in_queue_global
  else
    start_next_in_queue_repo
  fi
}

# このリポジトリだけで数える（PARALLEL_SCOPE=repo・全部では数えられないとき）。今までの決まり
start_next_in_queue_repo() {
  local busy stuck prs inflight queue n body t rc started=0 holds pr state files startedlist=" " limit_info limit idle=0 nomark_started=0
  busy=$(count_active_implementing) || return 1
  stuck=$(count_open_issues_with_label "ai:stuck") || return 1
  prs=$(count_open_prs) || return 1
  limit_info=$(current_parallel)
  limit="${limit_info%% *}"
  echo "実装中 ${busy} / 停止中 ${stuck}（数えない） / openのPR ${prs}（並列の上限 ${limit}：${limit_info#* }）"
  # 並べ替えは全体でする（ページごとに並べると、2ページ目の急ぎ・番号の小さい物が後ろに回る）
  queue=$(open_items_json "ai:queue" \
    | jq -r '[.[] | select(.pull_request | not) | select(([.labels[].name] | index("ai:skip")) == null) | {n: .number, p: ([.labels[].name] | index("priority:high") != null)}] | sort_by((if .p then 0 else 1 end), .n) | .[].n') || return 1
  # 人間のマージ待ちのPRは、この実行で1回だけ調べる（下の inflight_touches・目印の付け替えで使い回す）
  remember_hold_prs
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
  # 止まった実装中の Issue（PRがまだ無い物）の印は、席に数えなくても進行中のファイルに数える（inflight_touches）ので、止まった物があれば調べる
  if [ "$busy" -eq 0 ] && [ "$prs" -eq 0 ] && [ "$stuck" -eq 0 ]; then
    # 進行中の物が無い：先頭の1つで終わらず、下の繰り返し（上限・重なり・印の無い物の決まり）で上限まで並べて始める。
    # 進行中が空なので、先頭は必ず始まる（印の無い物なら、その1つだけで、この実行は終わる）
    inflight=""
  else
    inflight=$(inflight_touches) || return 1
  fi
  if printf '%s\n' "$inflight" | grep -qx unknown; then
    echo "進行中の物に、触るファイルが分からない物があるので、順番待ちは進めません"
    return 0
  fi
  # 数える進行中の物が1つも無い（数えないPRしか開いていない）なら、印の無い Issue も1つ始められる
  if [ -z "$(printf '%s\n' "$inflight" | tr -d '[:space:]')" ]; then idle=1; fi
  holds=$(hold_prs 2> /dev/null) || holds=""
  for n in $queue; do
    if [ $((busy + started)) -ge "$limit" ]; then
      echo "並列の上限（${limit}）なので、ここまでにします"
      break
    fi
    body=$(issue_body "$n") || continue
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
    if paths_overlap "$t" "$inflight"; then
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
        if paths_overlap "$t" "$files"; then note_hold_released "$pr" "$n"; fi
      done <<< "$holds"
    fi
  done
  sync_queue_hold_marks "$queue" "$startedlist" "$holds"
  [ "$started" -eq 0 ] && echo "今は始められる物がありません（進行中の物が終わると、もう一度見ます）"
  return 0
}

# 止まっている（時間内の）マージ待ちのPRに、待っている Issue の番号を全部集めて目印を付ける。止めなくなったPRの目印は書き換える。
# 引数：順番待ちの番号（空白・改行区切り）、この実行で始めた番号（" 3 4 " の形）、hold_prs の結果
sync_queue_hold_marks() {
  local queue="$1" startedlist="$2" holds="$3" n body t pr state files blocks=""
  for n in $queue; do
    case "$startedlist" in *" $n "*) continue ;; esac
    body=$(issue_body "$n" 2> /dev/null) || continue
    t=$(touches_from_body "$body")
    [ -z "$t" ] && continue
    while read -r pr state; do
      [ "$state" = waiting ] || continue
      files=$(gh api "repos/$REPO/pulls/$pr/files?per_page=100" --paginate -q '.[].filename' 2> /dev/null) || continue
      if paths_overlap "$t" "$files"; then blocks="${blocks}${pr} ${n}
"; fi
    done <<< "$holds"
  done
  while read -r pr state; do
    [ -z "$pr" ] && continue
    sync_hold_blocking "$pr" "$(printf '%s' "$blocks" | awk -v p="$pr" '$1 == p {print $2}' | tr '\n' ' ')"
  done <<< "$holds"
  return 0
}

# 企画のあとの数え直し：ai:implement を付けた直後に呼ぶ。同時に企画が終わった物が先に実装に入っていて、
# 上限を超える・触るファイルが重なるなら、番号の大きい方（この Issue）が引いて、ai:implement を外し ai:queue に入れ直す。
# 引数：Issue番号、上限、触るファイル（改行区切り・空でもよい）。引いたら 0、そのまま進めるなら 1
# 数え方は番号だけで決まる（番号の小さい方は、相手を見ても引かない）ので、2つが互いを見ても、両方は引かない
yield_if_crowded() {
  local issue="$1" limit="$2" mine="$3" others active older=0 n body t overlap=no
  others=$(open_numbers_with_label "ai:implement" 2> /dev/null) || return 1
  # 席に数えるのは count_active_implementing と同じ物（止まった物・長いマージ待ちは数えない）。重なりは、止まった物も見る
  active=$(active_implementing_numbers 2> /dev/null) || return 1
  for n in $others; do
    [ "$n" -lt "$issue" ] || continue
    if printf '%s\n' "$active" | grep -qx "$n"; then older=$((older + 1)); fi
    # PRがもうある物は、同時に始めた物ではない（PRの変えたファイルでの重なりは、付ける前に確かめ済み）
    if [ -n "$mine" ] && [ "$overlap" = no ] && ! open_pulls_json 2> /dev/null | jq -e --arg p "claude/issue-$n-" 'any(.[]; .head.ref | startswith($p))' > /dev/null 2>&1; then
      body=$(issue_body "$n" 2> /dev/null) || continue
      t=$(touches_from_body "$body")
      if [ -n "$t" ] && paths_overlap "$mine" "$t"; then overlap=yes; fi
    fi
  done
  if [ "$older" -ge "$limit" ] || [ "$overlap" = yes ]; then
    # 実装のワークフローは始まっているかもしれない。ai:queue と ai:implement を同時に持たないよう、先に外してから入れ直す
    take_label "$issue" "ai:implement" || return 1
    add_label "$issue" "ai:queue" || true
    return 0
  fi
  return 1
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

# ---- 並列の上限を、持ち主の全部のリポジトリで合わせて数える（PARALLEL_SCOPE=global。#216） ----
# Claude の使用量はアカウント全体で共通なので、上限（PARALLEL_DAY・PARALLEL_NIGHT）は、同じ持ち主のパイプラインのある全部のリポジトリで合わせて数える。
#   ・動いている数：このリポジトリは今までどおり（count_active_implementing）。ほかのリポジトリは、Search API で ai:implement・ai:queue が
#     付いた Issue のあるリポジトリを見つけ、そのリポジトリの中で同じ決まり（active_implementing_numbers）で数える
#   ・始める物：全部のリポジトリの ai:queue から、ai:queue が付いた時刻の古い順（priority:high を先に）。重なりの判断はそのリポジトリの中で今までどおり
#   ・取り合い：始めたあとに数え直し、上限より多い分は、ai:queue（無ければ ai:implement）が付いた時刻の新しい方から ai:queue に戻す
#   ・鍵がほかのリポジトリを読めない・検索できないときは、黙って広げず、このリポジトリだけで数える（repo）。Summary に ⚠️ で理由を出す
SCOPE_RESOLVED=""      # この実行で決めたか
SCOPE_EFFECTIVE=repo   # 決まった広さ（global / repo）
SCOPE_REASON=""        # repo に落としたときの理由（設定で repo のときは空）
GLOBAL_COUNTS=""       # ほかのリポジトリの動いている数（「owner/repo 数」を1行ずつ）
GLOBAL_QUEUE_ITEMS="[]" # 検索で見つけた、全部のリポジトリの順番待ち（search/issues の items）

# 広さを決める（純粋な関数）。引数：設定（PARALLEL_SCOPE）、JSON {"search_ok":true,"repos":[{"repo":"o/r2","ok":true,"why":""}]}
# 出力：「global」か「repo 理由」（設定が repo なら「repo」だけ）。repo 以外の設定（空・global・書き間違い）は global として扱う
parallel_scope_decide() {
  if [ "${1:-global}" = repo ]; then echo repo; return 0; fi
  printf '%s' "$2" | jq -r '
    if (.search_ok | not) then "repo 検索（Search API）で、ほかのリポジトリの Issue を探せませんでした"
    else ([(.repos // [])[] | select(.ok | not) | "\(.repo)（\(.why)）"]) as $bad
      | if ($bad | length) > 0 then "repo 鍵で読めないリポジトリがあります：" + ($bad | join("、")) else "global" end
    end'
}

# 全部のリポジトリの順番待ちを、始める順に「owner/repo 番号」で1行ずつ出す（純粋な関数）。
# 引数：JSON [{"repo":"o/r","n":3,"at":"2026-11-18T10:00:00Z","p":false}]（at は ai:queue が付いた時刻、p は priority:high）。
# priority:high を先に、その中は at の古い順（分からない物は最後）、同じならリポジトリ名・番号の順
global_queue_order() {
  printf '%s' "$1" | jq -r '
    sort_by((if .p then 0 else 1 end), ((.at // "") | if . == "" then "9999" else . end), (.repo | ascii_downcase), .n)
    | .[] | "\(.repo) \(.n)"'
}

# 取り合いで上限を超えたとき、ai:queue に戻す物を「owner/repo 番号」で1行ずつ出す（純粋な関数）。
# 引数：上限、JSON {"active":[{"repo":"o/r","n":3,"key":"2026-…"}],"mine":[{"repo":"o/r","n":3}]}。
# active は全部のリポジトリで動いている物（自分が始めた物も入れる）、key は席に着いた順を決める時刻（ai:queue が付いた時刻。無ければ ai:implement）。
# key の古い順に上限の数だけ席に残し、残りのうち自分が始めた物（mine）だけを戻す（前から動いている物・ほかの実行が始めた物は触らない）。
# key が分からない物は、いちばん古い扱い（動いている作業を、分からないまま追い出さない）。同時に動いた2つの実行が同じ一覧を見れば、同じ物を戻す
global_overflow_pick() {
  printf '%s' "$2" | jq -r --argjson limit "$1" '
    def id: "\(.repo | ascii_downcase)#\(.n)";
    ((.mine // []) | map(id)) as $mine
    | (.active // []) | unique_by(id)
    | sort_by(((.key // "") | if . == "" then "0000" else . end), (.repo | ascii_downcase), .n)
    | . as $s | [range($limit; length) | $s[.]]
    | .[] | select(id as $i | $mine | index($i)) | "\(.repo) \(.n)"'
}

# 持ち主の open の Issue のうち、ラベルが付いた物（search/issues の items の配列）。読めなければ失敗
search_owner_issues() {
  local q
  q=$(urlencode "user:$OWNER is:issue is:open label:\"$1\"")
  gh api "search/issues?q=${q}&per_page=100" --paginate --slurp | jq -c 'map(.items // []) | add // []'
}

# 検索の items から、このリポジトリ以外のリポジトリ名（owner/repo）を1行ずつ出す
search_other_repos() {
  printf '%s\n' "$@" | jq -rs --arg own "${REPO,,}" '
    map(.[]?) | map((.repository_url // "") | sub("^.*/repos/"; "")) | map(select(. != "" and ascii_downcase != $own)) | unique | .[]'
}

# ほかのリポジトリで「数える」実装中の Issue の番号（active_implementing_numbers と同じ決まり）。そのリポジトリの一覧を読み直す。読めなければ失敗
repo_active_numbers() {
  (
    REPO="$1"
    use_open_snapshot || exit 1
    active_implementing_numbers
  )
}

# ラベルが最後に付いた時刻（events の labeled）。読めなければ空
label_time() { # owner/repo 番号 ラベル
  gh api "repos/$1/issues/$2/events?per_page=100" --paginate --slurp 2> /dev/null \
    | jq -r --arg l "$3" 'add // [] | map(select(.event == "labeled" and .label.name == $l) | .created_at) | last // ""' 2> /dev/null || true
}

# 全部では数えられない理由を、ログと実行の Summary に ⚠️ で出す
scope_warn() {
  local msg="⚠️ 並列の上限を、このリポジトリ（${REPO}）だけで数えています：${SCOPE_REASON}。全部のリポジトリで合わせて数えるには、パイプラインの鍵（GitHub App）を持ち主のリポジトリ全部に Install してください（わざとなら Variable PARALLEL_SCOPE を repo に。docs/pipeline-setup.md「変えたい人向けの設定」）"
  echo "::warning::${msg}"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n\n' "$msg" >> "$GITHUB_STEP_SUMMARY" || true; fi
}

# 広さを決めて、ほかのリポジトリの数・順番待ちを読む（1回の実行で1回だけ）。呼ぶ側の本体で呼ぶ（$(…) の中では、決めた物が残らない）
parallel_scope_resolve() {
  [ -n "$SCOPE_RESOLVED" ] && return 0
  SCOPE_RESOLVED=1
  SCOPE_EFFECTIVE=repo SCOPE_REASON="" GLOBAL_COUNTS="" GLOBAL_QUEUE_ITEMS="[]"
  local setting="${PARALLEL_SCOPE:-global}" queue="[]" impl="[]" search_ok=true repos r info="[]" ok why installed="" inst_ok=0 nums counts="" decision
  [ "$setting" = repo ] && return 0
  if ! queue=$(search_owner_issues "ai:queue" 2> /dev/null) || ! impl=$(search_owner_issues "ai:implement" 2> /dev/null); then
    search_ok=false queue="[]" impl="[]"
  fi
  repos=$(search_other_repos "$queue" "$impl")
  # GitHub App の鍵なら、届くリポジトリの一覧で見る（公開のリポジトリは検索には出るが、App が入っていなければ書けない）。PIPELINE_TOKEN では読めないので見ない
  if [ -n "$repos" ] && installed=$(gh api "installation/repositories?per_page=100" --paginate -q '.repositories[].full_name' 2> /dev/null); then inst_ok=1; fi
  for r in $repos; do
    ok=true why=""
    if [ "$inst_ok" = 1 ] && ! grep -qixF -- "$r" <<< "$installed"; then
      ok=false why="鍵のインストールに入っていません"
    elif ! nums=$(repo_active_numbers "$r" 2> /dev/null); then
      ok=false why="読めません（403・404）"
    else
      counts="${counts}${r} $(printf '%s' "$nums" | grep -c . || true)
"
    fi
    info=$(jq -c --arg r "$r" --argjson ok "$ok" --arg w "$why" '. + [{repo: $r, ok: $ok, why: $w}]' <<< "$info")
  done
  decision=$(parallel_scope_decide "$setting" "$(jq -nc --argjson s "$search_ok" --argjson repos "$info" '{search_ok: $s, repos: $repos}')")
  if [ "$decision" = global ]; then
    SCOPE_EFFECTIVE=global
    GLOBAL_COUNTS="$counts"
    GLOBAL_QUEUE_ITEMS="$queue"
  else
    SCOPE_REASON="${decision#repo }"
    scope_warn
  fi
  return 0
}

# 診断（doctor.sh）向け：広さを決めて1行で出す。「global ほかのリポジトリの数」／「repo-set」（設定で repo）／「repo 理由」
parallel_scope_report() {
  parallel_scope_resolve > /dev/null 2>&1
  if [ "$SCOPE_EFFECTIVE" = global ]; then echo "global $(printf '%s' "$GLOBAL_COUNTS" | grep -c . || true)"
  elif [ -z "$SCOPE_REASON" ]; then echo repo-set
  else echo "repo $SCOPE_REASON"; fi
}

# ほかのリポジトリで動いている数の合計（parallel_scope_resolve のあと）
global_other_busy() {
  local r c sum=0
  while read -r r c; do
    [ -z "$r" ] && continue
    sum=$((sum + c))
  done <<< "$GLOBAL_COUNTS"
  echo "$sum"
}

# ほかのリポジトリの順番待ちの数（parallel_scope_resolve のあと。repo なら 0）
global_other_queued() {
  [ "$SCOPE_EFFECTIVE" = global ] || { echo 0; return 0; }
  printf '%s' "$GLOBAL_QUEUE_ITEMS" | jq --arg own "${REPO,,}" '[.[] | select(((.repository_url // "") | sub("^.*/repos/"; "") | ascii_downcase) != $own)] | length'
}

# 今のリポジトリ（REPO）の順番待ち1つを、そのリポジトリの中の決まりで始められるか見て、始められれば始める。始めたら 0、待つなら 1。
# 決まりは start_next_in_queue_repo と同じ：進行中に触るファイルの分からない物があれば待つ・印の無い物は進行中が空のときだけ・重なれば待つ。
# 進行中の物は毎回一覧から数え直す（始めた物は ai:implement が付くので、次の判断に入る。印の無い物を始めたら、そのリポジトリは「分からない物」で待つ）
queue_try_start() {
  local n="$1" inflight body t why rc holds pr state files
  inflight=$(inflight_touches) || return 1
  if printf '%s\n' "$inflight" | grep -qx unknown; then
    echo "#$n：進行中の物に、触るファイルが分からない物があるので、待ちます"
    return 1
  fi
  body=$(issue_body "$n") || return 1
  t=$(touches_from_body "$body")
  if [ -z "$t" ]; then
    if [ -n "$(printf '%s\n' "$inflight" | tr -d '[:space:]')" ]; then
      echo "#$n：触るファイルが分からないので、進行中の物が終わるまで待ちます"
      return 1
    fi
    why="（進行中に数える作業が無いので、始めます）"
  elif paths_overlap "$t" "$inflight"; then
    echo "#$n：進行中の作業と触るファイルが重なるので、待ちます"
    return 1
  else
    why="（進行中の作業と触るファイルが重ならないので、並べて始めます）"
  fi
  rc=0
  start_queued_issue "$n" "$why" || rc=$?
  if [ "$rc" -eq 2 ]; then
    # ほかの処理が先に始めたか、外せなかった（書けない）か。一覧から確かめる
    drop_open_snapshot
    has_label "$n" "ai:implement" && return 0
    return 1
  fi
  [ "$rc" -eq 0 ] || return 1
  if [ -n "$t" ]; then
    holds=$(hold_prs 2> /dev/null) || holds=""
    while read -r pr state; do
      [ "$state" = expired ] || continue
      files=$(gh api "repos/$REPO/pulls/$pr/files?per_page=100" --paginate -q '.[].filename' 2> /dev/null) || continue
      if paths_overlap "$t" "$files"; then note_hold_released "$pr" "$n"; fi
    done <<< "$holds"
  fi
  return 0
}

# 全部のリポジトリで合わせて数えて、順番待ちを進める（PARALLEL_SCOPE=global）
start_next_in_queue_global() {
  local own_busy busy limit_info limit own_items cand r n at started=0 mine="" startedlist=" " rc holds own_queue detail
  own_busy=$(count_active_implementing) || return 1
  busy=$((own_busy + $(global_other_busy)))
  detail="${REPO} ${own_busy}"
  while read -r r n; do [ -n "$r" ] && detail="${detail}・${r} ${n}"; done <<< "$GLOBAL_COUNTS"
  limit_info=$(current_parallel)
  limit="${limit_info%% *}"
  echo "全部のリポジトリで実装中 ${busy}（${detail}）（並列の上限 ${limit}：${limit_info#* }。上限は全部のリポジトリで合わせて数えます）"
  remember_hold_prs
  holds=$(hold_prs 2> /dev/null) || holds=""
  # このリポジトリの順番待ちは一覧から（検索の反映の遅れで、付けたばかりの ai:queue を見落とさない）。ほかのリポジトリは検索から
  own_items=$(open_items_json "ai:queue" | jq -c --arg r "$REPO" '[.[] | select(.pull_request | not) | select(([.labels[].name] | index("ai:skip")) == null) | {repo: $r, n: .number, p: ([.labels[].name] | index("priority:high") != null)}]') || return 1
  own_queue=$(printf '%s' "$own_items" | jq -r '.[].n')
  cand=$(printf '%s' "$GLOBAL_QUEUE_ITEMS" | jq -c --arg own "${REPO,,}" --argjson mine "$own_items" '
    $mine + [.[] | ((.repository_url // "") | sub("^.*/repos/"; "")) as $r | select(($r | ascii_downcase) != $own and $r != "") | select(([(.labels // [])[].name] | index("ai:skip")) == null)
      | {repo: $r, n: .number, p: ([(.labels // [])[].name] | index("priority:high") != null)}]')
  if [ "$(printf '%s' "$cand" | jq 'length')" -eq 0 ]; then
    echo "順番待ちはありません（全部のリポジトリ）"
  elif [ "$busy" -ge "$limit" ]; then
    echo "全部のリポジトリで並列の上限（${limit}）なので、今は始めません"
  else
    # ai:queue が付いた時刻を足して、古い順に並べる
    cand=$(printf '%s' "$cand" | jq -c '.[]' | while IFS= read -r c; do
      r=$(printf '%s' "$c" | jq -r .repo); n=$(printf '%s' "$c" | jq -r .n)
      at=$(label_time "$r" "$n" "ai:queue")
      printf '%s' "$c" | jq -c --arg at "$at" '. + {at: $at}'
    done | jq -sc '.')
    while read -r r n; do
      [ -z "$r" ] && continue
      if [ $((busy + started)) -ge "$limit" ]; then
        echo "全部のリポジトリで並列の上限（${limit}）なので、ここまでにします"
        break
      fi
      rc=0
      if [ "${r,,}" = "${REPO,,}" ]; then
        queue_try_start "$n" || rc=$?
      else
        echo "（${r}）"
        ( REPO="$r"; use_open_snapshot || exit 1; queue_try_start "$n" ) || rc=$?
      fi
      if [ "$rc" -eq 0 ]; then
        started=$((started + 1))
        mine="${mine}${r} ${n}
"
        [ "${r,,}" = "${REPO,,}" ] && startedlist="${startedlist}${n} "
      fi
    done < <(global_queue_order "$cand")
  fi
  # 写しが捨てられていたら（ラベルを外せたか分からなかった）、目印の付け替えは API から読む
  sync_queue_hold_marks "$own_queue" "$startedlist" "$holds"
  if [ "$started" -gt 0 ]; then
    global_yield_overflow "$limit" "$mine"
  else
    echo "今は始められる物がありません（どこかの進行中の物が終わると、もう一度見ます）"
  fi
  return 0
}

# 始めたあとの数え直し（取り合い）：2つのリポジトリの順番待ちが同時に動くと、互いの始めた物を見ずに上限を超える。
# 少し待ってから（検索の反映の遅れを吸収する）全部のリポジトリで数え直し、上限より多い分のうち、自分が始めた物を ai:queue に戻す。
# 引数：上限、自分が始めた物（「owner/repo 番号」を1行ずつ）。戻した数を出さず、ログに書く
global_yield_overflow() {
  local limit="$1" mine="$2" impl repos r n nums active="" total json picks key mine_json
  sleep "${QUEUE_RECOUNT_WAIT_SEC:-5}"
  impl=$(search_owner_issues "ai:implement" 2> /dev/null) || impl="[]"
  repos=$( { printf '%s\n' "$REPO"; printf '%s\n' "$GLOBAL_COUNTS" | awk 'NF {print $1}'; search_other_repos "$impl" "$GLOBAL_QUEUE_ITEMS"; printf '%s' "$mine" | awk 'NF {print $1}'; } | awk 'NF && !seen[tolower($0)]++')
  for r in $repos; do
    nums=$(repo_active_numbers "$r" 2> /dev/null) || continue
    for n in $nums; do active="${active}${r} ${n}
"; done
  done
  active=$(printf '%s%s' "$active" "$mine" | awk 'NF && !seen[tolower($0)]++')
  total=$(printf '%s\n' "$active" | grep -c . || true)
  echo "数え直し：全部のリポジトリで実装中 ${total}（並列の上限 ${limit}）"
  [ "$total" -gt "$limit" ] || return 0
  json="[]"
  while read -r r n; do
    [ -z "$r" ] && continue
    key=$(label_time "$r" "$n" "ai:queue")
    [ -n "$key" ] || key=$(label_time "$r" "$n" "ai:implement")
    json=$(jq -c --arg r "$r" --argjson n "$n" --arg k "$key" '. + [{repo: $r, n: $n, key: $k}]' <<< "$json")
  done <<< "$active"
  mine_json=$(printf '%s' "$mine" | awk 'NF' | jq -Rsc 'split("\n") | map(select(. != "") | split(" ") | {repo: .[0], n: (.[1] | tonumber)})')
  picks=$(global_overflow_pick "$limit" "$(jq -nc --argjson a "$json" --argjson m "$mine_json" '{active: $a, mine: $m}')")
  while read -r r n; do
    [ -z "$r" ] && continue
    if ( REPO="$r"; drop_open_snapshot; take_label "$n" "ai:implement" || exit 1; add_label "$n" "ai:queue" || true
         comment "$n" "↩ ほかのリポジトリの順番待ちと同時に始まり、全部のリポジトリで並列の上限（${limit}）を超えたので、順番待ちに戻しました（\`ai:queue\` が付いたのが新しい方が戻ります）。空きができると自動で始まります。" || true ); then
      echo "${r}#${n}：同時に始めた物があり、全部のリポジトリで上限を超えたので、順番待ちに戻しました"
    fi
    if [ "${r,,}" = "${REPO,,}" ]; then use_open_snapshot || drop_open_snapshot; fi
  done <<< "$picks"
  return 0
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
  elif [ "$subtype" = "error_max_turns" ]; then
    # 手数で止まったのが本当の原因。途中で断られた操作は寄り道なので、添えるだけ
    if [ "${denials:-0}" -gt 0 ]; then
      echo "作業回数の上限（--max-turns。途中で断られた操作：${denials}件）"
    else
      echo "作業回数の上限（--max-turns）"
    fi
  elif [ "${denials:-0}" -gt 0 ]; then
    if [ -n "$first" ]; then
      echo "許可不足（AIが許可されていない操作を試した：${denials}件。最初の1件：${first}）"
    else
      echo "許可不足（AIが許可されていない操作を試した：${denials}件）"
    fi
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

# AIの実行記録が「正常に終わった」（結果が success で、エラーではない）か。
# AIのアクションは、AIが正常に終わっていても、手数が --max-turns を越えていると失敗にする。そのときの見分けに使う
ai_finished_ok() {
  local f="${1:-}" ok
  { [ -n "$f" ] && [ -s "$f" ] && [ ! -L "$f" ]; } || return 1
  ok=$(jq -r 'if type == "array" then . else [.] end | map(select(type == "object" and .type == "result")) | last // {} | if .subtype == "success" and .is_error != true then "yes" else "no" end' "$f" 2> /dev/null) || return 1
  [ "$ok" = yes ]
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
#   第3引数にリポジトリを書くと、そこを探す（既定はこのリポジトリ）
find_issues_by_title() {
  local title="$1" state="$2" repo="${3:-$REPO}" q found
  q=$(jq -rn --arg t "\"$title\" in:title repo:$repo type:issue$([ "$state" = open ] && echo ' is:open')" '$t | @uri')
  found=$(gh api "search/issues?q=${q}&per_page=100" -q ".items[] | select(.title == \"$title\") | .number" 2> /dev/null | sort -n) || found=""
  if [ -z "$found" ]; then
    found=$(gh api "repos/$repo/issues?state=${state}&per_page=100" -q ".[] | select(.title == \"$title\") | .number" | sort -n) || return 1
  fi
  printf '%s\n' "$found" | awk 'NF'
}

# 方針として開けない操作の一覧（docs/pipeline.md の「AIの許可」の「開けない操作」と同じ。食い違うと tests/test-permissions.sh が落ちる）。
# ここに無い操作の不足だけが、「許可が足りない」Issue になる
PERM_NEVER_OPEN=('Bash(rm:*)' 'Bash(sed:*)' 'Bash(curl:*)' 'Bash(git push --force:*)' 'Bash(git rebase:*)' 'Bash(gh pr merge:*)')

# 許可の書き方 KEY が、開けない操作の一覧にあるか（0 = ある）
permission_never_open() {
  local k
  for k in "${PERM_NEVER_OPEN[@]}"; do
    [ "$k" = "$1" ] && return 0
  done
  return 1
}

# 拒否された操作（許可の書き方、改行区切り）から、止まった理由の文を作る。
# 開けない操作は「開けない操作を試した（AIへの指示を直す所）」、それ以外の物だけを「足りない許可」に書く。
#   使い方：permission_reason_text 許可の書き方 [「足りない許可」の言い方]
permission_reason_text() {
  local label="${2:-足りない許可}" k never="" other="" out=""
  while IFS= read -r k; do
    [ -z "$k" ] && continue
    if permission_never_open "$k"; then never+="${never:+$'\n'}$k"; else other+="${other:+$'\n'}$k"; fi
  done <<< "$1"
  [ -n "$never" ] && out="開けない操作を試した（AIへの指示を直す所）：$(permission_list_short "$never")"
  if [ -n "$other" ]; then
    out+="${out:+。}${label}：$(permission_list_short "$other")（docs/pipeline.md の「AIの許可」の表と、ワークフローの --allowedTools を見てください）"
  fi
  printf '%s' "$out"
}

# テンプレート（ai-dev-template）のリポジトリ名を出す。環境変数 PIPELINE_TEMPLATE_REPO → 最近の配布PRの印
# （<!-- pipeline-sync-src: owner/repo@sha -->）の順。分からなければ何も出さない
template_repo() {
  local t="${PIPELINE_TEMPLATE_REPO:-}"
  if [ -z "$t" ]; then
    t=$(gh api "repos/$REPO/pulls?state=all&per_page=30" -q '.[] | select(.head.ref | startswith("pipeline-sync/")) | .body // ""' 2> /dev/null \
      | sed -n 's/.*pipeline-sync-src: \([^@ ]*\)@.*/\1/p' | head -n 1) || t=""
  fi
  if grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' <<< "$t"; then printf '%s' "$t"; fi
  return 0
}

# 「AIの許可が足りない」を、テンプレートの Issue 1つにまとめる（同じ題名の開いた Issue のうち、最小の番号がまとめ先。
# 無ければ作り、ラベル audit を付ける。audit が無くて作れなければ、ラベルなしで作る）。アプリの番号はコメントで足す。
# 読めない・作れないときは失敗で終わる（呼んだ側がアプリに作る）。使い方：report_gap_to_template テンプレート 題名 キー 回数 記録Issue 番号
report_gap_to_template() {
  local tpl="$1" title="$2" key="$3" n="$4" ledger="$5" from="$6" list target mine=""
  list=$(find_issues_by_title "$title" open "$tpl") || return 1
  target=$(printf '%s\n' "$list" | head -n 1)
  if [ -z "$target" ]; then
    local body="### 背景
アプリ \`${REPO}\` で、AIが \`${key}\` を許可されておらず、${n}回止まりました（記録：${REPO}#${ledger}）。同じ不足が別のアプリでも起きたら、下のコメントに \`<アプリ>#<番号>\` を足します。

### やること（マネージャーが行う。\`.github/\` を触るのでAIには回さない）
- docs/pipeline.md の「AIの許可」の表を見て、どのAIにこの操作が要るかを決める
- 要るなら、そのワークフローの \`--allowedTools\` に足し、表にも書く（tests/test-permissions.sh が食い違いを見つける）
- 要らない操作なら、AIへの指示の方を直す"
    mine=$(gh api -X POST "repos/$tpl/issues" -f title="$title" -f body="$body" -f 'labels[]=audit' -q .number 2> /dev/null) \
      || mine=$(gh api -X POST "repos/$tpl/issues" -f title="$title" -f body="$body" -q .number 2> /dev/null) || return 1
    # 同時に作った別のアプリがいたら、最小の番号をまとめ先にする
    list=$(find_issues_by_title "$title" open "$tpl") || list=""
    target=$(printf '%s\n' "$list" | head -n 1)
    [ -n "$target" ] || target="$mine"
    if [ "$mine" != "$target" ]; then
      gh api -X PATCH "repos/$tpl/issues/$mine" -f state=closed > /dev/null 2>&1 || true
      mine=""
    fi
  fi
  gh api "repos/$tpl/issues/$target/comments" -f body="\`${REPO}#${from}\`：\`${key}\` の不足（${n}回目）" > /dev/null 2>&1 || return 1
  if [ -n "$mine" ]; then
    notify stuck "AIの許可が足りません" "同じ不足（${key}）が${n}回起きたので、${tpl} に Issue #${target} を作りました" 4
  fi
  return 0
}

# 許可の不足を、記録用のIssue（閉じたまま）にコメントで残し、同じ不足が2回目なら、直すためのIssueを自動で作る。
#   開けない操作（PERM_NEVER_OPEN）は記録だけ（Issue は作らない）。
#   それ以外はテンプレートに1つにまとめる（届かないときだけ、このリポジトリに ai:skip・pipeline ラベルで作る）
#   使い方：report_permission_gap 番号 "許可の書き方（改行区切り）"
report_permission_gap() {
  local from="$1" keys key ledger ledgers l n n1 title existing created tpl
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
    # 開けない操作は、記録のコメントだけ残す（直すIssueは作らない）
    permission_never_open "$key" && continue
    n=0
    while IFS= read -r l; do
      [ -z "$l" ] && continue
      n1=$(all_comments "$l" | jq --arg k "<!-- perm-gap: ${key} -->" '[.[] | select(.body | contains($k))] | length') || n1=0
      n=$((n + ${n1:-0}))
    done <<< "$ledgers"
    if [ "$n" -ge 2 ]; then
      title="AIの許可が足りない：${key}"
      # テンプレートにまとめる。届かない（名前が分からない・読めない・作れない）ときだけ、このリポジトリに作る
      tpl=$(template_repo)
      if [ -n "$tpl" ] && report_gap_to_template "$tpl" "$title" "$key" "$n" "$ledger" "$from"; then
        continue
      fi
      existing=$(find_issues_by_title "$title" open) || return 0
      if [ -z "$existing" ]; then
        created=$(gh api -X POST "repos/$REPO/issues" -f title="$title" -f 'labels[]=ai:skip' -f 'labels[]=pipeline' \
          -f body="<!-- pipeline-maintenance -->
### 背景
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
  # 作業回数の上限で止まったときも同じ。拒否は途中の寄り道で（例：cat >> でファイルに書こうとして断られ、Edit で書き直す）、止まった本当の原因は手数。
  # 許可不足として人間に回すと「許可を足せ」と的外れな理由になり、やり直せば進む作業まで止まる（agent-desk #658）。拒否は記録だけ残す
  if [ -n "$denied" ] && [ -z "$(limit_signal "$file")" ] && hit_max_turns "$file"; then
    report_permission_gap "$num" "$denied"
  elif [ -n "$denied" ] && [ -z "$(limit_signal "$file")" ]; then
    reason="$(failure_reason "$label" "$file")。$(permission_reason_text "$denied")"
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
  # 実装AIが作業回数の上限で止まった1回目：同じ上限でやり直しても同じ所で止まるので、大きい作業（size:L：手数100・強いモデル）にしてやり直す
  if [ -z "$limit" ] && [ "$kind" = implement ] && hit_max_turns "$file" && ! has_label "$num" "size:L"; then
    remove_label "$num" "size:S"
    add_label "$num" "size:L"
    mark_for_retry "$num" "$kind" "$(failure_reason "$label" "$file")。大きい作業として（size:L：手数を増やし、強いモデルで）やり直します" "$limit"
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

# 落ちた手順の名前（JSON の配列）が、パイプライン側の確認（PIPELINE_CHECK_STEPS）だけか、それと見た目のテストだけ（かつパイプライン側を1つは含む）かを true / false で出す。
#   使い方：pipeline_steps_only 落ちた手順の配列 [with_visual]（with_visual を付けると、見た目のテストが混ざっていてもよい）
pipeline_steps_only() {
  printf '%s' "$1" | jq --argjson names "$PIPELINE_CHECK_STEPS" --arg wv "${2:-}" '
    length > 0
    and any(.[]; . as $n | $names | index($n) != null)
    and all(.[]; . as $n | ($names | index($n) != null) or ($wv != "" and $n == "見た目のテスト"))' 2> /dev/null || echo false
}

# 落ちた手順（JSON の配列）が全部ブラウザ・依存を入れる所（NETWORK_CHECK_STEPS）で、ログにネットワークの失敗の言葉があるかを true / false で出す。
# ログが空（読めなかった）ときは false（外の障害とは決めない）
#   使い方：network_failure_only 落ちた手順の配列 ジョブのログ
network_failure_only() {
  local steps="$1" log="${2:-}"
  [ -n "$log" ] || { echo false; return 0; }
  printf '%s' "$log" | grep -Eq "$NETWORK_FAILURE_RE" || { echo false; return 0; }
  printf '%s' "$steps" | jq --argjson names "$NETWORK_CHECK_STEPS" '
    length > 0 and all(.[]; . as $n | $names | index($n) != null)' 2> /dev/null || echo false
}

# このコミットで、外の障害によるやり直しを何回やったか（NETWORK_RERUN_MARK の印。コミットの記載があるコメントだけ数える）
#   使い方：network_rerun_count PR番号 先頭コミット
network_rerun_count() {
  all_comments "$1" | jq --arg m "$NETWORK_RERUN_MARK" --arg s "$2" \
    '[.[] | select(.body | contains($m)) | select(.body | contains($s))] | length' 2> /dev/null || echo 0
}

# 外の障害のとき、落ちたジョブを（上限まで）やり直す。やり直せたら 0、上限に達した・やり直せなかったら 1
#   使い方：rerun_for_network_failure PR番号 先頭コミット 実行の番号
rerun_for_network_failure() {
  local pr="$1" sha="$2" run="$3" n
  n=$(network_rerun_count "$pr" "$sha")
  [ "${n:-0}" -lt "$NETWORK_RERUN_MAX" ] || return 1
  GH_TOKEN="${READ_TOKEN:-$GH_TOKEN}" gh api -X POST "repos/$REPO/actions/runs/$run/rerun-failed-jobs" > /dev/null 2>&1 || return 1
  comment "$pr" "外の障害（Ubuntu のミラーなど）でブラウザ・依存を入れられませんでした。コードの問題ではないので、修正AIには頼まず、落ちたジョブをやり直します（$((n + 1))/${NETWORK_RERUN_MAX}回目。直す回数には数えません）（コミット ${sha}）

${NETWORK_RERUN_MARK}"
}

# PRが .github/ を触っているか（0 = 触っている）。ファイルの一覧を読めないときも、触っているものとして扱う（やり直し・人間に回す近道に進まない）
pr_touches_github() {
  local files
  files=$(gh api "repos/$REPO/pulls/$1/files?per_page=100" --paginate -q '.[].filename' 2> /dev/null) || return 0
  printf '%s\n' "$files" | grep -q '^\.github/'
}

# このコミットで、パイプライン側のテストのやり直し（PIPELINE_TEST_MARK の印）をもう1回やったか（0 = やった）。
# 印の付いたコメントに「コミット <sha>」があれば、そのコミットの分。コミットの記載が無い古い印は、どのコミットでも「やった」と数える
#   使い方：pipeline_rerun_done PR番号 先頭コミット [コメントのJSON]
pipeline_rerun_done() {
  local comments="${3:-}"
  [ -z "$comments" ] && comments=$(all_comments "$1")
  printf '%s' "$comments" | jq -e --arg m "$PIPELINE_TEST_MARK" --arg s "$2" \
    '[.[] | select(.body | contains($m)) | select(((.body | contains("コミット ")) | not) or (.body | contains($s)))] | length > 0' > /dev/null
}

# そのコミットの、いちばん新しい CI（PRの物）が失敗していれば、その実行の番号を出す。無ければ何も出さない
ci_failed_run_id() {
  GH_TOKEN="${READ_TOKEN:-$GH_TOKEN}" gh api "repos/$REPO/actions/runs?head_sha=$1&event=pull_request&per_page=20" \
    -q '[.workflow_runs[] | select(.name == "CI")] | sort_by(.created_at) | last | select(. != null and .conclusion == "failure") | .id' 2> /dev/null || true
}

# 落ちたジョブを、同じ先頭コミットで1回だけやり直す（印を残す）。やり直せたら 0、すでにやった・やり直せなかったら 1
#   使い方：rerun_failed_ci_once PR番号 先頭コミット 知らせの文 [実行の番号（無ければ探す）]
rerun_failed_ci_once() {
  local pr="$1" sha="$2" msg="$3" run="${4:-}"
  pipeline_rerun_done "$pr" "$sha" && return 1
  [ -n "$run" ] || run=$(ci_failed_run_id "$sha")
  [ -n "$run" ] || return 1
  GH_TOKEN="${READ_TOKEN:-$GH_TOKEN}" gh api -X POST "repos/$REPO/actions/runs/$run/rerun-failed-jobs" > /dev/null 2>&1 || return 1
  comment "$pr" "${msg}（コミット ${sha}）

${PIPELINE_TEST_MARK}"
  return 0
}

# パイプライン側のテストが落ちていることを、テンプレートの Issue にまとめる（同じ題名の開いた Issue があれば、コメントで足すだけ）。
# 作れた・足せたら 0、テンプレートが分からない・読み書きできないときは 1（呼んだ側が、人間に回す文に「Issue を作ってほしい」と書く）
#   使い方：report_pipeline_test_to_template PR番号 落ちた手順の名前
report_pipeline_test_to_template() {
  local pr="$1" names="$2" tpl list target
  tpl=$(template_repo)
  [ -n "$tpl" ] || return 1
  list=$(find_issues_by_title "$PIPELINE_TEST_ISSUE_TITLE" open "$tpl") || return 1
  target=$(printf '%s\n' "$list" | head -n 1)
  if [ -z "$target" ]; then
    local body="### 背景
アプリ \`${REPO}\` のPR #${pr} で、PRと関係ない所（パイプライン側）のテスト（${names}）が、やり直しても落ちました。PRは \`.github/\` を触っておらず、AIは \`.github/\` を直せないので、人間に回りました。同じことが別のアプリでも起きたら、下のコメントに \`<アプリ>#<番号>\` を足します。

### やること（マネージャーが行う。\`.github/\` を触るのでAIには回さない）
- 落ちたテストのログを見て、たまに落ちるのか（時間・実行環境の揺れ）、壊れているのかを確かめる
- 直したら、アプリへ配布する"
    target=$(gh api -X POST "repos/$tpl/issues" -f title="$PIPELINE_TEST_ISSUE_TITLE" -f body="$body" -q .number 2> /dev/null) || return 1
    notify stuck "パイプライン側のテストが落ちています" "${tpl} に Issue #${target} を作りました（${REPO}#${pr}）" 4
    return 0
  fi
  gh api "repos/$tpl/issues/$target/comments" -f body="\`${REPO}#${pr}\`：パイプライン側のテスト（${names}）が、やり直しても落ちました" > /dev/null 2>&1 || return 1
  return 0
}

# そのコミットの、いちばん新しい CI（PRの物。created_at がいちばん新しい実行）の状態を1語で出す。
#   none＝実行が見つからない／unreadable＝読めない／pending＝まだ終わっていない／success＝通った／failure＝それ以外（failure・cancelled など）
# 読めない・見つからないを、通ったと取り違えない（どちらも success 以外）。読み取りは read_api と同じ（READ_TOKEN、だめならパイプラインの鍵）
ci_state() {
  local sha="$1" out
  if ! out=$(read_api "repos/$REPO/actions/runs?head_sha=$sha&event=pull_request&per_page=100" \
    -q '[.workflow_runs[] | select(.name == "CI")] | sort_by(.created_at) | last
        | if . == null then "none" elif .status != "completed" then "pending" elif .conclusion == "success" then "success" else "failure" end'); then
    echo unreadable
    return 0
  fi
  case "$out" in
    none | pending | success | failure) echo "$out" ;;
    *) echo unreadable ;;
  esac
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
  # コンフリクト中（dirty）は GitHub がCIを動かさない。待っても来ないので1回だけ見る
  local dirty=false tries=4
  if [ "$(printf '%s' "$pr_json" | jq -r '.mergeable_state // ""')" = dirty ]; then
    dirty=true
    tries=1
  fi
  RERUN_CI_NEW_HEAD=""
  for _ in $(seq 1 "$tries"); do
    runs=$(GH_TOKEN="$READ_TOKEN" gh api "repos/$REPO/actions/runs?head_sha=$sha&event=pull_request&per_page=50" \
      -q '[.workflow_runs[] | select(.name == "CI")]')
    [ "$(printf '%s' "$runs" | jq 'length')" -gt 0 ] && break
    [ "$dirty" = true ] || sleep 15
  done
  if [ "$dirty" = true ] && [ "$(printf '%s' "$runs" | jq 'length')" -eq 0 ]; then
    echo "PR #$pr：main とコンフリクトしていてCIが動かないので、空のコミットは足しません（コンフリクトの解消を頼みます）"
    return 0
  fi
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
  # shellcheck disable=SC2034 # 呼んだ側（after-mention.sh）が読む
  RERUN_CI_NEW_HEAD="$new"
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
# 修正AIが push せずに終わり、同じコミットをもう一度レビューする流れで、止まらないように。
# 修正AIが「PRが更新されたので動かない」と返した依頼（STALE_FIX_RE）と、人間が ai:stuck を外す前の依頼も、もう動いていないので数えない
fix_requested_for() { # PR番号 先頭コミット
  all_comments "$1" | jq -e --arg mark "$AUTO_FIX_MARK" --arg sha "<!-- auto-fix-sha: $2 -->" --arg resume "$RESUME_MARK" --arg stale "$STALE_FIX_RE" "$STALE_FIX_JQ"'
    . as $all | stale_ids as $void
    | (map(select(.body | contains($resume)) | .created_at) | max // "") as $since
    | any($all[] | select((.body | contains($mark)) and (.body | contains($sha)) and .created_at > $since) | select(.id as $i | $void | index($i) | not) | .created_at as $t
      | ([$all[] | select(.user.login == "claude[bot]" and (.body | startswith("## Code review") | not)
          and (.body | contains("Claude finished")) and .created_at >= $t)] | length == 0); .)' > /dev/null
}

# いまの先頭コミットへの、いちばん新しいレビューの結果（「## Code review」のまとめ）に指摘があるか。
# レビューは CI と同時に動くので、CIが落ちた時点で、指摘のある結果がもう出ていることがある（直す依頼は、このあと after-review.sh が出す）
review_has_findings() { # PR番号 先頭コミット
  local head_date
  head_date=$(gh api "repos/$REPO/commits/$2" -q .commit.committer.date) || return 1
  all_comments "$1" | jq -e --arg since "$head_date" '
    map(select((.user.login == "claude[bot]" or .user.login == "github-actions[bot]") and (.body | startswith("## Code review")) and .created_at >= $since)) | last
    | . != null and (.body | contains("No issues found") | not)' > /dev/null
}

# 修正AIが「PRが更新されたので動かない」と返して終わった依頼を、最新のコミットで出し直す（after-mention.sh が呼ぶ）。
# 動かなかった依頼は直す回数に数えない（count_auto_fix）ので、出し直した依頼が、同じ回（同じ「n/m」・同じモデル）になる。
# いまの先頭コミットに、別の依頼がもう出ていれば出し直さない（その修正AIに任せる）。MAX_STALE_FIX 回を超えたら人間に回す
STALE_FIX_NOTE='（前の依頼は、依頼のあとにPRが更新されたため、修正AIが動きませんでした。直す回数には数えず、最新のコミットで出し直しています）'
reissue_stale_fix() { # PR番号 動かなかった依頼のコメント（JSON）
  local pr="$1" req="$2" body head stale message reason
  body=$(printf '%s' "$req" | jq -r .body)
  head=$(gh api "repos/$REPO/pulls/$pr" -q .head.sha)
  stale=$(count_stale_fix "$pr")
  if [ "$stale" -gt "$MAX_STALE_FIX" ]; then
    stop_for_human "$pr" "修正AIへの依頼が、${stale}回続けて「依頼のあとにPRが更新された」ため動きませんでした（何かが、このPRのブランチを動かし続けています。Actions の Claude Mention・Visual Update・Pipeline の実行を確かめてください）"
    return 0
  fi
  if fix_requested_for "$pr" "$head"; then
    echo "PR #$pr：修正AIは「PRが更新された」ため動きませんでしたが、いまの先頭コミットにはもう直すよう頼んであるので、出し直しません"
    return 0
  fi
  if printf '%s' "$body" | grep -q '<!-- auto-fix-retry -->'; then
    # やり直しの依頼（もともと直す回数に数えない依頼）は、同じ文のまま、先頭コミットとPRの説明の目印だけを今の物にして出し直す
    comment "$pr" "$(printf '%s\n' "$body" | sed -E -e "s/(auto-fix-sha: )[0-9a-f]+/\\1${head}/" -e "s/(auto-fix-body: )[0-9a-f]+/\\1$(pr_body_hash "$pr")/")"
    echo "PR #$pr：修正AIは「PRが更新された」ため動かなかったので、やり直しの依頼を最新のコミットで出し直しました"
    return 0
  fi
  # 依頼の文は、コメントの1行目（「@claude 」の後ろ）。前の出し直しの断り書きは付け直す
  message=$(printf '%s\n' "$body" | sed -n '1{s/^@claude //;p;}')
  message=${message%%"$STALE_FIX_NOTE"*}
  # 人向けの理由は、依頼の文の書き出しで種類を見分ける（after-ci.sh・after-review.sh・CONFLICT_FIX_MSG の文と合わせる）。見分けられなければ渡さない（既定の理由）
  case "$message" in
    CIが失敗しました*) reason="CIが失敗したままです" ;;
    レビューで指摘があり*) reason="レビューの指摘が直りませんでした" ;;
    "main とコンフリクト"*) reason="main とのコンフリクトが解けませんでした" ;;
    *) reason="" ;;
  esac
  # コンフリクトの解消の依頼は、同じ種類のまま出し直す（直す回数ではなく、コンフリクトの回数で数える）
  if printf '%s' "$body" | grep -qF "$CONFLICT_KIND_MARK"; then
    request_conflict_fix_or_stop "$pr" "$head" "${message}${STALE_FIX_NOTE}" "main とのコンフリクトが解けませんでした"
  elif [ -n "$reason" ]; then
    request_fix_or_stop "$pr" "$head" "${message}${STALE_FIX_NOTE}" "$reason"
  else
    request_fix_or_stop "$pr" "$head" "${message}${STALE_FIX_NOTE}"
  fi
  echo "PR #$pr：修正AIは「PRが更新された」ため動かなかったので、直す回数に数えず、最新のコミットで依頼を出し直しました"
}
