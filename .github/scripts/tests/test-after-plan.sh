#!/usr/bin/env bash
# 企画AIのあと（after-plan.sh）：清書の結果のサイズを付けて実装へ。先に決まっているサイズ（工場の size:L など）は残す
source "$(dirname "$0")/lib.sh"
setup_mock
work="$MOCK_DIR/work"; mkdir -p "$work"
run_plan() { (cd "$work" && if [ -n "$1" ]; then printf '%s\n%s\n' "$1" PARALLEL > plan-result.txt; else rm -f plan-result.txt; fi && ISSUE=3 PLAN_OUTCOME=success GITHUB_TOKEN_FOR_LABELS=x bash "$SCRIPTS_DIR/after-plan.sh" 2>&1); }

echo "== サイズが無ければ、企画AIの決めたサイズを付けて実装へ"
init_state '{"labels":{"3":["ai:plan"]}}'
run_plan "READY size:S" > /dev/null
assert_eq "size:S と ai:implement" "ai:implement,size:S" "$(labels_of 3)"

echo "== 工場が size:L を付けていれば、企画AIが size:S と言っても size:L のまま"
init_state '{"labels":{"3":["ai:plan","size:L"]}}'
run_plan "READY size:S" > /dev/null
assert_eq "size:L のまま" "ai:implement,size:L" "$(labels_of 3)"

echo "== 結果を書かずに終わった（質問も無い）：黙って止めず、2回までは自動でやり直す"
init_state '{"labels":{"3":["ai:plan"]}}'
run_plan "" > /dev/null
assert_contains "やり直し待ち" "$(labels_of 3)" "ai:retry"
assert_not_contains "人間に回さない" "$(labels_of 3)" "ai:stuck"
state_py "
import re
for c in s['comments']:
    if 'auto-retry' in c['body']: c['body']=re.sub(r'count=[0-9]+ kind=','count=2 kind=',c['body'])
s['labels']['3']=['ai:plan']"
run_plan "" > /dev/null
assert_contains "やり直しのあとも書かなければ人間に回す" "$(labels_of 3)" "ai:stuck"
assert_contains "理由を書く" "$(comments_of 3)" "清書の結果を書きませんでした"

echo "== 迷いがあれば選択式で質問して待つ（ai:question。止まった扱いにはしない）"
init_state '{"labels":{"3":["ai:plan"]}}'
run_plan "ASK" > /dev/null
assert_eq "質問の印だけ" "ai:question" "$(labels_of 3)"

echo "== 答えたら清書に戻す（after-answer.sh）"
init_state '{"labels":{"3":["ai:question"]}}'
(ISSUE=3 GH_TOKEN=pipe GITHUB_TOKEN_FOR_LABELS=x bash "$SCRIPTS_DIR/after-answer.sh" > /dev/null 2>&1)
assert_eq "質問の印を外して ai:plan" "ai:plan" "$(labels_of 3)"

echo "== 見た目の大きい作り直しは、作る前に画面案（ai:mocks。パイプラインの鍵で付けて画面案のワークフローを動かす）"
init_state '{"labels":{"3":["ai:plan"]}}'
(cd "$work" && printf 'MOCKS\nPARALLEL\n' > plan-result.txt && ISSUE=3 PLAN_OUTCOME=success GH_TOKEN=pipe GITHUB_TOKEN_FOR_LABELS=x bash "$SCRIPTS_DIR/after-plan.sh" > /dev/null 2>&1)
assert_eq "画面案の印" "ai:mocks" "$(labels_of 3)"


echo "== ai:skip が付いた Issue（オーナー以外が作った物）は、失敗してもやり直しに回さず、結果も使わない"
init_state '{"labels":{"3":["ai:plan","ai:skip"]}}'
(cd "$work" && rm -f plan-result.txt && ISSUE=3 PLAN_OUTCOME=failure GITHUB_TOKEN_FOR_LABELS=x bash "$SCRIPTS_DIR/after-plan.sh" > /dev/null 2>&1)
assert_eq "ai:retry を付けず、ai:plan を外す" "ai:skip" "$(labels_of 3)"
init_state '{"labels":{"3":["ai:plan","ai:skip"]}}'
run_plan "READY" > /dev/null
assert_eq "清書できていても、実装に回さない" "ai:skip" "$(labels_of 3)"

echo "== 企画AIが PARALLEL と言っても、企画の間に始まった作業と触るファイルが重なるなら、順番待ちにする"
touch_state() { # この Issue の印 進行中の Issue の印
  init_state '{"labels":{"3":["ai:plan"],"8":["ai:implement"]},"issues_meta":{"3":{"body":"本文\n<!-- ai-touches: '"$1"' -->"},"8":{"body":"本文\n<!-- ai-touches: '"$2"' -->"}}}'
}
touch_state "src/lib/a.ts, docs/spec.md" "src/lib/a.ts"
out=$(run_plan "READY")
assert_eq "重なるので順番待ち" "ai:queue" "$(labels_of 3)"
assert_contains "理由をログに出す" "$out" "触るファイルが重なるので、待ちます"
touch_state "src/lib/a.ts" "src/lib/b.ts"
run_plan "READY" > /dev/null
assert_eq "重ならなければ、今までどおり並列で実装へ" "ai:implement" "$(labels_of 3)"
init_state '{"labels":{"3":["ai:plan"],"8":["ai:implement"]},"issues_meta":{"3":{"body":"本文\n<!-- ai-touches: src/lib/a.ts -->"}}}'
run_plan "READY" > /dev/null
assert_eq "進行中の物に印が無ければ、今までどおり企画AIの判断" "ai:implement" "$(labels_of 3)"
echo "== 止まった実装中の物（ai:stuck）は席に数えない：上限1でも並列で実装へ。触るファイルが重なれば待つ"
init_state '{"labels":{"3":["ai:plan"],"8":["ai:implement","ai:stuck"]},"issues_meta":{"3":{"body":"本文\n<!-- ai-touches: src/lib/b.ts -->"},"8":{"body":"本文\n<!-- ai-touches: src/lib/a.ts -->"}}}'
out=$(MAX_PARALLEL=1 run_plan "READY")
assert_eq "重ならないので実装へ" "ai:implement" "$(labels_of 3)"
assert_contains "実装中は0" "$out" "実装中 0"
init_state '{"labels":{"3":["ai:plan"],"8":["ai:implement","ai:stuck"]},"issues_meta":{"3":{"body":"本文\n<!-- ai-touches: src/lib/a.ts -->"},"8":{"body":"本文\n<!-- ai-touches: src/lib/a.ts -->"}}}'
MAX_PARALLEL=1 run_plan "READY" > /dev/null
assert_eq "重なるので順番待ち" "ai:queue" "$(labels_of 3)"
init_state '{"labels":{"3":["ai:plan"],"1":["ai:implement","ai:stuck"]},"issues_meta":{"3":{"body":"本文\n<!-- ai-touches: src/lib/b.ts -->"},"1":{"body":"本文\n<!-- ai-touches: src/lib/a.ts -->"}}}'
MAX_PARALLEL=1 run_plan "READY" > /dev/null
assert_eq "止まった物の番号が小さくても、数え直しで引かない" "ai:implement" "$(labels_of 3)"

echo "== 仕様書だけが重なるなら、順番待ちにしない／印を書き忘れた Issue は、本文のファイル名から印を補う"
touch_state "src/lib/a.ts, docs/spec.md" "src/lib/b.ts, docs/spec.md"
run_plan "READY" > /dev/null
assert_eq "仕様書だけが重なる：並列で実装へ" "ai:implement" "$(labels_of 3)"
body_of() { python3 -c "import json,os;print(json.load(open(os.environ['MOCK_STATE'])).get('issues_meta',{}).get('$1',{}).get('body',''))"; }
# shellcheck disable=SC2016
init_state '{"labels":{"3":["ai:plan"],"8":["ai:implement"]},"issues_meta":{"3":{"body":"本文 `src/lib/a.ts` を直す"},"8":{"body":"本文\n<!-- ai-touches: src/lib/a.ts -->"}}}'
out=$(run_plan "READY")
assert_contains "印を補った" "$(body_of 3)" "<!-- ai-touches: src/lib/a.ts -->"
assert_contains "補ったことをログに出す" "$out" "本文のファイル名から補いました"
assert_eq "補った印が重なるので順番待ち" "ai:queue" "$(labels_of 3)"
init_state '{"labels":{"3":["ai:plan"],"8":["ai:implement"]},"issues_meta":{"3":{"body":"ファイル名の無い本文"},"8":{"body":"本文\n<!-- ai-touches: src/lib/a.ts -->"}}}'
out=$(run_plan "READY")
assert_contains "補えないことをログに出す" "$out" "補えませんでした"
assert_eq "補えなければ、今までどおり企画AIの判断" "ai:implement" "$(labels_of 3)"

echo "== 印に共有の大きなフォルダがある：1回だけ、ファイル単位で書き直させる（サイズは付けない）"
init_state '{"labels":{"3":["ai:plan"]},"issues_meta":{"3":{"body":"本文\n<!-- ai-touches: src/components/, src/lib/a.ts -->"}}}'
out=$(run_plan "READY size:S")
assert_eq "ai:plan を付け直す（実装・順番待ち・サイズは付けない）" "ai:plan" "$(labels_of 3)"
assert_contains "印のコメント" "$(comments_of 3)" "<!-- touches-too-broad -->"
assert_contains "広い物の一覧" "$(comments_of 3)" "src/components/"
assert_contains "書き直しの頼み" "$(comments_of 3)" "ファイル単位で書き直してください"
assert_not_contains "ファイルは広い物に入れない" "$(comments_of 3)" "src/lib/a.ts"
run_plan "READY size:S" > /dev/null
assert_eq "2回目は今までどおり進める" "ai:implement,size:S" "$(labels_of 3)"
init_state '{"labels":{"3":["ai:plan"],"8":["ai:implement"]},"issues_meta":{"3":{"body":"本文\n<!-- ai-touches: src/components/ -->"},"8":{"body":"本文\n<!-- ai-touches: src/components/A.tsx -->"}}}'
run_plan "READY" > /dev/null
run_plan "READY" > /dev/null
assert_eq "やり直しのあとは、重なるので順番待ち" "ai:queue" "$(labels_of 3)"
init_state '{"labels":{"3":["ai:plan"]},"issues_meta":{"3":{"body":"本文\n<!-- ai-touches: src/app/(app)/lanes/, src/lib/a.ts -->"}}}'
run_plan "READY size:S" > /dev/null
assert_eq "新しいフォルダ・ファイルは今までどおり" "ai:implement,size:S" "$(labels_of 3)"

echo "== 作業回数の上限に届いた企画：ワークフローが上限を増やしてやり直しても、また届いたら、やり直さず人間に回す"
turns_file="$MOCK_DIR/turns.json"; printf '%s' '[{"type":"result","subtype":"error_max_turns","result":""}]' > "$turns_file"
other_file="$MOCK_DIR/other.json"; printf '%s' '[{"type":"result","subtype":"error_during_execution","result":""}]' > "$other_file"
limit_file="$MOCK_DIR/limit.json"; printf '%s' '[{"type":"result","subtype":"error_max_turns","result":"Claude usage limit reached|1900000000"}]' > "$limit_file"
run_failed() { # 上限を増やしてやり直したか（true／false／空） 実行記録
  (cd "$work" && rm -f plan-result.txt && ISSUE=3 PLAN_OUTCOME=failure PLAN_TURNS_RAISED="$1" EXECUTION_FILE="$2" GITHUB_TOKEN_FOR_LABELS=x bash "$SCRIPTS_DIR/after-plan.sh" 2>&1)
}
init_state '{"labels":{"3":["ai:plan"]}}'
run_failed true "$turns_file" > /dev/null
assert_eq "人間に回す（ai:plan は外す。やり直し待ちにしない）" "ai:stuck" "$(labels_of 3)"
assert_contains "理由を書く" "$(comments_of 3)" "作業回数の上限を増やしてやり直しても、また上限に届きました"
assert_contains "次にすることを書く" "$(comments_of 3)" "Issue を小さく分けるか"
assert_not_contains "やり直しの記録は作らない" "$(comments_of 3)" "auto-retry"

echo "== AIは正常に終わって結果も書いたのに、アクションが失敗にした（手数が上限を少し越えた。途中に拒否あり）：失敗にせず、結果を使って進める（agent-desk #447）"
done_file="$MOCK_DIR/done.json"; printf '%s' '[{"type":"result","subtype":"success","is_error":false,"num_turns":34,"result":"清書は終わりました","permission_denials":[{"tool_name":"Edit","tool_input":{"file_path":"/tmp/issue447.md"}},{"tool_name":"Bash","tool_input":{"command":"rm issue-447-body.md"}}]}]' > "$done_file"
err_file="$MOCK_DIR/err.json"; printf '%s' '[{"type":"result","subtype":"success","is_error":true,"result":"","permission_denials":[{"tool_name":"Edit","tool_input":{"file_path":"/tmp/a.md"}}]}]' > "$err_file"
run_done() { # plan-result.txt の1行目（空なら、無し） 実行記録
  (cd "$work" && if [ -n "$1" ]; then printf '%s\n%s\n' "$1" PARALLEL > plan-result.txt; else rm -f plan-result.txt; fi && ISSUE=3 PLAN_OUTCOME=failure PLAN_TURNS_RAISED=false EXECUTION_FILE="$2" GH_TOKEN=pipe GITHUB_TOKEN_FOR_LABELS=x bash "$SCRIPTS_DIR/after-plan.sh" 2>&1)
}
init_state '{"labels":{"3":["ai:plan"]}}'
out=$(run_done "READY" "$done_file")
assert_eq "実装へ進む（人間に回さない）" "ai:implement" "$(labels_of 3)"
assert_contains "理由をログに出す" "$out" "失敗として扱いません"
assert_not_contains "許可不足のコメントを書かない" "$(comments_of 3)" "足りない許可"
init_state '{"labels":{"3":["ai:plan"]}}'
run_done "ASK" "$done_file" > /dev/null
assert_eq "質問の結果も、そのまま使う" "ai:question" "$(labels_of 3)"
init_state '{"labels":{"3":["ai:plan"]}}'
run_done "" "$done_file" > /dev/null
assert_contains "結果を書いていなければ、今までどおり許可不足で人間に回す" "$(labels_of 3)" "ai:stuck"
assert_contains "足りない許可を書く" "$(comments_of 3)" "足りない許可"
init_state '{"labels":{"3":["ai:plan"]}}'
run_done "READY" "$err_file" > /dev/null
assert_contains "AIがエラーで終わっていれば、結果があっても使わない" "$(labels_of 3)" "ai:stuck"
init_state '{"labels":{"3":["ai:plan"]}}'
run_done "READY" "$turns_file" > /dev/null
assert_eq "上限に届いて終わった（正常に終わっていない）なら、今までどおりやり直し待ち" "ai:plan,ai:retry" "$(labels_of 3)"
init_state '{"labels":{"3":["ai:plan"]}}'
run_done "READY" "$MOCK_DIR/none.json" > /dev/null
assert_eq "実行記録が無ければ、今までどおりやり直し待ち" "ai:plan,ai:retry" "$(labels_of 3)"
init_state '{"labels":{"3":["ai:plan"]}}'
run_done "なにか" "$done_file" > /dev/null
assert_contains "知らない結果は使わない" "$(labels_of 3)" "ai:stuck"

echo "== 上限を増やしたやり直しをしていない（古いワークフロー・結果ファイルがあった）ときは、今までどおり1回やり直す"
for raised in false ""; do
  init_state '{"labels":{"3":["ai:plan"]}}'
  run_failed "$raised" "$turns_file" > /dev/null
  assert_eq "やり直し待ち（raised=${raised:-空}）" "ai:plan,ai:retry" "$(labels_of 3)"
done

echo "== 上限を増やしたやり直しが、別の理由（エラー・使用量の上限）で終わったときは、今までどおりやり直す"
init_state '{"labels":{"3":["ai:plan"]}}'
run_failed true "$other_file" > /dev/null
assert_eq "エラー：やり直し待ち" "ai:plan,ai:retry" "$(labels_of 3)"
init_state '{"labels":{"3":["ai:plan"]}}'
run_failed true "$limit_file" > /dev/null
assert_eq "使用量の上限：待つ（人間に回さない）" "ai:plan,ai:retry" "$(labels_of 3)"
assert_contains "上限の待ちとして記録する" "$(comments_of 3)" "limit-until=1900000000"

echo "== 上限を増やしたやり直しで清書できたら、いつもどおり実装へ"
init_state '{"labels":{"3":["ai:plan"]}}'
(cd "$work" && printf '%s\n%s\n' "READY" PARALLEL > plan-result.txt && ISSUE=3 PLAN_OUTCOME=success PLAN_TURNS_RAISED=true EXECUTION_FILE="$turns_file" GITHUB_TOKEN_FOR_LABELS=x bash "$SCRIPTS_DIR/after-plan.sh" > /dev/null 2>&1)
assert_eq "ai:implement" "ai:implement" "$(labels_of 3)"

echo "== 清書で消えた画像を、本文の最後に足し直す（実装AIも同じ画像を見るため）"
body_of() { python3 -c "import json,os;print(json.load(open(os.environ['MOCK_STATE'])).get('issues_meta',{}).get('$1',{}).get('body',''))"; }
init_state '{"labels":{"3":["ai:plan"]},"issues_meta":{"3":{"body":"### 背景\n清書した本文 ![keep](https://github.com/me/app/raw/issue-images/images/k.png)"}}}'
before='直したい ![s](https://github.com/me/app/raw/issue-images/images/a.png "題")
<img width="300" src="https://github.com/user-attachments/assets/b.png">
残っている物 ![keep](https://github.com/me/app/raw/issue-images/images/k.png)'
(cd "$work" && printf 'READY\nPARALLEL\n' > plan-result.txt && ISSUE=3 PLAN_OUTCOME=success GITHUB_TOKEN_FOR_LABELS=x ISSUE_BODY_BEFORE="$before" bash "$SCRIPTS_DIR/after-plan.sh" > /dev/null 2>&1)
b=$(body_of 3)
assert_contains "清書した本文は残す" "$b" "清書した本文"
assert_contains "見出し" "$b" "### 貼られた画像"
assert_contains "消えた Markdown の画像" "$b" "images/a.png"
assert_contains "消えた <img>" "$b" "assets/b.png"
assert_eq "残っている画像は二重にしない" "1" "$(printf '%s' "$b" | grep -o 'images/k.png' | wc -l | tr -d ' ')"
assert_contains "実装へ進む" "$(labels_of 3)" "ai:implement"

echo "== 画像が全部残っていれば、本文を変えない"
init_state '{"labels":{"3":["ai:plan"]},"issues_meta":{"3":{"body":"清書 ![a](https://x.example/a.png)"}}}'
(cd "$work" && printf 'READY\nPARALLEL\n' > plan-result.txt && ISSUE=3 PLAN_OUTCOME=success GITHUB_TOKEN_FOR_LABELS=x ISSUE_BODY_BEFORE='メモ ![a](https://x.example/a.png)' bash "$SCRIPTS_DIR/after-plan.sh" > /dev/null 2>&1)
assert_eq "そのまま" "清書 ![a](https://x.example/a.png)" "$(body_of 3)"

finish
