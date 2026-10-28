#!/usr/bin/env bash
# ワークフローの安全の確認：秘密（PIPELINE_TOKEN・AIのトークン）を使うワークフローが、
# PRの中身で書き換えられる版（pull_request）で動かないこと。
#   pull_request は、PRのブランチにある版のワークフローが動く。PRが書き換えたワークフローで秘密を使われる恐れがある。
#   pull_request_target は、main にある版が動くので安全。
source "$(dirname "$0")/lib.sh"
WORKFLOWS="$(cd "$SCRIPTS_DIR/../workflows" && pwd)"

# pull_request で動かしてよい物（理由つき）。増やすときは、秘密がPRの変更で使われないかを確かめてから
#   visual-update.yml：同じリポジトリのPR（フォークではない）だけを、if で絞っている
#   claude-review.yml：同じリポジトリのPRだけが秘密を受け取る（フォークのPRには GitHub が秘密を渡さない）。レビューは読むだけで、トークンでは書き換えない
ALLOWED_PULL_REQUEST="visual-update.yml claude-review.yml"

echo "== 秘密を使うワークフローは、pull_request で動かない（許可の一覧にある物だけ例外）"
for f in "$WORKFLOWS"/*.yml; do
  name=$(basename "$f")
  uses_secret=$(grep -cE 'secrets\.(PIPELINE_TOKEN|CLAUDE_CODE_OAUTH_TOKEN)' "$f" || true)
  [ "$uses_secret" -eq 0 ] && continue
  triggers=$(python3 -c "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d.get(True, d.get('on', {}))
print(' '.join(on if isinstance(on, (list, dict)) else [on]))" "$f")
  if printf ' %s ' "$triggers" | grep -q ' pull_request '; then
    case " $ALLOWED_PULL_REQUEST " in
      *" $name "*) assert_eq "$name：pull_request（許可の一覧にある）" "ok" "ok" ;;
      *) assert_eq "$name：秘密を使うのに pull_request で動く（pull_request_target にするか、許可の一覧に理由つきで足す）" "pull_request_target" "pull_request" ;;
    esac
  else
    assert_eq "$name：pull_request で動かない" "ok" "ok"
  fi
done

echo "== 再開・順番待ちは pull_request_target"
for name in queue.yml resume.yml; do
  assert_contains "$name：pull_request_target を使う" "$(cat "$WORKFLOWS/$name")" "pull_request_target:"
done

echo "== visual-update.yml：PRのコードを動かすジョブには Secret を渡さない"
result=$(python3 - "$WORKFLOWS/visual-update.yml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
bad = []
for name, job in d['jobs'].items():
    text = yaml.dump(job)
    runs_code = any(w in text for w in ('npm ci', 'npm run', 'npx '))
    uses_secret = 'secrets.' in text
    if runs_code and uses_secret:
        bad.append(name)
print(','.join(bad) or 'ok')
PY
)
assert_eq "npm を動かすジョブが Secret を使わない" "ok" "$result"
assert_contains "撮り直しはトークンを残さない" "$(cat "$WORKFLOWS/visual-update.yml")" "persist-credentials: false"

echo "== doctor.yml：診断の失敗（❌）が、tee で隠れず、実行の失敗になる"
assert_contains "pipefail を使う" "$(cat "$WORKFLOWS/doctor.yml")" "set -o pipefail"

finish
