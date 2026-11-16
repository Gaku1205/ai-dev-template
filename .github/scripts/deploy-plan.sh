#!/usr/bin/env bash
# 公開の計画：pipeline.json の deploy から、どの公開先を動かすかを決めて GITHUB_OUTPUT に書く。deploy.yml から呼ぶ。
#   apprunner=true/false、release=true/false、release_os=["windows-latest",...]、expo=true/false、pages=true/false、supabase=true/false、skip_reason=...
# パイプラインの更新だけのコミット（.github/ と docs/pipeline.md だけ）は公開しない（Vercel の ignoreCommand と同じ考え）。手で動かしたとき（GITHUB_EVENT_NAME=workflow_dispatch）は、いつも公開する。
# 「パイプラインの更新だけ」かは、直前のコミットとの差だけで決めない：公開は1つずつ順に動き、待っている古い実行は、新しい実行が来ると
# 取り消される（deploy.yml の concurrency）。アプリの変更のすぐあとに配布のコミット（.github/ だけ）が入ると、アプリの変更の公開は
# 取り消され、配布のコミットは「更新だけ」で公開しないので、アプリの変更が公開されないまま残る。そこで、直前との差が更新だけのときは、
# main をさかのぼって「公開の結果（deploy/* の success・failure・error）が付いた一番新しいコミット」を探し、そこからの差で決め直す
# （GH_TOKEN があるとき。調べられなければ、今までどおり直前との差で決める）。
# 環境変数：GITHUB_OUTPUT（無ければ標準出力に書く）、CHANGED_FILES（テスト用。無ければ git diff HEAD^ HEAD で調べる）、
#           GH_TOKEN・GITHUB_REPOSITORY・SHA（さかのぼって調べるとき。SHA が無ければ git の HEAD）、DEPLOY_LOOKBACK（さかのぼる数。既定 30）
source "$(dirname "$0")/stack.sh"
out="${GITHUB_OUTPUT:-/dev/stdout}"

errs=$(stack_validate)
if [ -n "$errs" ]; then
  while IFS= read -r e; do echo "::error title=pipeline.json::$e"; done <<< "$errs"
  exit 1
fi

if [ -n "${CHANGED_FILES+x}" ]; then
  changed="$CHANGED_FILES"
else
  changed=$(git diff --name-only HEAD^ HEAD 2> /dev/null || true)
fi
kinds=$(stack_deploy_kinds)
pipeline_only() { [ -n "$1" ] && ! printf '%s\n' "$1" | grep -vqE '^(\.github/|docs/pipeline\.md$)'; }

# 最後に公開の結果が付いたコミットから、今のコミットまでに変わったファイル（調べられなければ 1 で終わる）
changed_since_last_deploy() {
  local repo="${GITHUB_REPOSITORY:-}" head shas sha n base=""
  [ -n "${GH_TOKEN:-}" ] && [ -n "$repo" ] || return 1
  head="${SHA:-$(git rev-parse HEAD 2> /dev/null)}"
  [ -n "$head" ] || return 1
  shas=$(gh api "repos/$repo/commits?sha=$head&per_page=${DEPLOY_LOOKBACK:-30}" -q '.[].sha' 2> /dev/null) || return 1
  for sha in $shas; do
    [ "$sha" = "$head" ] && continue
    n=$(gh api "repos/$repo/commits/$sha/statuses?per_page=100" \
      -q '[.[] | select((.context | startswith("deploy/")) and .state != "pending")] | length' 2> /dev/null) || return 1
    if [ "${n:-0}" -gt 0 ]; then base="$sha"; break; fi
  done
  [ -n "$base" ] || return 1
  gh api "repos/$repo/compare/$base...$head" -q '.files[].filename' 2> /dev/null || return 1
}

skip=""
if [ "${GITHUB_EVENT_NAME:-}" != workflow_dispatch ] && pipeline_only "$changed"; then
  skip="パイプラインの更新だけのコミットなので公開しません"
  # ここで動かす公開先（Vercel 以外）があるときだけ調べる
  if printf '%s\n' "$kinds" | grep -qxE 'aws-apprunner|github-release|expo|github-pages|supabase' &&
    since=$(changed_since_last_deploy) && [ -n "$since" ] && ! pipeline_only "$since"; then
    skip=""
    echo "::notice::このコミットはパイプラインの更新だけですが、前のアプリの変更がまだ公開されていないので、ここで公開します"
  fi
fi

has() { [ -z "$skip" ] && printf '%s\n' "$kinds" | grep -qx "$1" && echo true || echo false; }
{
  echo "apprunner=$(has aws-apprunner)"
  echo "release=$(has github-release)"
  echo "expo=$(has expo)"
  echo "pages=$(has github-pages)"
  echo "supabase=$(has supabase)"
  # 公開先の設定（同じ種類が複数あれば最初の1つ）
  echo "apprunner_config=$(stack_deploy aws-apprunner | head -n 1)"
  echo "release_config=$(stack_deploy github-release | head -n 1)"
  echo "expo_config=$(stack_deploy expo | head -n 1)"
  echo "pages_config=$(stack_deploy github-pages | head -n 1)"
  echo "release_os=$(stack_deploy github-release | head -n 1 | jq -c '.os // ["windows-latest"]' 2> /dev/null || echo '[]')"
  echo "skip_reason=$skip"
} >> "$out"
[ -n "$skip" ] && echo "$skip"
echo "公開先：$(printf '%s' "$kinds" | paste -sd, - || true)"
