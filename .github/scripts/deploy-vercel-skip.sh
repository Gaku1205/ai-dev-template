#!/usr/bin/env bash
# 「寝なくてよいか」を調べる（deploy-vercel.yml の「続けてのマージを待つ」の前に呼ぶ）。読むだけで、公開は頼まない。
# deploy-vercel.sh と同じ判定で、公開しなくてよいと分かったときだけ 0（寝ずにすぐ終わってよい）：
#   - 最新の main が、もう公開に成功している
#   - 最後に公開に成功したコミットから、パイプラインの物（pipeline-paths.sh）しか変わっていない
# それ以外は 1（アプリのファイルが変わった・公開に成功したコミットが無い・API が読めない・VERCEL_TOKEN が無い・VERCEL_FORCE=1）。
# 1 のときは、今までどおり待って deploy-vercel.sh に任せる
# 環境変数：GITHUB_REPOSITORY、GH_TOKEN、VERCEL_TOKEN、VERCEL_FORCE（任意）
set -uo pipefail
dir="$(dirname "$0")"
source "$dir/pipeline-paths.sh"
source "$dir/vercel-state.sh"
REPO="${GITHUB_REPOSITORY:?}"

[ -n "${VERCEL_TOKEN:-}" ] || exit 1
[ "${VERCEL_FORCE:-}" != 1 ] || exit 1

head=$(gh api "repos/$REPO/commits/main" -q .sha 2> /dev/null) || exit 1
[ -n "$head" ] || exit 1
last_ok=$(vercel_last_ok) || exit 1
[ -n "$last_ok" ] || exit 1
if [ "$last_ok" = "$head" ]; then
  echo "::notice::最新の main（${head:0:7}）はもう公開されているので、待ちません"
  exit 0
fi
changed=$(gh api "repos/$REPO/compare/$last_ok...$head" -q '.files[].filename' 2> /dev/null) || exit 1
if pipeline_files_only "$changed"; then
  echo "::notice::前の公開（${last_ok:0:7}）から、パイプラインの更新しか変わっていないので、待ちません"
  exit 0
fi
exit 1
