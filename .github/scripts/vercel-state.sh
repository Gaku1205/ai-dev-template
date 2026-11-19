#!/usr/bin/env bash
# Vercel の公開の状態を読む共通の関数（deploy-vercel.sh と deploy-vercel-skip.sh が source する。読むだけで、公開は頼まない）
# 使う前に REPO（owner/name）を決めておく

# コミットの Vercel の状態（success・pending・failure・error・ignored。無ければ空）を出す。
# 「Canceled by Ignored Build Step」（vercel.json の ignoreCommand で飛ばした物）も success になるので、ignored として分ける
vercel_state() { # sha
  gh api "repos/$REPO/commits/$1/status" -q '[.statuses[] | select(.context | startswith("Vercel"))] | sort_by(.updated_at) | last
    | if . == null then "" elif .state == "success" and ((.description // "") | test("Ignored Build Step"; "i")) then "ignored" else .state end' 2> /dev/null || true
}

# main の直近のコミット（新しい順に最大30件）のうち、最後に公開に成功した物の sha を出す（無ければ空）
vercel_last_ok() {
  local sha
  for sha in $(gh api "repos/$REPO/commits?sha=main&per_page=30" -q '.[].sha'); do
    if [ "$(vercel_state "$sha")" = success ]; then echo "$sha"; return 0; fi
  done
  return 0
}
