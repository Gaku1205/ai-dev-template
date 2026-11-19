#!/usr/bin/env bash
# テストの共通部品：疑似 gh の準備、状態の読み書き、判定（assert_*）
# 使い方：各テストの先頭で source して、最後に finish を呼ぶ
set -u
export PYTHONWARNINGS=ignore
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
PASSED=0
FAILED=0

setup_mock() {
  MOCK_DIR="$(mktemp -d)"
  mkdir -p "$MOCK_DIR/bin"
  cp "$TESTS_DIR/fake-gh" "$MOCK_DIR/bin/gh"
  # 疑似 curl：通知（ntfy）に送る内容を curl.log に1行ずつ残す（本物のネットワークには出ない）
  printf '#!/usr/bin/env bash\ncat >> "%s/curl.log"\necho >> "%s/curl.log"\n' "$MOCK_DIR" "$MOCK_DIR" > "$MOCK_DIR/bin/curl"
  chmod +x "$MOCK_DIR/bin/curl"
  : > "$MOCK_DIR/curl.log"
  export PATH="$MOCK_DIR/bin:$PATH"
  export MOCK_STATE="$MOCK_DIR/state.json"
  export GITHUB_REPOSITORY=o/r GH_TOKEN=x READ_TOKEN=x NTFY_TOPIC=test-topic MAX_RETRY=3 RETRY_COOLDOWN_MIN=30 INTAKE_WAIT_SEC=0 MERGE_STATE_WAIT_SEC=0 MERGE_RETRY_WAIT_SEC=0 STEP_LOG_VERIFY_WAIT=0
  # 並列の上限は、既定（global）だと全部のリポジトリで数える（検索の API が増える）。1つのリポジトリの決まりを確かめる
  # 今までのテストは repo で動かし、全部で数えるテスト（test-parallel-scope.sh）だけが PARALLEL_SCOPE を外す
  export PARALLEL_SCOPE=repo QUEUE_RECOUNT_WAIT_SEC=0
  unset NOTIFY_EVENTS AGENT_DESK_URL GITHUB_STEP_SUMMARY
  trap 'rm -rf "$MOCK_DIR"' EXIT
}

# 状態を初期化する。引数は JSON（足りない項目は空で補う）
init_state() {
  # 一時ファイルに書いてから置き換える（読む側が書きかけを見ない）。書けなかったら、古い状態のまま進まず、すぐ失敗させる
  python3 - "$1" <<'PY' || { echo "init_state が失敗しました（古い状態が残っている可能性）"; exit 70; }
import json, os, sys
s = {'next_id': 0, 'comments': [], 'labels': {}, 'issue_updated': {}, 'pulls': [], 'checks': [], 'runs': [], 'jobs': [], 'branches': [], 'authors': {}}
s.update(json.loads(sys.argv[1]))
p = os.environ['MOCK_STATE']
# 場面ごとに疑似 gh の呼び出し記録も新しくする
try: os.remove(os.path.join(os.path.dirname(p), 'calls.log'))
except OSError: pass
json.dump(s, open(p + '.tmp', 'w'))
os.replace(p + '.tmp', p)
PY
}

# 状態を python で書き換える（変数 s が状態）。例：state_py "s['labels']['7']=[]"
state_py() {
  python3 - "$1" <<'PY'
import json, os, sys
s = json.load(open(os.environ['MOCK_STATE']))
exec(sys.argv[1])
json.dump(s, open(os.environ['MOCK_STATE'], 'w'))
PY
}

ago() { date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ; }
labels_of() { python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print(','.join(sorted(s['labels'].get('$1',[]))))"; }
comments_of() { python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print('\n'.join(c['body'] for c in s['comments'] if c['issue']=='$1'))"; }
branch_names() { python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print(','.join(sorted(b['name'] for b in s['branches'])))"; }
# 記録のコメント（<!-- auto-retry -->）の更新時刻を、N分前に書き換える（待ち時間が過ぎたことにする）
age_retry_comments() { state_py "
for c in s['comments']:
    if 'auto-retry' in c['body']: c['updated_at'] = '$(ago "$1")'"; }
# 送った通知の数（疑似 curl の記録）
notify_count() { grep -c '"topic"' "$MOCK_DIR/curl.log" || true; }
# 記録のコメントの印を書き換える（上限の待ちの時刻をずらすのに使う）。使い方：set_mark_value limit-until 123
set_mark_value() { state_py "
import re
for c in s['comments']:
    if 'auto-retry' in c['body']: c['body'] = re.sub(r'<!-- $1=[0-9a-z]+ -->', '<!-- $1=$2 -->', c['body'])"; }
# スクリプトを、リポジトリのルートから動かす
run_script() { local script="$1"; shift; bash "$SCRIPTS_DIR/$script" "$@" 2>&1; }
# スクリプトを動かし、出力を捨てずに LAST_OUT に取る（失敗したとき show_context が表示する）。終了コードはスクリプトのもの
LAST_OUT=""
run_script_keep() { LAST_OUT=$(run_script "$@"); local rc=$?; return "$rc"; }
# 失敗したとき、どの状態で動いたかを出す：MOCK_STATE の中身・calls.log・直前のスクリプトの出力・通知の記録
show_context() {
  echo "       --- 失敗時の状態（MOCK_STATE=${MOCK_STATE:-未設定}）---"
  if [ -f "${MOCK_STATE:-/nonexistent}" ]; then sed 's/^/       state: /' "$MOCK_STATE" | cut -c1-2000; else echo "       state: （ファイルが無い）"; fi
  if [ -n "${MOCK_DIR:-}" ] && [ -f "$MOCK_DIR/calls.log" ]; then sed 's/^/       calls: /' "$MOCK_DIR/calls.log" | tail -n 40; fi
  if [ -n "${MOCK_DIR:-}" ] && [ -f "$MOCK_DIR/curl.log" ]; then sed 's/^/       curl: /' "$MOCK_DIR/curl.log" | tail -n 10; fi
  if [ -n "$LAST_OUT" ]; then printf '%s\n' "$LAST_OUT" | sed 's/^/       出力: /' | tail -n 40; fi
  echo "       ---"
}
run_lib() { bash -c "source '$SCRIPTS_DIR/pipeline-lib.sh'; $1" 2>&1; }

assert_eq() { # 説明 期待 実際
  if [ "$2" = "$3" ]; then PASSED=$((PASSED + 1)); echo "  ok   $1"
  else FAILED=$((FAILED + 1)); echo "  FAIL $1"; echo "       期待: $2"; echo "       実際: $3"; show_context; fi
}
# 全体は、パイプ（printf | grep -q）ではなく <<< で渡す。grep -q は見つけた所で読むのをやめるので、pipefail のテストでは、
# 書く側が途中で切られて「無い」になることがある（テストを並べて動かすと、混んで起きやすい）
assert_contains() { # 説明 全体 含むはずの文字
  if grep -qF -- "$3" <<< "$2"; then PASSED=$((PASSED + 1)); echo "  ok   $1"
  else FAILED=$((FAILED + 1)); echo "  FAIL $1"; echo "       含むはず: $3"; echo "       実際: $2"; show_context; fi
}
assert_not_contains() { # 説明 全体 含まないはずの文字
  if grep -qF -- "$3" <<< "$2"; then FAILED=$((FAILED + 1)); echo "  FAIL $1"; echo "       含まないはず: $3"; echo "       実際: $2"; show_context
  else PASSED=$((PASSED + 1)); echo "  ok   $1"; fi
}
finish() {
  echo "$(basename "$0")：成功 $PASSED / 失敗 $FAILED"
  [ "$FAILED" -eq 0 ]
}
