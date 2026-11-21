#!/usr/bin/env bash
# ai-dev-template の .github と docs/pipeline.md を、アプリのリポジトリへ配る。
# 使い方: sync-to-apps.sh owner/repo [owner/repo ...]
# 必要な環境変数: GH_TOKEN（配る先に push と PR 作成ができる鍵。ワークフローも配るので Workflows 権限が要る）
# 配り先の main には直接入れず、PR（ブランチ pipeline-sync/<sha>）を作る。配り先の CI が通ったら after-ci.sh がマージする。
# 配る先に .github/sync-keep があれば、そこに書かれたファイル名（1行1つ）は消さずに残す。
# CLAUDE.md / AGENTS.md / docs/spec.md / docs/design.md は配らない。
#
# sync-to-apps.sh --local フォルダ：GitHub には触らず、手元のフォルダに「配ったあとの形」だけを作る（tests/run-as-app.sh が、
# 配り先の形でテストが通るかを、配る前に確かめるのに使う）。
# テスト用：SYNC_GIT_URL（clone 先の書式。%s にリポジトリ名）
set -euo pipefail

src_root="$(cd "$(dirname "$0")/../.." && pwd)"

# 配る物を、配り先のフォルダに写す（配る中身の決まりは、ここ1か所）
copy_pipeline() { # 配り先のルート
  local dir="$1" name
  # テンプレート本体だけの物（配り先では動かない）：工場のIssueの雛形
  # app-fixtures：配る前のテスト用の見本（配り先に入ると、見本の中でさらに見本を回してしまう）
  # dependabot.yml：外の Actions の更新の PR は本体だけで出す（配り先で出ても、次に配る PR で上書きされる）
  local excludes=(--exclude=sync-keep --exclude=sync-targets --exclude=dependabot.yml --exclude=ISSUE_TEMPLATE/new-service.yml --exclude=app-fixtures)
  if [ -f "$dir/.github/sync-keep" ]; then
    while IFS= read -r name || [ -n "$name" ]; do
      name="${name%$'\r'}"
      [ -n "$name" ] && excludes+=("--exclude=$name")
    done < "$dir/.github/sync-keep"
  fi
  mkdir -p "$dir/.github"
  # rsync の終了コード 24（読む途中でファイルが消えた）は失敗にしない。ほかの作業が .github の中の一時ファイルを作って消すと、
  # 起こりうる。set -e でここで全体が止まると、古いPRを閉じる所に届かない（たまに落ちるテストの疑われる原因）
  local rc=0
  rsync -a --delete "${excludes[@]}" "$src_root/.github/" "$dir/.github/" || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 24 ]; then return "$rc"; fi
  mkdir -p "$dir/docs"
  cp "$src_root/docs/pipeline.md" "$src_root/docs/pipeline-setup.md" "$dir/docs/"
  # 共通のスキル（.claude/skills/）も配る。配り先だけのスキルは消さない（同じ名前の物だけ上書き）
  if [ -d "$src_root/.claude/skills" ]; then
    mkdir -p "$dir/.claude/skills"
    cp -R "$src_root/.claude/skills/." "$dir/.claude/skills/"
  fi
}

if [ "${1:-}" = "--local" ]; then
  copy_pipeline "${2:?フォルダを指定}"
  exit 0
fi

src_sha="$(git -C "$src_root" rev-parse --short HEAD)"
GIT_URL="${SYNC_GIT_URL:-https://x-access-token:${GH_TOKEN}@github.com/%s.git}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

for repo in "$@"; do
  echo "== $repo"
  dir="$work/${repo//\//_}"
  # shellcheck disable=SC2059
  if ! git clone -q --depth 1 "$(printf "$GIT_URL" "$repo")" "$dir"; then
    echo "::error::$repo を取得できません"; fail=1; continue
  fi
  copy_pipeline "$dir"

  if [ -z "$(git -C "$dir" status --porcelain)" ]; then
    echo "変更なし"; continue
  fi
  # main には直接 push しない（main の保護で、App は CI を通らないコミットを入れられない）。
  # ブランチに push して PR を作り、配り先の CI が通ったら進行役（after-ci.sh）がマージする
  branch="pipeline-sync/${src_sha}"
  git -C "$dir" checkout -q -b "$branch"
  git -C "$dir" add -A
  git -C "$dir" -c user.name="pipeline-sync" -c user.email="noreply@github.com" \
    commit -q -m "パイプラインの更新を ai-dev-template から取り込む（${src_sha}）"
  if ! git -C "$dir" push -q -f origin "HEAD:refs/heads/$branch"; then
    echo "::error::$repo へ push できません（App が入っているか、Contents・Workflows の権限を確認）"; fail=1; continue
  fi
  # 前の配布のPRがまだ開いていたら、新しい物に置き換える。
  # 一覧を読めなければ、このアプリだけ飛ばして後ろのアプリへ続ける（set -e で全体が終わり、後ろのアプリに配られなくならないように）
  if ! old_prs=$(gh api "repos/$repo/pulls?state=open&per_page=100" --jq '.[] | select(.head.ref | startswith("pipeline-sync/")) | "\(.number) \(.head.ref)"'); then
    echo "::warning::$repo の古い配布のPRの一覧を読めないので、このアプリは飛ばします（次の配布で配ります）"; fail=1; continue
  fi
  while read -r old_pr old_branch; do
    [ -z "$old_pr" ] && continue
    [ "$old_branch" = "$branch" ] && continue
    gh api -X PATCH "repos/$repo/pulls/$old_pr" -f state=closed > /dev/null && echo "古い配布のPR #$old_pr を閉じました"
    gh api -X DELETE "repos/$repo/git/refs/heads/$old_branch" > /dev/null 2>&1 || true
  done <<< "$old_prs"
  # PR があるかを調べられなかったときに「PRを更新した」と言わない（PR が無いまま、配ったことになってしまう）
  if ! open=$(gh api "repos/$repo/pulls?state=open&head=${repo%%/*}:$branch" --jq 'length'); then
    echo "::error::$repo のPRを調べられません"; fail=1; continue
  fi
  if [ "$open" = 0 ]; then
    gh api "repos/$repo/pulls" -f title="パイプラインの更新を取り込む（${src_sha}）" -f head="$branch" -f base=main \
      -f body="ai-dev-template の main（${src_sha}）で CI が通ったパイプラインの更新（\`.github/\`・\`docs/pipeline.md\`・\`docs/pipeline-setup.md\`）です。このリポジトリの CI が通ったら、進行役が自動でマージします。<!-- pipeline-sync --><!-- pipeline-sync-src: ${GITHUB_REPOSITORY:-}@${src_sha} -->" > /dev/null \
      && echo "配った（PR）: $repo" || { echo "::error::$repo にPRを作れません"; fail=1; }
  else
    echo "配った（PRを更新）: $repo"
  fi
done
exit "$fail"
