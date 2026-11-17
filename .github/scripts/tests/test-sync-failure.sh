#!/usr/bin/env bash
# 配布のPRのCIが落ちたとき（after-ci.sh・sync-failure-report.sh）：同じ配布の通知は最初の1件だけにして、テンプレートの Issue にまとめる
source "$(dirname "$0")/lib.sh"
setup_mock

MARK='<!-- pipeline-sync --><!-- pipeline-sync-src: o/tmpl@123abcd -->'
TITLE='配布 123abcd が配り先で落ちています'

setup_state() { # PR本文
  python3 - "$1" <<'PY'
import json, os, sys
pr = {'number': 70, 'body': sys.argv[1], 'user': {'login': 'gaku-ai-pipeline[bot]'}, 'state': 'open', 'head': {'sha': 'abc', 'ref': 'pipeline-sync/123abcd'}, 'updated_at': '2026-01-01T00:00:00Z'}
s = {'next_id': 0, 'comments': [], 'labels': {'70': []}, 'issue_updated': {}, 'pulls': [pr], 'jobs': [], 'checks': [], 'runs': [], 'branches': [{'name': 'pipeline-sync/123abcd'}], 'authors': {}, 'ahead_by': 0}
json.dump(s, open(os.environ['MOCK_STATE'], 'w'))
PY
}
fail_ci() { # 配り先のリポジトリ名
  : > "$MOCK_DIR/curl.log"
  GITHUB_REPOSITORY="$1" RUN_ID=1 CONCLUSION=failure HEAD_SHA=abc HEAD_BRANCH=pipeline-sync/123abcd run_script after-ci.sh > /dev/null
}
issue_titles() { python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print('\n'.join(m['title'] for m in s.get('issues_meta',{}).values()))"; }
issue_count() { python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print(sum(1 for m in s.get('issues_meta',{}).values() if m['state']=='open'))"; }

echo "== 最初の1件：テンプレートに Issue ができ、通知は送られる"
setup_state "$MARK"
fail_ci o/app1
assert_eq "通知が1件" "1" "$(notify_count)"
assert_eq "まとめの Issue が1つ" "$TITLE" "$(issue_titles)"
assert_contains "落ちたアプリが1行残る" "$(comments_of 101)" "\`o/app1\` PR #70：CIが落ちました"
assert_contains "ラベルは付けない" "[$(labels_of 101)]" "[]"
assert_contains "ai:stuck は今までどおり付く" "$(labels_of 70)" "ai:stuck"
assert_contains "PRへのコメントは今までどおり" "$(comments_of 70)" "CIが落ちました"

echo "== 2件目以降：通知は送られず、まとめ先にコメントが付く（PRのコメントと ai:stuck は今までどおり）"
state_py "s['labels']['70']=[]; s['comments']=[c for c in s['comments'] if c['issue']!='70']"
fail_ci o/app2
assert_eq "通知は送られない" "0" "$(notify_count)"
assert_eq "Issue は増えない" "1" "$(issue_count)"
assert_contains "まとめ先に2件目が書かれる" "$(comments_of 101)" "\`o/app2\` PR #70：CIが落ちました"
assert_contains "1件目も残っている" "$(comments_of 101)" "\`o/app1\` PR #70"
assert_contains "ai:stuck が付く" "$(labels_of 70)" "ai:stuck"
assert_contains "PRへのコメントが付く" "$(comments_of 70)" "CIが落ちました"

echo "== 別の配布（別の sha）は、別の Issue にまとめ、通知する"
state_py "s['labels']['70']=[]; s['pulls'][0]['body']=s['pulls'][0]['body'].replace('123abcd','999ffff'); s['pulls'][0]['head']['ref']='pipeline-sync/999ffff'; s['branches']=[{'name':'pipeline-sync/999ffff'}]"
: > "$MOCK_DIR/curl.log"
GITHUB_REPOSITORY=o/app3 RUN_ID=1 CONCLUSION=failure HEAD_SHA=abc HEAD_BRANCH=pipeline-sync/999ffff run_script after-ci.sh > /dev/null
assert_eq "通知が1件" "1" "$(notify_count)"
assert_contains "別の Issue ができる" "$(issue_titles)" "配布 999ffff が配り先で落ちています"

echo "== テンプレートの Issue を読めない（権限なし）：今までどおり通知する"
mv "$MOCK_DIR/bin/gh" "$MOCK_DIR/bin/gh.real"
cat > "$MOCK_DIR/bin/gh" <<SH
#!/usr/bin/env bash
case "\$*" in *repos/o/tmpl/*) echo "HTTP 403: Resource not accessible by integration" >&2; exit 1 ;; esac
exec "$MOCK_DIR/bin/gh.real" "\$@"
SH
chmod +x "$MOCK_DIR/bin/gh"
setup_state "$MARK"
fail_ci o/app1
assert_eq "通知が送られる" "1" "$(notify_count)"
assert_contains "ai:stuck は付く" "$(labels_of 70)" "ai:stuck"
assert_contains "PRへのコメントは付く" "$(comments_of 70)" "CIが落ちました"
assert_eq "Issue は作られない" "" "$(issue_titles)"
mv "$MOCK_DIR/bin/gh.real" "$MOCK_DIR/bin/gh"

echo "== 元のリポジトリの印が無いPR：今までどおり通知する"
setup_state '<!-- pipeline-sync -->'
fail_ci o/app1
assert_eq "通知が送られる" "1" "$(notify_count)"
assert_eq "Issue は作られない" "" "$(issue_titles)"
setup_state '<!-- pipeline-sync -->'
fail_ci o/app2
assert_eq "印が無ければ毎回通知する" "1" "$(notify_count)"

echo "== 同時に作って重複した：番号が小さい方がまとめ先。大きい方を作った側は閉じて、通知しない"
setup_state "$MARK"
# 先に別のアプリが作った Issue（#101）があるのに、探したときは見えなかった、を表す：1回目の一覧は空にして、作ったあとの一覧に両方が出る
state_py "s['labels']['101']=[]; s.setdefault('issues_meta',{})['101']={'title':'$TITLE','state':'open','body':''}"
export MOCK_DIR
python3 - <<'PY'
import os
p = os.path.join(os.environ['MOCK_DIR'], 'bin', 'gh')
real = p + '.real'
os.rename(p, real)
open(p, 'w').write('''#!/usr/bin/env bash
# 1回目の Issue の一覧だけ、空で返す（同時に作った別アプリの Issue がまだ見えない場面）
f="%s/first-list"
case "$*" in *"issues?state=all"*) if [ ! -e "$f" ]; then : > "$f"; exit 0; fi ;; esac
exec "%s" "$@"
''' % (os.environ['MOCK_DIR'], real))
os.chmod(p, 0o755)
PY
fail_ci o/app4
assert_eq "通知は送られない" "0" "$(notify_count)"
assert_contains "小さい番号の Issue（#101）にコメントが付く" "$(comments_of 101)" "\`o/app4\` PR #70：CIが落ちました"
assert_eq "開いている Issue は1つ" "1" "$(issue_count)"

finish
