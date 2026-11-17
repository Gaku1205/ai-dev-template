#!/usr/bin/env bash
# 修正AIが変更なしで終わった理由の分類（classify_no_change）と、それぞれの動き（after-mention.sh）：
#   人間のラベル作業が要る（撮り直し）→ visual:update ／ 指摘は誤り → レビューを付け直す ／
#   許可の拒否 → 1回だけやり直し、2回目は人間に回す ／ 分類できない → ai:stuck
source "$(dirname "$0")/lib.sh"
setup_mock
classify() { # 1: AIの返事 2: ほかの文 3: 拒否された操作
  local f="$MOCK_DIR/ai.txt"
  printf '%s' "$1" > "$f"
  bash -c "source '$SCRIPTS_DIR/pipeline-lib.sh'; classify_no_change \"\$1\" \"\$2\" \"\$3\" < '$f'" _ "${2:-}" "${3:-}" "${4:-}" 2>&1
}

echo "== classify_no_change：理由を1語に分ける"
assert_eq "visual:update の依頼" "visual" "$(classify '基準の画像が古いので `visual:update` で撮り直してください。')"
assert_eq "言い回しが違っても（基準の画像を更新）" "visual" "$(classify 'テストの基準画像を更新する必要があります。')"
assert_eq "レビューの指摘にだけある" "visual" "$(classify 'コードは直さなくてよいです。' '## Code review
repo-merge.png の基準の画像が古い')"
assert_eq "撮り直しは、許可の話より先に見る" "visual" "$(classify '確認コマンドが許可されていないため動かせませんでした。基準の画像の撮り直しが要ります。')"
assert_eq "AIが許可されていないと報告" "permission" "$(classify '`npm run lint` が許可されていないため動かせませんでした。')"
assert_eq "実行記録に拒否がある" "permission" "$(classify '直しました。' '' 'Bash(npm run lint:*)')"
assert_eq "指摘は誤り" "disagree" "$(classify 'この指摘は誤りだと判断したので、直さずに理由を書きます。')"
assert_eq "直す必要はない" "disagree" "$(classify '既に対処済みで、修正の必要はありません。')"
assert_eq "英語の言い方" "disagree" "$(classify 'This is a false positive.')"
# 前の対応で直し済みと返した（tochi-rirekisho PR #5：PRの説明を前の回に直したのに、もう一度依頼が来た）→ もう一度レビューへ
assert_eq "前回の対応で直し済み" "disagree" "$(classify '指摘はPRの説明の不足だけで、前回の対応で直し済みでした。今回はコードを変えていないので、pushするコミットはありません。')"
assert_eq "すでに書かれている" "disagree" "$(classify 'Closes や受け入れ条件は、すでに書かれています。')"
assert_eq "英語：already fixed" "disagree" "$(classify 'This was already fixed in the previous commit.')"
assert_eq "ワークフローの指摘が残っている（AIの返事が「直せない」だけでも）" "workflow" "$(classify '.github/workflows/ci.yml は直せませんでした。' '' '' 1)"
assert_eq "ワークフローの指摘が無ければ unknown のまま" "unknown" "$(classify '直せませんでした。' '' '' '')"
assert_eq "直せなかった、は誤りに数えない" "unknown" "$(classify 'テストが通らず、直せませんでした。')"
assert_eq "分類できない" "unknown" "$(classify 'うまくいきませんでした。')"
assert_eq "空" "unknown" "$(classify '')"

pr='{"number":58,"body":"Closes #57","state":"open","head":{"sha":"abc","ref":"claude/issue-57-x"},"updated_at":"2026-01-01T00:00:00Z"}'
setup_case() { # 1: AIの返事 2: CIの結果（success / failure） 3: 依頼の本文の追加
  init_state '{"labels":{"58":["ai:review"]},"pulls":['"$pr"'],"runs":[{"id":9,"name":"CI","conclusion":"'"${2:-success}"'","created_at":"2026-01-01T00:00:00Z"}],"jobs":[{"steps":[{"name":"テスト","conclusion":"'"${2:-success}"'"}]}]}'
  state_py "
s['comments'].append({'id':50,'issue':'58','body':'@claude レビューで指摘がありました。直してください。\\n<!-- auto-fix -->\\n<!-- auto-fix-sha: abc -->${3:-}','user':{'login':'x'},'created_at':'$(ago 2)','updated_at':'$(ago 2)'})
s['comments'].append({'id':51,'issue':'58','body':'''$1''','user':{'login':'claude[bot]'},'created_at':'$(ago 1)','updated_at':'$(ago 1)'})
s['next_id']=51"
}
run_after() { RUN_STARTED=$(ago 1) CONCLUSION=success run_script after-mention.sh; }

echo "== 指摘は誤りと返した（CIは通っている）：人間に回さず、レビューを付け直す"
setup_case '指摘は誤りです。この関数は既に null を扱っているので、直さずに理由をコメントしました。'
out=$(run_after)
assert_contains "分類を出す" "$out" "理由：disagree"
assert_not_contains "ai:stuck にしない" "$(labels_of 58)" "ai:stuck"
assert_contains "ai:review が付いている（付け直し）" "$(labels_of 58)" "ai:review"
assert_contains "レビューに回すと書く" "$(comments_of 58)" "もう一度レビューに回します"

echo "== 指摘は誤りと返したが、CIが落ちたまま：先へ進めないので人間に回す"
setup_case '指摘は誤りです。直す必要はありません。' failure
run_after > /dev/null
assert_contains "ai:stuck" "$(labels_of 58)" "ai:stuck"
assert_contains "CIが落ちたまま、と書く" "$(comments_of 58)" "CIが落ちたまま"

echo "== 許可の拒否（実行記録）：拒否されたツール名を書いて、1回だけ同じ依頼を出し直す"
setup_case '確認コマンドを動かせませんでした。'
printf '%s' '[{"type":"result","subtype":"success","result":"","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"npm run typecheck 2>&1"}},{"tool_name":"Write","tool_input":{"file_path":"x"}}]}]' > "$MOCK_DIR/exec.json"
out=$(EXECUTION_FILE="$MOCK_DIR/exec.json" run_after)
assert_contains "分類を出す" "$out" "理由：permission"
assert_not_contains "ai:stuck にしない" "$(labels_of 58)" "ai:stuck"
retry=$(comments_of 58)
assert_contains "拒否されたツール名を書く" "$retry" "拒否された操作：Bash(npm run typecheck 2>&1)、Write(x)"
assert_contains "@claude で依頼し直す" "$retry" "@claude レビューで指摘がありました"
assert_contains "やり直しの印" "$retry" "auto-perm-retry"
assert_contains "watchdog と同じやり直しの印" "$retry" "<!-- auto-fix-retry -->"
assert_contains "同じ先頭コミット" "$retry" "auto-fix-sha: abc"
assert_eq "直す回数には数えない（auto-fix の印は依頼の1つだけ）" "1" "$(python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print(sum('<!-- auto-fix -->' in c['body'] for c in s['comments']))")"

echo "== 許可の拒否が2回目：やり直さず、足りない許可を書いて人間に回す"
setup_case '`npm run lint` が許可されていないため動かせませんでした。'
state_py "
s['comments'].insert(0,{'id':40,'issue':'58','body':'@claude 前の依頼\\n<!-- auto-perm-retry -->\\n<!-- auto-fix-retry -->','user':{'login':'x'},'created_at':'$(ago 20)','updated_at':'$(ago 20)'})"
run_after > /dev/null
assert_contains "ai:stuck" "$(labels_of 58)" "ai:stuck"
assert_contains "足りない許可の候補を書く" "$(comments_of 58)" "足りない許可の候補：Bash(npm run lint)"
assert_contains "1回やり直したと書く" "$(comments_of 58)" "1回自動でやり直しても同じでした"
assert_eq "やり直しの依頼は増えない" "1" "$(comments_of 58 | grep -c 'auto-perm-retry')"

echo "== 人間が再開（ai:stuck を外した）したあとは、もう1回やり直せる"
setup_case '`npm run lint` が許可されていないため動かせませんでした。'
state_py "
s['comments'].insert(0,{'id':40,'issue':'58','body':'@claude 前の依頼\\n<!-- auto-perm-retry -->','user':{'login':'x'},'created_at':'$(ago 20)','updated_at':'$(ago 20)'})
s['comments'].insert(1,{'id':41,'issue':'58','body':'再開します\\n<!-- auto-resume -->','user':{'login':'x'},'created_at':'$(ago 10)','updated_at':'$(ago 10)'})"
run_after > /dev/null
assert_not_contains "ai:stuck にしない" "$(labels_of 58)" "ai:stuck"
assert_eq "やり直しの依頼が1つ増える" "2" "$(comments_of 58 | grep -c 'auto-perm-retry')"

echo "== 最後の1回（強いモデル）の依頼をやり直すときは、強いモデルの印も引き継ぐ"
setup_case '`npm run lint` が許可されていないため動かせませんでした。' success '\n<!-- auto-fix-model: opus -->'
run_after > /dev/null
assert_eq "強いモデルの印が2つ（元の依頼とやり直し）" "2" "$(comments_of 58 | grep -c 'auto-fix-model: opus')"

echo "== PRの説明に visual:update があっても、判定には使わない（指摘は誤りと返したとき）"
setup_case '指摘は誤りです。この関数は既に null を扱っているので、直さずに理由をコメントしました。'
state_py "s['pulls'][0]['body']='Closes #57\\n\\n見た目を変えた場合は visual:update で撮り直してください'"
out=$(run_after)
assert_contains "disagree になる" "$out" "理由：disagree"
assert_not_contains "visual:update は付けない" "$(labels_of 58)" "visual:update"
assert_contains "レビューに回す" "$(comments_of 58)" "もう一度レビューに回します"

echo "== PRの説明に visual:update があっても、許可の拒否は permission になる"
setup_case '確認コマンドを動かせませんでした。'
state_py "s['pulls'][0]['body']='Closes #57\\n\\nvisual:update'"
out=$(EXECUTION_FILE="$MOCK_DIR/exec.json" run_after)
assert_contains "permission になる" "$out" "理由：permission"
assert_not_contains "visual:update は付けない" "$(labels_of 58)" "visual:update"
assert_contains "やり直しの印" "$(comments_of 58)" "auto-perm-retry"

echo "== PRの説明に visual:update が無くても、AIの返事に撮り直しの依頼があれば visual"
setup_case '基準の画像が古いので撮り直してください。'
out=$(run_after)
assert_contains "visual になる" "$out" "理由：visual"
assert_contains "visual:update を付ける" "$(labels_of 58)" "visual:update"

echo "== 変更なしで終わり、ワークフローの指摘が残っている：理由は unknown ではなく「ワークフローの指摘が残っている」"
setup_case '直せませんでした。'
state_py "
s['comments'].append({'id':52,'issue':'58','body':'## Code review\n\n- \`.github/workflows/ci.yml\` の権限','user':{'login':'github-actions[bot]'},'created_at':'$(ago 0)','updated_at':'$(ago 0)'})"
out=$(run_after)
assert_contains "分類を出す" "$out" "理由：workflow"
assert_contains "ai:stuck" "$(labels_of 58)" "ai:stuck"
assert_contains "理由の文" "$(comments_of 58)" "ワークフローの指摘が残っています"
assert_contains "指摘の場所" "$(comments_of 58)" ".github/workflows/ci.yml"

echo "== 「No issues found」のまとめにワークフローのパスがあっても、workflow にしない（許可の拒否は permission のまま）"
setup_case '確認コマンドを動かせませんでした。'
state_py "
s['comments'].append({'id':52,'issue':'58','body':'## Code review\n\nNo issues found. \`.github/workflows/ci.yml\` を確かめました。','user':{'login':'github-actions[bot]'},'created_at':'$(ago 0)','updated_at':'$(ago 0)'})"
out=$(EXECUTION_FILE="$MOCK_DIR/exec.json" run_after)
assert_contains "permission になる" "$out" "理由：permission"
assert_not_contains "ai:stuck にしない" "$(labels_of 58)" "ai:stuck"

echo "== 分類できない：今までどおり人間に回す"
setup_case 'うまくいきませんでした。'
run_after > /dev/null
assert_contains "ai:stuck" "$(labels_of 58)" "ai:stuck"
assert_contains "変更が入りませんでした、の文言" "$(comments_of 58)" "変更が入りませんでした"

echo "== 前の回のAIの返事は読まない（この依頼のあとの返事だけを見る）"
setup_case 'うまくいきませんでした。'
state_py "
s['comments'].insert(0,{'id':30,'issue':'58','body':'visual:update で撮り直してください','user':{'login':'claude[bot]'},'created_at':'$(ago 50)','updated_at':'$(ago 50)'})
s['comments']=[c for c in s['comments'] if c['id']!=51]"
run_after > /dev/null
assert_contains "ai:stuck" "$(labels_of 58)" "ai:stuck"
assert_not_contains "visual:update は付けない" "$(labels_of 58)" "visual:update"

finish
