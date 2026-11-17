#!/usr/bin/env bash
# 新しいIssueを、人間がラベルを付けなくても自動で企画AI（ai:plan）に回す。intake.yml から呼ぶ。
# ai: で始まるラベルが1つでも付いていれば何もしない（自分で ai:queue などを付けた物、ai:skip で止めている物）。
#
# 公開リポジトリでは誰でもIssueを作れるので、オーナー（とパイプライン自身が作るIssue）以外が
# 作ったIssueは、自動で動かさず ai:skip で止める（雛形で付いた ai:plan などの作業のラベルも外す）。
# オーナーが ai:skip を外せば、そのまま企画に回る。
#
# 環境変数：NUMBER、ACTION（opened か unlabeled）
source "$(dirname "$0")/pipeline-lib.sh"
has_pipeline_token || { echo "PIPELINE_TOKEN が無いので何もしません"; exit 0; }

if [ "${ACTION:-opened}" = "opened" ]; then
  author=$(gh api "repos/$REPO/issues/$NUMBER" -q '.user.login') || exit 1
  if ! trusted_author "$author"; then
    labels=$(gh api "repos/$REPO/issues/$NUMBER/labels" -q '.[].name') || exit 1
    case "$author" in
      *"[bot]")
        # パイプライン自身（App）が、ラベルを付けて作った Issue（使ってみる役・監査役の ai:found など）は、そのまま進める。
        # ボットは Issue の雛形を使わないので、ai: のラベルを付けて作れるのは、このリポジトリに書き込める仕組みだけ
        if printf '%s\n' "$labels" | grep -q '^ai:'; then
          echo "#$NUMBER：仕組み（$author）がラベルを付けて作った Issue なので、そのまま進めます"
          exit 0
        fi
        ;;
    esac
    # 雛形（メモ）から作ると、誰が作っても ai:plan が付く。オーナー以外の Issue では、作業のラベルを外して止める
    # （残すと、AIのアクションが断ったあと、自動のやり直しがパイプラインの鍵で ai:plan を付け直し、他人の Issue を実装してしまう）
    # 先に ai:skip を付ける（ai:skip がある間は、企画のあとの処理も見張り役も動かさない）
    printf '%s\n' "$labels" | grep -qx "ai:skip" || add_label "$NUMBER" "ai:skip"
    for l in ai:plan ai:implement ai:queue ai:mocks; do
      if printf '%s\n' "$labels" | grep -qx "$l"; then remove_label "$NUMBER" "$l"; fi
    done
    echo "#$NUMBER：オーナー以外（$author）が作ったので、ai:skip で止めました"
    exit 0
  fi
fi

# テンプレートでない所の「新サービス：」は、工場が動かないので、普通の Issue として企画・実装に回ってしまう。
# 理由を書いて ai:skip で止める（Template repository のチェックが要る）。ai: のラベルが付いた物は、上と同じく何もしない
if [ "${ACTION:-opened}" = "opened" ]; then
  title=$(gh api "repos/$REPO/issues/$NUMBER" -q '.title' 2> /dev/null) || title=""
  case "$title" in
    新サービス：* | 新サービス:*)
      if [ "$(gh api "repos/$REPO" -q .is_template 2> /dev/null)" != "true" ]; then
        labels=$(gh api "repos/$REPO/issues/$NUMBER/labels" -q '.[].name') || exit 1
        # すでに止まっている物には、二重に書かない
        printf '%s\n' "$labels" | grep -qx "ai:skip" && exit 0
        # 先に ai:skip を付け、雛形で付いた作業のラベルを外す（残すと企画・実装が動く）
        add_label "$NUMBER" "ai:skip"
        for l in ai:plan ai:implement ai:queue ai:mocks; do
          if printf '%s\n' "$labels" | grep -qx "$l"; then remove_label "$NUMBER" "$l"; fi
        done
        comment "$NUMBER" "⏸ 「新サービス：」は、このリポジトリの **Template repository** のチェックが入っているときだけ、工場が新しいサービスを作ります（Settings → General → Template repository）。いまはチェックが無いので、企画にも実装にも回さず止めました。

チェックを入れてから、もう一度「新サービス：〜」の Issue を作ってください。普通の Issue として進めたいときは、タイトルから「新サービス：」を外して、\`ai:skip\` を外してください。" || true
        echo "#$NUMBER：テンプレートではない所の「新サービス：」なので、ai:skip で止めました"
        exit 0
      fi
      ;;
  esac
fi

# 作った直後にラベルを付ける人・スクリプトがいるので、少し待ってから見る
sleep "${INTAKE_WAIT_SEC:-15}"
if needs_intake "$NUMBER"; then
  # オーナーのトークンで付けるので、企画AIのワークフローが動く
  add_label "$NUMBER" "ai:plan"
  echo "#$NUMBER：ラベルが無かったので、企画に回しました"
else
  echo "#$NUMBER：すでにパイプラインのラベルがあるので何もしません"
fi
