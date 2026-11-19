#!/usr/bin/env bash
# CIが外の障害（Ubuntu のミラーなど）で落ちたとき（after-ci.sh）：修正AIに頼まず、落ちたジョブをやり直す。2回やり直しても同じなら人間に回す
source "$(dirname "$0")/lib.sh"
setup_mock

BROWSER="見た目のテスト用のブラウザを入れる"
NETLOG="E: Failed to fetch http://security.ubuntu.com/ubuntu/pool/x.deb  Could not wait for server fd"

# 使い方：run_case 落ちた手順（カンマ区切り） ログ（"-" ならログを読めない） [既存のコメントの JSON]
run_case() {
  python3 - "$1" "$2" "${3:-[]}" <<'PY'
import json, os, sys
pr = {'number': 58, 'body': 'Closes #1', 'state': 'open', 'head': {'sha': 'abc', 'ref': 'claude/issue-54-x'}, 'updated_at': '2026-01-01T00:00:00Z'}
steps = [{'name': '型チェック', 'conclusion': 'success'}] + [{'name': n, 'conclusion': 'failure'} for n in sys.argv[1].split(',')]
s = {'next_id': 0, 'comments': json.loads(sys.argv[3]), 'labels': {'58': []}, 'issue_updated': {}, 'pulls': [pr], 'jobs': [{'id': 77, 'steps': steps}], 'checks': [], 'runs': [], 'branches': [], 'authors': {},
     'files': ['src/app/page.tsx']}
if sys.argv[2] != '-':
    s['job_logs'] = {'77': sys.argv[2]}
json.dump(s, open(os.environ['MOCK_STATE'], 'w'))
PY
  READ_TOKEN=readtok RUN_ID=1 CONCLUSION=failure HEAD_SHA=abc HEAD_BRANCH=claude/issue-54-x run_script after-ci.sh > /dev/null
}

reruns() { python3 -c "import json,os;print(len(json.load(open(os.environ['MOCK_STATE'])).get('reruns',[])))"; }
mark_comment() { # 回数分の印つきコメントの JSON
  python3 -c "
import json,sys
print(json.dumps([{'id':10+i,'issue':'58','body':'x（コミット abc）<!-- auto-network-rerun -->','user':{'login':'p'},'created_at':'2026-01-01T00:00:00Z','updated_at':'2026-01-01T00:00:00Z'} for i in range(int(sys.argv[1]))]))" "$1"
}

echo "== ブラウザを入れる所だけがネットワークで落ちた → 修正AIに頼まず、落ちたジョブをやり直す"
run_case "$BROWSER" "$NETLOG"
assert_eq "落ちたジョブをやり直す" "1" "$(reruns)"
assert_not_contains "修正AIは呼ばない" "$(comments_of 58)" "auto-fix"
assert_contains "外の障害の印" "$(comments_of 58)" "auto-network-rerun"
assert_not_contains "止めない" "$(labels_of 58)" "ai:stuck"

echo "== 1回やり直し済みで、また同じ → もう1回やり直す"
run_case "$BROWSER" "$NETLOG" "$(mark_comment 1)"
assert_eq "もう1回やり直す" "1" "$(reruns)"
assert_not_contains "修正AIは呼ばない" "$(comments_of 58)" "auto-fix"

echo "== 2回やり直しても同じ → ai:stuck で人間に回り、修正AIは呼ばれない"
run_case "$BROWSER" "$NETLOG" "$(mark_comment 2)"
assert_eq "もうやり直さない" "0" "$(reruns)"
assert_contains "ai:stuck" "$(labels_of 58)" "ai:stuck"
assert_contains "外の障害と分かる文" "$(comments_of 58)" "外の障害（Ubuntu のミラーなど）"
assert_not_contains "修正AIは呼ばない" "$(comments_of 58)" "auto-fix"

echo "== 依存を入れる所（実行環境をそろえる）がネットワークで落ちた → やり直す"
run_case "実行環境をそろえる" "npm ERR! code ETIMEDOUT"
assert_eq "落ちたジョブをやり直す" "1" "$(reruns)"

echo "== ブラウザを入れる所が落ちたが、ログにネットワークの語が無い → 今まで通り修正AIに頼む"
run_case "$BROWSER" "something else went wrong"
assert_eq "やり直さない" "0" "$(reruns)"
assert_contains "修正AIに頼む" "$(comments_of 58)" "auto-fix"

echo "== ログが読めない → 今まで通り修正AIに頼む"
run_case "$BROWSER" "-"
assert_eq "やり直さない" "0" "$(reruns)"
assert_contains "修正AIに頼む" "$(comments_of 58)" "auto-fix"

echo "== 別の手順も一緒に落ちている → 今まで通り修正AIに頼む"
run_case "$BROWSER,型チェック" "$NETLOG"
assert_eq "やり直さない" "0" "$(reruns)"
assert_contains "修正AIに頼む" "$(comments_of 58)" "auto-fix"

finish
