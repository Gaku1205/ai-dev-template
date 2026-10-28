#!/usr/bin/env bash
# セットアップの診断（doctor.sh）：足りない物を ❌ で言い当てるか
# shellcheck disable=SC2034  # doctor.sh（source）が読む変数を、ここで渡している
source "$(dirname "$0")/lib.sh"
setup_mock
source "$SCRIPTS_DIR/doctor.sh"
REPO=o/r

all_labels="ai:plan ai:implement ai:review ai:queue ai:hold ai:stuck ai:skip ai:retry visual:update size:S size:L"
fetch_labels() { printf '%s\n' $LABELS; }
fetch_delete_branch() { echo "$DELBR"; }
token_can_push() { echo "$CANPUSH"; }

run_doctor() { out="$(main 2>&1)"; rc=$?; }
workdir="$(mktemp -d)"; cd "$workdir" || exit 1
mkdir -p docs; echo "# app" > CLAUDE.md; echo x > AGENTS.md; echo x > docs/spec.md
echo '{"scripts":{"typecheck":"x","lint":"x","test":"x","build":"x"}}' > package.json

echo "== 全部そろっていれば問題なし"
LABELS="$all_labels" DELBR=true CANPUSH=true HAS_OAUTH=1 HAS_PIPELINE_TOKEN=1 HAS_NTFY=1
run_doctor
assert_eq "終了コード 0" "0" "$rc"
assert_contains "問題なし" "問題なし" "$out"

echo "== Secret もラベルも無ければ ❌"
LABELS="ai:plan" DELBR=false CANPUSH=false HAS_OAUTH=0 HAS_PIPELINE_TOKEN=0 HAS_NTFY=0
run_doctor
assert_eq "終了コード 1" "1" "$rc"
assert_contains "OAuth" "CLAUDE_CODE_OAUTH_TOKEN が無い" "$out"
assert_contains "PIPELINE_TOKEN" "PIPELINE_TOKEN が無い" "$out"
assert_contains "ラベル" "ラベルが足りない" "$out"
assert_contains "通知は警告" "⚠️ NTFY_TOPIC" "$out"

echo "== トークンはあるが書き込めない"
LABELS="$all_labels" DELBR=true CANPUSH=false HAS_OAUTH=1 HAS_PIPELINE_TOKEN=1 HAS_NTFY=1
run_doctor
assert_contains "書き込めない" "書き込めない" "$out"

echo "== CLAUDE.md がテンプレートのまま・足りないスクリプト"
echo "（アプリの説明を1〜2行で書く）" > CLAUDE.md
echo '{"scripts":{"lint":"x"}}' > package.json
CANPUSH=true
run_doctor
assert_contains "テンプレートのまま" "CLAUDE.md がテンプレートのまま" "$out"
assert_contains "test が無い" "test のスクリプトが無い" "$out"

echo "== セルフ編集の印が他のリポジトリに残っていたら警告"
echo "<!-- pipeline-self-edit: auto -->" > CLAUDE.md
run_doctor
assert_contains "印の警告" "pipeline-self-edit の印が残っている" "$out"

cd /; rm -rf "$workdir"
finish
