#!/usr/bin/env bash
# コミットのステータス「AIレビュー」（review-status.sh）：どの場面で何が付くか。STATUS_TOKEN が無くても失敗にしない。Doctor が未設定を知らせる
# shellcheck disable=SC2034,SC2329  # doctor.sh（source）が読む変数・関数を、ここで渡している
source "$(dirname "$0")/lib.sh"
setup_mock
printf '%s\n' '# 普通のリポジトリ' > "$MOCK_DIR/CLAUDE_default.md"
export CLAUDE_MD="$MOCK_DIR/CLAUDE_default.md"

# 付いたステータスを「状態:context:説明」で1行ずつ出す
posts() { python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print('\n'.join('%s:%s:%s:%s' % (p['sha'],p['state'],p['context'],p['description']) for p in s.get('status_posts',[])))"; }

PR_STATE='"labels":{"58":[]},"pulls":[{"number":58,"state":"open","body":"Closes #54","head":{"sha":"abc","ref":"claude/issue-54-x"},"updated_at":"2026-01-01T00:00:00Z"}],"checks":[{"name":"check","status":"completed","conclusion":"success","app":{"slug":"github-actions"}}],"branches":[{"name":"claude/issue-54-x","date":"2026-01-01T00:00:00Z"}]'

review_case() { # レビューのまとめ（空なら書かない） 変更ファイル（JSON の配列）
  init_state '{'"$PR_STATE"',"files":'"$2"'}'
  if [ -n "$1" ]; then
    state_py "s['comments'].append({'id':1,'issue':'58','body':'$1','user':{'login':'github-actions[bot]'},'created_at':'$(ago 1)','updated_at':'$(ago 1)'})"
  fi
  CONCLUSION=success HEAD_SHA=abc HEAD_BRANCH=claude/issue-54-x run_script after-review.sh > /dev/null
}

echo "== review-status.sh 単体：context「AIレビュー」で、指定のコミットに付ける"
init_state '{}'
STATUS_TOKEN=tok run_script review-status.sh abc123 pending "AIがレビュー中です" > /dev/null
assert_eq "pending が付く（ワークフローのトークンで）" "abc123:pending:AIレビュー:AIがレビュー中です" "$(posts)"
assert_eq "STATUS_TOKEN で書く" "tok" "$(python3 -c "import json,os;print(json.load(open(os.environ['MOCK_STATE']))['status_posts'][0]['token'])")"
long=$(printf 'あ%.0s' $(seq 1 200))
STATUS_TOKEN=tok run_script review-status.sh abc123 success "$long" > /dev/null
assert_eq "説明は140字まで" "140" "$(python3 -c "import json,os;print(len(json.load(open(os.environ['MOCK_STATE']))['status_posts'][-1]['description']))")"

echo "== STATUS_TOKEN が無い：失敗にせず、何も付けない"
init_state '{}'
out=$(env -u STATUS_TOKEN bash "$SCRIPTS_DIR/review-status.sh" abc123 success "指摘なし" 2>&1); rc=$?
assert_eq "終了コード 0" "0" "$rc"
assert_contains "警告を出す" "$out" "STATUS_TOKEN が無い"
assert_eq "何も付かない" "" "$(posts)"

echo "== 書けなかった（権限が無い）：失敗にしない"
init_state '{"status_fail":true}'
out=$(STATUS_TOKEN=tok bash "$SCRIPTS_DIR/review-status.sh" abc123 success "指摘なし" 2>&1); rc=$?
assert_eq "終了コード 0" "0" "$rc"
assert_contains "警告を出す" "$out" "付けられませんでした"

echo "== 状態が正しくなければ、何も付けず失敗にもしない"
init_state '{}'
STATUS_TOKEN=tok run_script review-status.sh abc123 bogus "x" > /dev/null; rc=$?
assert_eq "終了コード 0" "0" "$rc"
assert_eq "何も付かない" "" "$(posts)"

echo "== 指摘なし → success"
export STATUS_TOKEN=tok
review_case '## Code review\n\nNo issues found.' '["src/a.ts"]'
assert_eq "success が付く" "abc:success:AIレビュー:指摘なし" "$(posts)"

echo "== 指摘あり → failure（直すよう依頼する）"
review_case '## Code review\n\n1. バグがあります' '["src/a.ts"]'
assert_eq "failure が付く" "abc:failure:AIレビュー:指摘があります。AIが直しています" "$(posts)"
assert_contains "直す依頼も出る" "$(comments_of 58)" "auto-fix"

echo "== 画像だけのPR → 理由を書いた success"
review_case '' '[{"filename":"assets/readme/home.png","changes":0}]'
assert_eq "success（理由つき）が付く" "abc:success:AIレビュー:画像など文字で読めない変更だけなので、レビューする差分がありません" "$(posts)"

echo "== claude-review.yml を変えるPR → 理由を書いた success（ai:hold）"
review_case '' '[{"filename":".github/workflows/claude-review.yml","changes":3}]'
assert_eq "success（理由つき）が付く" "abc:success:AIレビュー:レビューAIが動けないPRなので、人間が確かめてください" "$(posts)"
assert_eq "ai:hold が付く" "ai:hold" "$(labels_of 58)"

echo "== レビューAIが何も書かずに終わった（やり直す間）→ 何も付けない"
review_case '' '[{"filename":"src/a.ts","changes":3}]'
assert_eq "何も付かない" "" "$(posts)"

echo "== STATUS_TOKEN が無くても、レビューのあとの処理は今までどおり進む（マージされる）"
unset STATUS_TOKEN
review_case '## Code review\n\nNo issues found.' '["src/a.ts"]'
assert_eq "何も付かない" "" "$(posts)"
assert_eq "マージされる" "58" "$(python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print(','.join(map(str,s.get('merged',[]))))")"

echo "== 配布のPR（pipeline-sync）→ 理由を書いた success（マージの判断の前）"
export STATUS_TOKEN=tok
init_state '{"labels":{"70":[]},"pulls":[{"number":70,"state":"open","body":"<!-- pipeline-sync -->","user":{"login":"gaku-ai-pipeline[bot]"},"head":{"sha":"abc","ref":"pipeline-sync/123abcd"},"updated_at":"2026-01-01T00:00:00Z"}],"branches":[{"name":"pipeline-sync/123abcd"}],"ahead_by":0}'
RUN_ID=1 CONCLUSION=success HEAD_SHA=abc HEAD_BRANCH=pipeline-sync/123abcd run_script after-ci.sh > /dev/null
assert_eq "success が付く" "abc:success:AIレビュー:配布のPRなのでAIレビューは通しません。CIで決めます" "$(posts)"
assert_eq "マージもされる" "70" "$(python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print(','.join(map(str,s.get('merged',[]))))")"
init_state '{"labels":{"70":[]},"pulls":[{"number":70,"state":"open","body":"<!-- pipeline-sync -->","user":{"login":"claude[bot]"},"head":{"sha":"abc","ref":"pipeline-sync/123abcd"},"updated_at":"2026-01-01T00:00:00Z"}],"branches":[{"name":"pipeline-sync/123abcd"}],"ahead_by":0,"jobs":[]}'
RUN_ID=1 CONCLUSION=success HEAD_SHA=abc HEAD_BRANCH=pipeline-sync/123abcd run_script after-ci.sh > /dev/null
assert_not_contains "AI（claude[bot]）が作った物は、配布のPRとして扱わない" "$(posts)" "配布のPR"

echo "== Doctor：main の保護で AIレビュー が必須か"
source "$SCRIPTS_DIR/doctor.sh"
REPO=o/r
fetch_main_protected() { echo true; }
run_check() { out="$(check_review_required 2>&1)"; }
fetch_main_required_contexts() { printf 'check\n'; }
run_check
assert_contains "未設定なら警告" "$out" "⚠️ AIレビューが必須になっていない（レビューの前・指摘を直している間に、人間がマージできてしまう）"
assert_contains "直し方は docs/pipeline.md" "$out" "docs/pipeline.md"
fetch_main_required_contexts() { printf 'check\nAIレビュー\n'; }
run_check
assert_contains "設定済みなら ✅" "$out" "✅ main の保護で「AIレビュー」が必須になっている"
fetch_main_required_contexts() { return 1; }
run_check
assert_eq "保護が無い・読めないときは何も足さない" "" "$out"

finish
