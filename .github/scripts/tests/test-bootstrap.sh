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

- `.github/` 配下（ワークフロー）。ただし ai-dev-template 自身だけ、下の「ai-dev-template 自身の作業」で許した物は触ってよい
- `CLAUDE.md`、`docs/pipeline.md`（パイプラインの説明。ai-dev-template 自身だけ、`docs/pipeline.md` は下の節で触ってよい）

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

# 疑似 gh：ラベルを作る（gh label create）を記録し、LABEL_FAIL の名前で失敗する。ラベルの一覧は、作れた物を返す
cat > "$MOCK_DIR/bin/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1" = label ] && [ "$2" = create ]; then
  [ "$3" = "${LABEL_FAIL:-}" ] && { echo "HTTP 502" >&2; exit 1; }
  echo "$3" >> "$MOCK_DIR/made-labels"; exit 0
fi
case "$*" in *"/labels?"*) cat "$MOCK_DIR/made-labels" 2> /dev/null; exit 0 ;; esac
echo "想定外：$*" >&2; exit 1
GH
chmod +x "$MOCK_DIR/bin/gh"
export MOCK_DIR
work="$(mktemp -d)"; cd "$work" || exit 1
# 本物と同じく、スクリプトとして動かす（診断（doctor.sh）の中身は、別のテストで確かめる）
boot() { REPO=o/r GITHUB_ENV="$work/env" bash "$SCRIPTS_DIR/bootstrap.sh" 2>&1; }
printf '# app\n\n## ai-dev-template 自身の作業（パイプライン本体だけ）\n\n- x\n\n## コードの書き方\n' > CLAUDE.md

echo "== ラベルを作る途中で失敗：準備ずみにしない（次の push でやり直せる）"
: > "$MOCK_DIR/made-labels"
out=$(LABEL_FAIL=ai:stuck boot); rc=$?
assert_eq "失敗で終わる" "1" "$rc"
assert_contains "作れなかったと書く" "$out" "❌ ラベルを全部は作れませんでした"
assert_not_contains "目印の ai:plan はまだ作っていない" "$(cat "$MOCK_DIR/made-labels")" "ai:plan"
assert_contains "CLAUDE.md はまだ触らない" "$(cat CLAUDE.md)" "ai-dev-template 自身の作業"
assert_eq "labels.sh は ai:plan を最後に作る" "ai:plan" "$(sed -nE 's/^make_label "([^"]+)".*/\1/p' "$SCRIPTS_DIR/labels.sh" | tail -1)"

echo "== もう一度動かす：今度は全部作り、CLAUDE.md の節も消す"
out=$(boot)
assert_not_contains "準備ずみとは言わない" "$out" "準備ずみ"
assert_contains "ラベルを作った" "$out" "✅ ラベルを作った"
assert_eq "最後に ai:plan" "ai:plan" "$(tail -1 "$MOCK_DIR/made-labels")"
assert_not_contains "CLAUDE.md の節を消す" "$(cat CLAUDE.md)" "ai-dev-template 自身の作業"
assert_contains "コミットの目印" "$(cat "$work/env")" "CHANGED_CLAUDE_MD=1"

echo "== 3回目：準備ずみなので何もしない"
out=$(boot)
assert_contains "準備ずみ" "$out" "準備ずみ（ラベルがある）"
cd /; rm -rf "$work"
finish
