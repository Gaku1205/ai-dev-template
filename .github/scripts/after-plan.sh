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
# 環境変数：ISSUE、PLAN_OUTCOME、GITHUB_TOKEN_FOR_LABELS（ワークフローのトークン）、EXECUTION_FILE（AIの実行記録。失敗の原因の分類に使う）
source "$(dirname "$0")/pipeline-lib.sh"
# 同時に実装してよい数（使用量を増やしすぎないため）
MAX_PARALLEL="${MAX_PARALLEL:-2}"

result=$(head -n 1 plan-result.txt 2> /dev/null | tr -d '\r' || true)
# 企画AIがエラーで終わったとき（使用量の上限など）は、質問扱いにせず、自動でやり直す（watchdog.sh）
if [ "$PLAN_OUTCOME" != "success" ]; then
  export GH_TOKEN="$GITHUB_TOKEN_FOR_LABELS"
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
    size=$(printf '%s' "$result" | grep -oE 'size:(S|L)' || true)
    # 人間や工場が先にサイズを決めていれば（最初の画面を作る Issue の size:L など）、そちらを残す
    if [ -n "$size" ] && ! has_label "$ISSUE" "size:S" && ! has_label "$ISSUE" "size:L"; then
      add_label "$ISSUE" "$size"
    fi
    if [ -n "$pipeline_token" ]; then
      # 並列にしてよいかは企画AIが2行目で判断（PARALLEL / WAIT）。止まっている物があるとき、
      # すでに上限（MAX_PARALLEL）の数だけ動いているときは、AIの判断にかかわらず待つ
      parallel=$(sed -n 2p plan-result.txt 2> /dev/null | tr -d '\r ' || true)
      busy=$(GH_TOKEN="$pipeline_token" count_open_issues_with_label "ai:implement")
      stuck=$(GH_TOKEN="$pipeline_token" count_open_issues_with_label "ai:stuck")
      echo "企画AIの判断：${parallel:-なし} / 実装中 ${busy} / 停止中 ${stuck}（並列の上限 ${MAX_PARALLEL}）"
      if [ "$busy" -gt 0 ] && { [ "$parallel" != "PARALLEL" ] || [ "$stuck" -gt 0 ] || [ "$busy" -ge "$MAX_PARALLEL" ]; }; then
        # 終われば queue.yml が始める
        GH_TOKEN="$pipeline_token" add_label "$ISSUE" "ai:queue"
        echo "#$ISSUE：進行中の作業とぶつかる・上限なので、順番待ちに入れました"
      else
        # オーナーのトークンで付けるので、実装AIのワークフローが動く
        GH_TOKEN="$pipeline_token" add_label "$ISSUE" "ai:implement"
        echo "#$ISSUE：実装を依頼しました"
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
