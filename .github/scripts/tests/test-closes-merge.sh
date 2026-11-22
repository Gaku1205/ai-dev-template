#!/usr/bin/env bash
# Closes/Fixes/Resolves のPRがマージされたら、閉じる Issue から ai:implement（と ai:retry・ai:review）を外す。コメントは付けない
source "$(dirname "$0")/lib.sh"
setup_mock
# PR を持つ状態にする。引数：PR番号 本文 Issueのラベル（JSON の配列）。マージ済み
init_pr() {
  PR_NUM="$1" PR_BODY="$2" PR_LABELS="$3" python3 -c "
import json, os
n = int(os.environ['PR_NUM'])
print(json.dumps({'labels': {'7': json.loads(os.environ['PR_LABELS'])}, 'pulls': [{'number': n, 'head': {'sha': 'abc', 'ref': 'claude/issue-7-x%d' % n}, 'body': os.environ['PR_BODY'], 'state': 'closed', 'merged_at': '2026-11-19T03:00:00Z'}]}))" > "$MOCK_DIR/init.json"
  init_state "$(cat "$MOCK_DIR/init.json")"
}

echo "== Closes のPRがマージされたら、ai:implement・ai:retry・ai:review が外れ、コメントは付かない"
init_pr 5 $'Closes #7\n\n## 受け入れ条件\n- [x] できた' '["ai:implement","ai:retry","ai:review","audit"]'
run_lib "release_issue_after_closes_merge 5" > /dev/null
assert_eq "進行ラベルが外れる" "audit" "$(labels_of 7)"
assert_eq "コメントは付かない" "" "$(comments_of 7)"

echo "== Fixes・Resolves でも同じ。二重に呼んでも同じ"
init_pr 5 'Fixes #7' '["ai:implement"]'
run_lib "release_issue_after_closes_merge 5" > /dev/null
run_lib "release_issue_after_closes_merge 5" > /dev/null
assert_eq "Fixes" "" "$(labels_of 7)"
init_pr 5 'Resolves #7' '["ai:implement","size:S"]'
run_lib "release_issue_after_closes_merge 5" > /dev/null
assert_eq "Resolves" "size:S" "$(labels_of 7)"

echo "== Refs のPRでは何もしない"
init_pr 5 $'Refs #7\n\n- [ ] 残り' '["ai:implement"]'
run_lib "release_issue_after_closes_merge 5" > /dev/null
assert_eq "ラベルはそのまま" "ai:implement" "$(labels_of 7)"

echo "== マージされていないPRでは何もしない"
init_pr 5 'Closes #7' '["ai:implement"]'
state_py "s['pulls'][0].pop('merged_at')"
run_lib "release_issue_after_closes_merge 5" > /dev/null
assert_eq "ラベルはそのまま" "ai:implement" "$(labels_of 7)"

echo "== 『人間にお願いしたいこと』のPRでは何もしない"
init_pr 5 $'Closes #7\n\n### 人間にお願いしたいこと\n差分を当てて' '["ai:implement"]'
run_lib "release_issue_after_closes_merge 5" > /dev/null
assert_eq "ラベルはそのまま" "ai:implement" "$(labels_of 7)"

echo "== 外すのに失敗しても、呼び出しは成功で終わる"
init_pr 5 'Closes #7' '["ai:implement"]'
state_py "s['label_delete_fail']=['7']"
run_lib "release_issue_after_closes_merge 5" > /dev/null
assert_eq "失敗しても落ちない" "0" "$?"

finish
