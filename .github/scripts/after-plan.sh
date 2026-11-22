#!/usr/bin/env bash
# 企画AI（ai:plan）のあと：清書の結果（plan-result.txt）を見て次へ進める。
#   READY [size:S|size:L] → サイズのラベルを付けてから ai:implement を付ける（実装AIが動く）。
#                            進行中の作業とぶつかる（企画AIが WAIT と判断）・上限に達しているなら、代わりに ai:queue
#   QUESTION              → ai:stuck を付けて人間に回す（人間にしかできない作業。頼みごとはIssueのコメントにある）
#   ASK                   → ai:question を付けて答えを待つ（選択式の質問はIssueのコメントにある。答えると answer.yml が ai:plan に戻す）
#   MOCKS                 → ai:mocks を付ける（claude-mocks.yml がざっくり画面を2案作って、ai:question で答えを待つ）
#   BLOCKED               → ai:blocked を付けて、他の Issue・PR が終わるのを待つ（2行目から下が待ち先。1行に1つ：owner/repo#N か #N か URL）。
#                            待ち先が全部閉じたら、見張り役（watchdog.sh）が ai:plan に戻す。人間は何もしなくてよい
#
# 環境変数：ISSUE、PLAN_OUTCOME、GITHUB_TOKEN_FOR_LABELS（ワークフローのトークン）、EXECUTION_FILE（AIの実行記録。失敗の原因の分類に使う）、
#           PLAN_TURNS_RAISED（true：作業回数の上限に届いたので、ワークフローが上限を増やしてもう1回動かした）
source "$(dirname "$0")/pipeline-lib.sh"
# 同時に実装してよい数は、pipeline-lib.sh の current_parallel（時間帯・手の上書き・MAX_PARALLEL の既定 3）で決める

# 作業中に Issue が閉じられた（人間が別のPRで片付けた・やめた）ときは、続きを進めない（ラベルも Issue も作らない）。
# 閉じた Issue の企画の結果で実装が始まり、同じ作業のPRがもう1つできたことがある（ai-dev-template #71・#84）
if [ "$(gh api "repos/$GITHUB_REPOSITORY/issues/$ISSUE" --jq .state 2> /dev/null || echo open)" = closed ]; then
  echo "#$ISSUE は閉じられているので、企画の結果は使いません"
  for l in ai:plan ai:implement ai:queue ai:question ai:mocks ai:blocked; do remove_label "$ISSUE" "$l" 2> /dev/null || true; done
  exit 0
fi

# ai:skip が付いている Issue（オーナー以外が作って、受付が止めた物など）は、進めない。やり直しにも回さない。
# 雛形（メモ）から作ると誰の Issue にも ai:plan が付き、AIのアクションは書き込み権限の無い人を断って失敗で終わる。
# それを「一時的な失敗」としてやり直すと、パイプラインの鍵が ai:plan を付け直し、他人の Issue を企画・実装してしまう
# ラベルを読めなければ、進めない（「ai:skip が無い」と取り違えない）。ラベルはそのまま残すので、見張り役が企画の止まりとして拾い直す
skip_rc=0
GH_TOKEN="$GITHUB_TOKEN_FOR_LABELS" has_label "$ISSUE" "ai:skip" || skip_rc=$?
if [ "$skip_rc" -eq 2 ]; then
  echo "::warning::#$ISSUE のラベルを読めないので、企画の結果は使いません（見張り役が、企画の止まりとしてやり直します）"
  exit 0
fi
if [ "$skip_rc" -eq 0 ]; then
  echo "#$ISSUE は ai:skip が付いているので、企画の結果は使いません（オーナーが ai:skip を外すと、企画に回ります）"
  GH_TOKEN="$GITHUB_TOKEN_FOR_LABELS" remove_label "$ISSUE" "ai:plan"
  GH_TOKEN="$GITHUB_TOKEN_FOR_LABELS" remove_label "$ISSUE" "ai:retry"
  exit 0
fi

result=$(head -n 1 plan-result.txt 2> /dev/null | tr -d '\r' || true)
# AIは正常に終わって結果も書いたのに、AIのアクションが失敗にしたとき（手数が --max-turns を少し越えて終わった、など）は、
# 清書は済んでいるので、結果を使って先へ進める。途中で拒否された操作があっても「許可不足」として人間に回さない（agent-desk #447）
if [ "$PLAN_OUTCOME" != "success" ]; then
  case "$result" in
    READY* | QUESTION* | ASK* | MOCKS* | BLOCKED*)
      if ai_finished_ok "${EXECUTION_FILE:-}"; then
        echo "企画AIは正常に終わって結果（$result）も書いています。アクションの失敗（手数が上限を越えた、など）は、失敗として扱いません"
        PLAN_OUTCOME=success
      fi
      ;;
  esac
fi
# 企画AIがエラーで終わったとき（使用量の上限など）は、質問扱いにせず、自動でやり直す（watchdog.sh）
if [ "$PLAN_OUTCOME" != "success" ]; then
  export GH_TOKEN="$GITHUB_TOKEN_FOR_LABELS"
  # 作業回数の上限に届いたので、上限を増やしてその場でやり直した（claude-plan.yml）のに、また上限に届いた：
  # 同じことを30分後にやり直しても同じ所で止まり、そのたびに上限いっぱいまでAIを使う。やり直さず、すぐ人間に回す
  if [ "${PLAN_TURNS_RAISED:-}" = true ] && hit_max_turns "${EXECUTION_FILE:-}" && [ -z "$(limit_signal "${EXECUTION_FILE:-}")" ]; then
    remove_label "$ISSUE" "ai:plan"
    stop_issue_for_human "$ISSUE" "$(failure_reason "企画AIが、作業回数の上限を増やしてやり直しても、また上限に届きました" "${EXECUTION_FILE:-}")。作業が大きすぎるか、読む物が多すぎます。Issue を小さく分けるか、触る場所（ファイルや画面の名前）を Issue に書いてください"
    exit 0
  fi
  handle_ai_failure "$ISSUE" plan "企画AIがエラーで止まりました" "${EXECUTION_FILE:-}"
  exit 0
fi
# 結果を書かずに終わった（質問のコメントも無い）のは、AIの一時的な不調。質問として人間に回すと、理由の分からない停止になるので、
# 2回までは自動でやり直す（それでも書かなければ、理由を書いて人間に回す）
if [ -z "$result" ]; then
  export GH_TOKEN="$GITHUB_TOKEN_FOR_LABELS"
  if [ "$(retry_count "$ISSUE")" -lt 2 ]; then
    mark_for_retry "$ISSUE" plan "企画AIが、清書の結果を書かずに終わりました"
  else
    remove_label "$ISSUE" "ai:plan"
    stop_issue_for_human "$ISSUE" "企画AIが、自動のやり直しでも清書の結果を書きませんでした（質問もありません）。Issue の内容を確かめて、もう一度 ai:plan を付けるか、自分で ai:implement を付けてください"
  fi
  exit 0
fi
echo "清書の結果：$result"

# ここまではワークフローのトークンで十分（次のワークフローを動かさなくてよい操作）
pipeline_token="${GH_TOKEN:-}"
export GH_TOKEN="$GITHUB_TOKEN_FOR_LABELS"
remove_label "$ISSUE" "ai:plan"
title=$(issue_title "$ISSUE")

case "$result" in
  READY*)
    # 清書で画像の行が消えていたら足し直す（実装AIが同じ画像を見るため。企画AIには残すよう頼んでいるが、確かめはここ）
    keep_issue_images "$ISSUE" "${ISSUE_BODY_BEFORE:-}" || true
    # 印が書かれていなければ、本文のファイル名から補う（補えなければ、印は無いまま＝順番待ちは今までどおり待つ）
    if [ -n "$pipeline_token" ]; then
      GH_TOKEN="$pipeline_token" ensure_touches_mark "$ISSUE" || true
      # 印に共有の大きなフォルダがあると、ほかの順番待ちが全部「触るファイルが重なる」で待たされる。
      # 1回だけ、ファイル単位で書き直させる（前に同じ印のコメントがあれば、今までどおり進める）。サイズは2回目に付ける
      broad_body=$(GH_TOKEN="$pipeline_token" gh api "repos/$REPO/issues/$ISSUE" -q '.body // ""' 2> /dev/null || true)
      broad=$(touches_too_broad "$(touches_from_body "$broad_body")")
      if [ -n "$broad" ]; then
        if GH_TOKEN="$pipeline_token" all_comments "$ISSUE" 2> /dev/null | jq -e --arg m "$TOUCHES_TOO_BROAD_MARK" 'any(.[]; (.body // "") | contains($m))' > /dev/null 2>&1; then
          echo "#$ISSUE：触るファイルに広いフォルダがありますが、書き直しは済んでいるので、このまま進めます"
        else
          broad_list=$(printf '%s\n' "$broad" | sed -E 's/^(.*)$/- `\1`/')
          comment "$ISSUE" "${TOUCHES_TOO_BROAD_MARK}
触るファイルが広すぎるので、並べて始められません。次のフォルダは、ほかの作業も使う大きなフォルダです（中の全部と重なり扱いになり、ほかの順番待ちが全部待たされます）。

${broad_list}

ファイル単位で書き直してください。触るファイルの印（\`ai-touches\`）には、触るファイルを1つずつ書きます。フォルダ（/ で終わる）で書いてよいのは、新しく作るフォルダ（中身が全部この作業の物）だけです。" || true
          GH_TOKEN="$pipeline_token" add_label "$ISSUE" "ai:plan"
          echo "#$ISSUE：触るファイルが広すぎるので（$(printf '%s' "$broad" | paste -sd, -)）、ファイル単位で企画をやり直させます"
          exit 0
        fi
      fi
    fi
    size=$(printf '%s' "$result" | grep -oE 'size:(S|L)' || true)
    # 人間や工場が先にサイズを決めていれば（最初の画面を作る Issue の size:L など）、そちらを残す
    if [ -n "$size" ] && ! has_label "$ISSUE" "size:S" && ! has_label "$ISSUE" "size:L"; then
      add_label "$ISSUE" "$size"
    fi
    if [ -n "$pipeline_token" ]; then
      # 並列にしてよいかは企画AIが2行目で判断（PARALLEL / WAIT）。すでに今の上限の数だけ動いているとき
      # （数えるのは AIがいま動かしている物だけ。止まった物・長く待たれたマージ待ちは数えない）は、AIの判断にかかわらず待つ
      parallel=$(sed -n 2p plan-result.txt 2> /dev/null | tr -d '\r ' || true)
      busy=$(GH_TOKEN="$pipeline_token" count_active_implementing)
      stuck=$(GH_TOKEN="$pipeline_token" count_open_issues_with_label "ai:stuck")
      limit_info=$(current_parallel)
      limit="${limit_info%% *}"
      echo "企画AIの判断：${parallel:-なし} / 実装中 ${busy} / 停止中 ${stuck}（並列の上限 ${limit}：${limit_info#* }）"
      # 上限は、PARALLEL_SCOPE（既定 global）なら全部のリポジトリで合わせて数える（#216）。重なりの判断は、このリポジトリの中だけ
      GH_TOKEN="$pipeline_token" parallel_scope_resolve
      all_busy="$busy"
      if [ "$SCOPE_EFFECTIVE" = global ]; then
        all_busy=$((busy + $(global_other_busy)))
        echo "全部のリポジトリで実装中 ${all_busy}（上限は全部のリポジトリで合わせて数えます）"
      fi
      # 企画AIの「並列でよい」は、企画を始めた時点の進行中の作業を見た判断。企画の間に別の Issue の実装が始まっていると
      # （まとめて Issue を書いたとき）、その作業とは見比べていない。触るファイルの印（ai-touches）が両方にあって重なるなら、待つ
      overlap=no
      if { [ "$busy" -gt 0 ] || [ "$stuck" -gt 0 ]; } && [ "$parallel" = "PARALLEL" ]; then
        mine=$(touches_from_body "$(GH_TOKEN="$pipeline_token" gh api "repos/$REPO/issues/$ISSUE" -q '.body // ""' 2> /dev/null || true)")
        if [ -n "$mine" ]; then
          inflight=$(GH_TOKEN="$pipeline_token" inflight_touches) || inflight=unknown
          if ! grep -qx unknown <<< "$inflight" && paths_overlap "$mine" "$inflight"; then
            overlap=yes
            echo "#$ISSUE：企画AIは並列でよいと判断しましたが、進行中の作業と触るファイルが重なるので、待ちます"
          fi
        fi
      fi
      if { [ "$busy" -gt 0 ] && { [ "$parallel" != "PARALLEL" ] || [ "$busy" -ge "$limit" ]; }; } || [ "$overlap" = yes ] || [ "$all_busy" -ge "$limit" ]; then
        # 終われば queue.yml が始める
        GH_TOKEN="$pipeline_token" add_label "$ISSUE" "ai:queue"
        echo "#$ISSUE：進行中の作業とぶつかる・上限なので、順番待ちに入れました"
      else
        # オーナーのトークンで付けるので、実装AIのワークフローが動く
        GH_TOKEN="$pipeline_token" add_label "$ISSUE" "ai:implement"
        echo "#$ISSUE：実装を依頼しました"
        # 同時に終わった企画は、互いの ai:implement を見ずに付ける。付けたあとにもう一度数え、番号の大きい方が引く
        mine=$(touches_from_body "$(GH_TOKEN="$pipeline_token" gh api "repos/$REPO/issues/$ISSUE" -q '.body // ""' 2> /dev/null || true)")
        if GH_TOKEN="$pipeline_token" yield_if_crowded "$ISSUE" "$limit" "$mine"; then
          echo "#$ISSUE：同時に始めた物があり、上限・触るファイルの重なりを越えるので、順番待ちに入れ直しました"
        elif [ "$SCOPE_EFFECTIVE" = global ]; then
          # ほかのリポジトリで同時に始まった物と合わせて上限を超えたら、席に着いたのが新しい方（企画から直接始めたこの Issue）が引く
          GH_TOKEN="$pipeline_token" global_yield_overflow "$limit" "${REPO} ${ISSUE}
"
        fi
      fi
    else
      notify manual "Issueを清書しました" "#${ISSUE} ${title}：ai:implement を付けると実装が始まります" 3
    fi
    ;;
  MOCKS*)
    if [ -n "$pipeline_token" ]; then
      # オーナーのトークンで付けるので、画面案のワークフローが動く
      GH_TOKEN="$pipeline_token" add_label "$ISSUE" "ai:mocks"
      echo "#$ISSUE：作る前に画面案を作ります"
    else
      notify manual "画面案を作る前に止まりました" "#${ISSUE} ${title}：ai:mocks を付けると画面案を作ります" 3
    fi
    ;;
  BLOCKED*)
    # 待ち先を owner/repo#N の形にそろえる（#N はこのリポジトリ。Issue・PR の URL も読む）。自分自身と、読めない行は捨てる。最大10件
    targets=$(tail -n +2 plan-result.txt 2> /dev/null | tr -d '\r' | head -n 30 | while IFS= read -r line; do
      t=$(printf '%s' "$line" | sed -E 's#https?://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/(issues|pull)/([0-9]+).*#\1\#\3#' | grep -oE '([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+' | head -1 || true)
      [ -z "$t" ] && continue
      case "$t" in \#*) t="${REPO}${t}" ;; esac
      [ "$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "${REPO}#${ISSUE}" | tr '[:upper:]' '[:lower:]')" ] && continue
      printf '%s\n' "$t"
    done | awk '!seen[$0]++' | head -n 10 || true)
    if [ -z "$targets" ]; then
      stop_issue_for_human "$ISSUE" "企画AIが「他の Issue・PR が終わるのを待つ（BLOCKED）」と判断しましたが、待ち先が読み取れませんでした。Issue のコメントを確かめて、待つ必要が無ければ ai:plan を付け直してください"
    else
      marks=$(printf '%s\n' "$targets" | sed -E 's/^(.*)$/<!-- blocked-by: \1 -->/')
      list=$(printf '%s\n' "$targets" | sed -E "s#^${REPO}(\#[0-9]+)\$#\1#" | paste -sd, - | sed 's/,/、/g')
      comment "$ISSUE" "⏳ 他の作業が終わるのを待っています（待ち先：${list}）。待ち先が全部閉じる（マージされる）と、自動で企画に戻ります。人間は何もしなくて大丈夫です。

${marks}" || true
      add_label "$ISSUE" "ai:blocked" || true
      echo "#$ISSUE：待ち先（${list}）が終わるまで待ちます"
    fi
    ;;
  ASK*)
    add_label "$ISSUE" "ai:question" || true
    notify question "質問があります" "#${ISSUE} ${title}：コメントで答えると続きを始めます" 4
    ;;
  *)
    add_label "$ISSUE" "ai:stuck" || true
    notify question "質問があります" "#${ISSUE} ${title}：Issueのコメントを見て答えてください" 4
    ;;
esac
