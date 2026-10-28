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
token_expiration() { echo "${EXP:-}"; }
is_template_repo() { [ "${IS_TEMPLATE:-false}" = true ]; }

run_doctor() { out="$(main 2>&1)"; rc=$?; }
workdir="$(mktemp -d)"; cd "$workdir" || exit 1
mkdir -p docs; echo "# app" > CLAUDE.md; echo x > AGENTS.md; echo x > docs/spec.md
echo '{"scripts":{"typecheck":"x","lint":"x","test":"x","build":"x"}}' > package.json

echo "== 全部そろっていれば問題なし"
LABELS="$all_labels" DELBR=true CANPUSH=true HAS_OAUTH=1 HAS_PIPELINE_TOKEN=1 HAS_NTFY=1
run_doctor
assert_eq "終了コード 0" "0" "$rc"
assert_contains "問題なし" "$out" "問題なし"

echo "== Secret もラベルも無ければ ❌"
LABELS="ai:plan" DELBR=false CANPUSH=false HAS_OAUTH=0 HAS_PIPELINE_TOKEN=0 HAS_NTFY=0
run_doctor
assert_eq "終了コード 1" "1" "$rc"
assert_contains "OAuth" "$out" "CLAUDE_CODE_OAUTH_TOKEN が無い"
assert_contains "鍵が無い" "$out" "パイプラインの鍵が無い"
assert_contains "ラベル" "$out" "ラベルが足りない"
assert_contains "通知は警告" "$out" "⚠️ NTFY_TOPIC"

echo "== トークンはあるが書き込めない"
LABELS="$all_labels" DELBR=true CANPUSH=false HAS_OAUTH=1 HAS_PIPELINE_TOKEN=1 HAS_NTFY=1
run_doctor
assert_contains "書き込めない" "$out" "書き込めない"

echo "== CLAUDE.md がテンプレートのまま・足りないスクリプト"
echo "（アプリの説明を1〜2行で書く）" > CLAUDE.md
echo '{"scripts":{"lint":"x"}}' > package.json
CANPUSH=true
run_doctor
assert_contains "テンプレートのまま" "$out" "CLAUDE.md がテンプレートのまま"
IS_TEMPLATE=true
run_doctor
assert_not_contains "テンプレート自身なら書きかけでよい" "$out" "CLAUDE.md がテンプレートのまま"
IS_TEMPLATE=false
assert_contains "test が無いのは警告" "$out" "⚠️ package.json に test のスクリプトが無い"
assert_contains "typecheck が無いのは ❌" "$out" "❌ package.json に typecheck のスクリプトが無い"

echo "== セルフ編集の印が他のリポジトリに残っていたら警告"
echo "<!-- pipeline-self-edit: auto -->" > CLAUDE.md
run_doctor
assert_contains "印の警告" "$out" "pipeline-self-edit の印が残っている"
IS_TEMPLATE=true
run_doctor
assert_not_contains "テンプレート自身なら警告しない" "$out" "pipeline-self-edit の印が残っている"

cd /; rm -rf "$workdir"
echo "== ブランチ削除の設定が見えない（空）なら、オフと決めつけない"
DELBR=""
run_doctor
assert_not_contains "オフと言わない" "$out" "がオフ"
assert_contains "見えないと書く" "$out" "確かめていない"

echo "== トークンの期限"
DELBR=true CANPUSH=true HAS_PIPELINE_TOKEN=1
EXP="$(date -u -d '+10 days' '+%Y-%m-%d %H:%M:%S UTC')"
run_doctor
assert_contains "30日未満は警告" "$out" "⚠️ PIPELINE_TOKEN の期限まであと"
EXP="$(date -u -d '-1 days' '+%Y-%m-%d %H:%M:%S UTC')"
run_doctor
assert_contains "切れていたら ❌" "$out" "❌ PIPELINE_TOKEN の期限が切れている"
EXP="$(date -u -d '+200 days' '+%Y-%m-%d %H:%M:%S UTC')"
run_doctor
assert_contains "十分あれば ✅" "$out" "✅ PIPELINE_TOKEN の期限まであと"
EXP=""

echo "== GitHub App の鍵を使っているとき"
USING_APP=1 CANPUSH=true HAS_PIPELINE_TOKEN=1 EXP="$(date -u -d '+0 days' '+%Y-%m-%d %H:%M:%S UTC')"
run_doctor
assert_contains "App で書き込める" "$out" "GitHub App の鍵でこのリポジトリに書き込める"
assert_not_contains "1時間の鍵の期限で警告しない" "$out" "PIPELINE_TOKEN の期限"
assert_not_contains "切り替えを勧めない" "$out" "GitHub App ではなく"
USING_APP=0 EXP=""
run_doctor
assert_contains "PIPELINE_TOKEN なら App を勧める" "$out" "⚠️ GitHub App ではなく PIPELINE_TOKEN"

finish
