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

echo "== 長い日本語の題名でも、文字の途中で切れず、重複として見送れる"
LONG="仕様書の保存の節とデザイン仕様の保存ボタンの節で、ボタンの文言と押したあとの挙動が食い違っている件について詳しく"
init_state '{}'
jq -n --arg t "$LONG" '{findings:[{title:$t,body:"本文"}]}' > "$F"
bash "$SCRIPTS_DIR/found-report.sh" audit "$F" > /dev/null
bash "$SCRIPTS_DIR/found-report.sh" audit "$F" > "$MOCK_DIR/rep2.txt"
assert_not_contains "題名に壊れた文字が無い" "$(python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print([m['title'] for m in s['issues_meta'].values()])")" "�"
assert_contains "2回目は重複で見送る" "$(cat "$MOCK_DIR/rep2.txt")" "作った Issue：0件（重複で見送り：1件）"

echo "== kind:shorten は ai:found＋ai:skip（ai:plan なし）。食い違いと合わせて3件の枠"
init_state '{}'
cat > "$F" <<'JSON'
{"findings":[
 {"title":"食い違いA","body":"本文A"},
 {"title":"仕様書の保存の節を短くまとめる提案","body":"元の節：docs/spec.md ## 保存","kind":"shorten"},
 {"title":"食い違いB","body":"本文B","kind":"other"},
 {"title":"デザインの節を短くまとめる提案","body":"元の節：docs/design.md ## 色","kind":"shorten"}]}
JSON
bash "$SCRIPTS_DIR/found-report.sh" audit "$F" > /dev/null
all=$(python3 -c "
import json,os
s=json.load(open(os.environ['MOCK_STATE']))
for n,m in sorted(s['issues_meta'].items()):
    print(m['title']+'|'+','.join(sorted(s['labels'][n]))+'|'+m['body'].replace(chr(10),' '))")
assert_eq "合計3件だけ作る" "3" "$(grep -c . <<< "$all")"
assert_contains "食い違いは ai:found,ai:plan" "$(grep '^食い違いA|' <<< "$all")" "|ai:found,ai:plan|"
assert_contains "短くする案は ai:found,ai:skip" "$(grep '^仕様書の保存' <<< "$all")" "|ai:found,ai:skip|"
assert_not_contains "短くする案に ai:plan は付かない" "$(grep '^仕様書の保存' <<< "$all")" "ai:plan"
assert_contains "短くする案の印" "$(grep '^仕様書の保存' <<< "$all")" "<!-- ai-found-kind: shorten -->"
assert_not_contains "食い違いに短くする印は付かない" "$(grep '^食い違いA|' <<< "$all")" "ai-found-kind"
assert_not_contains "枠を超えた分は作らない" "$all" "デザインの節"

echo "== 結果のファイルが無い・壊れている → 何もしない（失敗にしない）"
init_state '{}'
bash "$SCRIPTS_DIR/found-report.sh" audit "$MOCK_DIR/none.json" > /dev/null
assert_eq "終了コード 0" "0" "$?"
echo '{"findings": "x"}' > "$F"
bash "$SCRIPTS_DIR/found-report.sh" audit "$F" > /dev/null
assert_eq "壊れていても 0" "0" "$?"
out=$(bash "$SCRIPTS_DIR/found-report.sh" try "$MOCK_DIR/none.json" 2>&1)
assert_contains "結果が無いのを「問題なし」と言わない" "$out" "確かめられていません"
echo '{"findings": []}' > "$F"
assert_contains "0件なら問題なし" "$(bash "$SCRIPTS_DIR/found-report.sh" try "$F")" "見つけた問題はありません"
assert_contains "ワークフロー：結果が無ければ1回やり直す" "$(cat "$SCRIPTS_DIR/../workflows/claude-try.yml")" "hashFiles('.try/result.json') == ''"
assert_contains "監査役も" "$(cat "$SCRIPTS_DIR/../workflows/claude-audit.yml")" "hashFiles('.audit/result.json') == ''"
finish
