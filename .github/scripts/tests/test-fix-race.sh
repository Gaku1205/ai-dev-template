#!/usr/bin/env bash
# 修正AIと、基準の画像の撮り直し（visual:update）・別の修正AIが、同じブランチを同時に動かさない。
# 修正AIが「PRが更新されたので動かない」と返した依頼は、直す回数に数えず、最新のコミットで出し直す
# agent-desk PR #478：レビューの指摘の依頼（2/3）と、撮り直しの失敗の依頼（3/3）が同じコミットに出て、
# 後の方が「PR #478 was updated after the trigger」で何もせずに終わり、直す回数の上限で止まった
source "$(dirname "$0")/lib.sh"
setup_mock

# 依頼・返事・レビューのコメント（時刻は T<分>）
t() { printf '2026-01-02T00:%02d:00Z' "$1"; }
req() { # id 分 先頭コミット [印（既定 auto-fix）] [文]
  printf '{"id":%s,"issue":"58","user":{"login":"gaku-ai-pipeline[bot]"},"body":"@claude %s\\n\\n直したら、pushしてください。（自動の依頼）\\n\\n<!-- %s -->\\n<!-- auto-fix-sha: %s -->\\n<!-- auto-fix-body: 000000000000 -->","created_at":"%s","updated_at":"%s"}' \
    "$1" "${5:-レビューで指摘がありました。}" "${4:-auto-fix}" "$3" "$(t "$2")" "$(t "$2")"
}
finished() { printf '{"id":%s,"issue":"58","user":{"login":"claude[bot]"},"body":"**Claude finished** 直しました","created_at":"%s","updated_at":"%s"}' "$1" "$(t "$2")" "$(t "$2")"; }
# 修正AIの「動かなかった」の返事（かっこの中の後ろの時刻が、依頼のコメントの時刻）
stale() { # id 分 依頼の分
  printf '{"id":%s,"issue":"58","user":{"login":"claude[bot]"},"body":"PR #58 was updated after the trigger (%s >= %s). Mention Claude again to run on the latest version.","created_at":"%s","updated_at":"%s"}' \
    "$1" "$(t "$2")" "$(t "$3")" "$(t "$2")" "$(t "$2")"
}
review_ng() { printf '{"id":%s,"issue":"58","user":{"login":"claude[bot]"},"body":"## Code review\\n\\n1 issue found.","created_at":"%s","updated_at":"%s"}' "$1" "$(t "$2")" "$(t "$2")"; }
review_ok() { printf '{"id":%s,"issue":"58","user":{"login":"claude[bot]"},"body":"## Code review\\n\\nNo issues found.","created_at":"%s","updated_at":"%s"}' "$1" "$(t "$2")" "$(t "$2")"; }
resume() { printf '{"id":%s,"issue":"58","user":{"login":"gaku-ai-pipeline[bot]"},"body":"再開します\\n<!-- auto-resume -->","created_at":"%s","updated_at":"%s"}' "$1" "$(t "$2")" "$(t "$2")"; }

state() { # コメント（JSONの並び） [先頭コミット] [ラベル（JSON）] [落ちたステップ名]
  python3 - "$1" "${2:-abc}" "${3:-[]}" "${4:-見た目のテスト}" <<'PY'
import json, os, sys
pr = {'number': 58, 'body': 'Closes #1 見た目を変えたので visual:update ラベルで基準の画像を撮り直してください', 'state': 'open',
      'head': {'sha': sys.argv[2], 'ref': 'claude/issue-1-x', 'repo': {'full_name': 'o/r'}}, 'updated_at': '2026-01-01T00:00:00Z', 'mergeable_state': 'clean', 'user': {'login': 'claude[bot]'}}
steps = [{'name': '型チェック', 'conclusion': 'success'}, {'name': sys.argv[4], 'conclusion': 'failure'}]
s = {'next_id': 100, 'comments': json.loads(sys.argv[1]), 'labels': {'58': json.loads(sys.argv[3])}, 'issue_updated': {}, 'pulls': [pr], 'jobs': [{'steps': steps}],
     'checks': [], 'runs': [], 'branches': [], 'authors': {}, 'files': ['src/app/page.tsx']}
json.dump(s, open(os.environ['MOCK_STATE'], 'w'))
PY
}
ci_failed() { CONCLUSION=failure HEAD_SHA="${1:-abc}" HEAD_BRANCH=claude/issue-1-x RUN_ID=9 READ_TOKEN=x run_script after-ci.sh; }
after_review() { CONCLUSION=success HEAD_SHA="${1:-abc}" HEAD_BRANCH=claude/issue-1-x READ_TOKEN=x run_script after-review.sh; }
# 修正AIのあとの処理。きっかけの依頼は、いちばん新しい依頼（その直後に始まった対応）
after_mention() { RUN_STARTED="$1" CONCLUSION=success PR_NUMBER=58 run_script after-mention.sh; }
fix_count() { run_lib 'count_auto_fix 58'; }
requests() { comments_of 58 | grep -c '^<!-- auto-fix -->$' || true; }

echo "== 動かなかった依頼（PRが更新された）は、直す回数に数えない"
state "[$(req 1 1 aaa),$(finished 2 2),$(req 3 3 abc),$(finished 4 4),$(req 5 5 abc),$(stale 6 8 5)]" def
assert_eq "3回頼んで、動いたのは2回" "2" "$(fix_count)"
state "[$(req 1 1 aaa),$(req 3 3 abc),$(req 5 5 abc)]" def
assert_eq "返事が無ければ、今までどおり3回" "3" "$(fix_count)"
# 返事の時刻の書き方が変わって、依頼の時刻で見つけられないとき：その返事の直前の依頼を、動かなかった物とする
state "[$(req 1 1 aaa),$(req 3 3 abc),{\"id\":6,\"issue\":\"58\",\"user\":{\"login\":\"claude[bot]\"},\"body\":\"PR #58 was updated after the trigger. Mention Claude again to run on the latest version.\",\"created_at\":\"$(t 8)\",\"updated_at\":\"$(t 8)\"}]" def
assert_eq "時刻が読めなくても、直前の依頼を数えない" "1" "$(fix_count)"
# 他人が同じ文を書いても、数え方は変わらない（修正AIの返事だけを見る）
state "[$(req 1 1 aaa),$(req 3 3 abc),{\"id\":6,\"issue\":\"58\",\"user\":{\"login\":\"someone\"},\"body\":\"PR #58 was updated after the trigger ($(t 8) >= $(t 3)).\",\"created_at\":\"$(t 8)\",\"updated_at\":\"$(t 8)\"}]" def
assert_eq "修正AI以外が書いた文は見ない" "2" "$(fix_count)"

echo "== 修正AIが「PRが更新されたので動かない」で終わった → 回数に数えず、最新のコミットで出し直す（agent-desk PR #478 の3回目）"
# 1回目・2回目は動いて push 済み（先頭は def）。3回目（強いモデル）は古いコミット abc への依頼で、動かなかった
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
third=$(req 5 5 abc auto-fix '見た目のテストの基準の画像を撮り直そうとしたら、撮り直しでは直らない失敗がありました。' | sed "s/$(t 5)/$now/g; s/000000000000 -->/000000000000 -->\\\\n<!-- auto-fix-model: opus -->/")
state "[$(req 1 1 aaa),$(finished 2 2),$(req 3 3 abc),$(finished 4 4),$third,$(stale 6 8 5 | sed "s/>= $(t 5)/>= $now/; s/$(t 8)/$now/g")]" def
out=$(after_mention "$now")
assert_contains "出し直したと出す" "$out" "直す回数に数えず、最新のコミットで依頼を出し直しました"
assert_contains "最新のコミットへの依頼" "$(comments_of 58)" "auto-fix-sha: def"
assert_contains "同じ文で頼む" "$(comments_of 58 | grep 'auto-fix-sha: def' -B8)" "撮り直しでは直らない失敗がありました"
assert_contains "動かなかったと断る" "$(comments_of 58)" "直す回数には数えず、最新のコミットで出し直しています"
assert_contains "同じ回（3/3）のまま" "$(comments_of 58 | tail -n 8)" "（自動の依頼 3/3）"
assert_contains "強いモデルのまま" "$(comments_of 58 | tail -n 4)" "auto-fix-model: opus"
assert_not_contains "人間に回さない" "$(labels_of 58)" "ai:stuck"
assert_not_contains "「直してpushした」と読み違えて、レビューに回さない" "$(labels_of 58)" "ai:review"
assert_eq "出し直した依頼を入れて3回（上限の中）" "3" "$(fix_count)"

echo "== 出し直した依頼も動かなかった → もう一度出し直す（断り書きは重ねない）"
second=$(comments_of 58 | grep -c '直す回数には数えず' || true)
assert_eq "断り書きは1つ" "1" "$second"
later=$(date -u -d '1 minute' +%Y-%m-%dT%H:%M:%SZ)
state_py "
last = s['comments'][-1]
last['created_at'] = last['updated_at'] = '$later'
s['comments'].append({'id': 200, 'issue': '58', 'user': {'login': 'claude[bot]'}, 'body': 'PR #58 was updated after the trigger ($later >= $later). Mention Claude again to run on the latest version.', 'created_at': '$later', 'updated_at': '$later'})
s['pulls'][0]['head']['sha'] = 'fed'"
out=$(after_mention "$later")
assert_contains "最新のコミットへ出し直す" "$(comments_of 58)" "auto-fix-sha: fed"
assert_eq "断り書きは依頼ごとに1つ" "1" "$(comments_of 58 | grep 'auto-fix-sha: fed' -B8 | grep -o '直す回数には数えず' | wc -l | tr -d ' ')"
assert_eq "回数は増えない" "3" "$(fix_count)"

echo "== 動かなかったが、いまの先頭コミットには別の依頼がもう出ている → 出し直さない（その修正AIに任せる）"
state "[$(req 1 1 aaa),$(finished 2 2),$(req 7 4 def),$(req 5 5 abc | sed "s/$(t 5)/$now/g"),$(stale 6 8 5 | sed "s/>= $(t 5)/>= $now/; s/$(t 8)/$now/g")]" def
out=$(after_mention "$now")
assert_contains "出し直さない" "$out" "いまの先頭コミットにはもう直すよう頼んであるので、出し直しません"
assert_eq "依頼は増えない" "3" "$(requests)"
assert_not_contains "人間に回さない" "$(labels_of 58)" "ai:stuck"

echo "== 動かないのが何回も続く → 人間に回す（何かがブランチを動かし続けている）"
state "[$(req 1 1 aaa),$(stale 2 2 1),$(req 3 3 bbb),$(stale 4 4 3),$(req 7 5 ccc),$(stale 8 6 5),$(req 5 7 abc | sed "s/$(t 7)/$now/g"),$(stale 6 8 7 | sed "s/>= $(t 7)/>= $now/; s/$(t 8)/$now/g")]" def
out=$(after_mention "$now")
assert_contains "ai:stuck" "$(labels_of 58)" "ai:stuck"
assert_contains "理由" "$(comments_of 58)" "依頼のあとにPRが更新された"
assert_eq "依頼は増えない" "4" "$(requests)"

echo "== やり直しの依頼（数えない依頼）が動かなかった → 同じ文のまま、最新のコミットで出し直す"
state "[$(req 1 1 abc),$(finished 2 2),$(req 5 5 abc auto-fix-retry | sed "s/$(t 5)/$now/g"),$(stale 6 8 5 | sed "s/>= $(t 5)/>= $now/; s/$(t 8)/$now/g")]" def
out=$(after_mention "$now")
assert_contains "出し直したと出す" "$out" "やり直しの依頼を最新のコミットで出し直しました"
assert_contains "やり直しの印のまま、最新のコミット" "$(comments_of 58 | tail -n 3)" "auto-fix-sha: def"
assert_contains "やり直しの印のまま" "$(comments_of 58 | tail -n 3)" "<!-- auto-fix-retry -->"
assert_eq "回数は増えない" "1" "$(fix_count)"

echo "== 修正AIが普通に終わって push した → 今までどおり（出し直さない）"
state "[$(req 5 5 abc | sed "s/$(t 5)/$now/g"),$(finished 6 6 | sed "s/$(t 6)/$now/g")]" def
out=$(after_mention "$now")
assert_eq "依頼は1つのまま" "1" "$(requests)"
assert_contains "直したコミットのレビューを始める" "$(labels_of 58)" "ai:review"

echo "== 同じコミットに、まだ終わっていない依頼がある → どこから頼んでも重ねて頼まず、回数にも数えない（撮り直しの失敗 visual-update.yml など）"
state "[$(req 1 1 aaa),$(finished 2 2),$(req 3 3 abc)]"
out=$(run_lib 'request_fix_or_stop 58 abc "撮り直しでは直らない失敗がありました。"')
assert_contains "重ねて頼まない" "$out" "重ねて頼みません"
assert_eq "依頼は2つのまま" "2" "$(requests)"
assert_eq "回数も2のまま" "2" "$(fix_count)"
# 上限に届いていても、動いている修正AIがあれば止めない（その結果を待つ）
state "[$(req 1 1 aaa),$(finished 2 2),$(req 3 3 bbb),$(finished 4 4),$(req 5 5 abc)]"
out=$(run_lib 'request_fix_or_stop 58 abc "CIが失敗しました。"')
assert_not_contains "動いている間は人間に回さない" "$(labels_of 58)" "ai:stuck"

echo "== 前の依頼が終わっていれば（Claude finished・動かなかった・人間が再開した）、同じコミットにもう一度頼める"
state "[$(req 3 3 abc),$(finished 4 4)]"
run_lib 'request_fix_or_stop 58 abc "CIが失敗しました。"' > /dev/null
assert_eq "終わった依頼のあとは頼める" "2" "$(requests)"
state "[$(req 3 3 abc),$(stale 4 4 3)]"
run_lib 'request_fix_or_stop 58 abc "CIが失敗しました。"' > /dev/null
assert_eq "動かなかった依頼のあとは頼める" "2" "$(requests)"
assert_contains "動かなかった分は数えないので 1/3" "$(comments_of 58 | tail -n 6)" "（自動の依頼 1/3）"
state "[$(req 3 3 abc),$(resume 4 4)]"
run_lib 'request_fix_or_stop 58 abc "CIが失敗しました。"' > /dev/null
assert_eq "人間が再開したあとは頼める" "2" "$(requests)"
state "[$(req 3 3 abc)]"
run_lib 'request_fix_or_stop 58 def "CIが失敗しました。"' > /dev/null
assert_eq "別のコミットには頼める" "2" "$(requests)"

echo "== 見た目のテストだけが落ちた・このコミットにもう直すよう頼んである → 撮り直しを始めない（修正AIの push のあとの CI で決める）"
state "[$(review_ng 2 2),$(req 3 3 abc)]"
out=$(ci_failed)
assert_contains "撮り直しを始めない" "$out" "基準の画像の撮り直しは始めません"
assert_not_contains "visual:update を付けない" "$(labels_of 58)" "visual:update"
assert_not_contains "撮り直しの回数に数えない" "$(comments_of 58)" "auto-visual-update"
assert_eq "直す依頼は1つのまま" "1" "$(requests)"

echo "== 見た目のテストだけが落ちた・レビューの指摘がもう出ている（直す依頼はまだ） → 撮り直しを始めず、先に直すよう頼む"
state "[$(review_ng 2 2)]"
out=$(ci_failed)
assert_contains "先に直すよう頼む" "$out" "基準の画像の撮り直しは始めず、先に直すよう依頼しました"
assert_not_contains "visual:update を付けない" "$(labels_of 58)" "visual:update"
assert_contains "直す依頼（レビューの指摘と見た目のテスト）" "$(comments_of 58)" "レビューで指摘があり、CIでは見た目のテストも落ちています"
assert_contains "このコミットへの依頼" "$(comments_of 58)" "auto-fix-sha: abc"
# そのあとに動く after-review.sh は、この依頼を見て、重ねて頼まない
out=$(after_review)
assert_contains "レビューの側は重ねて頼まない" "$out" "重ねて頼みません"
assert_eq "直す依頼は1つのまま" "1" "$(requests)"

echo "== 見た目のテストだけが落ちた・レビューは指摘なし／まだ無い → 今までどおり撮り直す"
state "[$(review_ok 2 2)]"
ci_failed > /dev/null
assert_contains "指摘なしなら撮り直す" "$(labels_of 58)" "visual:update"
state "[]"
ci_failed > /dev/null
assert_contains "レビューがまだなら撮り直す" "$(labels_of 58)" "visual:update"
# 前の依頼が終わっている（修正AIが push せずに終わった）なら、撮り直しを止めない
state "[$(req 3 3 abc),$(finished 4 4)]"
ci_failed > /dev/null
assert_contains "終わった依頼は、撮り直しを止めない" "$(labels_of 58)" "visual:update"

echo "== レビューに指摘・基準の画像の撮り直しが動いている → いまは直すよう頼まない（撮り直しのあとに、もう一度レビューされる）"
state "[$(review_ng 2 2)]" abc '["ai:review","visual:update"]'
out=$(after_review)
assert_contains "頼まない" "$out" "基準の画像の撮り直し（visual:update）が動いているので、いまは直すよう頼みません"
assert_eq "直す依頼は無い" "0" "$(requests)"
assert_not_contains "人間に回さない" "$(labels_of 58)" "ai:stuck"
# 撮り直しが終わって（ラベルが外れて）から、同じコミットをもう一度レビューして指摘があれば、頼む
state "[$(review_ng 2 2)]" abc '["ai:review"]'
after_review > /dev/null
assert_eq "撮り直しのあとは頼む" "1" "$(requests)"

finish
