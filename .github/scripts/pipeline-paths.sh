#!/usr/bin/env bash
# パイプラインの物（テンプレートが配る物）の場所。ここ1か所で決める。
#   .github/・.claude/（スキル）・docs/pipeline.md・docs/pipeline-setup.md
# 公開を飛ばす（deploy-plan.sh・deploy-vercel.sh）、使ってみる役を見送る（found-gate.sh）、人間のマージに回す（after-review.sh）が使う。
# vercel.json の ignoreCommand も同じ場所を除く（JSON なのでここを読めない。変えたら合わせる。test-pipeline-paths.sh が確かめる）
PIPELINE_PATHS_RE='^(\.github/|\.claude/|docs/pipeline(-setup)?\.md$)'

# 変わったファイルの一覧（1行1つ）が、全部パイプラインの物なら 0。空なら 1（何も変わっていない物は「パイプラインだけ」と言わない）
pipeline_files_only() { # files
  [ -n "$1" ] && ! grep -vqE "$PIPELINE_PATHS_RE" <<< "$1"
}
