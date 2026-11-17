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

echo "== 本番が main の最新に追いついていない（先頭に公開のステータスが無く、前のコミットにある）→ 動かさない"
init_state '{"homepage":"https://app.vercel.app","main_commit_date":"2026-11-16T03:00:00Z","main_commits":["h2","h1"],"statuses_by_sha":{"h2":[],"h1":[{"context":"Vercel","state":"success"}]}}'
gate try
assert_eq "run" "false" "$(val run)"
echo "== 先頭の公開が公開中 → 動かさない"
init_state '{"homepage":"https://app.vercel.app","main_commit_date":"2026-11-16T03:00:00Z","main_commits":["h2"],"statuses_by_sha":{"h2":[{"context":"deploy/vercel","state":"pending"}]}}'
gate try
assert_eq "run" "false" "$(val run)"
echo "== 先頭の公開が成功 → 動かす"
init_state '{"homepage":"https://app.vercel.app","main_commit_date":"2026-11-16T03:00:00Z","main_commits":["h2","h1"],"statuses_by_sha":{"h2":[{"context":"Vercel","state":"success"},{"context":"CI","state":"failure"}]}}'
gate try
assert_eq "run" "true" "$(val run)"
echo "== 先頭がパイプラインの更新だけのコミット（公開されない）で、前のアプリのコミットが成功 → 動かす"
init_state '{"homepage":"https://app.vercel.app","main_commit_date":"2026-11-16T03:00:00Z","main_commits":["h3","h2","h1"],"commit_files":{"h3":[".github/scripts/a.sh","docs/pipeline.md"],"h2":["src/app.ts"]},"statuses_by_sha":{"h3":[],"h2":[{"context":"Vercel","state":"success"}]}}'
gate try
assert_eq "run" "true" "$(val run)"
echo "== パイプラインの更新の前にアプリのコミットがあり、公開が無い（追いついていない）→ 動かさない"
init_state '{"homepage":"https://app.vercel.app","main_commit_date":"2026-11-16T03:00:00Z","main_commits":["h3","h2","h1"],"commit_files":{"h3":["docs/pipeline.md"],"h2":["src/app.ts"]},"statuses_by_sha":{"h3":[],"h2":[],"h1":[{"context":"Vercel","state":"success"}]}}'
gate try
assert_eq "run" "false" "$(val run)"
echo "== 手で動かしたら（FORCE=1）見ない"
init_state '{"homepage":"https://app.vercel.app","main_commit_date":"2026-11-16T03:00:00Z","main_commits":["h2","h1"],"statuses_by_sha":{"h2":[],"h1":[{"context":"Vercel","state":"success"}]}}'
FORCE=1 gate try
assert_eq "run" "true" "$(val run)"

echo "== 直近24時間の main の変更が、パイプラインの配布だけ（.github/・docs/pipeline.md・.claude/）→ 動かさない"
SYNC_ONLY='{"homepage":"https://app.vercel.app","main_commit_date":"2026-11-16T03:00:00Z","main_commits":["h3","h2","h1"],"commit_dates":{"h1":"2026-11-10T03:00:00Z"},"commit_files":{"h3":[".github/scripts/a.sh","docs/pipeline.md"],"h2":[".claude/skills/x/SKILL.md",".github/workflows/ci.yml"],"h1":["src/app.ts"]},"statuses_by_sha":{"h3":[],"h2":[],"h1":[{"context":"Vercel","state":"success"}]}}'
init_state "$SYNC_ONLY"
gate try
assert_eq "run" "false" "$(val run)"
assert_contains "理由" "$(val reason)" "パイプラインの更新"
assert_eq "URL は出す" "https://app.vercel.app" "$(val url)"
echo "== 手で動かしたら（FORCE=1）、配布だけの日でも動かす"
FORCE=1 gate try
assert_eq "run" "true" "$(val run)"
echo "== 配布のコミットに混じって、アプリのコミットが1つでもある → 動かす（本番も追いついている）"
init_state '{"homepage":"https://app.vercel.app","main_commit_date":"2026-11-16T03:00:00Z","main_commits":["h3","h2","h1"],"commit_dates":{"h1":"2026-11-10T03:00:00Z"},"commit_files":{"h3":["docs/pipeline.md"],"h2":["src/app.ts","docs/pipeline.md"],"h1":["src/app.ts"]},"statuses_by_sha":{"h3":[],"h2":[{"context":"Vercel","state":"success"}]}}'
gate try
assert_eq "run" "true" "$(val run)"
assert_eq "同じコミットの中身は1回しか読まない（h3・h2 の2回）" "2" "$(python3 -c "import json,os;print(json.load(open(os.environ['MOCK_STATE'])).get('commit_calls',0))")"
echo "== アプリのコミットはあるが、本番が追いついていない → 動かさない（#102 の確かめはそのまま）"
init_state '{"homepage":"https://app.vercel.app","main_commit_date":"2026-11-16T03:00:00Z","main_commits":["h3","h2","h1"],"commit_dates":{"h1":"2026-11-10T03:00:00Z"},"commit_files":{"h3":["docs/pipeline.md"],"h2":["src/app.ts"],"h1":["src/app.ts"]},"statuses_by_sha":{"h3":[],"h2":[],"h1":[{"context":"Vercel","state":"success"}]}}'
gate try
assert_eq "run" "false" "$(val run)"
assert_contains "理由は追いつき" "$(val reason)" "追いついていない"
echo "== docs/pipeline.md に似た名前のアプリのファイル（docs/pipeline.md.bak・docs/spec.md）は、アプリの変更"
init_state '{"homepage":"https://app.vercel.app","main_commit_date":"2026-11-16T03:00:00Z","main_commits":["h2"],"commit_files":{"h2":["docs/spec.md"]},"statuses_by_sha":{"h2":[]}}'
gate try
assert_eq "run" "true" "$(val run)"
echo "== 変わったファイルを読めなかった（API の失敗）→ アプリの変更として動かす（黙って試さなくならない）"
init_state "$SYNC_ONLY"
state_py "s['commit_fail']=['h3','h2']; s['statuses_by_sha']['h3']=[{'context':'Vercel','state':'success'}]"
gate try
assert_eq "run" "true" "$(val run)"
echo "== 直近24時間のコミットが30件以上 → 中身を読まずに動かす（API の回数を増やさない）"
init_state "$(python3 -c "
import json
c=['c%d'%i for i in range(30)]
print(json.dumps({'homepage':'https://app.vercel.app','main_commit_date':'2026-11-16T03:00:00Z','main_commits':c,'commit_files':{x:['docs/pipeline.md'] for x in c},'statuses_by_sha':{'c0':[{'context':'Vercel','state':'success'}]}}))")"
gate try
assert_eq "run" "true" "$(val run)"

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

echo "== 開いている ai:found が多いとき（直る前に、同じ問題がちがう題名で積み上がる）：新しく作らない"
init_state '{"labels":{"1":["ai:found","ai:plan"],"2":["ai:found","ai:implement"],"3":["ai:found","ai:queue"],"4":["ai:found"],"5":["ai:found","ai:stuck"],"6":["ai:found","ai:review"],"7":["ai:found","ai:skip"]}}'
echo '{"findings":[{"title":"新しい問題","body":"本文"}]}' > "$F"
out=$(bash "$SCRIPTS_DIR/found-report.sh" try "$F")
assert_contains "作らないと言う" "$out" "開いている ai:found の Issue が 6 件あるので、今回は新しく作りません"
assert_eq "Issue は増えない" "0" "$(python3 -c "import json,os;s=json.load(open(os.environ['MOCK_STATE']));print(len(s.get('issues_meta',{})))")"
state_py "s['issues_meta']={'6':{'state':'closed','title':'t'}}"
out=$(bash "$SCRIPTS_DIR/found-report.sh" try "$F")
assert_contains "1件片付いたら（人間の返事待ちの ai:skip は数えない）、また作る" "$out" "作った Issue：1件"
out=$(FOUND_OPEN_MAX=2 bash "$SCRIPTS_DIR/found-report.sh" try "$F")
assert_contains "上限は FOUND_OPEN_MAX で変えられる" "$out" "今回は新しく作りません"

echo "== もう報告してある問題の一覧（found-known.sh）：開いている物と、最近閉じた物の題名をAIに渡す"
K="$MOCK_DIR/known/known.md"
init_state '{"labels":{"1":["ai:found","ai:plan"],"2":["ai:found"],"3":["ai:found"],"4":["bug"],"5":["ai:found"]},
  "issues_meta":{"1":{"title":"スマホで表がはみ出す","state":"open"},"2":{"title":"戻るボタンが無い","state":"closed","closed_at":"2026-11-10T00:00:00Z"},
                 "3":{"title":"古い問題","state":"closed","closed_at":"2026-10-01T00:00:00Z"},"4":{"title":"人間が書いた別の Issue","state":"open"},
                 "5":{"title":"`rm -rf` して @owner に <b>知らせる</b>","state":"open"}}}'
NOW=$(date -u -d 2026-11-16T12:00:00Z +%s) bash "$SCRIPTS_DIR/found-known.sh" "$K" > /dev/null; rc=$?
assert_eq "終了コード 0" "0" "$rc"
known=$(cat "$K")
assert_contains "開いている物" "$known" "- （対応中）スマホで表がはみ出す"
assert_contains "最近閉じた物" "$known" "- （最近閉じた）戻るボタンが無い"
assert_not_contains "14日より前に閉じた物は入れない" "$known" "古い問題"
assert_not_contains "ai:found ではない Issue は入れない" "$known" "人間が書いた"
assert_contains "記号を落とす（AIが書いた題名を、そのまま指示にしない）" "$known" "- （対応中）rm -rf して owner に b知らせる/b"
init_state '{}'
bash "$SCRIPTS_DIR/found-known.sh" "$K" > /dev/null
assert_contains "無ければ、無いと書く" "$(cat "$K")" "（まだありません）"
mkdir -p "$MOCK_DIR/ngbin" && printf '#!/usr/bin/env bash\necho "HTTP 502" >&2\nexit 1\n' > "$MOCK_DIR/ngbin/gh" && chmod +x "$MOCK_DIR/ngbin/gh"
PATH="$MOCK_DIR/ngbin:$PATH" bash "$SCRIPTS_DIR/found-known.sh" "$K" > /dev/null 2>&1; rc=$?
assert_eq "読めなくても 0 で終わる（役は動かす）" "0" "$rc"
assert_contains "読めなくても、空の一覧を書く" "$(cat "$K")" "（まだありません）"

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
