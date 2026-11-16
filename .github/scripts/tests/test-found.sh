#!/usr/bin/env bash
# 使ってみる役・監査役：動かすかの判定（found-gate.sh）と、見つけた問題を Issue にする（found-report.sh）
source "$(dirname "$0")/lib.sh"
setup_mock
OUT="$MOCK_DIR/out.txt"
gate() { : > "$OUT"; GITHUB_OUTPUT="$OUT" NOW=$(date -u -d 2026-11-16T12:00:00Z +%s) bash "$SCRIPTS_DIR/found-gate.sh" "$@" > /dev/null; }
val() { grep "^$1=" "$OUT" | tail -1 | cut -d= -f2-; }

echo "== 使ってみる役：Website があり、main が24時間以内に変わった → 動かす"
init_state '{"homepage":"https://app.vercel.app","main_commit_date":"2026-11-16T03:00:00Z"}'
gate try
assert_eq "run" "true" "$(val run)"
assert_eq "url" "https://app.vercel.app" "$(val url)"

echo "== main が24時間より前 → 動かさない（公開が無かった日）"
init_state '{"homepage":"https://app.vercel.app","main_commit_date":"2026-11-14T03:00:00Z"}'
gate try
assert_eq "run" "false" "$(val run)"
echo "== 手で動かした（FORCE=1）なら、日付は見ない"
FORCE=1 gate try
assert_eq "run" "true" "$(val run)"

echo "== Website が空（ゲームの exe など）→ 動かさない"
init_state '{"homepage":"","main_commit_date":"2026-11-16T03:00:00Z"}'
gate try
assert_eq "run" "false" "$(val run)"

echo "== GitHub Pages の公開があれば、その URL を使う（Website が古くても）"
init_state '{"homepage":"https://old.vercel.app","main_commit_date":"2026-11-16T03:00:00Z","deployments":[{"id":7,"environment":"github-pages","url":"https://o.github.io/r/"}]}'
gate try
assert_eq "url" "https://o.github.io/r/" "$(val url)"

echo "== 監査役：進行中の作業が無い → 動かす"
init_state '{"labels":{"5":[]}}'
gate audit
assert_eq "run" "true" "$(val run)"
echo "== 実装中の Issue がある → 見送る"
init_state '{"labels":{"5":["ai:implement"]}}'
gate audit
assert_eq "run" "false" "$(val run)"
echo "== AIのPRが開いている → 見送る"
init_state '{"pulls":[{"number":9,"state":"open","head":{"ref":"claude/issue-5-x","sha":"a"},"labels":[]}]}'
gate audit
assert_eq "run" "false" "$(val run)"
FORCE=1 gate audit
assert_eq "手で動かしたら動かす" "true" "$(val run)"

echo "== 見つけた問題を Issue にする（最大3件・ai:found と ai:plan）"
init_state '{"labels":{"3":["ai:found"]},"issues_meta":{"3":{"title":"保存ボタンを押しても 何も起きない","state":"open"}}}'
F="$MOCK_DIR/r.json"
cat > "$F" <<'JSON'
{"findings":[
 {"title":"保存ボタンを押しても何も起きない","body":"重複"},
 {"title":"スマホで表がはみ出す","body":"390 の幅で、右の列が切れる"},
 {"title":"戻るボタンが無い","body":"詳細から一覧へ戻れない"},
 {"title":"エラーの文言が英語","body":"Network error と出る"},
 {"title":"4件目","body":"上限を超える"}]}
JSON
RUN_URL=https://example/run bash "$SCRIPTS_DIR/found-report.sh" try "$F" > "$MOCK_DIR/rep.txt"
made=$(python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print(len([n for n in s['issues_meta'] if n!='3']))")
assert_eq "3件だけ作る" "3" "$made"
assert_contains "空白だけ違う題名は重複として見送る" "$(cat "$MOCK_DIR/rep.txt")" "重複で見送り：1件"
first=$(python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));n=sorted(k for k in s['issues_meta'] if k!='3')[0];print(','.join(sorted(s['labels'][n])));print(s['issues_meta'][n]['body'])")
assert_contains "ラベル" "$first" "ai:found,ai:plan"
assert_contains "誰が見つけたか" "$first" "使ってみる役"
assert_contains "ログの場所" "$first" "https://example/run"
assert_contains "印" "$first" "<!-- ai-found: try -->"
assert_not_contains "上限を超えた分は作らない" "$(python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print([m['title'] for m in s['issues_meta'].values()])")" "4件目"

echo "== 結果のファイルが無い・壊れている → 何もしない（失敗にしない）"
init_state '{}'
bash "$SCRIPTS_DIR/found-report.sh" audit "$MOCK_DIR/none.json" > /dev/null
assert_eq "終了コード 0" "0" "$?"
echo '{"findings": "x"}' > "$F"
bash "$SCRIPTS_DIR/found-report.sh" audit "$F" > /dev/null
assert_eq "壊れていても 0" "0" "$?"
finish
