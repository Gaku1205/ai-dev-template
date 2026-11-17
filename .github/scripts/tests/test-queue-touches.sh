#!/usr/bin/env bash
# 順番待ち：触るファイルが進行中の作業と重ならない物は並べて始める・priority:high を先に（ai-dev-template #72）
source "$(dirname "$0")/lib.sh"
setup_mock
next() { run_script queue-next.sh; }
body() { printf '本文\n<!-- ai-touches: %s -->' "$1"; }
state_with() { # JSON（labels・issues_meta・pulls・files・contents）
  init_state "$1"
}

echo "== 部品：触るファイルの読み取りと重なり"
source "$SCRIPTS_DIR/pipeline-lib.sh"; trap - ERR; set +e
assert_eq "印から読む" "$(printf 'src/a.ts\nsrc/b/')" "$(touches_from_body "$(body ' src/a.ts , ./src/b/ ')")"
assert_eq "印が無ければ空" "" "$(touches_from_body "本文だけ")"
paths_overlap "src/a.ts" "src/a.ts"; assert_eq "同じファイル" "0" "$?"
paths_overlap "src/lib/" "src/lib/x.ts"; assert_eq "フォルダの中" "0" "$?"
paths_overlap "src/lib/x.ts" "src/lib/"; assert_eq "逆向きも" "0" "$?"
paths_overlap "src/lib/a.ts" "src/lib/b.ts"; assert_eq "別のファイルは重ならない" "1" "$?"
paths_overlap "src/components/A.tsx" "src/app/page.tsx" 0; assert_eq "見た目のテストが無ければ画面どうしも並べる" "1" "$?"
paths_overlap "src/components/A.tsx" "src/app/page.tsx" 1; assert_eq "見た目のテストがあれば画面どうしは重なり" "0" "$?"

echo "== 進行中の物が無い：priority:high を先に始める（番号が大きくても）"
state_with '{"labels":{"3":["ai:queue"],"9":["ai:queue","priority:high"]}}'
next > /dev/null
assert_contains "#9 が実装へ" "$(labels_of 9)" "ai:implement"
assert_eq "#3 は待ち" "ai:queue" "$(labels_of 3)"

echo "== 実装中の物と触るファイルが重ならない：並べて始める（上限 2 を明示）"
state_with "$(python3 -c "
import json
print(json.dumps({'labels':{'1':['ai:implement'],'3':['ai:queue'],'4':['ai:queue']},
 'issues_meta':{'1':{'title':'a','body':'''$(body src/lib/a.ts)'''},'3':{'title':'b','body':'''$(body src/lib/b.ts)'''},'4':{'title':'c','body':'''$(body src/lib/c.ts)'''}}}))")"
out=$(MAX_PARALLEL=2 next)
assert_contains "#3 を始める" "$(labels_of 3)" "ai:implement"
assert_eq "上限なので #4 は待つ" "ai:queue" "$(labels_of 4)"
assert_contains "理由" "$(comments_of 3)" "重ならないので、並べて始めます"

echo "== 既定の上限は3：進行中が2件なら3件目は並べて始め、進行中が3件なら重ならなくても待つ"
assert_eq "既定は3" "3" "$(env -u MAX_PARALLEL bash -c "source '$SCRIPTS_DIR/pipeline-lib.sh'; echo \"\$MAX_PARALLEL\"" 2>&1 | tail -1)"
assert_eq "after-plan.sh も今の上限の関数を使う" "1" "$(grep -c 'current_parallel)' "$SCRIPTS_DIR/after-plan.sh")"
state_with "$(python3 -c "
import json
print(json.dumps({'labels':{'1':['ai:implement'],'2':['ai:implement'],'3':['ai:queue'],'4':['ai:queue']},
 'issues_meta':{'1':{'title':'a','body':'''$(body src/lib/a.ts)'''},'2':{'title':'a2','body':'''$(body src/lib/a2.ts)'''},'3':{'title':'b','body':'''$(body src/lib/b.ts)'''},'4':{'title':'c','body':'''$(body src/lib/c.ts)'''}}}))")"
out=$(next)
assert_contains "3件目の #3 を並べて始める" "$(labels_of 3)" "ai:implement"
assert_eq "4件目の #4 は待つ" "ai:queue" "$(labels_of 4)"
assert_contains "上限の表示は3" "$out" "並列の上限（3）"
echo "== MAX_PARALLEL を環境変数で指定すれば、その値が優先される（4なら4件目も始める）"
state_with "$(python3 -c "
import json
print(json.dumps({'labels':{'1':['ai:implement'],'2':['ai:implement'],'3':['ai:queue'],'4':['ai:queue']},
 'issues_meta':{'1':{'title':'a','body':'''$(body src/lib/a.ts)'''},'2':{'title':'a2','body':'''$(body src/lib/a2.ts)'''},'3':{'title':'b','body':'''$(body src/lib/b.ts)'''},'4':{'title':'c','body':'''$(body src/lib/c.ts)'''}}}))")"
MAX_PARALLEL=4 next > /dev/null
assert_contains "#3 を始める" "$(labels_of 3)" "ai:implement"
assert_contains "#4 も始める" "$(labels_of 4)" "ai:implement"

echo "== 重なる物は待ち、重ならない次の物を始める"
state_with "$(python3 -c "
import json
print(json.dumps({'labels':{'1':['ai:implement'],'3':['ai:queue'],'4':['ai:queue']},
 'issues_meta':{'1':{'title':'a','body':'''$(body src/lib/)'''},'3':{'title':'b','body':'''$(body src/lib/b.ts)'''},'4':{'title':'c','body':'''$(body docs/x.md)'''}}}))")"
out=$(next)
assert_eq "#3 は重なるので待つ" "ai:queue" "$(labels_of 3)"
assert_contains "#4 を始める" "$(labels_of 4)" "ai:implement"
assert_contains "待つ理由を出す" "$out" "#3：進行中の作業と触るファイルが重なる"

echo "== 印の無い物は、進行中の物があれば待つ（今までどおり）"
state_with "$(python3 -c "
import json
print(json.dumps({'labels':{'1':['ai:implement'],'3':['ai:queue']},
 'issues_meta':{'1':{'title':'a','body':'''$(body src/lib/a.ts)'''},'3':{'title':'b','body':'本文'}}}))")"
next > /dev/null
assert_eq "#3 は待つ" "ai:queue" "$(labels_of 3)"

echo "== 数えないPRしか開いていない：印の無い Issue も始める（ai:stuck のPR）"
state_with '{"labels":{"20":["ai:stuck"],"3":["ai:queue"]},
 "pulls":[{"number":20,"state":"open","head":{"ref":"pipeline-sync/abc","sha":"s"},"labels":[{"name":"ai:stuck"}]}],"files":["src/lib/a.ts"],
 "issues_meta":{"3":{"title":"b","body":"本文"}}}'
next > /dev/null
assert_contains "#3 が実装へ" "$(labels_of 3)" "ai:implement"

echo "== 数えないPRしか開いていない：印の無い Issue も始める（待ちが長い ai:hold のPR）"
review='{"id":901,"issue":"20","user":{"login":"github-actions[bot]"},"created_at":"2026-11-17T00:00:00Z","updated_at":"2026-11-17T00:00:00Z","body":"## Code review\n\nNo issues found."}'
state_with '{"labels":{"20":["ai:hold"],"3":["ai:queue"]},
 "events":{"20":[{"event":"labeled","label":{"name":"ai:hold"},"created_at":"'"$(ago 90)"'"}]},
 "pulls":[{"number":20,"state":"open","mergeable_state":"clean","head":{"ref":"claude/issue-9-x","sha":"abc"},"labels":[{"name":"ai:hold"}]}],
 "files":["src/lib/a.ts"],"comments":['"$review"'],
 "issues_meta":{"3":{"title":"b","body":"本文"}}}'
next > /dev/null
assert_contains "#3 が実装へ" "$(labels_of 3)" "ai:implement"

echo "== 数えるPRが開いている：印の無い Issue は今までどおり待つ"
state_with '{"labels":{"20":[],"3":["ai:queue"]},
 "pulls":[{"number":20,"state":"open","head":{"ref":"pipeline-sync/abc","sha":"s"},"labels":[]}],"files":["src/lib/a.ts"],
 "issues_meta":{"3":{"title":"b","body":"本文"}}}'
next > /dev/null
assert_eq "#3 は待つ" "ai:queue" "$(labels_of 3)"

echo "== 印の無い Issue が2つ待っている：1つだけ始める"
state_with '{"labels":{"20":["ai:stuck"],"3":["ai:queue"],"4":["ai:queue"]},
 "pulls":[{"number":20,"state":"open","head":{"ref":"pipeline-sync/abc","sha":"s"},"labels":[{"name":"ai:stuck"}]}],"files":["src/lib/a.ts"],
 "issues_meta":{"3":{"title":"b","body":"本文"},"4":{"title":"c","body":"本文"}}}'
next > /dev/null
assert_contains "#3 が実装へ" "$(labels_of 3)" "ai:implement"
assert_eq "#4 は待つ" "ai:queue" "$(labels_of 4)"

echo "== 進行中の物の触るファイルが分からない：並べない"
state_with "$(python3 -c "
import json
print(json.dumps({'labels':{'1':['ai:implement'],'3':['ai:queue']},
 'issues_meta':{'1':{'title':'a','body':'本文'},'3':{'title':'b','body':'''$(body src/lib/b.ts)'''}}}))")"
out=$(next)
assert_eq "#3 は待つ" "ai:queue" "$(labels_of 3)"
assert_contains "理由" "$out" "分からない物がある"

echo "== open のPRは、変えたファイルで比べる（配布のPRなど、AI以外のPRも）"
state_with "$(python3 -c "
import json
print(json.dumps({'labels':{'3':['ai:queue'],'4':['ai:queue']},
 'pulls':[{'number':20,'state':'open','head':{'ref':'pipeline-sync/abc','sha':'s'},'labels':[]}],'files':['.github/workflows/ci.yml'],
 'issues_meta':{'3':{'title':'b','body':'''$(body .github/workflows/)'''},'4':{'title':'c','body':'''$(body src/lib/c.ts)'''}}}))")"
next > /dev/null
assert_eq "#3 は配布と重なるので待つ" "ai:queue" "$(labels_of 3)"
assert_contains "#4 を始める" "$(labels_of 4)" "ai:implement"

echo "== 見た目のテストがあるリポジトリ：画面どうしは並べない"
state_with "$(python3 -c "
import json
print(json.dumps({'labels':{'1':['ai:implement'],'3':['ai:queue']},'contents':{'main':{'tests/visual':'[]'}},
 'issues_meta':{'1':{'title':'a','body':'''$(body src/components/A.tsx)'''},'3':{'title':'b','body':'''$(body src/app/page.tsx)'''}}}))")"
next > /dev/null
assert_eq "#3 は待つ" "ai:queue" "$(labels_of 3)"
finish
