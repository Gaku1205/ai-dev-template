#!/usr/bin/env bash
# 一覧のページ送り：100件を超えても、101件目からの Issue・PR を見落とさない（per_page=100 だけだと、黙って見えなくなる）。
# 疑似 gh は本物と同じく、--paginate が無ければ1ページ目（per_page 件）だけを返す
source "$(dirname "$0")/lib.sh"
setup_mock
cd "$SCRIPTS_DIR/../.." || exit 1

# 番号 from〜to の Issue を、同じラベルで作る JSON の中身（"1":["x"],"2":["x"],…）
many() { python3 -c "
import json, sys
a, b, labels = int(sys.argv[1]), int(sys.argv[2]), [l for l in sys.argv[3].split(',') if l]
print(','.join('\"%d\":%s' % (n, json.dumps(labels)) for n in range(a, b + 1)))" "$1" "$2" "$3"; }
pages() { python3 -c "import json,os;print(json.load(open(os.environ['MOCK_STATE'])).get('api_pages',0))"; }

echo "== 疑似 gh：--paginate が無ければ1ページ目だけ、あれば全部（本物と同じ）"
init_state '{"labels":{'"$(many 1 150 ai:queue)"'}}'
assert_eq "ページ送りなし：100件まで" "100" "$(gh api "repos/o/r/issues?state=open&per_page=100" -q 'length')"
assert_eq "ページ送りあり・-q：ページごとに jq が当たる" "100 50" "$(gh api "repos/o/r/issues?state=open&per_page=100" --paginate -q 'length' | paste -sd' ' -)"
assert_eq "api_list：全部を1つの配列に" "150" "$(run_lib 'api_list "repos/$REPO/issues?state=open&per_page=100" | jq length')"

echo "== 数える：101件目からも数える"
assert_eq "ラベルの付いた Issue の数" "150" "$(run_lib 'count_open_issues_with_label ai:queue')"
init_state '{"pulls":'"$(python3 -c "
import json
print(json.dumps([{'number': n, 'state': 'open', 'head': {'sha': 's%d' % n, 'ref': 'feature/%d' % n}} for n in range(1, 121)]))")"'}'
assert_eq "開いているPRの数" "120" "$(run_lib 'count_open_prs')"

echo "== 順番待ち：2ページ目にある急ぎ（priority:high）を先に始める（並べ替えは全体で）"
# 一覧は新しい順（番号の大きい順）に返る。急ぎの #5 は2ページ目にある
init_state '{"labels":{'"$(python3 -c "
print(','.join('\"%d\":[\"ai:queue\"]' % n for n in range(130, 5, -1)))")"',"5":["ai:queue","priority:high"],"4":["ai:queue"]}}'
out=$(run_lib 'start_next_in_queue')
assert_contains "急ぎの #5 を始める" "$out" "順番待ちの #5 を実装に回しました"
assert_eq "#5 が実装に回る" "ai:implement,priority:high" "$(labels_of 5)"
assert_eq "番号の大きい物は待ったまま" "ai:queue" "$(labels_of 130)"

echo "== 見張り役：101件目からの Issue も見る（ラベルの無い Issue を企画へ・ラベルの矛盾を直す）"
# 1〜120 は ai:skip（何もしない物）。そのあとに、ラベルの無い古い Issue（#201）と、矛盾したラベルの Issue（#202）
init_state '{"labels":{'"$(many 1 120 ai:skip)"',"201":[],"202":["ai:queue","ai:implement"]},"issue_updated":{"201":"'"$(ago 60)"'","202":"'"$(ago 1)"'"},"pulls":[{"number":300,"state":"open","mergeable_state":"clean","head":{"sha":"x","ref":"claude/issue-202-x","repo":{"full_name":"o/r"}},"updated_at":"'"$(ago 1)"'"}]}'
run_script watchdog.sh > /dev/null
assert_eq "101件目からの、ラベルの無い Issue を企画に回す" "ai:plan" "$(labels_of 201)"
assert_eq "101件目からの、ラベルの矛盾を直す" "ai:implement" "$(labels_of 202)"
assert_eq "ai:skip の物は触らない" "ai:skip" "$(labels_of 1)"

echo "== API の回数：100件までなら、一覧を読む回数は増えない。開いている Issue の一覧は、1回の見張りで1度だけ読む"
init_state '{"labels":{'"$(many 1 3 ai:skip)"'}}'
run_script watchdog.sh > /dev/null
few=$(pages)
init_state '{"labels":{'"$(many 1 150 ai:skip)"'}}'
run_script watchdog.sh > /dev/null
assert_eq "150件に増えて余分に読むのは、開いている Issue の一覧の2ページ目の1回だけ" "$((few + 1))" "$(pages)"

echo "== 再開：101件目からのPRも、この Issue のPRとして見つける（企画をやり直さない）"
init_state '{"labels":{"54":[]},"pulls":'"$(python3 -c "
import json
prs = [{'number': 1000 + n, 'state': 'open', 'body': '', 'head': {'sha': 's%d' % n, 'ref': 'feature/%d' % n}} for n in range(1, 111)]
prs.append({'number': 58, 'state': 'open', 'body': 'Closes #54', 'head': {'sha': 'abc', 'ref': 'fix/x'}})
print(json.dumps(prs))")"'}'
out=$(NUMBER=54 IS_PR=false run_script resume.sh)
assert_contains "PRが開いているので、企画し直さない" "$out" "この Issue のPRが開いているので、企画はやり直しません"
assert_eq "ai:plan を付けない" "" "$(labels_of 54)"

echo "== 進行中の作業が触るファイル：変えたファイルが100を超えるPRも、全部を見る"
init_state '{"labels":{},"pulls":[{"number":9,"state":"open","head":{"sha":"x","ref":"feature/big"}}],"files":'"$(python3 -c "
import json
print(json.dumps(['src/gen/f%03d.ts' % n for n in range(1, 131)]))")"'}'
out=$(run_lib 'inflight_touches')
assert_eq "130個とも出る" "130" "$(printf '%s\n' "$out" | grep -c '^src/gen/')"
assert_contains "101個目からも入っている" "$out" "src/gen/f130.ts"

finish
