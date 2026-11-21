#!/usr/bin/env bash
# 一部だけ直したPR（Refs #N）がマージされたら、Issue を「残り」つきで順番待ちに戻す
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

partial=$'Refs #7\n\n## 受け入れ条件\n- [x] 一覧が出る\n- [ ] 並べ替えができる\n- [ ] 検索ができる\n'

echo "== ① 未チェック行から『残り』を取り、ai:queue に戻る"
init_pr 5 "$partial" '["ai:implement","ai:retry","audit"]'
run_lib "requeue_issue_after_partial_merge 5" > /dev/null
c=$(comments_of 7)
assert_contains "前のPRで一部が済んだ" "$c" "前の PR #5"
assert_contains "未チェック行を残りに書く" "$c" "- 並べ替えができる"
assert_contains "未チェック行（2つ目）" "$c" "- 検索ができる"
assert_not_contains "チェック済みは書かない" "$c" "一覧が出る"
assert_contains "PRごとの印" "$c" "<!-- refs-merge-pr: #5 -->"
assert_eq "ai:queue になり、ai:implement・ai:retry は外れる" "ai:queue,audit" "$(labels_of 7)"

echo "== ④ 二重に呼んでも1回だけ"
run_lib "requeue_issue_after_partial_merge 5" > /dev/null
assert_eq "コメントは1つ" "1" "$(comments_of 7 | grep -c 'refs-merge-pr')"

echo "== ai:skip（人間待ち）の Issue は順番待ちに戻さず、コメントは1回だけ"
init_pr 5 "$partial" '["ai:skip","ai:implement"]'
run_lib "requeue_issue_after_partial_merge 5" > /dev/null
assert_not_contains "ai:queue は付かない" "$(labels_of 7)" "ai:queue"
assert_contains "人間待ちと書く" "$(comments_of 7)" "人間の作業待ち（ai:skip）なので、順番待ちには戻しません"
run_lib "requeue_issue_after_partial_merge 5" > /dev/null
assert_eq "コメントは1つ" "1" "$(comments_of 7 | grep -c 'refs-merge-skip-pr')"

echo "== ② 未チェック行が取れないときの文言"
init_pr 5 $'Refs #7\n\n## 受け入れ条件\n- [x] 全部\n' '["ai:implement"]'
run_lib "requeue_issue_after_partial_merge 5" > /dev/null
assert_contains "PR の説明を見て続ける" "$(comments_of 7)" "PR #5 の説明を見て、残りを続ける"
assert_eq "ai:queue" "ai:queue" "$(labels_of 7)"

echo "== ③ Closes のPRでは何もしない"
init_pr 5 $'Closes #7\n\n- [ ] 残り' '["ai:implement"]'
run_lib "requeue_issue_after_partial_merge 5" > /dev/null
assert_eq "コメントなし" "" "$(comments_of 7)"
assert_eq "ラベルはそのまま" "ai:implement" "$(labels_of 7)"

echo "== ③ 『人間にお願いしたいこと』のPRでは何もしない"
init_pr 5 $'Refs #7\n\n- [ ] 残り\n\n### 人間にお願いしたいこと\n差分を当てて' '["ai:implement"]'
run_lib "requeue_issue_after_partial_merge 5" > /dev/null
assert_eq "コメントなし" "" "$(comments_of 7)"
assert_eq "ラベルはそのまま" "ai:implement" "$(labels_of 7)"

echo "== マージされていないPR・閉じた Issue では何もしない"
init_pr 5 "$partial" '["ai:implement"]'
state_py "s['pulls'][0].pop('merged_at')"
run_lib "requeue_issue_after_partial_merge 5" > /dev/null
assert_eq "マージ前は何もしない" "ai:implement" "$(labels_of 7)"
state_py "s['pulls'][0]['merged_at']='2026-11-19T03:00:00Z'; s.setdefault('issues_meta',{})['7']={'state':'closed'}"
run_lib "requeue_issue_after_partial_merge 5" > /dev/null
assert_eq "閉じた Issue は何もしない" "ai:implement" "$(labels_of 7)"

echo "== ⑤ 3回目は ai:stuck で人間に回り、順番待ちに戻らない"
init_pr 6 "$partial" '["ai:implement"]'
state_py "
s['comments'] = [{'id': i, 'body': '<!-- refs-merge-pr: #%d -->' % i, 'user': {'login': 'x'}, 'created_at': 'a', 'updated_at': 'a', 'issue': '7'} for i in (1, 2)]; s['next_id'] = 10"
run_lib "requeue_issue_after_partial_merge 6" > /dev/null
assert_contains "ai:stuck が付く" "$(labels_of 7)" "ai:stuck"
assert_not_contains "ai:queue は付けない" "$(labels_of 7)" "ai:queue"
assert_contains "理由を書く" "$(comments_of 7)" "Refs"

echo "== ⑥ 見張り役は、マージ済みPRのある ai:implement に ai:retry を付けない"
init_pr 5 "$partial" '["ai:implement"]'
state_py "s['issue_updated']['7']='$(ago 120)'"
run_script watchdog.sh > /dev/null
# 順番待ちに戻したあと、同じ実行の中で順番待ちが進み、空きがあれば ai:implement に戻ることがある
assert_not_contains "ai:retry は付けない" "$(labels_of 7)" "ai:retry"
assert_contains "残りのコメント" "$(comments_of 7)" "- 並べ替えができる"
assert_not_contains "やり直しの記録は付かない" "$(comments_of 7)" "auto-retry"

echo "== ⑥ 戻したあとの実装AIが止まったときは、いつもどおり ai:retry"
state_py "s['labels']['7']=['ai:implement']; s['issue_updated']['7']='$(ago 120)'"
run_script watchdog.sh > /dev/null
assert_contains "印のあるPRは何もせず、やり直し待ち" "$(labels_of 7)" "ai:retry"

finish
