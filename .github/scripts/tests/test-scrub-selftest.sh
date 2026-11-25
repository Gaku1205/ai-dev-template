#!/usr/bin/env bash
# 子プロセスの鍵消しの自己テスト（scrub-selftest.yml）：答え合わせ（scrub-selftest-check.sh）が、
# 撮れた・鍵が見えない時だけ通り、どれかがだめなら失敗にする。ワークフローは手でだけ動き、決まった頼み文だけを使う
source "$(dirname "$0")/lib.sh"
WF="$SCRIPTS_DIR/../workflows/scrub-selftest.yml"

work=$(mktemp -d)
check() { # 結果の文（最後の行に rc=）
  (cd "$work" && GITHUB_STEP_SUMMARY="$work/summary.md" OUTCOME=success bash "$SCRIPTS_DIR/scrub-selftest-check.sh" > /dev/null 2>&1; echo "rc=$?"; cat "$work/summary.md")
}
reset() { rm -rf "$work/.shots" "$work/scrub-env-names.txt" "$work/summary.md"; }
good_names() { printf '%s\n' GITHUB_WORKSPACE HOME PATH > "$work/scrub-env-names.txt"; }
good_shot() { mkdir -p "$work/.shots" && printf 'png' > "$work/.shots/scrub-page-1440.png"; }

echo "== 撮れて、鍵の名前が見えなければ通る"
reset; good_names; good_shot
out=$(check)
assert_contains "通る" "$out" "rc=0"
assert_contains "撮影は✅" "$out" "✅ 撮影"
assert_contains "環境変数は✅" "$out" "✅ 環境変数"

echo "== 画像が無ければ失敗（囲いの中で Chrome が立たない）"
reset; good_names
out=$(check)
assert_contains "失敗" "$out" "rc=1"
assert_contains "撮影は❌" "$out" "❌ 撮影"

echo "== AIの鍵の名前が見えたら失敗"
reset; good_shot; good_names; printf '%s\n' CLAUDE_CODE_OAUTH_TOKEN ACTIONS_ID_TOKEN_REQUEST_TOKEN >> "$work/scrub-env-names.txt"
out=$(check)
assert_contains "失敗" "$out" "rc=1"
assert_contains "見えた名前を書く" "$out" "CLAUDE_CODE_OAUTH_TOKEN ACTIONS_ID_TOKEN_REQUEST_TOKEN"

echo "== 似た名前（前後に文字がある）は鍵に数えない"
reset; good_shot; good_names; printf '%s\n' MY_CLAUDE_CODE_OAUTH_TOKEN_HINT >> "$work/scrub-env-names.txt"
assert_contains "通る" "$(check)" "rc=0"

echo "== 名前の一覧が無い・おかしいときは失敗（鍵が無いと誤って通さない）"
reset; good_shot
assert_contains "一覧が無い" "$(check)" "rc=1"
reset; good_shot; printf '%s\n' PATH > "$work/scrub-env-names.txt"
out=$(check)
assert_contains "GITHUB_WORKSPACE も無い" "$out" "rc=1"
assert_contains "理由を書く" "$out" "GITHUB_WORKSPACE も無い"

echo "== ワークフロー：手でだけ動き、テンプレート本体だけ。AIのステップだけに鍵消しを入れ、動かせるのは2つのコマンドだけ"
result=$(python3 - "$WF" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d.get(True, d.get('on'))
out = []
out.append('on=' + ','.join(on if isinstance(on, (list, dict)) else [on]))
job = d['jobs']['scrub']
out.append('if=' + job.get('if', ''))
ai = [s for s in job['steps'] if str(s.get('uses', '')).startswith('anthropics/claude-code-action@')]
out.append('ai=%d' % len(ai))
out.append('scrub=' + str(ai[0].get('env', {}).get('CLAUDE_CODE_SUBPROCESS_ENV_SCRUB')))
args = ai[0]['with']['claude_args']
out.append('tools=' + args.split('--allowedTools ')[1])
out.append('persist=' + str(job['steps'][0]['with'].get('persist-credentials')))
names = [st.get('name', '') for st in job['steps']]
idx_ai = job['steps'].index(ai[0])
out.append('tools_before_ai=' + str(any('socat' in str(st.get('run', '')) for st in job['steps'][:idx_ai])))
out.append('full_output=' + str(ai[0]['with'].get('show_full_output')))
out.append('prompt_has_expr=' + str('${{' in ai[0]['with']['prompt']))
print('\n'.join(out))
PY
)
assert_contains "workflow_dispatch だけ" "$result" "on=workflow_dispatch"
assert_contains "テンプレート本体だけ" "$result" "if=github.event.repository.is_template"
assert_contains "AIのステップは1つ" "$result" "ai=1"
assert_contains "鍵消しを入れる" "$result" "scrub=1"
assert_contains "動かせるのは撮影と名前の書き出しだけ" "$result" 'tools="Bash(node .github/scripts/shot.mjs scrub-page.html),Bash(./scrub-env.sh)"'
assert_contains "git の鍵を残さない" "$result" "persist=False"
assert_contains "AIの前に囲いの道具（socat）を入れる" "$result" "tools_before_ai=True"
assert_contains "コマンドの結果をログで見られる" "$result" "full_output=True"
assert_contains "頼み文に外の値を入れない" "$result" "prompt_has_expr=False"

rm -rf "$work"
finish
