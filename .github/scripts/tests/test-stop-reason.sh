#!/usr/bin/env bash
# 上限で止まったときの「最後の理由」：AIへの指示の文ではなく、人向けの短い1行の文を入れる
source "$(dirname "$0")/lib.sh"
setup_mock

# 直す依頼を上限（3回）まで出した状態にする
full_state() { # PR番号
  init_state '{"labels":{"'"$1"'":[]},"pulls":[{"number":'"$1"',"state":"open","body":"","head":{"sha":"abc123","ref":"x"},"labels":[]}]}'
  for i in 1 2 3; do
    state_py "
s['comments'].append({'id': 900+$i, 'body': '@claude 直して\n<!-- auto-fix -->', 'user': {'login': 'github-actions[bot]'}, 'created_at': '2026-01-01T00:00:0${i}Z', 'updated_at': '2026-01-01T00:00:0${i}Z', 'issue': '$1'})"
  done
}

AI_MSG="レビューで指摘がありました。このPRの「Code review」のコメントを読んで直してください。"

echo "== 上限で止まる：人向けの1文が入り、AIへの指示の文は入らない"
full_state 70
run_lib "request_fix_or_stop 70 abc123 '$AI_MSG' 'レビューの指摘が直りませんでした（指摘：src/components/Desk.tsx:313）'" > /dev/null
c=$(comments_of 70)
assert_contains "止まったコメントが出る" "$c" "自動で進めるのを止めました"
assert_contains "人向けの1文が入る" "$c" "最後の理由：レビューの指摘が直りませんでした（指摘：src/components/Desk.tsx:313）"
assert_not_contains "AIへの指示の文は入らない" "$c" "読んで直してください"
assert_contains "人がすることの文は今のまま" "$c" "AIに続きを任せるなら \`ai:stuck\` を外してください"
assert_contains "ai:stuck が付く" "$(labels_of 70)" "ai:stuck"

echo "== 4番目に改行があっても、最後の理由は1行"
full_state 71
run_lib "request_fix_or_stop 71 abc123 '$AI_MSG' \$'CIが失敗したままです\n（失敗したチェック：test）\r\n'" > /dev/null
line=$(comments_of 71 | grep '最後の理由')
assert_contains "改行が空白になって1行に入る" "$line" "最後の理由：CIが失敗したままです （失敗したチェック：test））"

echo "== 4番目が無い・空：固定の短い文（AIへの指示の文は入らない）"
full_state 72
run_lib "request_fix_or_stop 72 abc123 '$AI_MSG'" > /dev/null
c=$(comments_of 72)
assert_contains "固定の文" "$c" "最後の理由：AIが直せませんでした）"
assert_not_contains "AIへの指示の文は入らない" "$c" "読んで直してください"
full_state 73
run_lib "request_fix_or_stop 73 abc123 '$AI_MSG' ''" > /dev/null
assert_contains "空でも固定の文" "$(comments_of 73)" "最後の理由：AIが直せませんでした）"

echo "== 上限の前は、AIへの依頼文がそのまま出る（変えていない）"
init_state '{"labels":{"74":[]},"pulls":[{"number":74,"state":"open","body":"","head":{"sha":"abc123","ref":"x"},"labels":[]}]}'
run_lib "request_fix_or_stop 74 abc123 '$AI_MSG' '人向けの文'" > /dev/null
c=$(comments_of 74)
assert_contains "依頼文は今のまま" "$c" "@claude $AI_MSG"
assert_not_contains "人向けの文は依頼に入れない" "$c" "人向けの文"

finish
