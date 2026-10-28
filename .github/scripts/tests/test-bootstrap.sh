#!/usr/bin/env bash
# 最初の準備（bootstrap.sh）：CLAUDE.md から自己編集の節だけを消す
source "$(dirname "$0")/lib.sh"
setup_mock
source "$SCRIPTS_DIR/bootstrap.sh"

f="$(mktemp)"
cat > "$f" <<'MD'
# このリポジトリでのルール

アプリの説明

## 触ってはいけないもの

- a

## ai-dev-template 自身の作業（パイプライン本体だけ）

- 触ってよい：x
<!-- pipeline-self-edit: auto -->

## コードの書き方

- b
MD

echo "== 自己編集の節だけが消える"
strip_self_edit "$f"
out="$(cat "$f")"
assert_not_contains "節の見出しが消える" "$out" "ai-dev-template 自身の作業"
assert_not_contains "印が消える" "$out" "pipeline-self-edit"
assert_contains "前の節は残る" "$out" "触ってはいけないもの"
assert_contains "後ろの節は残る" "$out" "コードの書き方"
assert_contains "後ろの中身も残る" "$out" "- b"

echo "== 節が無ければ変わらない"
before="$(cat "$f")"; strip_self_edit "$f"
assert_eq "変わらない" "$before" "$(cat "$f")"
rm -f "$f"
finish
