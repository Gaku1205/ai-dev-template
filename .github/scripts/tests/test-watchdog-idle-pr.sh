#!/usr/bin/env bash
# 見張り役（3.4）：CIは終わっているのに、誰も先へ進めていないPRを動かす。
# 進行役（pipeline.yml）の処理が途中で落ちた・時間切れで呼ばれなかったとき、ラベルも記録も無いまま止まるのを防ぐ
source "$(dirname "$0")/lib.sh"
setup_mock

pr_of() { # 番号 ブランチ 更新からの分 [足す項目（JSON の中身）]
  echo '{"number":'"$1"',"state":"open","mergeable_state":"clean","body":"Closes #5","head":{"sha":"abc123","ref":"'"$2"'","repo":{"full_name":"o/r"}},"labels":[],"updated_at":"'"$(ago "$3")"'"'"${4:+,$4}"'}'
}
ci() { echo '{"id":11,"name":"CI","status":"completed","conclusion":"'"$1"'","created_at":"2026-01-01T00:00:00Z"}'; }
reruns() { python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print(len(s.get('reruns_all',[])))"; }
fix_request() { # 何分前に出したか
  echo '{"id":900,"issue":"58","user":{"login":"pipeline[bot]"},"created_at":"'"$(ago "$1")"'","updated_at":"'"$(ago "$1")"'","body":"@claude CIが失敗しました。\n\n<!-- auto-fix -->\n<!-- auto-fix-sha: abc123 -->"}'
}

echo "== CIが通ったのに、レビューが始まっていない（進行役が落ちた）：続きを動かす（レビューへ）"
init_state '{"labels":{"58":[]},"pulls":['"$(pr_of 58 claude/issue-5-x 60)"'],"runs":['"$(ci success)"']}'
out=$(run_script watchdog.sh)
assert_contains "レビューに回す" "$(labels_of 58)" "ai:review"
assert_contains "動かした印を残す" "$(comments_of 58)" "auto-nudge: abc123"
assert_contains "ログに出す" "$out" "誰も進めていないので、続きを動かします"

echo "== CIが落ちたのに、直す依頼が出ていない：AIに直させる"
init_state '{"labels":{"58":[]},"pulls":['"$(pr_of 58 claude/issue-5-x 60)"'],"runs":['"$(ci failure)"'],"jobs":[{"steps":[{"name":"確認","conclusion":"failure"}]}]}'
run_script watchdog.sh > /dev/null
assert_contains "直す依頼が出る" "$(comments_of 58)" "@claude CIが失敗しました"
assert_contains "直す回数に数える" "$(comments_of 58)" "<!-- auto-fix -->"

echo "== CIが時間切れ・取り消しで終わった（進行役は呼ばれない）：CIを1回だけ動かし直す"
init_state '{"labels":{"58":[]},"pulls":['"$(pr_of 58 claude/issue-5-x 60)"'],"runs":['"$(ci cancelled)"']}'
run_script watchdog.sh > /dev/null
assert_eq "CIを動かし直す" "1" "$(reruns)"
assert_contains "理由を書く" "$(comments_of 58)" "CIを動かし直します"
assert_not_contains "人間には回さない" "$(labels_of 58)" "ai:stuck"

echo "== 動かし直せなければ、人間に回す"
init_state '{"labels":{"58":[]},"rerun_fail":true,"pulls":['"$(pr_of 58 claude/issue-5-x 60)"'],"runs":['"$(ci timed_out)"']}'
run_script watchdog.sh > /dev/null
assert_contains "人間に回す" "$(labels_of 58)" "ai:stuck"

echo "== 1回動かしても進まない（同じ先頭コミットのまま、また止まっている）：人間に回す（何度も動かさない）"
init_state '{"labels":{"58":["ai:review"]},"pulls":['"$(pr_of 58 claude/issue-5-x 60)"'],"runs":['"$(ci success)"'],
  "comments":[{"id":901,"issue":"58","user":{"login":"pipeline[bot]"},"created_at":"'"$(ago 120)"'","updated_at":"'"$(ago 120)"'","body":"🔧 続きを動かします\n\n<!-- auto-nudge: abc123 -->"},
              {"id":902,"issue":"58","user":{"login":"github-actions[bot]"},"created_at":"'"$(ago 100)"'","updated_at":"'"$(ago 100)"'","body":"## Code review\n\nNo issues found."}]}'
run_script watchdog.sh > /dev/null
assert_contains "人間に回す" "$(labels_of 58)" "ai:stuck"
assert_contains "理由を書く" "$(comments_of 58)" "見張り役が1回続きを動かしても進みませんでした"
assert_eq "印は増えない" "1" "$(comments_of 58 | grep -c 'auto-nudge: abc123')"

echo "== 直す依頼に応答が無い（修正AIが時間切れ・起動しなかった）：同じ依頼をやり直し待ちにする"
init_state '{"labels":{"58":[]},"pulls":['"$(pr_of 58 claude/issue-5-x 60)"'],"runs":['"$(ci failure)"'],"comments":['"$(fix_request 60)"']}'
run_script watchdog.sh > /dev/null
assert_contains "やり直し待ちになる" "$(labels_of 58)" "ai:retry"
assert_contains "修正のやり直しとして記録" "$(comments_of 58)" "kind=mention"
assert_eq "新しい直す依頼は、まだ出さない（直す回数を使わない）" "1" "$(comments_of 58 | grep -c '<!-- auto-fix -->')"
age_retry_comments 40
state_py "s['pulls'][0]['updated_at']='$(ago 1)'"
run_script watchdog.sh > /dev/null
assert_contains "待ちが明けたら、同じ依頼をもう一度出す" "$(comments_of 58)" "<!-- auto-fix-retry -->"

echo "== 待つ理由がある・まだ早い・CIが動いている：何もしない"
for case in \
  '{"labels":{"58":["ai:stuck"]},"pulls":['"$(pr_of 58 claude/issue-5-x 60)"'],"runs":['"$(ci success)"']}' \
  '{"labels":{"58":["visual:update"]},"wf_runs":{"visual-update.yml":[{"status":"in_progress","head_branch":"claude/issue-5-x"}]},"pulls":['"$(pr_of 58 claude/issue-5-x 60)"'],"runs":['"$(ci success)"']}' \
  '{"labels":{"58":[]},"pulls":['"$(pr_of 58 claude/issue-5-x 20)"'],"runs":['"$(ci success)"']}' \
  '{"labels":{"58":[]},"pulls":['"$(pr_of 58 claude/issue-5-x 60)"'],"runs":[{"id":11,"name":"CI","status":"in_progress","conclusion":null,"created_at":"2026-01-01T00:00:00Z"}]}' \
  '{"labels":{"58":[]},"pulls":['"$(pr_of 58 claude/issue-5-x 60 '"draft":true')"'],"runs":['"$(ci success)"']}' \
  '{"labels":{"58":[]},"pulls":['"$(pr_of 58 pipeline-sync/abc 60)"'],"runs":['"$(ci success)"']}' \
  '{"labels":{"58":[]},"pulls":['"$(pr_of 58 feature-x 60 | sed 's#"full_name":"o/r"#"full_name":"stranger/r"#')"'],"runs":['"$(ci cancelled)"']}'; do
  init_state "$case"
  before=$(labels_of 58)
  run_script watchdog.sh > /dev/null
  assert_eq "ラベルは変わらない（$(printf '%s' "$case" | cut -c1-60)…）" "$before" "$(labels_of 58)"
  assert_not_contains "印も付かない" "$(comments_of 58)" "auto-nudge"
done

new_commits() { python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print(len(s.get('ref_updates',[])))"; }

echo "== 先頭コミットにCIの実行が0件（イベントの取りこぼし）：空のコミットでCIを動かし、印を残す"
init_state '{"labels":{"58":[]},"pulls":['"$(pr_of 58 claude/issue-5-x 60)"'],"runs":[]}'
out=$(run_script watchdog.sh)
assert_eq "ブランチを更新（空のコミット）" "1" "$(new_commits)"
assert_contains "印を残す" "$(comments_of 58)" "auto-nudge: newcommit"
assert_not_contains "人間には回さない" "$(labels_of 58)" "ai:stuck"
assert_contains "ログに出す" "$out" "CIの実行が0件"

echo "== 空のコミットを足したのに、まだ0件：人間に回す（2回目は動かさない）"
init_state '{"labels":{"58":[]},"pulls":['"$(pr_of 58 claude/issue-5-x 60)"'],"runs":[],
  "comments":[{"id":950,"issue":"58","user":{"login":"pipeline[bot]"},"created_at":"'"$(ago 60)"'","updated_at":"'"$(ago 60)"'","body":"🔧 動かします\n\n<!-- auto-nudge: abc123 -->"}]}'
run_script watchdog.sh > /dev/null
assert_contains "人間に回す" "$(labels_of 58)" "ai:stuck"
assert_eq "もう空のコミットは足さない" "0" "$(new_commits)"

echo "== 0件でも、早い・コンフリクト中・fork・下書き・配布・ai:retry・visual:update：動かさない"
for case in \
  '{"labels":{"58":[]},"pulls":['"$(pr_of 58 claude/issue-5-x 20)"'],"runs":[]}' \
  '{"labels":{"58":[]},"pulls":['"$(pr_of 58 claude/issue-5-x 60 | sed 's/"mergeable_state":"clean"/"mergeable_state":"dirty"/')"'],"runs":[]}' \
  '{"labels":{"58":[]},"pulls":['"$(pr_of 58 claude/issue-5-x 60 '"draft":true')"'],"runs":[]}' \
  '{"labels":{"58":[]},"pulls":['"$(pr_of 58 pipeline-sync/abc 60)"'],"runs":[]}' \
  '{"labels":{"58":[]},"pulls":['"$(pr_of 58 feature-x 60 | sed 's#"full_name":"o/r"#"full_name":"stranger/r"#')"'],"runs":[]}' \
  '{"labels":{"58":["ai:retry"]},"pulls":['"$(pr_of 58 claude/issue-5-x 60)"'],"runs":[]}' \
  '{"labels":{"58":["visual:update"]},"pulls":['"$(pr_of 58 claude/issue-5-x 60)"'],"runs":[]}'; do
  init_state "$case"
  run_script watchdog.sh > /dev/null
  assert_eq "空のコミットを足さない（$(printf '%s' "$case" | cut -c1-60)…）" "0" "$(new_commits)"
  assert_not_contains "CIの印は付かない" "$(comments_of 58)" "CIの実行が1件も無い"
done

echo "== マージ待ち（ai:hold で、レビューまで済んでいる）は、人間が押すのを待つ。レビューがまだなら動かす"
init_state '{"labels":{"58":["ai:hold","ai:review"]},"pulls":['"$(pr_of 58 claude/issue-5-x 600)"'],"runs":['"$(ci success)"'],
  "comments":[{"id":902,"issue":"58","user":{"login":"github-actions[bot]"},"created_at":"'"$(ago 600)"'","updated_at":"'"$(ago 600)"'","body":"## Code review\n\nNo issues found."}]}'
run_script watchdog.sh > /dev/null
assert_not_contains "マージ待ちは動かさない" "$(comments_of 58)" "auto-nudge"
assert_not_contains "人間に回す印も付けない" "$(labels_of 58)" "ai:stuck"
init_state '{"labels":{"58":["ai:hold"]},"pulls":['"$(pr_of 58 claude/issue-5-x 600)"'],"runs":['"$(ci success)"']}'
run_script watchdog.sh > /dev/null
assert_contains "レビューがまだなら、レビューへ" "$(labels_of 58)" "ai:review"

echo "== マージ待ち（ai:hold）のPRが main とコンフリクトした：AIに解消を頼む（同じ先頭コミットには1回だけ）"
init_state '{"labels":{"58":["ai:hold","ai:review"]},"pulls":['"$(pr_of 58 claude/issue-5-x 600 | sed 's/"mergeable_state":"clean"/"mergeable_state":"dirty"/')"'],"runs":['"$(ci success)"'],
  "comments":[{"id":902,"issue":"58","user":{"login":"github-actions[bot]"},"created_at":"'"$(ago 600)"'","updated_at":"'"$(ago 600)"'","body":"## Code review\n\nNo issues found."}]}'
run_script watchdog.sh > /dev/null
assert_contains "解消の依頼が付く" "$(comments_of 58)" "コンフリクトしています"
assert_contains "直す依頼の印" "$(comments_of 58)" "auto-fix-sha: abc123"
assert_not_contains "人間には回さない" "$(labels_of 58)" "ai:stuck"
run_script watchdog.sh > /dev/null
assert_eq "二度目は頼まない" "1" "$(comments_of 58 | grep -c 'auto-fix-sha: abc123')"


echo "== レビューAIが動けないPR（レビューのワークフローを変えるPR）で、人間のマージ待ちにしてある：動かさない"
init_state '{"labels":{"58":["ai:hold","ai:review"]},"pulls":['"$(pr_of 58 fix/review 600)"'],"runs":['"$(ci success)"'],
  "comments":[{"id":903,"issue":"58","user":{"login":"pipeline[bot]"},"created_at":"'"$(ago 600)"'","updated_at":"'"$(ago 600)"'","body":"ℹ️ レビューAIは動けません\n\n<!-- review-unavailable: abc123 -->"}]}'
run_script watchdog.sh > /dev/null
assert_not_contains "動かさない" "$(comments_of 58)" "auto-nudge"
assert_eq "ラベルは変わらない（レビューのやり直しにも回さない）" "ai:hold,ai:review" "$(labels_of 58)"
state_py "s['pulls'][0]['head']['sha']='def456'"
run_script watchdog.sh > /dev/null
assert_contains "新しいコミットが入っていれば、印は効かない（レビューの結果を待つ・やり直す）" "$(labels_of 58)" "ai:retry"

finish
