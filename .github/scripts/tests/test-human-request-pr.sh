#!/usr/bin/env bash
# 「人間にお願いしたいこと」の節があるPR：マージしてもIssueを閉じない（Closes を Refs に直し、Issueに頼みごとを1回だけ書く）
source "$(dirname "$0")/lib.sh"
setup_mock
pr_body() { python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print([p for p in s['pulls'] if p['number']==5][0]['body'])"; }
# PR 5 だけを持つ状態にする。引数：本文 Issueのラベル（JSON の配列）
init_pr() {
  PR_BODY="$1" PR_LABELS="$2" python3 -c "
import json, os
print(json.dumps({'labels': {'7': json.loads(os.environ['PR_LABELS'])}, 'pulls': [{'number': 5, 'head': {'sha': 'abc', 'ref': 'claude/issue-7-x'}, 'body': os.environ['PR_BODY']}]}))" > "$MOCK_DIR/init.json"
  init_state "$(cat "$MOCK_DIR/init.json")"
}

with_section=$'Closes #7\n\n## 変えたこと\nあれこれ\n\n### 人間にお願いしたいこと\nワークフローに次の差分を当ててください。\n\n+ foo\n\n---\n_自動で作ったPRです。_'

echo "== 節がある：Refs になり、Issueにコメントが1回だけ付く"
init_pr "$with_section" '["ai:implement","audit"]'
run_lib "defer_close_for_human_request 5" > /dev/null
b=$(pr_body)
assert_contains "Refs #7 になる" "$b" "Refs #7"
assert_not_contains "Closes は残らない" "$b" "Closes #7"
c=$(comments_of 7)
assert_eq "1行目は human-request の印" "<!-- human-request -->" "$(printf '%s' "$c" | head -1)"
assert_contains "2行目が要点の1文" "$(printf '%s' "$c" | sed -n 2p)" "PR #5 の『人間にお願いしたいこと』を当ててください。当てたらこのIssueを閉じてください"
assert_contains "PRへのリンク" "$c" "/o/r/pull/5"
assert_contains "節の中身を写す" "$c" "+ foo"
assert_not_contains "節の外は写さない" "$c" "自動で作ったPRです"
assert_contains "PRごとの印" "$c" "<!-- human-request-pr: #5 -->"
assert_contains "PRが開いている間は ai:implement を残す" "$(labels_of 7)" "ai:implement"
assert_not_contains "PRが開いている間は ai:skip を付けない" "$(labels_of 7)" "ai:skip"

echo "== マージされた後：進行ラベルを外して ai:skip（何度呼んでも同じ）"
: > "$MOCK_DIR/curl.log"
run_lib "park_issue_after_human_request_merge 5" > /dev/null
assert_eq "マージ後に通知が1回" "1" "$(notify_count)"
run_lib "park_issue_after_human_request_merge 5" > /dev/null
assert_eq "2回呼んでも通知は1回" "1" "$(notify_count)"
assert_not_contains "進行ラベルを外す" "$(labels_of 7)" "ai:implement"
assert_contains "ai:skip を付ける" "$(labels_of 7)" "ai:skip"
assert_contains "ほかのラベルは残す" "$(labels_of 7)" "audit"

echo "== 開いていた Issue：開き直しのコメントは増えない"
assert_not_contains "開き直しのコメントなし" "$(comments_of 7)" "コミットの Closes で閉じた"

echo "== コミットの Closes で閉じていた Issue：開き直して ai:skip（2回呼んでもコメントは1つ）"
state_py "s.setdefault('issues_meta',{}).setdefault('7',{})['state']='closed'; s['labels']['7']=['ai:implement','audit']"
run_lib "park_issue_after_human_request_merge 5" > /dev/null
assert_eq "開き直す" "open" "$(python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print(s['issues_meta']['7']['state'])")"
assert_contains "ai:skip を付ける" "$(labels_of 7)" "ai:skip"
assert_not_contains "ai:implement を外す" "$(labels_of 7)" "ai:implement"
assert_eq "開き直しのコメントは1つ" "1" "$(comments_of 7 | grep -c 'コミットの Closes で閉じたので、差分を当てるまで開けておきます')"
run_lib "park_issue_after_human_request_merge 5" > /dev/null
assert_eq "2回呼んでも1つ" "1" "$(comments_of 7 | grep -c 'コミットの Closes で閉じたので、差分を当てるまで開けておきます')"

echo "== もう一度呼んでも（Refs のまま）、二重にコメントしない"
run_lib "defer_close_for_human_request 5" > /dev/null
assert_eq "コメントは1つ" "1" "$(comments_of 7 | grep -c 'human-request-pr')"

echo "== 節が無い：Closes のまま・コメントなし"
init_pr $'Closes #7\n\n## 変えたこと\nあれこれ' '["ai:implement"]'
run_lib "defer_close_for_human_request 5" > /dev/null
assert_contains "Closes のまま" "$(pr_body)" "Closes #7"
assert_eq "コメントなし" "" "$(comments_of 7)"
assert_eq "ラベルはそのまま" "ai:implement" "$(labels_of 7)"

echo "== 頼みごとのコメントが無いPR：マージされても何もしない"
init_pr $'Refs #7\n\n## 変えたこと\nあれこれ' '["ai:implement"]'
run_lib "park_issue_after_human_request_merge 5" > /dev/null
assert_eq "ラベルはそのまま" "ai:implement" "$(labels_of 7)"

echo "== Fixes でも Refs になる"
init_pr $'Fixes #7\n\n## 人間にお願いしたいこと\nsecret を登録' '[]'
run_lib "defer_close_for_human_request 5" > /dev/null
assert_contains "Refs になる" "$(pr_body)" "Refs #7"
assert_contains "節を写す" "$(comments_of 7)" "secret を登録"

finish
