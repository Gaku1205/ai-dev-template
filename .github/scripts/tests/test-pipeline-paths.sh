#!/usr/bin/env bash
# パイプラインの物の場所（pipeline-paths.sh）：公開を飛ばす・使ってみる役を見送る・人間のマージに回す、の判定が揃っている
source "$(dirname "$0")/lib.sh"
source "$SCRIPTS_DIR/pipeline-paths.sh"
yes_no() { if pipeline_files_only "$1"; then echo yes; else echo no; fi; }

echo "== パイプラインの物だけなら yes"
assert_eq ".github・docs/pipeline.md・docs/pipeline-setup.md" "yes" "$(yes_no "$(printf '.github/a.sh\ndocs/pipeline.md\ndocs/pipeline-setup.md')")"
assert_eq "スキル（.claude/）だけの配布も yes" "yes" "$(yes_no "$(printf '.claude/skills/x/SKILL.md\n.github/workflows/ci.yml')")"
echo "== アプリの物が1つでもあれば no。空も no"
assert_eq "アプリのファイル" "no" "$(yes_no "$(printf '.github/a.sh\nsrc/app.ts')")"
assert_eq "似た名前（docs/pipeline.md.bak）" "no" "$(yes_no "docs/pipeline.md.bak")"
assert_eq "空" "no" "$(yes_no "")"

echo "== vercel.json の ignoreCommand も同じ場所を除く"
# テンプレート本体だけ（配り先のアプリの vercel.json は、アプリの物で、この形とは限らない。examples/ はテンプレートにしか無い）
v=$(cat "$SCRIPTS_DIR/../../vercel.json" 2> /dev/null || true)
if [ -n "$v" ] && [ -d "$SCRIPTS_DIR/../../examples" ]; then
  for p in .github .claude docs/pipeline.md docs/pipeline-setup.md; do
    assert_contains "vercel.json：$p" "$v" ":(exclude)$p'"
  done
fi

echo "== 人間のマージに回す判定にも .claude/ と docs/pipeline-setup.md が入る"
ar=$(cat "$SCRIPTS_DIR/after-review.sh")
assert_contains "hold_pattern に .claude/" "$ar" "hold_pattern='^(\\.github/|\\.claude/|docs/pipeline(-setup)?\\.md\$"
finish
