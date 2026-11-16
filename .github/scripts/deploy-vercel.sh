#!/usr/bin/env bash
# Vercel の本番の公開を、まとめて1回だけ頼む（deploy-vercel.yml から、続けてのマージが落ち着いたあとに呼ぶ）。
# Vercel の無料プランは「1日100回まで」なので、マージのたびに Vercel が自分で公開するのをやめ（vercel.json の
# git.deploymentEnabled: false）、ここで最新の main を1回だけ公開する。
#   - 最新の main が、もう公開に成功している（Vercel の状態が success）なら何もしない
#   - 最後に公開に成功したコミットから、パイプラインの物（.github/・docs/pipeline.md）しか変わっていなければ何もしない
#   - そうでなければ、Vercel の API で最新の main を本番に公開する（プロジェクトは、このリポジトリにつながっている物を探す）
#   - VERCEL_TOKEN が無いのに、vercel.json で Vercel が自分で公開するのを止めていたら（どこからも公開されない）、失敗として知らせる
#   - 頼めなかったら（鍵の期限切れ・プロジェクトが見つからない など）、スマホに知らせる（Vercel まで届いていないので、Vercel の結果を待つ
#     deploy-notify.yml は鳴らない。黙って公開されないままになるのを防ぐ）。3時間ごとの確かめでは知らせない（同じ知らせが1日8回鳴るため）
#   - 3時間ごとの確かめでは、同じコミットの公開が VERCEL_RETRY_MAX 回（既定 3）失敗していたら、もう頼まない（作る途中のエラーなど、
#     頼み直しても直らない失敗で、公開の回数と通知を使い続けないように）。回数の上限（rate limited）での失敗は数えない
# 環境変数：VERCEL_TOKEN、VERCEL_TEAM_ID（任意）、GITHUB_REPOSITORY、GH_TOKEN、VERCEL_FORCE（任意。1 なら必ず公開）、VERCEL_API（テスト用）、
#           GITHUB_EVENT_NAME（schedule なら3時間ごとの確かめ）、NTFY_TOPIC・NOTIFY_EVENTS（通知。無ければ知らせない）、VERCEL_RETRY_MAX
# 終了コード：公開を頼んだ・何もしなくてよい → 0、頼めなかった → 1
set -uo pipefail
VERCEL_API="${VERCEL_API:-https://api.vercel.com}"
REPO="${GITHUB_REPOSITORY:?}"

# 頼めなかった：ログに出し、スマホに知らせて、失敗で終わる。3時間ごとの確かめと、回数の上限（あとで自動でやり直す）では知らせない
give_up() {
  echo "::error::$1"
  if [ "${GITHUB_EVENT_NAME:-}" != schedule ] && ! printf '%s' "$1" | grep -qiE 'rate.?limit'; then
    "$(dirname "$0")/notify.sh" deploy_failed "公開を頼めませんでした（Vercel）" "$1" 5 > /dev/null || true
  fi
  exit 1
}

if [ -z "${VERCEL_TOKEN:-}" ]; then
  # 鍵が無いのに、vercel.json で Vercel が自分で公開するのを止めている：どこからも公開されない（鍵を配れなかった・消えた など）。
  # 黙って「何もしない」で終わると、マージしても本番が古いままになるので、失敗として知らせる
  if [ -f vercel.json ] && [ "$(jq -r '.git.deploymentEnabled' vercel.json 2> /dev/null)" = false ]; then
    give_up "VERCEL_TOKEN が無いのに、vercel.json で Vercel が自分で公開するのを止めています（git.deploymentEnabled: false）。このままでは、どこからも公開されません。Secret の VERCEL_TOKEN を入れるか、vercel.json のその行を消してください"
  fi
  echo "::notice::VERCEL_TOKEN が無いので、ここでは公開しません（vercel.json で Vercel が自分で公開する設定なら、そちらで公開されます）"
  exit 0
fi

head=$(gh api "repos/$REPO/commits/main" -q .sha) || give_up "main の先頭を調べられません"

# VERCEL_FORCE=1：調べずに、最新の main を必ず公開する（環境変数を変えたあとなど。同じコミットでも新しく作り直す）
if [ "${VERCEL_FORCE:-}" != 1 ]; then
  # main の直近のコミットのうち、Vercel の公開に成功した物（新しい順に最大30件。飛ばした物は除く）
  last_ok=""
  for sha in $(gh api "repos/$REPO/commits?sha=main&per_page=30" -q '.[].sha'); do
    # 「Canceled by Ignored Build Step」（vercel.json の ignoreCommand で飛ばした物）も success になるので、公開した物には数えない
    state=$(gh api "repos/$REPO/commits/$sha/status" -q '[.statuses[] | select(.context | startswith("Vercel"))] | sort_by(.updated_at) | last
      | if . == null then "" elif .state == "success" and ((.description // "") | test("Ignored Build Step"; "i")) then "ignored" else .state end' 2> /dev/null || true)
    if [ "$state" = success ]; then last_ok="$sha"; break; fi
  done
  if [ "$last_ok" = "$head" ]; then
    echo "::notice::最新の main（${head:0:7}）はもう公開されています"
    exit 0
  fi
  head_state=$(gh api "repos/$REPO/commits/$head/status" -q '[.statuses[] | select(.context | startswith("Vercel"))] | sort_by(.updated_at) | last
    | if . == null then "" elif .state == "success" and ((.description // "") | test("Ignored Build Step"; "i")) then "ignored" else .state end' 2> /dev/null || true)
  if [ "$head_state" = pending ]; then
    echo "::notice::最新の main（${head:0:7}）は、いま公開中です"
    exit 0
  fi
  # 最新の main を前に頼んだら、Vercel が vercel.json の ignoreCommand で飛ばした（直前のコミットとの差しか見ないため）。
  # 何度頼んでも同じなので、やり直さない（3時間ごとに頼み続けて、そのたびに通知が鳴るのを防ぐ）。ignoreCommand を消せば直る
  if [ "$head_state" = ignored ]; then
    echo "::warning::最新の main（${head:0:7}）の公開は、Vercel の ignoreCommand で飛ばされました。公開をまとめて頼む形では、vercel.json の ignoreCommand を消してください（パイプラインの物しか変わっていない時は、ここで公開しないので要りません）"
    exit 0
  fi
  # 3時間ごとの確かめ：同じコミットが何度も失敗しているなら、頼み直しても直らない。次のマージか、手で動かすまで待つ
  if [ "${GITHUB_EVENT_NAME:-}" = schedule ] && { [ "$head_state" = failure ] || [ "$head_state" = error ]; }; then
    fails=$(gh api "repos/$REPO/commits/$head/statuses?per_page=100" -q '[.[] | select((.context | startswith("Vercel")) and (.state == "failure" or .state == "error")
      and ((.description // "") | test("rate limit"; "i") | not))] | length' 2> /dev/null || echo 0)
    if [ "${fails:-0}" -ge "${VERCEL_RETRY_MAX:-3}" ]; then
      echo "::warning::最新の main（${head:0:7}）の公開は、もう ${fails} 回失敗しています。頼み直しても直らないので、ここでは頼みません（Vercel の画面で理由を確かめ、直してマージするか、Actions の Deploy Vercel を手で動かしてください）"
      exit 0
    fi
  fi
  if [ -n "$last_ok" ]; then
    changed=$(gh api "repos/$REPO/compare/$last_ok...$head" -q '.files[].filename' 2> /dev/null || true)
    if [ -n "$changed" ] && ! printf '%s\n' "$changed" | grep -vqE '^(\.github/|docs/pipeline\.md$)'; then
      echo "::notice::前の公開（${last_ok:0:7}）から、パイプラインの更新しか変わっていないので公開しません"
      exit 0
    fi
  fi

fi

q=""; [ -n "${VERCEL_TEAM_ID:-}" ] && q="&teamId=${VERCEL_TEAM_ID}"
auth=(-H "Authorization: Bearer $VERCEL_TOKEN")
# このリポジトリにつながっている Vercel のプロジェクト（名前がリポジトリと違うことがあるので、つながりで探す）
if ! projects=$(curl -sS "${auth[@]}" "$VERCEL_API/v10/projects?repoUrl=https://github.com/$REPO&limit=5$q"); then
  give_up "Vercel に届きませんでした"
fi
project=$(printf '%s' "$projects" | jq -r '.projects[0].name // empty' 2> /dev/null)
if [ -z "$project" ]; then
  give_up "このリポジトリにつながった Vercel のプロジェクトが見つかりません（$(printf '%s' "$projects" | jq -r '.error.message // "0件"' 2> /dev/null)）"
fi
repo_id=$(gh api "repos/$REPO" -q .id) || give_up "リポジトリの番号を調べられません"
body=$(jq -nc --arg n "$project" --arg id "$repo_id" --arg sha "$head" \
  '{name: $n, project: $n, target: "production", gitSource: {type: "github", repoId: $id, ref: "main", sha: $sha}}')
dq=""; [ -n "${VERCEL_TEAM_ID:-}" ] && dq="?teamId=${VERCEL_TEAM_ID}"
res=$(printf '%s' "$body" | curl -sS -X POST "$VERCEL_API/v13/deployments${dq}" "${auth[@]}" -H "Content-Type: application/json" --data-binary @-) || res=""
url=$(printf '%s' "$res" | jq -r '.url // empty' 2> /dev/null)
if [ -z "$url" ]; then
  give_up "Vercel に公開を頼めませんでした（$(printf '%s' "$res" | jq -r '.error.message // "理由不明"' 2> /dev/null)）"
fi
echo "::notice::最新の main（${head:0:7}）の公開を頼みました：https://$url（プロジェクト $project）"
