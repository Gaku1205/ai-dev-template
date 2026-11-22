#!/usr/bin/env bash
# テンプレートから作ったリポジトリの、最初の1回だけの準備。
#   1. ラベルが無ければ作る  2. CLAUDE.md から「ai-dev-template 自身の作業」の節を消す  3. 診断（doctor）を出す
# ラベル（ai:plan）がもうあれば、何もしない（2回目以降の push では動かない）。
# 必要な環境変数：GH_TOKEN、REPO。出力は Summary 向けの文章。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# CLAUDE.md から「## ai-dev-template 自身の作業」で始まる節（次の「## 」の手前まで）を消す
strip_self_edit() {
  local file="$1" tmp
  [ -f "$file" ] || return 0
  tmp="$(mktemp)"
  awk '
    /^## ai-dev-template 自身の作業/ { skip = 1; next }
    /^## / { skip = 0 }
    !skip { print }
  ' "$file" > "$tmp"
  # 節の外にある、ai-dev-template 自身だけの但し書きも消す
  sed -i -e 's/。ただし ai-dev-template 自身だけ、下の「ai-dev-template 自身の作業」で許した物は触ってよい//' \
    -e 's/（パイプラインの説明。ai-dev-template 自身だけ、`docs\/pipeline.md` は下の節で触ってよい）/（パイプラインの説明）/' "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# 配り先の一覧（.github/sync-targets）の中身を空にする（コメント行と空行は残す）。
# 作者の配り先（Gaku1205/agent-desk など）が、写しにも付いてくるため
clear_sync_targets() {
  local file="$1" tmp
  [ -f "$file" ] || return 0
  tmp="$(mktemp)"
  awk '/^[[:space:]]*#/ || NF == 0 { print }' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

is_template_repo() { [ "$(gh api "repos/$REPO" --jq '.is_template' 2> /dev/null)" = true ]; }

has_label() { grep -qxF "ai:plan" <<< "$(gh api "repos/$REPO/labels?per_page=100" --paginate --jq '.[].name')"; }

main() {
  REPO="${REPO:?REPO を指定}"
  if has_label; then echo "準備ずみ（ラベルがある）。何もしません。"; return 0; fi
  echo "## 最初の準備（$REPO）"
  # ラベルを作れなかったら、ここで止める（CLAUDE.md も触らない）。目印の ai:plan は最後に作るので、次の push でもう一度やり直す
  if REPO="$REPO" "$HERE/labels.sh" > /dev/null; then
    echo "- ✅ ラベルを作った"
  else
    echo "- ❌ ラベルを全部は作れませんでした（GitHub の不調など）。次に main へ push されたときに、もう一度やり直します。急ぐときは Actions の「Bootstrap」を手で動かす"
    return 1
  fi
  if [ -f CLAUDE.md ] && grep -q "^## ai-dev-template 自身の作業" CLAUDE.md; then
    strip_self_edit CLAUDE.md
    echo "- ✅ CLAUDE.md から「ai-dev-template 自身の作業」の節を消した"
    echo "CHANGED_CLAUDE_MD=1" >> "${GITHUB_ENV:-/dev/null}"
  fi
  # テンプレート本体ではない所だけ：作者の配り先を残さない
  if [ -f .github/sync-targets ] && ! is_template_repo && grep -qE '^[[:space:]]*[^#[:space:]]' .github/sync-targets; then
    clear_sync_targets .github/sync-targets
    echo "- ✅ .github/sync-targets の配り先を空にした（作者の配り先を、この写しから配らないため）"
    echo "CHANGED_SYNC_TARGETS=1" >> "${GITHUB_ENV:-/dev/null}"
  fi
  echo
  REPO="$REPO" "$HERE/doctor.sh" || true
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main; fi
