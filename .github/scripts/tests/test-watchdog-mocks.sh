#!/usr/bin/env bash
# 見張り役（2.5）：画面案（ai:mocks）のまま、後片付け（画面案のコメント・次への進め方）が動かず止まった Issue を拾う。
# 画面案のジョブが時間切れ・取り消しになると、ai:mocks が残ったまま、失敗の知らせも ai:retry も付かない（誰も拾わなかった）
source "$(dirname "$0")/lib.sh"
setup_mock
# resume.sh も使うので、リポジトリのルートで動かす
cd "$SCRIPTS_DIR/../.." || exit 1

mocks_issue() { # 更新からの分 [足す項目（JSON の中身）]
  init_state '{"labels":{"7":["ai:mocks"]},"issue_updated":{"7":"'"$(ago "$1")"'"}'"${2:+,$2}"'}'
}
touch_issue() { state_py "s['issue_updated']['7'] = '$(ago "$1")'"; }

echo "== ai:mocks のまま120分動きが無く、画面案のジョブも動いていない：やり直し待ちにする"
mocks_issue 130
out=$(run_script watchdog.sh)
assert_eq "ai:retry が付く（ai:mocks は残す）" "ai:mocks,ai:retry" "$(labels_of 7)"
assert_contains "記録の種類は mocks" "$(comments_of 7)" "count=0 kind=mocks"
assert_contains "理由を書く" "$(comments_of 7)" "画面案（ai:mocks）のまま130分のあいだ動きがありません"
assert_not_contains "人間には回さない" "$(labels_of 7)" "ai:stuck"

echo "== 待ち時間が過ぎたら、ai:mocks を付け直して画面案をやり直す（印を残す）"
out=$(run_script watchdog.sh)
assert_contains "待ち時間のうちは「まだ早い」" "$out" "まだ早い"
assert_not_contains "まだ印は無い" "$(comments_of 7)" "auto-mocks-retry"
age_retry_comments 40
out=$(run_script watchdog.sh)
assert_contains "やり直す" "$out" "mocks をやり直します（1/3回目）"
assert_eq "ai:retry が外れ、ai:mocks が付いている" "ai:mocks" "$(labels_of 7)"
assert_contains "やり直した印" "$(comments_of 7)" "<!-- auto-mocks-retry -->"
assert_eq "やり直した同じ実行では、もう一度止まりとみなさない" "1" "$(comments_of 7 | grep -c 'auto-mocks-retry -->')"

echo "== やり直しても、また120分止まった：2回目は人間に回す（もうやり直さない）"
touch_issue 125
state_py "
for c in s['comments']: c['created_at'] = c['updated_at'] = '$(ago 126)'"
out=$(run_script watchdog.sh)
assert_contains "人間に回す" "$(labels_of 7)" "ai:stuck"
assert_not_contains "やり直し待ちにしない" "$(labels_of 7)" "ai:retry"
assert_contains "理由と、次にすることを書く" "$(comments_of 7)" "やり直しても125分のあいだ進みませんでした"
assert_contains "案なしで進める道も書く" "$(comments_of 7)" "案なしで進めるなら"
assert_eq "印は増えない" "1" "$(comments_of 7 | grep -c 'auto-mocks-retry -->')"
assert_eq "通知する" "1" "$(notify_count)"
out=$(run_script watchdog.sh)
assert_eq "人間待ちの間は、何もしない" "1" "$(comments_of 7 | grep -c '自動で進めるのを止めました')"

echo "== 人間が ai:stuck を外す：画面案をもう一度作る（そのあと止まれば、また1回だけやり直せる）"
state_py "s['labels']['7'].remove('ai:stuck')"
out=$(NUMBER=7 IS_PR=false run_script resume.sh)
assert_contains "画面案をやり直す" "$out" "画面案をやり直しました"
assert_eq "ai:mocks が付いている" "ai:mocks" "$(labels_of 7)"
assert_contains "再開の印" "$(comments_of 7)" "<!-- auto-resume -->"
touch_issue 130
state_py "
for c in s['comments']:
    c['created_at'] = c['updated_at'] = '$(ago 131)' if 'auto-resume' in c['body'] else '$(ago 300)'"
out=$(run_script watchdog.sh)
assert_eq "再開のあとは、もう一度やり直し待ちにできる" "ai:mocks,ai:retry" "$(labels_of 7)"

echo "== 人間が ai:stuck を外したとき、画面案のジョブが動いていれば、付け直さない（同じ画面案を2つ作らない）"
mocks_issue 130 '"wf_runs":{"claude-mocks.yml":[{"id":1,"status":"in_progress"}]}'
out=$(NUMBER=7 IS_PR=false run_script resume.sh)
assert_contains "何もしない" "$out" "画面案の実行が動いているので、何もしません"
assert_not_contains "再開の印を書かない" "$(comments_of 7)" "auto-resume"

echo "== 画面案のジョブが動いている・待っている間は、止まったとみなさない"
mocks_issue 130 '"wf_runs":{"claude-mocks.yml":[{"id":1,"status":"in_progress"}]}'
out=$(run_script watchdog.sh)
assert_eq "何もしない" "ai:mocks" "$(labels_of 7)"
assert_contains "ログに出す" "$out" "画面案の実行が動いている"
mocks_issue 130 '"wf_runs":{"claude-mocks.yml":[{"id":1,"status":"queued"}]}'
run_script watchdog.sh > /dev/null
assert_eq "待っている実行（queued）でも何もしない" "ai:mocks" "$(labels_of 7)"
mocks_issue 130 '"wf_runs":{"claude-mocks.yml":[{"id":1,"status":"completed","conclusion":"cancelled"}]}'
run_script watchdog.sh > /dev/null
assert_eq "終わった実行は数えない（やり直し待ちにする）" "ai:mocks,ai:retry" "$(labels_of 7)"

echo "== まだ120分たっていない（画面案のジョブは最大100分動く）：何もしない"
mocks_issue 110
run_script watchdog.sh > /dev/null
assert_eq "何もしない" "ai:mocks" "$(labels_of 7)"
assert_eq "コメントも無い" "" "$(comments_of 7)"

echo "== 人間の確認待ち（ai:stuck）・まだ動かさない物（ai:skip）は触らない"
for l in ai:stuck ai:skip; do
  init_state '{"labels":{"7":["ai:mocks","'"$l"'"]},"issue_updated":{"7":"'"$(ago 300)"'"}}'
  run_script watchdog.sh > /dev/null
  assert_eq "$l：何もしない" "ai:mocks,$l" "$(labels_of 7)"
done

echo "== 前の回の画面案（出し直しの前）でやり直していても、新しい回では、もう一度やり直せる"
mocks_issue 130 '"comments":[
  {"id":1,"issue":"7","user":{"login":"pipeline[bot]"},"created_at":"'"$(ago 900)"'","updated_at":"'"$(ago 900)"'","body":"🔁 画面案をやり直します\n\n<!-- auto-mocks-retry -->"},
  {"id":2,"issue":"7","user":{"login":"pipeline[bot]"},"created_at":"'"$(ago 800)"'","updated_at":"'"$(ago 800)"'","body":"<!-- ai-question -->\n<!-- ai-mocks: issue-7/r1 -->\n## 🖼 作る前に、画面を2案作りました"}]'
run_script watchdog.sh > /dev/null
assert_eq "やり直し待ちにする（人間に回さない）" "ai:mocks,ai:retry" "$(labels_of 7)"

echo "== やり直し待ちの間に、画面案が先へ進んでいた（ai:mocks が外れた）：やり直さず、印だけ外す"
mocks_issue 130
run_script watchdog.sh > /dev/null
state_py "s['labels']['7'] = ['ai:question', 'ai:retry']"
age_retry_comments 40
out=$(run_script watchdog.sh)
assert_eq "ai:retry だけ外れる" "ai:question" "$(labels_of 7)"
assert_contains "ログに出す" "$out" "画面案はもう先へ進んでいる"
assert_not_contains "やり直した印は書かない" "$(comments_of 7)" "auto-mocks-retry"

echo "== やり直しの上限に届いていても、Issue として人間に回す（PRの扱いにしない）"
init_state '{"labels":{"7":["ai:mocks"]},"comments":[{"id":1,"issue":"7","user":{"login":"pipeline[bot]"},"created_at":"'"$(ago 500)"'","updated_at":"'"$(ago 500)"'","body":"🔁\n理由：x\n\n<!-- auto-retry -->\n<!-- count=3 kind=plan -->"}]}'
out=$(run_lib 'mark_for_retry 7 mocks "画面案のまま止まりました"')
assert_contains "人間に回す" "$(labels_of 7)" "ai:stuck"
assert_not_contains "PRとして読もうとしない" "$out" "UNHANDLED"

finish
