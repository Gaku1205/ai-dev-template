#!/usr/bin/env bash
# セットアップの診断：新しいリポジトリでパイプラインが動く状態かを、1回で全部チェックする。
# 結果は ✅（OK）・⚠️（動くが直したほうがよい）・❌（これが無いと動かない）で出す。❌ が1つでもあれば終了コード 1。
# 環境変数：REPO（owner/name）、GH_TOKEN、HAS_OAUTH / HAS_PIPELINE_TOKEN / HAS_NTFY（Secret が入っていれば 1）、PIPELINE_TOKEN（権限の確認用）
set -uo pipefail

NG=0
ok()   { echo "- ✅ $1"; }
warn() { echo "- ⚠️ $1 → $2"; }
ng()   { echo "- ❌ $1 → $2"; NG=$((NG + 1)); }

# 外に出る部分（テストでは差し替える）
fetch_labels()        { gh api "repos/$REPO/labels?per_page=100" --paginate --jq '.[].name'; }
fetch_delete_branch() { gh api "repos/$REPO" --jq '.delete_branch_on_merge'; }
is_template_repo()    { [ "$(gh api "repos/$REPO" --jq '.is_template' 2> /dev/null)" = true ]; }
token_can_push()      { GH_TOKEN="${PIPELINE_TOKEN:-}" gh api "repos/$REPO" --jq '.permissions.push' 2>/dev/null; }

check_secrets() {
  if [ "${HAS_OAUTH:-}" = 1 ]; then ok "CLAUDE_CODE_OAUTH_TOKEN が登録されている"
  else ng "CLAUDE_CODE_OAUTH_TOKEN が無い" "Settings → Secrets → Actions に、claude setup-token で作ったトークンを登録"; fi
  if [ "${HAS_PIPELINE_TOKEN:-}" != 1 ]; then
    ng "PIPELINE_TOKEN が無い" "Fine-grained トークン（Contents・Issues・Pull requests・Workflows の Read and write）を登録"
  elif [ "$(token_can_push)" = true ]; then ok "PIPELINE_TOKEN でこのリポジトリに書き込める"
  else ng "PIPELINE_TOKEN でこのリポジトリに書き込めない" "トークンの Repository access にこのリポジトリを足す"; fi
  if [ "${HAS_NTFY:-}" = 1 ]; then ok "NTFY_TOPIC が登録されている（通知が届く）"
  else warn "NTFY_TOPIC が無い" "スマホ通知が鳴らない。ntfy のトピック名を Secret に登録"; fi
}

check_labels() {
  local have missing="" l
  have="$(fetch_labels)"
  for l in ai:plan ai:implement ai:review ai:queue ai:hold ai:stuck ai:skip ai:retry visual:update size:S size:L; do
    printf '%s\n' "$have" | grep -qxF "$l" || missing="$missing $l"
  done
  if [ -z "$missing" ]; then ok "ラベルが全部ある"
  else ng "ラベルが足りない:${missing}" "Actions の「Setup Labels」を1回実行"; fi
}

check_settings() {
  if [ "$(fetch_delete_branch)" = true ]; then ok "マージ後にブランチを自動で消す設定がオン"
  else warn "「Automatically delete head branches」がオフ" "Settings → General → Pull Requests でオン（オフでも進行役が掃除はする）"; fi
}

check_files() {
  local f s
  for f in CLAUDE.md AGENTS.md docs/spec.md; do
    if [ -f "$f" ]; then ok "$f がある"; else ng "$f が無い" "テンプレートから作り、アプリの説明を書く"; fi
  done
  if [ -f CLAUDE.md ] && grep -q "（アプリの説明を1〜2行で書く）" CLAUDE.md; then
    ng "CLAUDE.md がテンプレートのまま" "アプリの説明を書き、「ai-dev-template 自身の作業」の節を消す"
  fi
  if [ -f CLAUDE.md ] && grep -q "pipeline-self-edit: auto" CLAUDE.md && ! is_template_repo; then
    warn "CLAUDE.md に pipeline-self-edit の印が残っている" "ai-dev-template 自身の節ごと消す（残るとパイプラインの変更が自動でマージされる）"
  fi
  if [ -f package.json ]; then
    for s in typecheck lint build; do
      if grep -q "\"$s\"[[:space:]]*:" package.json; then ok "npm run $s がある"
      else ng "package.json に $s のスクリプトが無い" "CLAUDE.md の「終わる前に実行する」コマンドと同じ名前で足す"; fi
    done
    # テストは無くても動く（CIは、無ければ飛ばす）。ただし無いと、AIの変更を確かめる物が減る
    if grep -q "\"test\"[[:space:]]*:" package.json; then ok "npm run test がある"
    else warn "package.json に test のスクリプトが無い" "動くが、AIの変更を確かめにくい。vitest を入れて \"test\": \"vitest run\" を足す"; fi
  else
    warn "package.json が無い" "Next.js 以外の構成なら、CLAUDE.md と ci.yml の確認コマンドを合わせる"
  fi
}

main() {
  REPO="${REPO:?REPO を指定}"
  echo "## パイプラインの診断（$REPO）"
  echo; echo "### Secret"; check_secrets
  echo; echo "### ラベル・設定"; check_labels; check_settings
  echo; echo "### ファイル"; check_files
  echo
  if [ "$NG" -eq 0 ]; then echo "**問題なし。Issue を書けば動く。**"
  else echo "**❌ が ${NG} 件。上の「→」のとおり直してから、もう一度実行。**"; fi
  [ "$NG" -eq 0 ]
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main; fi
