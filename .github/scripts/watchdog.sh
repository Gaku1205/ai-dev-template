#!/usr/bin/env bash
# 見張り役（watchdog.yml が、定期的に・ほかのワークフローが終わるたびに動かす）：パイプラインが止まったまま動かなくなっていないか見て、自動で再開させる。
#   1. ai:retry が付いた物（使用量の上限・AIのエラーで止まった物）を、待ち時間が過ぎていたらやり直す
#   2. 失敗の知らせも無いまま止まっている物（時間切れなど）を見つけて、ai:retry を付ける
#   2.5 画面案（ai:mocks）のまま、後片付けが動かず止まっている物をやり直す（2回目は人間に回す）
#   3. CIが「承認待ち」で止まっている物を動かし直す
#   3.3 visual:update が付いたまま撮り直しが動いていない物を動かす（コンフリクトならAIに解消させる）
#   3.4 CIは終わっているのに、誰も先へ進めていないPRを動かす（進行役の処理が途中で落ちた・時間切れで呼ばれなかった、など）
#   4. ラベルが無いまま放置されたIssueを企画（ai:plan）に回す
#   4.5 他の Issue・PR の完了待ち（ai:blocked）で、待ち先が全部閉じた物を企画（ai:plan）に戻す
#   5. 使い終わった claude/* ブランチを掃除する
#   6. ラベルの矛盾（ai:queue と ai:implement など）を直す
#   7. 順番待ち（ai:queue）を進める
#   8. 次のやり直しの時刻に、自分を起こす目覚まし（retry-timer.yml）をかける
# 人間の確認待ち（ai:stuck）の物は触らない。
#
# 環境変数：READ_TOKEN（ワークフローのトークン、actions: write・checks: read・statuses: read。CIの実行とチェックを読む・目覚ましを動かす）、RETRY_TIMER（off で目覚ましを使わない）
source "$(dirname "$0")/pipeline-lib.sh"

has_pipeline_token || { echo "PIPELINE_TOKEN が無いので何もしません"; exit 0; }

# これだけ何の動きも無ければ「止まっている」とみなす（分）
IDLE_PLAN_MIN="${IDLE_PLAN_MIN:-30}"
IDLE_IMPLEMENT_MIN="${IDLE_IMPLEMENT_MIN:-45}"
# 実装の「確実に止まった」時間（実装のジョブの上限75分＋PRを作るジョブ5分より長くする）。これ以上は、実装の実行が動いていても拾う
IDLE_IMPLEMENT_HARD_MIN="${IDLE_IMPLEMENT_HARD_MIN:-90}"
IDLE_REVIEW_MIN="${IDLE_REVIEW_MIN:-30}"
IDLE_CI_MIN="${IDLE_CI_MIN:-5}"
# 画面案のジョブ（claude-mocks.yml）の時間の上限（100分）より長くする
IDLE_MOCKS_MIN="${IDLE_MOCKS_MIN:-120}"
# 見張り役が画面案をやり直した印（同じ画面案の回で、やり直すのは1回だけ。2回目は人間に回す）
MOCKS_RETRY_MARK="<!-- auto-mocks-retry -->"
# CIが終わったPRが、これだけ何も起きなければ「誰も進めていない」とみなす（修正AIの時間の上限 30分より長くする）
IDLE_ORPHAN_MIN="${IDLE_ORPHAN_MIN:-45}"

now=$(date +%s)

# コンフリクトの解消の依頼が、応答の無いまま宙に浮いているか（3.2 と 3.4 の ai:hold が使う）。
# 同じ先頭コミットへの依頼があり、いちばん新しい物が IDLE_ORPHAN_MIN 分以上前で、このPRのブランチで Claude Mention の実行が
# 動いても待ってもいなければ、宙に浮いているとみなす（修正AIが時間切れ・取り消しになった、変更なしで終わって after-mention.sh も動かなかった、など）。
# 実行の一覧を読めなければ「動いている」とみなす（動いている修正AIに重ねない）。
# 宙に浮いていれば、1回目は印（auto-fix-retry）を残して同じ依頼をやり直し待ちにし、同じ先頭コミットでもう一度なら人間に回す
# 戻り値：0＝宙に浮いていたので扱った（呼ぶ側は continue する）、1＝何もしない
handle_lost_conflict_request() { # PR番号 先頭コミット ブランチ
  local pr="$1" head="$2" ref="$3" last_at age running last_is_retry
  has_label_or_unreadable "$pr" "ai:retry" && return 1
  last_at=$(all_comments "$pr" | jq -r --arg sha "<!-- auto-fix-sha: $head -->" --arg resume "$RESUME_MARK" '
    (map(select(.body | contains($resume)) | .created_at) | max // "") as $since
    | map(select((.body | test("<!-- auto-fix(-retry)? -->")) and (.body | contains($sha)) and .created_at > $since)) | last | .created_at // ""')
  [ -n "$last_at" ] || return 1
  age=$(idle_min "$last_at")
  [ "$age" -ge "$IDLE_ORPHAN_MIN" ] || return 1
  running=$(GH_TOKEN="$READ_TOKEN" gh api "repos/$REPO/actions/workflows/claude-mention.yml/runs?per_page=30" \
    -q "[.workflow_runs[] | select(.status != \"completed\" and .head_branch == \"$ref\")] | length" 2> /dev/null) || running=1
  [[ "$running" =~ ^[0-9]+$ ]] || running=1
  if [ "$running" -gt 0 ]; then
    echo "PR #$pr：コンフリクトの解消の依頼から${age}分たちましたが、修正AIの実行が動いている（${running} 件）ので、待ちます"
    return 1
  fi
  last_is_retry=$(all_comments "$pr" | jq --arg sha "<!-- auto-fix-sha: $head -->" --arg resume "$RESUME_MARK" '
    (map(select(.body | contains($resume)) | .created_at) | max // "") as $since
    | map(select((.body | test("<!-- auto-fix(-retry)? -->")) and (.body | contains($sha)) and .created_at > $since)) | last
    | (.body // "") | contains("<!-- auto-fix-retry -->")')
  if [ "$last_is_retry" = true ]; then
    stop_for_human "$pr" "main とのコンフリクトの解消を頼みましたが、修正AIの応答がありませんでした（同じ依頼をやり直しても、${age}分のあいだコンフリクトが解けないままです。Actions の Claude Mention の実行を確かめてください）"
  else
    comment "$pr" "🔧 main とのコンフリクトの解消を頼んで${age}分たちましたが、まだコンフリクトしたままなので、同じ依頼をもう一度出します（見張り役）。" || true
    mark_for_retry "$pr" mention "main とのコンフリクトの解消を頼みましたが、修正AIの応答が無いまま${age}分たちました（時間切れ・起動しなかった・変更なしで終わった、など）"
  fi
  return 0
}

idle_min() {
  echo $(( (now - $(date -d "$1" +%s)) / 60 ))
}
# Issue の最後の動きから何分か。更新時刻を読めない・空なら失敗する（空のまま idle_min に渡すと、date -d "" が今日の0時になり、
# 動いている物を「止まった」と見て ai:retry を付けてしまう）。呼ぶ側は、失敗したらその Issue を今回は飛ばす
issue_idle_min() {
  local at
  at=$(gh api "repos/$REPO/issues/$1" -q '.updated_at // ""' 2> /dev/null) || return 1
  [ -n "$at" ] || return 1
  idle_min "$at"
}

# ---- 8. の目覚ましの定義（間引いた回でも、目覚ましだけはかけるので、間引きの判定の前に置く）----
# 次のやり直しの時刻（と、マージ待ちのPRが順番待ちを止めなくなる時刻）に、見張り役を起こす目覚ましをかける。
# GitHub の定期の起動（30分ごと）は、混んでいると数時間遅れる。待ちが明ける時刻が分かっているので、
# その時刻に retry-timer.yml（待ってから見張り役を動かすだけ）を動かしておく。目覚ましは1つだけ（新しい物が古い物を止める）。
# 公開していないリポジトリでは待つあいだも Actions の時間を使うので、変数 RETRY_TIMER に off を入れれば止められる
# 見張りが要る物（進行中の Issue・PR、ラベルの無い Issue）が1つでもあるか。あれば 0
heartbeat_needed() {
  local items pulls hold
  items=$(open_items_json) || return 1
  if printf '%s' "$items" | jq -e --arg owner "${OWNER,,}" '
      def active($l): ($l | map(select(. == "ai:plan" or . == "ai:implement" or . == "ai:mocks" or . == "ai:blocked")) | length) > 0;
      def unlabeled($l): ($l | map(select(startswith("ai:"))) | length) == 0;
      def trusted: ((.user.login // "") | ascii_downcase) as $u | ($u == $owner or $u == "claude[bot]" or $u == "github-actions[bot]");
      def watch: ((.labels // []) | map(.name)) as $l
        | ($l | any(. == "ai:stuck" or . == "ai:skip") | not)
          and (active($l) or (unlabeled($l) and trusted));
      any(.[]; (.pull_request == null) and watch)' > /dev/null 2>&1; then
    return 0
  fi
  pulls=$(open_pulls_json) || return 1
  # 人間のマージ待ちのPR（hold_prs が waiting・expired で出す物）は除く
  hold=$(hold_prs 2> /dev/null | awk '{print $1}' | tr '\n' ' ') || hold=""
  printf '%s' "$pulls" | jq -e --arg repo "$REPO" --arg hold " $hold" '
    any(.[]; (.draft | not)
      and (((.head.repo.full_name // "") | ascii_downcase) == ($repo | ascii_downcase))
      and (((.labels // []) | map(.name) | index("ai:stuck")) | not)
      and ((.number | tostring) as $n | ($hold | contains(" " + $n + " ")) | not))' > /dev/null 2>&1
}

set_retry_timer() {
  local earliest="" n t now_s runs
  [ "${RETRY_TIMER:-on}" = "off" ] && return 0
  now_s=$(date +%s)
  for n in $(open_numbers_with_label "ai:retry" all); do
    has_label_or_unreadable "$n" "ai:stuck" && continue
    t=$(retry_due_at "$n")
    [ "$t" -gt "$now_s" ] || continue
    if [ -z "$earliest" ] || [ "$t" -lt "$earliest" ]; then earliest="$t"; fi
  done
  # 順番待ちがあるとき、人間のマージ待ち（ai:hold）のPRが進行中から外れる時刻（ai:hold が付いて HOLD_BLOCK_MIN 分）にも起こす。
  # 外れる時刻には何のイベントも起きないので、定期の起動が遅れると、順番待ちが何時間も止まる（PR #162 で、60分のはずが止まり続けた）
  local queued pr state w
  queued=$(count_open_issues_with_label "ai:queue" 2> /dev/null) || queued=0
  if [ "${queued:-0}" -gt 0 ]; then
    while read -r pr state; do
      [ "$state" = waiting ] || continue
      w=$(hold_wait_min "$pr")
      [ -n "$w" ] || continue
      t=$(( now_s + (HOLD_BLOCK_MIN - w) * 60 + 60 ))
      [ "$t" -gt "$now_s" ] || continue
      if [ -z "$earliest" ] || [ "$t" -lt "$earliest" ]; then earliest="$t"; fi
    done < <(hold_prs 2> /dev/null)
  fi
  # 定期の起動は当てにならない（実際は1日3〜4回）。進行中の物が残っている間は、WATCHDOG_HEARTBEAT_MIN 分後にも起こす（早い方を使う）。
  # 写しがあれば API は増えない。何も待っていなければかけない（静かなリポジトリで Actions を回し続けない）
  local hb="${WATCHDOG_HEARTBEAT_MIN:-15}"
  [[ "$hb" =~ ^[0-9]+$ ]] && [ "$hb" -ge 1 ] || hb=15
  if heartbeat_needed; then
    t=$(( now_s + hb * 60 ))
    if [ -z "$earliest" ] || [ "$t" -lt "$earliest" ]; then earliest="$t"; fi
  fi
  # 順番待ちがあるとき、並列の上限が変わる次の時刻（夜の始まり／終わり・上書きの期限）の1分後にも起こす
  if [ "${queued:-0}" -gt 0 ]; then
    t=$(parallel_next_change "$now_s")
    if [ -n "$t" ]; then
      t=$(( t + 60 ))
      if [ -z "$earliest" ] || [ "$t" -lt "$earliest" ]; then earliest="$t"; fi
    fi
  fi
  [ -z "$earliest" ] && return 0
  # 1回の待ちは最大 RETRY_TIMER_MAX_MIN 分（ジョブの時間の上限 6時間に収める）。それより先なら、起きた見張り役がかけ直す
  local cap=$(( now_s + ${RETRY_TIMER_MAX_MIN:-340} * 60 ))
  [ "$earliest" -gt "$cap" ] && earliest="$cap"
  # もう同じかそれより早い時刻の目覚ましが待っていれば、かけ直さない
  runs=$(GH_TOKEN="$READ_TOKEN" gh api "repos/$REPO/actions/workflows/retry-timer.yml/runs?per_page=20" \
    -q '[.workflow_runs[] | select(.status != "completed") | .display_title | capture("目覚まし (?<at>[0-9]+)") | .at | tonumber]' 2> /dev/null) || runs="[]"
  if printf '%s' "${runs:-[]}" | jq -e --argjson e "$earliest" --argjson n "$now_s" 'any(.[]; . > $n and . <= $e + 120)' > /dev/null 2>&1; then
    echo "次のやり直しの目覚ましは、もうかかっています"
    return 0
  fi
  if GH_TOKEN="$READ_TOKEN" gh api -X POST "repos/$REPO/actions/workflows/retry-timer.yml/dispatches" \
       -f ref="${GITHUB_REF_NAME:-main}" -f "inputs[at]=$earliest" > /dev/null 2>&1; then
    echo "次のやり直しの目覚ましを $(TZ=Asia/Tokyo date -d "@$earliest" +%H:%M) にかけました"
  else
    echo "::warning::やり直しの目覚まし（retry-timer.yml）を動かせませんでした。定期の見張りでやり直します"
  fi
}

# ---- 0. 続けて動くのを間引く ----
# ほかのワークフローが終わるたび（workflow_run）に動くと、作業が続くリポジトリでは1時間に20回近く、全部を見直す（2026年11月18日、
# パイプラインの鍵の回数制限＝全部のリポジトリで1時間5000回の半分近くを、見張り役だけで使っていた）。止まりの判定は「5〜45分動きが無い」
# なので、数分おきに見直しても何も変わらない。workflow_run で起きたときは、同じ時間の枠（WATCHDOG_SLOT_MIN 分。時計の区切り）で、
# もう見張りが成功していれば、何もせず終わる。定期・目覚まし・手で動かしたときは、いつも全部見る。
# 実行の一覧は READ_TOKEN（ワークフローのトークン。回数制限はリポジトリごとに別）で読む。読めなければ、間引かずに全部見る
WATCHDOG_SLOT_MIN="${WATCHDOG_SLOT_MIN:-10}"
if [ "${GITHUB_EVENT_NAME:-}" = workflow_run ] && [[ "$WATCHDOG_SLOT_MIN" =~ ^[0-9]+$ ]] && [ "$WATCHDOG_SLOT_MIN" -gt 0 ] &&
  [[ "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ ]]; then
  if recent_runs=$(GH_TOKEN="${READ_TOKEN:-}" gh api "repos/$REPO/actions/workflows/watchdog.yml/runs?per_page=50" 2> /dev/null) &&
    watchdog_slot_taken "$recent_runs" "$GITHUB_RUN_ID" "$(date +%s)" "$WATCHDOG_SLOT_MIN"; then
    echo "この${WATCHDOG_SLOT_MIN}分の枠では、もう見張りが済んでいるので、今回は何もしません（次の枠・定期の見張り・目覚ましで見ます）"
    # 済んだあとに付いた ai:retry・ai:hold の目覚ましだけは、かけ忘れない（目覚ましをかけるのは見張り役だけ）。一覧は2回ほどで読める
    use_open_snapshot || true
    set_retry_timer
    exit 0
  fi
fi

# 開いている Issue・PR の一覧（ラベルつき）は、ここで1回ずつ読んで写しを持ち、この実行の間は写しから答える
# （pipeline-lib.sh の use_open_snapshot。ラベルごとの一覧・ラベルの確かめのたびに API を呼ばない）。
# 一覧は、ページをまたいで全部読む（api_list。100件までなら API は1回のまま。per_page=100 だけだと、101件目からの
# Issue・PR を見張れず、止まったままになる）。写しを読めなければ、今までどおり、その都度 API から読む
use_open_snapshot || echo "::warning::開いている Issue・PR の一覧を読めなかったので、その都度 API から読みます"
open_prs=$(open_pulls_json)
# 実装AIのブランチ（claude/issue-N-...）のPRがopenであるか
has_open_pr_for_issue() {
  printf '%s' "$open_prs" | jq -e --arg p "claude/issue-$1-" 'any(.[]; .head.ref | startswith($p))' > /dev/null
}

# ---- 1. ai:retry が付いた物をやり直す ----
handled=" "   # この実行でやり直した番号（同じ実行で、すぐ次の確認に引っかからないように）
for n in $(open_numbers_with_label "ai:retry" all); do
  # ラベルを読めなければ、この回は触らない（「ai:stuck・ai:skip が無い」と取り違えて、やり直さない。次の見張りで見る）
  stuck_rc=0
  has_label "$n" "ai:stuck" || stuck_rc=$?
  if [ "$stuck_rc" -eq 2 ]; then
    echo "#$n：ラベルを読めないので、今回は触りません"
    continue
  fi
  if [ "$stuck_rc" -eq 0 ]; then
    remove_label "$n" "ai:retry"
    continue
  fi
  # まだ動かさない物（ai:skip。オーナー以外が作って受付が止めた Issue など）は、やり直さない。印だけ外す
  # （やり直すと、パイプラインの鍵が ai:plan を付け直し、オーナーが確かめていない Issue を企画・実装してしまう）
  skip_rc=0
  has_label "$n" "ai:skip" || skip_rc=$?
  if [ "$skip_rc" -eq 2 ]; then
    echo "#$n：ラベルを読めないので、今回は触りません"
    continue
  fi
  if [ "$skip_rc" -eq 0 ]; then
    remove_label "$n" "ai:retry"
    echo "#$n：ai:skip が付いているので、やり直しません"
    continue
  fi
  retry_due "$n" || { echo "#$n：やり直すにはまだ早いです"; continue; }

  record=$(retry_comment "$n")
  # やり直しの記録が無い物は、ここでは触らない（3.9 が ai:stuck にして人間に回す）
  [ -z "$record" ] && continue
  body=$(printf '%s' "$record" | jq -r .body)
  kind=$(printf '%s' "$body" | sed -nE 's/.*kind=([a-z]+).*/\1/p' | tail -1)
  reason=$(printf '%s' "$body" | sed -nE 's/^理由：(.*)$/\1/p' | head -1)
  count=$(retry_count "$n")
  next=$((count + 1))
  # 使用量の上限で待っていたぶんは、やり直しの回数を使わない（上限の待ちを始めた時刻は、次の失敗のために残す）
  limit_first=$(retry_mark_value "$body" limit-first)
  if [ -n "$(retry_mark_value "$body" limit-until)" ]; then
    next=$count
  fi
  # 企画のやり直し待ちなのに、企画がもう先へ進んでいる（別の実行が結果を出した）なら、やり直さない。印だけ外す
  # （やり直すと、順番待ち・実装中の Issue をもう一度企画し直してしまう）
  if [ "$kind" = plan ] && ! has_label "$n" "ai:plan"; then
    moved=""
    for l in ai:implement ai:queue ai:question ai:mocks ai:blocked; do
      if has_label "$n" "$l"; then moved="$l"; break; fi
    done
    if [ -n "$moved" ]; then
      remove_label "$n" "ai:retry"
      echo "#$n：企画はもう先へ進んでいる（${moved}）ので、やり直しません"
      continue
    fi
  fi
  # 企画・画面案・実装のやり直しは、作者がオーナーかパイプラインの Issue だけ（他人の Issue に ai:plan などを付け直さない）
  case "$kind" in
    plan | mocks | implement)
      author=$(gh api "repos/$REPO/issues/$n" -q .user.login 2> /dev/null) || author=""
      if ! trusted_author "$author"; then
        add_label "$n" "ai:skip"
        remove_label "$n" "ai:retry"
        echo "#$n：オーナー以外（${author:-不明}）が作った Issue なので、やり直さず ai:skip で止めました"
        continue
      fi
      ;;
  esac
  echo "#$n：${kind} をやり直します（${next}/${MAX_RETRY}回目）"
  handled="${handled}${n} "

  case "$kind" in
    plan)
      write_retry_record "$n" "$next" "$kind" "$reason" "" "$limit_first"
      remove_label "$n" "ai:retry"
      remove_label "$n" "ai:plan"
      add_label "$n" "ai:plan"
      ;;
    mocks)
      write_retry_record "$n" "$next" "$kind" "$reason" "" "$limit_first"
      remove_label "$n" "ai:retry"
      if has_label "$n" "ai:mocks"; then
        # 付け直すと labeled イベントが起きて、画面案のワークフローが最初から動く。印は「やり直した」の記録（次に止まったら人間に回す）
        comment "$n" "🔁 画面案をやり直します（見張り役。同じ画面案でやり直すのは1回だけです）。

${MOCKS_RETRY_MARK}"
        remove_label "$n" "ai:mocks"
        add_label "$n" "ai:mocks"
      else
        echo "#$n：画面案はもう先へ進んでいる（ai:mocks が無い）ので、やり直しません"
      fi
      ;;
    implement)
      write_retry_record "$n" "$next" "$kind" "$reason" "" "$limit_first"
      remove_label "$n" "ai:retry"
      if has_open_pr_for_issue "$n"; then
        echo "#$n：PRができているので、実装はやり直しません"
      else
        remove_label "$n" "ai:implement"
        add_label "$n" "ai:implement"
      fi
      ;;
    review)
      write_retry_record "$n" "$next" "$kind" "$reason" "" "$limit_first"
      remove_label "$n" "ai:retry"
      request_review "$n"
      ;;
    merge)
      # CIもレビューも済んでいて、マージだけができなかった（CI 以外のチェックが通っていない・GitHub が断った）。
      # AIは動かさず、レビューのあとの処理（after-review.sh）のマージの判断だけをやり直す
      pr_json=$(gh api "repos/$REPO/pulls/$n")
      head=$(printf '%s' "$pr_json" | jq -r .head.sha)
      ref=$(printf '%s' "$pr_json" | jq -r .head.ref)
      write_retry_record "$n" "$next" "$kind" "$reason" "" "$limit_first"
      remove_label "$n" "ai:retry"
      head_date=$(gh api "repos/$REPO/commits/$head" -q .commit.committer.date)
      reviewed=$(all_comments "$n" | jq --arg since "$head_date" \
        '[.[] | select((.user.login == "claude[bot]" or .user.login == "github-actions[bot]") and (.body | startswith("## Code review")) and .created_at >= $since)] | length')
      if [ "$(printf '%s' "$pr_json" | jq -r .state)" != open ]; then
        echo "PR #$n：もう閉じているので、マージはやり直しません"
      elif [ "$reviewed" -eq 0 ]; then
        # 待っている間に新しいコミットが入った：CI → レビューのいつもの流れが進めるので、ここでは何もしない
        echo "PR #$n：先頭コミットのレビュー結果がまだ無いので、マージはやり直しません（CIとレビューの流れに任せます）"
      else
        CONCLUSION=success HEAD_SHA="$head" HEAD_BRANCH="$ref" "$SCRIPT_DIR/after-review.sh" ||
          echo "::warning::PR #$n：マージの判断をやり直せませんでした（次の見張りで拾います）"
        # 別のスクリプトの中のラベルの付け外し・マージは写しに入らないので、読み直す
        use_open_snapshot || true
      fi
      ;;
    mention)
      pr_json=$(gh api "repos/$REPO/pulls/$n")
      head=$(printf '%s' "$pr_json" | jq -r .head.sha)
      # 前回の依頼の文を、そのままもう一度出す（印のコメント行は除く）
      last_request=$(all_comments "$n" | jq -r 'map(select(.body | test("<!-- auto-fix(-retry)? -->"))) | last | .body // ""')
      request=$(printf '%s' "$last_request" | sed -e '/^<!--/d' -e '/^（前回は応答がなかったので/d')
      model_mark=""
      if printf '%s' "$last_request" | grep -q 'auto-fix-model: opus'; then
        model_mark="
<!-- auto-fix-model: opus -->"
      fi
      write_retry_record "$n" "$next" "$kind" "$reason" "" "$limit_first"
      remove_label "$n" "ai:retry"
      comment "$n" "${request}

（前回は応答がなかったので、同じ依頼をもう一度出します。自動のやり直し ${next}/${MAX_RETRY}）

<!-- auto-fix-retry -->
<!-- auto-fix-sha: ${head} -->
<!-- auto-fix-body: $(pr_body_hash "$n") -->${model_mark}"
      ;;
    *)
      echo "#$n：やり直しの種類が分からないので、印だけ外します"
      remove_label "$n" "ai:retry"
      ;;
  esac
done

# ---- 2. 失敗の知らせも無いまま止まっている物 ----
# 企画AI：ai:plan が付いたまま動きが無い
for n in $(open_numbers_with_label "ai:plan"); do
  case "$handled" in *" $n "*) continue ;; esac
  # ラベル・更新時刻を読めなければ、この回は飛ばす（「付いていない」「今日の0時から動いていない」と取り違えない）
  has_label_or_unreadable "$n" "ai:stuck" && continue
  has_label_or_unreadable "$n" "ai:retry" && continue
  has_label_or_unreadable "$n" "ai:skip" && continue
  m=$(issue_idle_min "$n") || { echo "#$n：更新時刻を読めないので、今回は見ません"; continue; }
  [ "$m" -lt "$IDLE_PLAN_MIN" ] && continue
  mark_for_retry "$n" plan "企画AIの終了が確認できないまま${m}分たちました"
done

# 実装AI：ai:implement が付いたまま、PRもできず動きが無い
# 実装AIのジョブは、審査役と直しを含めて最大75分動く。その間 Issue には何も書かれないことがあるので、
# 実装AIの実行がまだ動いている間は「止まった」とみなさない（動いている物に ai:retry を付けない）
# 動いている（in_progress）物と、始まるのを待っている（queued）物の両方を数える（画面案の mocks_running と同じ数え方）。
# 一覧を読めなければ、その回は実装の止まりを見ない（「動いていない」と読むと、動いている実装に ai:retry を付け、二重に実装が走る）
implement_running=0
for st in in_progress queued; do
  if ! c=$(GH_TOKEN="$READ_TOKEN" gh api "repos/$REPO/actions/workflows/claude-implement.yml/runs?status=$st&per_page=30" \
    -q '[.workflow_runs[] | select(.status != "completed")] | length' 2> /dev/null) || ! [[ "$c" =~ ^[0-9]+$ ]]; then
    implement_running=unknown
    break
  fi
  implement_running=$(( implement_running + c ))
done
for n in $(open_numbers_with_label "ai:implement"); do
  case "$handled" in *" $n "*) continue ;; esac
  has_label_or_unreadable "$n" "ai:stuck" && continue
  has_label_or_unreadable "$n" "ai:retry" && continue
  has_label_or_unreadable "$n" "ai:skip" && continue
  has_open_pr_for_issue "$n" && continue
  m=$(issue_idle_min "$n") || { echo "#$n：更新時刻を読めないので、今回は見ません"; continue; }
  [ "$m" -lt "$IDLE_IMPLEMENT_MIN" ] && continue
  # 確実に止まった時間（HARD）未満では、実装の実行が動いている間・一覧を読めない間は触らない。
  # HARD 以上は、実行が動いていても（ジョブの上限を過ぎているので）止まったとみなす
  if [ "$m" -lt "$IDLE_IMPLEMENT_HARD_MIN" ]; then
    if [ "$implement_running" = unknown ]; then
      echo "#$n：実装AIの実行の一覧を読めないので、実装の止まりは今回は見ません"
      continue
    fi
    if [ "$implement_running" -gt 0 ]; then
      echo "#$n：実装AIの実行が動いている（${implement_running} 件）ので、実装の止まりは今回は見ません"
      continue
    fi
  fi
  mark_for_retry "$n" implement "実装AIの終了が確認できないまま${m}分たちました"
done

# ---- 2.5 画面案：ai:mocks が付いたまま、動きが無い ----
# 画面案は、AIが動くジョブ（work）のあとの後片付け（publish：画面案のコメントを書いて ai:question にする・案なしなら ai:plan にする）で
# 次へ進む。work が時間切れ・取り消しになる、実行環境が落ちる、後片付けが途中で落ちると、ai:mocks が残ったまま誰も拾わない
# （失敗の知らせも ai:retry も付かない）。IDLE_MOCKS_MIN 分なにも起きず、画面案のジョブも動いていなければ、やり直し待ちにする。
# やり直すのは、同じ画面案の回で1回だけ（Opus を最大100分動かすので、何度も回さない）。やり直しても止まったら、人間に回す
for n in $(open_numbers_with_label "ai:mocks"); do
  case "$handled" in *" $n "*) continue ;; esac
  has_label_or_unreadable "$n" "ai:stuck" && continue
  has_label_or_unreadable "$n" "ai:retry" && continue
  has_label_or_unreadable "$n" "ai:skip" && continue
  m=$(issue_idle_min "$n") || { echo "#$n：更新時刻を読めないので、今回は見ません"; continue; }
  [ "$m" -lt "$IDLE_MOCKS_MIN" ] && continue
  # IDLE_MOCKS_MIN は画面案のジョブの上限（100分）＋後片付け（10分）より長いので、動いている実行があっても
  # この時間たった物は止まっている（どの Issue の実行かは分からないので、実行の確認はしない）
  # この画面案の回で、もうやり直したか：いちばん新しい「画面案のコメント」（前の回が終わった印）・人間の再開より後に、やり直しの印がある
  retried=$(all_comments "$n" | jq --arg mk "$MOCKS_RETRY_MARK" --arg resume "$RESUME_MARK" '
    (map(select((.body | contains("<!-- ai-mocks: ")) or (.body | contains($resume))) | .created_at) | max // "") as $since
    | [.[] | select((.body | contains($mk)) and .created_at > $since)] | length')
  if [ "${retried:-0}" -gt 0 ]; then
    stop_issue_for_human "$n" "画面案（ai:mocks）が、やり直しても${m}分のあいだ進みませんでした（画面案のコメントも、企画への切り替えも出ていません）。Actions の Claude Mocks の実行を確かめてください。画面案をもう一度作るなら \`ai:stuck\` を外し、案なしで進めるなら \`ai:mocks\` を外して \`ai:plan\` を付けてください"
    echo "#$n：画面案をやり直しても進まないので、人間に回しました"
    continue
  fi
  mark_for_retry "$n" mocks "画面案（ai:mocks）のまま${m}分のあいだ動きがありません（画面案のジョブが時間切れ・取り消しになり、後片付けが動かなかった、など）"
done

# PRごとの確認
for pr in $(printf '%s' "$open_prs" | jq -r '.[].number'); do
  case "$handled" in *" $pr "*) continue ;; esac
  has_label_or_unreadable "$pr" "ai:stuck" && continue
  pr_json=$(printf '%s' "$open_prs" | jq -c --argjson n "$pr" '.[] | select(.number == $n)')
  head=$(printf '%s' "$pr_json" | jq -r .head.sha)
  ref=$(printf '%s' "$pr_json" | jq -r .head.ref)
  # fork からの他人のPRは何もしない（push・空コミット・修正の依頼をしない。pr-trust.sh と同じく、head がこのリポジトリのPRだけ）
  if ! pr_head_is_repo "$pr_json"; then
    echo "PR #$pr：head がこのリポジトリではない（fork）ので、何もしません"
    continue
  fi
  m=$(idle_min "$(printf '%s' "$pr_json" | jq -r .updated_at)")
  runs="[]"
  runs_read=false

  # ---- 3. CIが承認待ちで止まっている ----
  if [ "$m" -ge "$IDLE_CI_MIN" ]; then
    # 読めたときだけ runs_read=true にする（読めなかったのを「CIの実行が0件」と取り違えないため）
    if runs=$(GH_TOKEN="$READ_TOKEN" gh api "repos/$REPO/actions/runs?head_sha=$head&event=pull_request&per_page=50" \
      -q '[.workflow_runs[] | select(.name == "CI")]') && [ -n "$runs" ]; then
      runs_read=true
    else
      runs="[]"
    fi
    waiting=$(printf '%s' "$runs" | jq '[.[] | select(.conclusion == "action_required")] | length')
    running=$(printf '%s' "$runs" | jq '[.[] | select(.conclusion != "action_required")] | length')
    if [ "$waiting" -gt 0 ] && [ "$running" -eq 0 ]; then
      rerun_ci_if_waiting_approval "$pr" "$head" "$ref"
      continue
    fi
    # ---- 3.2 main とコンフリクトしていて、CIが動いていない ----
    # コンフリクトしたPRでは GitHub が CI（pull_request）を動かさないので、after-ci も呼ばれず止まる
    # （例：基準の画像の撮り直しを push している間に、別のPRが main に入った）。AIに解消させる。
    # 配布のPR（pipeline-sync/*）は次の配布で作り直されるので触らない。同じ先頭への依頼が出ていれば待つ
    # CIの一覧を読めたときだけ見る。マージの状態が unknown（mergeable が null＝GitHub が計算中）のときは、頼まず次の見張りまで待つ
    merge_state=unknown
    if [ "$runs_read" = true ] && [ "$(printf '%s' "$runs" | jq 'length')" -eq 0 ] && [[ "$ref" != pipeline-sync/* ]]; then
      merge_state=$(pr_merge_state "$pr")
    fi
    if [ "$merge_state" = unknown ] && [ "$runs_read" = true ] && [ "$(printf '%s' "$runs" | jq 'length')" -eq 0 ] &&
      [[ "$ref" != pipeline-sync/* ]]; then
      echo "PR #$pr：CIの実行が無く、マージの状態も分からない（GitHub が計算中）ので、今回は何もしません（次の見張りで見ます）"
      continue
    fi
    if [ "$merge_state" = dirty ]; then
      asked=$(all_comments "$pr" | jq --arg mark "auto-fix-sha: $head" '[.[] | select(.body | contains($mark))] | length')
      if [ "$asked" -eq 0 ]; then
        request_fix_or_stop "$pr" "$head" "main とコンフリクトしていて、このPRのCIが動いていません（コンフリクトがあるとCIは動きません）。\`git fetch origin main\` のあと \`git merge origin/main\` でコンフリクトを解消してください。両方の変更の意図を残し（docs/spec.md・docs/design.md も両方の決まりを残す）、どちらかを捨てるときはPRにコメントで理由を書いてください。" "main とのコンフリクトが解けませんでした"
      else
        # 頼んだのに応答が無いまま IDLE_ORPHAN_MIN 分たったら、やり直し→人間へ（CIが無いので、3.4 には来ない）
        handle_lost_conflict_request "$pr" "$head" "$ref" || true
      fi
      continue
    fi
  fi

  # ---- 3.3 visual:update が付いたまま、撮り直しが動いていない ----
  # コンフリクトしたPRでは GitHub が撮り直し（pull_request で動く）を動かさない。ラベルだけが残り、終わるとラベルを外す仕組みも動かないので、
  # 誰も動かなくなる。ラベルを外し、コンフリクトならAIに解消させる。コンフリクトが無いのに動いていなければ、1回だけ付け直す
  if has_label "$pr" "visual:update" && [ "$m" -ge "${IDLE_VISUAL_MIN:-10}" ]; then
    vruns=$(GH_TOKEN="$READ_TOKEN" gh api "repos/$REPO/actions/workflows/visual-update.yml/runs?per_page=30" \
      -q "[.workflow_runs[] | select(.status != \"completed\" and .head_branch == \"$ref\")] | length" 2> /dev/null) || vruns=0
    if [ "${vruns:-0}" -eq 0 ]; then
      remove_label "$pr" "visual:update"
      relabel_mark="<!-- auto-visual-relabel: ${head} -->"
      if [ "$(pr_merge_state "$pr")" = dirty ]; then
        request_fix_or_stop "$pr" "$head" "基準の画像の撮り直し（visual:update）が、${m}分たっても動いていません。main とコンフリクトしているためです（コンフリクトがあると、撮り直しもCIも動きません）。\`git fetch origin main\` のあと \`git merge origin/main\` でコンフリクトを解消してください。画像など、中身を混ぜられないファイルは \`git checkout --theirs -- パス\` で main の側を取って \`git add\` し、PR に「見た目を変えたので visual:update ラベルで基準の画像を撮り直してください」とコメントしてください。" "main とのコンフリクトが解けず、基準の画像の撮り直しが動きませんでした"
      elif all_comments "$pr" | jq -e --arg mk "$relabel_mark" 'any(.[]; .body | contains($mk))' > /dev/null; then
        stop_for_human "$pr" "基準の画像の撮り直し（visual:update）を付け直しても、撮り直しが動きませんでした（Actions の Visual Update を確認してください）"
      else
        comment "$pr" "🔧 visual:update が付いたまま${m}分たっても、撮り直しが動いていなかったので、付け直します（見張り役）。

${relabel_mark}"
        add_label "$pr" "visual:update"
        echo "PR #$pr：撮り直しが動いていなかったので、visual:update を付け直しました"
      fi
      continue
    fi
  fi

  # レビューAI：ai:review を付けたのに結果が出ないまま止まっている
  if has_label "$pr" "ai:review" && ! has_label_or_unreadable "$pr" "ai:retry" &&[ "$m" -ge "$IDLE_REVIEW_MIN" ]; then
    head_date=$(gh api "repos/$REPO/commits/$head" -q .commit.committer.date)
    reviewed=$(all_comments "$pr" | jq --arg since "$head_date" \
      '[.[] | select((.user.login == "claude[bot]" or .user.login == "github-actions[bot]") and (.body | startswith("## Code review")) and .created_at >= $since)] | length')
    # レビューAIが動けないPR（レビューのワークフローを変えるPR）だと知らせてある先頭コミットは、結果が無いのが正しい（人間のマージ待ち）
    if [ "$reviewed" -eq 0 ] && ! all_comments "$pr" | jq -e --arg mk "$REVIEW_UNAVAILABLE_MARK $head" 'any(.[]; .body | contains($mk))' > /dev/null; then
      mark_for_retry "$pr" review "レビューAIの結果が出ないまま${m}分たちました"
      continue
    fi
  fi

  # ---- 3.4 CIは終わっているのに、誰も先へ進めていない ----
  # 次の一手は、CI・レビューAI・修正AIが終わったときに進行役（pipeline.yml）が決める。その処理が途中で落ちた（APIの一時的なエラー・
  # 回数制限）・呼ばれなかった（CIや修正AIが時間切れで「取り消し」になると、進行役は動かない）ときは、ラベルも記録も残らず、
  # 誰も動かないまま止まる。CIが終わっていて、待つ理由（ai:stuck・ai:retry・visual:update・マージ待ちの ai:hold）が無いのに
  # IDLE_ORPHAN_MIN 分なにも起きていなければ、続きを動かす。同じ先頭コミットには1回だけ。それでも進まなければ人間に回す
  # fork からの他人のPRは見ない（進行役も扱わない。pr-trust.sh と同じく、head がこのリポジトリのPRだけ）。
  # 配布のPR（pipeline-sync/*）も見る（main の取り込み・マージが落ちたまま、次の配布まで黙って残らないように）。続きは after-ci.sh の配布の流れが決める
  if [ "$m" -ge "$IDLE_ORPHAN_MIN" ] &&
    [ "$(printf '%s' "$pr_json" | jq -r --arg r "$REPO" '((.head.repo.full_name // "") | ascii_downcase) == ($r | ascii_downcase)')" = true ] &&
    [ "$(printf '%s' "$pr_json" | jq -r '.draft // false')" != true ] &&
    ! has_label_or_unreadable "$pr" "ai:retry" && ! has_label_or_unreadable "$pr" "visual:update"; then
    ci=$(printf '%s' "${runs:-[]}" | jq -c 'sort_by(.created_at // "") | last // empty')
    if [ -n "$ci" ] && [ "$(printf '%s' "$ci" | jq -r '.status // "completed"')" = completed ]; then
      ci_conclusion=$(printf '%s' "$ci" | jq -r '.conclusion // ""')
      ci_id=$(printf '%s' "$ci" | jq -r '.id // ""')
      comments=$(all_comments "$pr")
      head_date=$(gh api "repos/$REPO/commits/$head" -q .commit.committer.date)
      reviewed=$(printf '%s' "$comments" | jq --arg since "$head_date" \
        '[.[] | select((.user.login == "claude[bot]" or .user.login == "github-actions[bot]") and (.body | startswith("## Code review")) and .created_at >= $since)] | length')
      # マージ待ち（ai:hold で、レビューまで済んでいる。または、レビューAIが動けないPRだと知らせてある）は、人間が押すのを待っている
      if has_label "$pr" "ai:hold" && { [ "$reviewed" -gt 0 ] ||
        printf '%s' "$comments" | jq -e --arg mk "$REVIEW_UNAVAILABLE_MARK $head" 'any(.[]; .body | contains($mk))' > /dev/null; }; then
        # 人間を待っている間に main が進んで、コンフリクトしたら、AIに解消を頼む（待ちが長い PR を順番待ちが追い越すので、あとで入る変更とぶつかりやすい）。
        # 同じ先頭コミットへの依頼は1回だけ
        if [[ "$ref" != pipeline-sync/* ]] && [ "$(pr_merge_state "$pr")" = dirty ]; then
          if ! printf '%s' "$comments" | jq -e --arg mk "auto-fix-sha: $head" 'any(.[]; .body | contains($mk))' > /dev/null; then
            request_fix_or_stop "$pr" "$head" "人間のマージ待ちの間に main が進み、コンフリクトしています。\`git fetch origin main\` のあと \`git merge origin/main\` でコンフリクトを解消してください。両方の変更の意図を残し（docs/spec.md・docs/design.md も両方の決まりを残す）、どちらかを捨てるときはPRにコメントで理由を書いてください。" "main とのコンフリクトが解けませんでした"
          else
            # 頼んだのに応答が無いまま IDLE_ORPHAN_MIN 分たったら、やり直し→人間へ
            handle_lost_conflict_request "$pr" "$head" "$ref" || true
          fi
        fi
        continue
      fi
      nudge_mark="<!-- auto-nudge: ${head} -->"
      if printf '%s' "$comments" | jq -e --arg mk "$nudge_mark" 'any(.[]; .body | contains($mk))' > /dev/null; then
        stop_for_human "$pr" "CIは終わっています（結果：${ci_conclusion:-不明}）が、${m}分のあいだ何も進んでいません。見張り役が1回続きを動かしても進みませんでした（Actions の Pipeline・Claude Review・Claude Mention の実行と、CI以外のチェックを確かめてください）"
        continue
      fi
      # 直す依頼が出たまま、応答が無い（修正AIが時間切れ・起動しなかった）：いちばん新しい依頼がこの先頭コミットへの物で、そのあとにレビューが無い
      lost_fix=$(printf '%s' "$comments" | jq --arg sha "auto-fix-sha: $head" '
        (map(select(.body | test("<!-- auto-fix(-retry)? -->"))) | last) as $req
        | if $req == null or ($req.body | contains($sha) | not) then false
          else ([.[] | select((.body | startswith("## Code review")) and .created_at > $req.created_at)] | length) == 0 end')
      if [ "$lost_fix" = true ]; then
        comment "$pr" "🔧 直す依頼に応答が無いまま${m}分たったので、同じ依頼をもう一度出します（見張り役）。

${nudge_mark}"
        mark_for_retry "$pr" mention "直す依頼を出しましたが、修正AIの応答が無いまま${m}分たちました（時間切れ・起動しなかった、など）"
        continue
      fi
      case "$ci_conclusion" in
        success | failure)
          comment "$pr" "🔧 CIは終わっています（結果：${ci_conclusion}）が、${m}分のあいだ次の工程が始まっていなかったので、続きを動かします（見張り役）。

${nudge_mark}"
          echo "PR #$pr：CI（${ci_conclusion}）のあと誰も進めていないので、続きを動かします"
          CONCLUSION="$ci_conclusion" HEAD_SHA="$head" HEAD_BRANCH="$ref" RUN_ID="$ci_id" "$SCRIPT_DIR/after-ci.sh" ||
            echo "::warning::PR #$pr：続きを動かせませんでした（次の見張りで人間に回します）"
          # 別のスクリプトの中のラベルの付け外し・マージは写しに入らないので、読み直す
          use_open_snapshot || true
          ;;
        *)
          # 取り消し・時間切れなど：進行役は呼ばれない。CIを1回だけ動かし直す
          if [ -n "$ci_id" ] && GH_TOKEN="$READ_TOKEN" gh api -X POST "repos/$REPO/actions/runs/$ci_id/rerun" > /dev/null 2>&1; then
            comment "$pr" "🔧 CIが「${ci_conclusion:-不明}」で終わったまま${m}分たったので、CIを動かし直します（見張り役。時間切れ・取り消しのときは、進行役が呼ばれないため）。

${nudge_mark}"
            echo "PR #$pr：CI（${ci_conclusion:-不明}）を動かし直しました"
          else
            stop_for_human "$pr" "CIが「${ci_conclusion:-不明}」で終わったまま${m}分たち、動かし直すこともできませんでした（Actions の CI を確かめてください）"
          fi
          ;;
      esac
      continue
    elif [ "$runs_read" = true ] && [ -z "$ci" ] && [[ "$ref" != pipeline-sync/* ]] && [ "$(pr_merge_state "$pr")" != dirty ]; then
      # CIの実行が1件も無い（イベントの取りこぼしなど）：レビューが通っても after-review.sh は「CIがまだ」で終わり、印も通知も無く止まる。
      # 空のコミットを足してCIを動かす。同じ先頭コミットには1回だけ。印があるのにまだ0件なら人間に回す
      # （配布のPRには空のコミットを足さない。次の配布で作り直される）
      # （コンフリクト中は 3.2 が扱う。待つ理由のある ai:hold でマージ待ちのPRは、CIの実行がある前提なのでここでは区別しない）
      nudge_mark="<!-- auto-nudge: ${head} -->"
      if all_comments "$pr" | jq -e --arg mk "$nudge_mark" 'any(.[]; .body | contains($mk))' > /dev/null; then
        stop_for_human "$pr" "このPRの先頭コミットにはCIの実行が1件もありません。見張り役が空のコミットで1回CIを動かしても、${m}分のあいだ動きませんでした（Actions の CI と、リポジトリのActionsの設定を確かめてください）"
        continue
      fi
      if tree=$(gh api "repos/$REPO/git/commits/$head" -q .tree.sha 2> /dev/null) &&
        new=$(gh api "repos/$REPO/git/commits" -f message="CIを動かす（先頭コミットにCIの実行が無かったため）" \
          -f tree="$tree" -f "parents[]=$head" -q .sha 2> /dev/null) &&
        gh api -X PATCH "repos/$REPO/git/refs/heads/$ref" -f sha="$new" > /dev/null 2>&1; then
        # 印は、足した空のコミット（これが新しい先頭）に付ける。そのコミットにもCIの実行が無ければ、次の見張りで人間に回す
        comment "$pr" "🔧 先頭コミットにCIの実行が1件も無いまま${m}分たったので、空のコミットを足してCIを動かします（見張り役）。

<!-- auto-nudge: ${new} -->"
        echo "PR #$pr：CIの実行が0件なので、空のコミット $new でCIを動かします"
      else
        stop_for_human "$pr" "先頭コミットにCIの実行が1件も無いまま${m}分たち、空のコミットでCIを動かすこともできませんでした（Actions の設定と、ブランチの保護を確かめてください）"
      fi
      continue
    fi
  fi
done

# ---- 3.5ラベルが無いまま放置されたIssueを、企画に回す（受付 intake.yml が動かなかったとき・ai:skip を外したとき） ----
# 一覧にラベルと更新時刻があるので、ai: のラベルが無く、時間がたった物だけを詳しく見る（Issue ごとに API を呼ばない。回数制限のため）
intake_before=$(date -u -d "${IDLE_INTAKE_MIN:-10} minutes ago" +%Y-%m-%dT%H:%M:%SZ)
# 開いている Issue・PR の一覧は、最初に読んだ写し（ここまでの付け外しを反映した物）を使い、下の 3.9（ラベルの矛盾）でも使う
# （同じ一覧を何度も読まない。写しが無ければ、ここで1回読む）
open_items_json=$(open_items_json)
for n in $(printf '%s' "$open_items_json" | jq -r --arg before "$intake_before" \
  '.[] | select(.pull_request | not) | select(([.labels[].name] | any(startswith("ai:"))) | not) | select(.updated_at <= $before) | .number'); do
  case "$handled" in *" $n "*) continue ;; esac
  needs_intake "$n" || continue
  info=$(gh api "repos/$REPO/issues/$n" -q '"\(.updated_at) \(.user.login)"' 2> /dev/null) || continue
  m=$(idle_min "${info%% *}")
  author="${info#* }"
  # 受付と同じ決まり：オーナーとこのパイプラインのワークフロー以外が作った Issue は、動かさず ai:skip で止める
  # （受付が動かなかったときに、ここが他人の Issue を企画に回さないように）
  if ! trusted_author "$author"; then
    add_label "$n" "ai:skip"
    echo "#$n：オーナー以外（$author）が作った Issue なので、ai:skip で止めました"
    continue
  fi
  add_label "$n" "ai:plan"
  echo "#$n：ラベルが無いまま${m}分たったので、企画に回しました"
  # 企画AIが分けて作った Issue（github-actions[bot]）は、作っても受付が動かない（GitHub の決まり）ので、ここで拾うのがいつもの流れ。知らせない
  case "$author" in *"[bot]") continue ;; esac
  # 受付（intake.yml）が拾えなかったということ。Secretsやトークンの期限切れなどに気づけるように知らせる
  notify intake "頼まれていないIssueがありました" "#${n} $(issue_title "$n")：ラベルが無いまま${m}分たったので、企画に回しました（受付が動いていないかもしれません。Secretsとトークンの期限を確認してください）" 3
done

# ---- 3.6 他の Issue・PR の完了待ち（ai:blocked）：待ち先が全部閉じたら、企画に戻す ----
# 待ち先は、いちばん新しい「待ち先のコメント」の印（<!-- blocked-by: owner/repo#N -->）。別のリポジトリでもよい（Issue でも PR でもよい。
# PR は issues の API で読めて、マージ・クローズで closed になる）。読めない待ち先があるときは、戻さない（間違って再開しない）。
# 読めないまま BLOCKED_UNREADABLE_MIN 分たったら、黙って待ち続けないように、理由を書いて人間に回す
BLOCKED_UNREADABLE_MIN="${BLOCKED_UNREADABLE_MIN:-60}"
for n in $(open_numbers_with_label "ai:blocked"); do
  case "$handled" in *" $n "*) continue ;; esac
  has_label_or_unreadable "$n" "ai:stuck" && continue
  marks=$(all_comments "$n" | jq -r 'map(select(.body | test("<!-- blocked-by: "))) | last | .body // ""' | grep -oE "$BLOCKED_MARK_RE" || true)
  if [ -z "$marks" ]; then
    stop_issue_for_human "$n" "ai:blocked（他の Issue・PR の完了待ち）が付いていますが、待ち先の印（blocked-by）がありません。待つ必要が無ければ、ai:blocked を外して ai:plan を付けてください"
    continue
  fi
  still="" unreadable=""
  while IFS= read -r mark; do
    [ -z "$mark" ] && continue
    [[ "$mark" =~ $BLOCKED_MARK_RE ]] || continue
    t_repo="${BASH_REMATCH[1]}"
    t_num="${BASH_REMATCH[2]}"
    state=$(gh api "repos/$t_repo/issues/$t_num" -q .state 2> /dev/null) || state=""
    case "$state" in
      closed) ;;
      open) still="${still}${t_repo}#${t_num} " ;;
      *) unreadable="${unreadable}${t_repo}#${t_num} " ;;
    esac
  done <<< "$marks"
  if [ -n "$unreadable" ]; then
    m=$(idle_min "$(gh api "repos/$REPO/issues/$n" -q .updated_at)")
    if [ "$m" -ge "$BLOCKED_UNREADABLE_MIN" ]; then
      stop_issue_for_human "$n" "待ち先（${unreadable% }）の状態を読めないまま${m}分たちました（別のリポジトリが非公開で、パイプラインの鍵では読めない、など）。待ち先が終わっていれば、ai:blocked を外して ai:plan を付けてください"
    else
      echo "#$n：待ち先（${unreadable% }）を読めないので、今回は何もしません"
    fi
    continue
  fi
  if [ -n "$still" ]; then
    echo "#$n：待ち先（${still% }）がまだ開いているので、待ちます"
    continue
  fi
  author=$(gh api "repos/$REPO/issues/$n" -q .user.login 2> /dev/null) || author=""
  if ! trusted_author "$author"; then
    remove_label "$n" "ai:blocked"
    add_label "$n" "ai:skip"
    echo "#$n：オーナー以外（${author:-不明}）が作った Issue なので、企画に戻さず ai:skip で止めました"
    continue
  fi
  remove_label "$n" "ai:blocked"
  comment "$n" "▶ 待ち先が全部終わったので、企画に戻します（自動）。" || true
  add_label "$n" "ai:plan"
  handled="${handled}${n} "
  echo "#$n：待ち先が全部終わったので、企画に戻しました"
done

# ---- 3.8 使い終わった claude/* ブランチを掃除する ----
# 開いているPRが無く、最後のコミットから2日以上たった物だけ（作業中の物は消さない）。1回に消すのは20本まで
cleaned=0
for b in $(gh api "repos/$REPO/branches?per_page=100" --paginate -q '.[].name | select(startswith("claude/"))'); do
  [ "$cleaned" -ge 20 ] && break
  if printf '%s' "$open_prs" | jq -e --arg b "$b" 'any(.[]; .head.ref == $b)' > /dev/null; then
    continue
  fi
  last=$(gh api "repos/$REPO/branches/$b" -q .commit.commit.committer.date 2> /dev/null) || continue
  [ "$(idle_min "$last")" -lt $(( 2 * 24 * 60 )) ] && continue
  delete_branch_if_ai "$b"
  cleaned=$(( cleaned + 1 ))
done

# ---- 3.9 ラベルの矛盾を直す（人が手でラベルを付け外ししたとき） ----
# 直したら、その Issue・PR に1行コメントする。矛盾が無ければ何もしない。1回に直すのは、Issue と PR を合わせて20件まで
fixed=0
fix_labels() { # 番号 コメント 外すラベル...
  local num="$1" msg="$2" l
  shift 2
  for l in "$@"; do remove_label "$num" "$l"; done
  comment "$num" "🔧 ${msg}（見張り役がラベルの矛盾を直しました）"
  echo "#$num：${msg}"
  fixed=$(( fixed + 1 ))
}
# 一覧は 3.5 で読んだ物を使う（3.5〜3.8 が付け外しするのは ai:plan・ai:skip・ai:blocked で、ここで見る組み合わせは作らない）
open_items=$(printf '%s' "$open_items_json" | jq -r '.[] | [.number, ([.labels[].name] | join(","))] | @tsv')
while IFS=$'\t' read -r n labels; do
  [ -z "$n" ] && continue
  [ "$fixed" -ge 20 ] && break
  case ",$labels," in
    *,ai:implement,*)
      case ",$labels," in
        *,ai:queue,*) fix_labels "$n" "ai:queue と ai:implement が両方付いていたので、ai:queue を外しました" ai:queue; continue ;;
      esac
      case ",$labels," in
        *,ai:plan,*) fix_labels "$n" "ai:plan と ai:implement が両方付いていたので、ai:plan を外しました" ai:plan; continue ;;
      esac
      ;;
  esac
  case ",$labels," in
    *,ai:retry,*)
      if [ -z "$(retry_comment "$n")" ]; then
        fix_labels "$n" "ai:retry が付いていますが、やり直しの記録が無いので、ai:retry を外して ai:stuck にしました。人間が確認してください" ai:retry
        add_label "$n" "ai:stuck"
      fi
      ;;
  esac
done <<< "$open_items"

# 閉じた物（直近7日に閉じた物だけ）に、ai:stuck・ai:retry・ai:queue が残っている
since=$(date -u -d "7 days ago" +%Y-%m-%dT%H:%M:%SZ)
closed_items=$(gh api "repos/$REPO/issues?state=closed&since=${since}&per_page=100" --paginate \
  -q ".[] | select(.closed_at != null and .closed_at >= \"$since\") | [.number, ([.labels[].name] | join(\",\"))] | @tsv")
while IFS=$'\t' read -r n labels; do
  [ -z "$n" ] && continue
  [ "$fixed" -ge 20 ] && break
  stale=()
  for l in ai:stuck ai:retry ai:queue ai:blocked ai:implement; do
    case ",$labels," in *,"$l",*) stale+=("$l") ;; esac
  done
  [ "${#stale[@]}" -eq 0 ] && continue
  fix_labels "$n" "閉じているのに ${stale[*]} が残っていたので、外しました" "${stale[@]}"
done <<< "$closed_items"

# ---- 4. 順番待ちを進める ----
start_next_in_queue || echo "順番待ちを進められませんでした"

# ---- 8. 次のやり直しの時刻（と、マージ待ちのPRが順番待ちを止めなくなる時刻）に、見張り役を起こす目覚ましをかける ----
# GitHub の定期の起動（30分ごと）は、混んでいると数時間遅れる。待ちが明ける時刻が分かっているので、
# その時刻に retry-timer.yml（待ってから見張り役を動かすだけ）を動かしておく。目覚ましは1つだけ（新しい物が古い物を止める）。
# 公開していないリポジトリでは待つあいだも Actions の時間を使うので、変数 RETRY_TIMER に off を入れれば止められる
set_retry_timer   # 定義は、間引きの判定の前（0 の上）にある
