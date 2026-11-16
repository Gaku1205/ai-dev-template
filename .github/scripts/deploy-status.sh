#!/usr/bin/env bash
# 公開の結果を、コミットの状態（context：deploy/<種類>）に書き、終わったらスマホに通知する。
# agent-desk などはこの状態を読んで「公開中・公開済み・公開に失敗」を出す。
# ワークフローのトークンで書いた状態は、ほかのワークフロー（deploy-notify.yml）を動かさないので、通知はここで出す。
# 使い方：deploy-status.sh 種類 状態（pending/success/failure/error） 説明 [見に行くURL]
# 環境変数：REPO か GITHUB_REPOSITORY、SHA、GH_TOKEN（statuses: write）、NTFY_TOPIC（通知。無ければ通知しない）
set -u
# shellcheck source=deploy-lib.sh
source "$(dirname "$0")/deploy-lib.sh"
kind="$1" state="$2" desc="$3" url="${4:-}"
REPO="${REPO:-${GITHUB_REPOSITORY:?}}"
SHA="${SHA:?SHA が要ります}"
# 説明は GitHub の上限（140文字）に収める。文字で数える（cut -c はバイトで切るので、日本語が約46文字で切れ、文字の途中で壊れる。
# pages の失敗に付ける URL も途中で切れていた）。bash の ${変数:0:N} は、文字コードが UTF-8 のときだけ文字で数えるので、ここでそろえる
export LC_ALL=C.UTF-8
desc=$(printf '%s' "$desc" | tr '\n' ' ')
# pages の失敗には、設定のページの URL を付ける（上限に収める。切れるのは前半の文のほう）
if [ "$kind" = pages ] && [ "$state" = failure ]; then
  suffix=" 設定：https://github.com/${REPO}/settings/pages"
  desc="${desc:0:$((140 - ${#suffix}))}${suffix}"
fi
desc="${desc:0:140}"
args=(-f state="$state" -f context="deploy/${kind}" -f description="$desc")
[ -n "$url" ] && args+=(-f target_url="$url")
gh api -X POST "repos/$REPO/statuses/$SHA" "${args[@]}" > /dev/null || echo "::warning::公開の状態を書けませんでした（${kind} ${state}）"

case "$state" in
  success | failure | error)
    title=$(commit_title "$(gh api "repos/$REPO/commits/$SHA" -q '.commit.message' 2> /dev/null)")
    if [ "$state" = success ]; then
      "$(dirname "$0")/notify.sh" deployed "公開されました（${kind}）" "${title}${url:+ $url}" 3 || true
    else
      "$(dirname "$0")/notify.sh" deploy_failed "公開に失敗しました（${kind}）" "${title}：${desc}" 5 || true
    fi
    ;;
esac
