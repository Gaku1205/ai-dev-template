#!/usr/bin/env bash
# main とのコンフリクトの解消を、直す回数（MAX_AUTO_FIX＋強いモデルの1回）に数えない。別の上限（MAX_CONFLICT_FIX）で止める。
# 基準の画像だけのコンフリクトは、AIを呼ばずにパイプラインが解いて撮り直しに回す（agent-desk PR #528：画像のコンフリクト2回で直す回数を使い切り、本物の指摘を直せずに止まった）
source "$(dirname "$0")/lib.sh"
setup_mock

fix_req() { # id 何分前 [種類の印]
  printf '{"id":%s,"issue":"58","user":{"login":"p"},"body":"@claude x\\n\\n<!-- auto-fix -->%s\\n<!-- auto-fix-sha: old%s -->","created_at":"%s","updated_at":"%s"}' \
    "$1" "${3:+\\n$3}" "$1" "$(ago "$2")" "$(ago "$2")"
}
conflict_req() { fix_req "$1" "$2" '<!-- auto-fix-kind: conflict -->'; }

setup_pr() { # コメントのJSONの並び（, 区切り）
  init_state "{\"labels\":{\"58\":[]},\"pulls\":[{\"number\":58,\"body\":\"Closes #1\",\"state\":\"open\",\"head\":{\"sha\":\"abc\",\"ref\":\"claude/issue-1-x\"},\"base\":{\"ref\":\"main\"}}],\"comments\":[${1:-}]}"
}

echo "== 数え方（入力から決まる）：種類ごとに数える"
cs="[$(fix_req 1 30),$(conflict_req 2 20),$(conflict_req 3 10)]"
assert_eq "直す回数はレビューの1回だけ" "1" "$(run_lib "printf '%s' '$cs' | count_auto_fix_in fix")"
assert_eq "コンフリクトは2回" "2" "$(run_lib "printf '%s' '$cs' | count_auto_fix_in conflict")"
assert_eq "種類を書かなければ直す回数" "1" "$(run_lib "printf '%s' '$cs' | count_auto_fix_in")"
resume='{"id":9,"issue":"58","user":{"login":"p"},"body":"<!-- auto-resume -->","created_at":"'"$(ago 15)"'","updated_at":"'"$(ago 15)"'"}'
assert_eq "再開より前のコンフリクトは数えない" "1" "$(run_lib "printf '%s' '[$(conflict_req 2 20),$resume,$(conflict_req 3 10)]' | count_auto_fix_in conflict")"

echo "== レビュー1回＋コンフリクト2回のあとに新しい指摘：直す回数は残っているので、直しを頼む"
setup_pr "$(fix_req 1 30),$(conflict_req 2 20),$(conflict_req 3 10)"
MAX_AUTO_FIX=2 run_lib 'request_fix_or_stop 58 abc "レビューで指摘がありました。" "レビューの指摘が直りませんでした"' > /dev/null
assert_not_contains "人間に回さない" "$(labels_of 58)" "ai:stuck"
assert_contains "直す依頼の2回目" "$(comments_of 58)" "（自動の依頼 2/3）"
assert_eq "新しい依頼には種類の印が無い" "2" "$(comments_of 58 | grep -c 'auto-fix-kind: conflict')"

echo "== コンフリクト3回のあと、4回目で止まる（直す回数は使っていない）"
setup_pr "$(conflict_req 1 30),$(conflict_req 2 20),$(conflict_req 3 10)"
run_lib 'request_conflict_fix_or_stop 58 abc "main とコンフリクトしています。"' > /dev/null
assert_contains "人間に回す" "$(labels_of 58)" "ai:stuck"
assert_contains "理由" "$(comments_of 58)" "main とのコンフリクトが4回続きました"
assert_contains "人向けの理由" "$(comments_of 58)" "最後の理由：main とのコンフリクトが解けませんでした"
assert_eq "AIには頼まない（依頼は前の3つのまま）" "3" "$(comments_of 58 | grep -c '^@claude')"

echo "== コンフリクト2回のあとの3回目は頼む（種類の印つき・直す回数は数えない）"
setup_pr "$(fix_req 1 40),$(fix_req 2 35),$(fix_req 3 32),$(conflict_req 4 30),$(conflict_req 5 20)"
run_lib 'request_conflict_fix_or_stop 58 abc "main とコンフリクトしています。"' > /dev/null
assert_not_contains "直す回数（3回）を使い切っていても止めない" "$(labels_of 58)" "ai:stuck"
last=$(comments_of 58 | grep -n '^@claude main とコンフリクトしています。' | tail -n 1)
assert_contains "コンフリクトの依頼を出す" "$last" "@claude main とコンフリクトしています。"
assert_contains "回数の書き方" "$(comments_of 58)" "コンフリクトの解消 3/3"
assert_eq "種類の印が付く" "3" "$(comments_of 58 | grep -c 'auto-fix-kind: conflict')"
assert_eq "強いモデルは使わない" "0" "$(comments_of 58 | grep -c 'auto-fix-model: opus')"
assert_eq "MAX_CONFLICT_FIX で上限を変えられる" "ai:stuck" "$(setup_pr "$(conflict_req 1 30)"; MAX_CONFLICT_FIX=1 run_lib 'request_conflict_fix_or_stop 58 abc "x"' > /dev/null; labels_of 58)"

echo "== 基準の画像かどうか（入力から決まる）"
G='tests/visual/**/*.png'
yes_no() { if run_lib "printf '%s\n' $1 | only_baseline_images '$2'" > /dev/null; then echo yes; else echo no; fi; }
assert_eq "画像だけ" "yes" "$(yes_no "tests/visual/home.spec.ts-snapshots/a.png tests/visual/b.png" "$G")"
assert_eq "画像とコードが混ざる" "no" "$(yes_no "tests/visual/a.png src/app/page.tsx" "$G")"
assert_eq "置き場所の外の png" "no" "$(yes_no "public/photos/a.png" "$G")"
assert_eq "空なら画像だけとは言わない" "no" "$(yes_no "" "$G")"
assert_eq "置き場所を変えられる（複数）" "yes" "$(yes_no "e2e/__snap__/x.png tests/visual/y.png" "$(printf 'e2e/**/*.png\n%s' "$G")")"
cd "$MOCK_DIR" || exit 1
printf '{"visual_baseline":["e2e/**/*.png"]}' > pipeline.json
assert_eq "pipeline.json の visual_baseline を読む" "e2e/**/*.png" "$(run_lib baseline_image_globs)"
rm pipeline.json
assert_eq "無ければ tests/visual/**/*.png" "$G" "$(run_lib baseline_image_globs)"

echo "== CIのあと main を取り込めない・コンフリクトは基準の画像だけ：AIを呼ばずに解いて、撮り直しに回す"
conflict_ci() { # PRの側の変更 main の側の変更（どちらも空白区切りのファイル名）
  python3 - "$1" "$2" <<'PY'
import json, os, sys
pr = {'number': 58, 'body': 'Closes #1', 'state': 'open', 'head': {'sha': 'abc', 'ref': 'claude/issue-1-x'}, 'base': {'ref': 'main'}}
files = lambda s: [{'filename': f, 'status': 'modified', 'sha': 'blob-' + f} for f in s.split()]
main_files = files(sys.argv[2]) + [{'filename': 'old.txt', 'status': 'removed'}]
tree = [{'path': f['filename'], 'mode': '100755' if f['filename'].endswith('.sh') else '100644', 'type': 'blob', 'sha': 'main-' + f['filename']} for f in main_files if f['status'] != 'removed']
s = {'next_id': 0, 'comments': [], 'labels': {'58': []}, 'issue_updated': {}, 'pulls': [pr], 'checks': [], 'runs': [], 'jobs': [], 'branches': [], 'authors': {},
     'ahead_by': 3, 'update_branch_fail': True, 'ref_shas': {'main': 'm1'},
     'compare': {'m1...abc': {'files': files(sys.argv[1])}, 'abc...m1': {'files': main_files}},
     'trees': {'m1': {'tree': tree, 'truncated': False}}}
json.dump(s, open(os.environ['MOCK_STATE'], 'w'))
PY
  CONCLUSION=success HEAD_SHA=abc HEAD_BRANCH=claude/issue-1-x run_script after-ci.sh > /dev/null
}
st() { python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print(json.dumps($1))"; }

conflict_ci "src/app/page.tsx tests/visual/a.png tests/visual/b.png" "tests/visual/a.png tests/visual/b.png scripts/run.sh"
assert_not_contains "AIを呼ばない" "$(comments_of 58)" "@claude"
assert_contains "撮り直しのラベル" "$(labels_of 58)" "visual:update"
assert_contains "知らせる（枚数）" "$(comments_of 58)" "基準の画像（2枚）だけだった"
assert_contains "撮り直しの回数に数える印" "$(comments_of 58)" "<!-- auto-visual-update -->"
assert_eq "PRのブランチを動かす" '["claude/issue-1-x"]' "$(st "s.get('ref_updates')")"
assert_eq "早送りだけ（force しない）" "false" "$(st "s['ref_update_bodies'][0]['force']")"
assert_eq "マージのコミット（PRの先頭と main）" '["abc", "m1"]' "$(st "s['new_commit_bodies'][0]['parents']")"
assert_eq "PRの先頭の木に重ねる" '"tree-abc"' "$(st "s['new_trees'][0]['base_tree']")"
assert_eq "画像は main の側（モードは main の木のまま）" '[{"path": "tests/visual/a.png", "mode": "100644", "type": "blob", "sha": "main-tests/visual/a.png"}]' \
  "$(st "[e for e in s['new_trees'][0]['tree'] if e['path']=='tests/visual/a.png']")"
assert_eq "main の側だけの変更も入る（実行のモードを保つ）" '"100755"' "$(st "[e['mode'] for e in s['new_trees'][0]['tree'] if e['path']=='scripts/run.sh'][0]")"
assert_eq "main で消えたファイルは消す" 'null' "$(st "[e['sha'] for e in s['new_trees'][0]['tree'] if e['path']=='old.txt'][0]")"
assert_eq "直す回数を使わない" "0" "$(run_lib 'count_auto_fix 58')"
assert_eq "コンフリクトの回数も使わない" "0" "$(run_lib 'count_auto_fix 58 conflict')"

echo "== 画像とコードが両方でぶつかる：今までどおりAIに頼む（コンフリクトの回数で数える）"
conflict_ci "src/app/page.tsx tests/visual/a.png" "src/app/page.tsx tests/visual/a.png"
assert_contains "AIに頼む" "$(comments_of 58)" "@claude main の変更を取り込もうとしたら、コンフリクト"
assert_contains "種類の印" "$(comments_of 58)" "<!-- auto-fix-kind: conflict -->"
assert_not_contains "撮り直しは付けない" "$(labels_of 58)" "visual:update"
assert_eq "ブランチは動かさない" 'null' "$(st "s.get('ref_updates')")"
assert_eq "直す回数は0のまま" "0" "$(run_lib 'count_auto_fix 58')"
assert_eq "コンフリクトの回数が1" "1" "$(run_lib 'count_auto_fix 58 conflict')"

echo "== 画像だけでも、ブランチを動かせない（その間に push が入った）：AIに任せる"
# 状態を作ってから断る印を足し、もう一度 after-ci を動かす
conflict_ci "tests/visual/a.png" "tests/visual/a.png" > /dev/null
state_py "s['comments']=[]; s['labels']['58']=[]; s['ref_updates']=[]; s['ref_update_fail']=True"
CONCLUSION=success HEAD_SHA=abc HEAD_BRANCH=claude/issue-1-x run_script after-ci.sh > /dev/null
assert_contains "AIに頼む" "$(comments_of 58)" "<!-- auto-fix-kind: conflict -->"
assert_not_contains "撮り直しは付けない" "$(labels_of 58)" "visual:update"

echo "== 同じ先頭で一度解いたのに、まだコンフリクト：2回は試さず、AIに任せる"
conflict_ci "tests/visual/a.png" "tests/visual/a.png" > /dev/null
state_py "s['labels']['58']=[]"
CONCLUSION=success HEAD_SHA=abc HEAD_BRANCH=claude/issue-1-x run_script after-ci.sh > /dev/null
assert_contains "AIに頼む" "$(comments_of 58)" "<!-- auto-fix-kind: conflict -->"
assert_eq "ブランチを動かしたのは1回だけ" '["claude/issue-1-x"]' "$(st "s.get('ref_updates')")"

echo "== 画像だけ・見張り役のマージ待ちの道（request_conflict_fix_or_stop）でも、AIを呼ばない"
conflict_ci "tests/visual/a.png" "tests/visual/a.png" > /dev/null
state_py "s['comments']=[]; s['labels']['58']=[]; s['ref_updates']=[]"
run_lib 'request_conflict_fix_or_stop 58 abc "人間のマージ待ちの間に main が進み、コンフリクトしています。"' > /dev/null
assert_not_contains "AIを呼ばない" "$(comments_of 58)" "@claude"
assert_contains "撮り直しのラベル" "$(labels_of 58)" "visual:update"

echo "== 比べたあとに main が進んだ（一覧・木・親が別のコミットになる）：巻き戻さないよう、sha で比べる。分からなければAIに任せる"
conflict_ci "tests/visual/a.png" "tests/visual/a.png" > /dev/null
state_py "s['comments']=[]; s['labels']['58']=[]; s['ref_updates']=[]; s['new_commit_bodies']=[]; s['ref_shas']={'main':'m2'}"
CONCLUSION=success HEAD_SHA=abc HEAD_BRANCH=claude/issue-1-x run_script after-ci.sh > /dev/null
assert_eq "マージのコミットを作らない" '[]' "$(st "s.get('new_commit_bodies', [])")"
assert_contains "AIに頼む" "$(comments_of 58)" "<!-- auto-fix-kind: conflict -->"

echo "== 直す依頼が動かなかった（PRが更新された）コンフリクトの依頼：同じ種類のまま出し直す"
setup_pr "$(conflict_req 1 5)"
req=$(python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print(json.dumps(s['comments'][0]))")
run_lib "reissue_stale_fix 58 '$req'" > /dev/null
assert_eq "種類の印が2つ（元と出し直し）" "2" "$(comments_of 58 | grep -c 'auto-fix-kind: conflict')"
assert_contains "コンフリクトの回数で書く" "$(comments_of 58)" "コンフリクトの解消"

finish
