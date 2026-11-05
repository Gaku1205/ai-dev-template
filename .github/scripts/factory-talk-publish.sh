#!/usr/bin/env bash
# 工場の相談（factory-talk.yml の publish）：AIが作った物の形を確かめ、画像を factory-talk ブランチに置き、
# 選択肢と質問をコメントに書いて返事を待つ（factory:wait）。「作る」になったら Factory（factory.yml）を動かす。AIは動かない。
#   入力：talk/state.json・talk/route.json（route が作る）、out/（work のAIが作った物。無いこともある）
#   環境変数：GH_TOKEN、GITHUB_REPOSITORY、ISSUE、NEXT（ideas・looks・mocks・confirm・go・clarify）、
#             NTFY_TOPIC・NOTIFY_EVENTS・AGENT_DESK_URL（通知。無くてもよい）、ASSETS_REMOTE（テスト用。画像の置き場の git の場所）
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
talk() { python3 "$here/factory-talk.py" "$@"; }
repo="$GITHUB_REPOSITORY"
state=talk/state.json
out="${OUT_DIR:-out}"

comment() { gh api "repos/$repo/issues/$ISSUE/comments" -f body="$1" > /dev/null; }
waiting() { gh api "repos/$repo/issues/$ISSUE/labels" -f "labels[]=factory:wait" > /dev/null || echo "::warning::factory:wait を付けられませんでした"; }
notify() { "$here/notify.sh" question "$1" "$2" 4 || true; }
title=$(gh api "repos/$repo/issues/$ISSUE" --jq .title 2> /dev/null || echo "新サービス")

# 画像とざっくり画面の HTML を factory-talk ブランチの DIR に置く（コメントの画像と、作り始めたときのデザイン担当が使う）
push_assets() {
  local dir="$1"; shift
  local a="${RUNNER_TEMP:-/tmp}/factory-talk-assets"
  local url="${ASSETS_REMOTE:-https://x-access-token:${GH_TOKEN}@github.com/${repo}.git}"
  rm -rf "$a"
  if git ls-remote --exit-code "$url" refs/heads/factory-talk > /dev/null 2>&1; then
    git clone -q --depth 1 --branch factory-talk "$url" "$a"
  else
    git init -q "$a"
    git -C "$a" checkout -q -b factory-talk
    git -C "$a" remote add origin "$url"
  fi
  mkdir -p "$a/$dir"
  cp "$@" "$a/$dir/"
  git -C "$a" add -A
  git -C "$a" -c user.name=github-actions -c user.email=github-actions@users.noreply.github.com commit -qm "工場の相談：$dir"
  local _
  for _ in 1 2 3; do
    if git -C "$a" push -q origin factory-talk 2> /dev/null; then return 0; fi
    git -C "$a" pull -q --rebase origin factory-talk || true
  done
  return 1
}

case "$NEXT" in
  clarify)
    msg=$(jq -r '.message // ""' talk/route.json)
    comment "🤔 ${msg}

$(talk mark "$state")"
    waiting
    ;;
  go)
    brief=$(talk brief "$state")
    name=$(jq -r '.name' <<< "$brief")
    if ! [[ "$name" =~ ^[a-z][a-z0-9-]{2,38}$ ]]; then
      comment "⚠️ 名前が決まっていないので作り始められません。最終確認をやり直すには「もう一回」と返事してください。

$(talk mark "$state")"
      waiting
      exit 0
    fi
    comment "🏭 **${name}** を作り始めます。できたらこの Issue に結果を書きます（1時間くらい）。

$(talk mark "$state")"
    gh api -X POST "repos/$repo/actions/workflows/factory.yml/dispatches" -f ref=main -f "inputs[issue]=$ISSUE" > /dev/null
    ;;
  ideas | looks | mocks | confirm)
    if [ -f "$out/$NEXT.json" ] && [ ! -L "$out/$NEXT.json" ] && talk check "$NEXT" "$out" > talk/out.json; then
      round=$(jq -r '(.round // 0) + 1' "$state")
      dir="issue-$ISSUE/r$round-$NEXT"
      talk merge "$state" "$NEXT" talk/out.json "$dir" > talk/state2.json
      files=()
      case "$NEXT" in
        looks) for f in "$out"/look-[1-3]-1440.png; do [ -f "$f" ] && [ ! -L "$f" ] && files+=("$f"); done ;;
        mocks) for f in "$out"/mock-[ab].html "$out"/mock-[ab]-1440.png "$out"/mock-[ab]-390.png; do [ -f "$f" ] && [ ! -L "$f" ] && files+=("$f"); done ;;
      esac
      if [ "${#files[@]}" -gt 0 ] && ! push_assets "$dir" "${files[@]}"; then
        echo "::warning::画像を factory-talk ブランチに置けませんでした（コメントの画像が出ません）"
      fi
      comment "$(talk render talk/state2.json "https://raw.githubusercontent.com/$repo/factory-talk")"
      waiting
      notify "工場：選んでください" "$title"
    else
      comment "⚠️ うまく作れませんでした（Actions の Factory talk のログを見てください）。「もう一回」と返事すると、同じ段階をやり直します。

$(talk mark "$state")"
      waiting
      notify "工場：作れませんでした" "$title"
    fi
    ;;
  *)
    echo "::error::知らない段階：$NEXT"
    exit 1
    ;;
esac
