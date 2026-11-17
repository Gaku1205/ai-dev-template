#!/usr/bin/env bash
# 配布（sync-to-apps.sh）：配る中身（消す物・残す物・配らない物）と、配り先のPRの作り方を確かめる。
# 配り先は手元の git（SYNC_GIT_URL）、GitHub の API はこのテストの中の疑似 gh で真似る（呼ばれた物を calls.log に残す）
source "$(dirname "$0")/lib.sh"
ROOT="$(cd "$SCRIPTS_DIR/../.." && pwd)"
if ! command -v rsync > /dev/null 2>&1; then echo "rsync が無いので、配布のテストは飛ばします"; finish; exit $?; fi
if ! git -C "$ROOT" rev-parse HEAD > /dev/null 2>&1; then echo "git のリポジトリではないので、配布のテストは飛ばします"; finish; exit $?; fi
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/remotes/o"
sha="$(git -C "$ROOT" rev-parse --short HEAD)"

# 疑似 gh：開いているPR（state.json の pulls）を返し、作る・閉じる・ブランチを消すを記録する
cat > "$T/bin/gh" <<'PY'
#!/usr/bin/env python3
import sys, os, json, subprocess, re
T = os.environ["FT"]
open(f"{T}/calls.log", "a").write(" ".join(sys.argv[1:]) + "\n")
sp = f"{T}/state.json"
st = json.load(open(sp)) if os.path.exists(sp) else {"pulls": {}}
a = sys.argv[1:]; assert a[0] == "api"
q = None; method = "GET"; fields = {}; path = None
i = 1
while i < len(a):
    if a[i] in ("-q", "--jq"): q = a[i + 1]; i += 2
    elif a[i] == "-X": method = a[i + 1]; i += 2
    elif a[i] == "-f": k, v = a[i + 1].split("=", 1); fields[k] = v; i += 2
    else: path = a[i]; i += 1
if fields and method == "GET": method = "POST"
def out(o):
    sys.stdout.write(subprocess.run(["jq", "-r", q], input=json.dumps(o), capture_output=True, text=True).stdout if q else json.dumps(o))
m = re.match(r"repos/([^/]+/[^/]+)/(.*)$", path); repo, rest = m.group(1), m.group(2)
pulls = st["pulls"].setdefault(repo, [])
if os.environ.get("PULLS_FAIL") and rest.startswith("pulls?") and "head=" in rest:
    sys.stderr.write("HTTP 502\n"); sys.exit(1)
# OLDPULLS_FAIL=owner/repo：そのリポジトリの開いているPRの一覧（古い配布のPRを探す所）は読めない
if os.environ.get("OLDPULLS_FAIL") == repo and rest.startswith("pulls?") and "head=" not in rest:
    sys.stderr.write("HTTP 502\n"); sys.exit(1)
if method == "GET" and rest.startswith("pulls?"):
    lst = [p for p in pulls if p["state"] == "open"]
    hm = re.search(r"head=[^:]+:([^&]+)", rest)
    if hm: lst = [p for p in lst if p["head"]["ref"] == hm.group(1)]
    out(lst)
elif method == "POST" and rest == "pulls":
    pulls.append({"number": 100 + len(pulls), "state": "open", "head": {"ref": fields["head"]}, "title": fields["title"], "body": fields["body"], "base": fields["base"]})
    out({})
elif method == "PATCH" and rest.startswith("pulls/"):
    for p in pulls:
        if str(p["number"]) == rest.split("/")[1]: p["state"] = fields["state"]
    out({})
elif method == "DELETE": pass
else: sys.stderr.write("UNHANDLED " + path + "\n"); sys.exit(1)
json.dump(st, open(sp, "w"))
PY
chmod +x "$T/bin/gh"

# 配り先のリポジトリを作る。使い方：make_app 名前（中身は $T/seed-名前 に用意しておく）
make_app() {
  git -C "$T/seed-$1" init -q -b main && git -C "$T/seed-$1" add -A && git -C "$T/seed-$1" -c user.name=t -c user.email=t@t commit -qm seed
  git clone -q --bare "$T/seed-$1" "$T/remotes/o/$1.git"
}
sync() { env PATH="$T/bin:$PATH" FT="$T" GH_TOKEN=x SYNC_GIT_URL="$T/remotes/%s.git" "$@" bash "$SCRIPTS_DIR/sync-to-apps.sh" "${REPOS[@]}" 2>&1; }
# 配ったブランチの中のファイル
# bare のリポジトリは --git-dir で明示して読む（git の設定 safe.bareRepository=explicit の環境でも読めるように）
in_branch() { git --git-dir="$T/remotes/o/$1.git" ls-tree -r --name-only "pipeline-sync/$sha" 2> /dev/null; }
show() { git --git-dir="$T/remotes/o/$1.git" show "pipeline-sync/$sha:$2" 2> /dev/null; }
pulls() { python3 -c "import json,sys; print(' '.join(f\"{p['number']}:{p['head']['ref']}:{p['state']}\" for p in json.load(open('$T/state.json'))['pulls'].get('o/$1', [])))"; }

# 配り先 app：古いパイプライン・自分で足したワークフロー（残す物と消える物）・自分の CLAUDE.md とスキル
mkdir -p "$T/seed-app/.github/workflows" "$T/seed-app/.github/scripts" "$T/seed-app/docs" "$T/seed-app/.claude/skills/mine"
echo "古い" > "$T/seed-app/.github/scripts/after-ci.sh"
echo "古いだけの物" > "$T/seed-app/.github/scripts/gone.sh"
echo "自分の物（残す）" > "$T/seed-app/.github/workflows/my-job.yml"
echo "自分の物（書いていないので消える）" > "$T/seed-app/.github/workflows/other-job.yml"
printf 'workflows/my-job.yml' > "$T/seed-app/.github/sync-keep"
echo "アプリの決まり" > "$T/seed-app/CLAUDE.md"
echo "アプリの仕様" > "$T/seed-app/docs/spec.md"
echo "アプリのスキル" > "$T/seed-app/.claude/skills/mine/SKILL.md"
make_app app

echo "== 配る：配り先の main には入れず、pipeline-sync/<sha> のPRにする"
REPOS=(o/app)
out=$(sync); rc=$?
assert_eq "終了コード 0" "0" "$rc"
assert_contains "配ったと言う" "$out" "配った（PR）: o/app"
files=$(in_branch app)
assert_contains "スクリプトが入る" "$files" ".github/scripts/after-ci.sh"
assert_eq "中身はテンプレートの物" "$(cat "$SCRIPTS_DIR/after-ci.sh")" "$(show app .github/scripts/after-ci.sh)"
assert_contains "ワークフローが入る" "$files" ".github/workflows/ci.yml"
assert_contains "docs/pipeline.md が入る" "$files" "docs/pipeline.md"
assert_contains "docs/pipeline-setup.md も入る" "$files" "docs/pipeline-setup.md"
assert_not_contains "テンプレートに無い物は消える" "$files" ".github/scripts/gone.sh"
assert_not_contains "sync-keep に書いていない自分の物も消える" "$files" "other-job.yml"
assert_contains "sync-keep に書いた物は残る" "$files" ".github/workflows/my-job.yml"
assert_contains "sync-keep 自身も残る" "$files" ".github/sync-keep"
assert_not_contains "配り先の一覧（sync-targets）は配らない" "$files" ".github/sync-targets"
assert_not_contains "工場のIssueの雛形は配らない" "$files" "ISSUE_TEMPLATE/new-service.yml"
assert_eq "CLAUDE.md は変えない" "アプリの決まり" "$(show app CLAUDE.md)"
assert_eq "仕様書は変えない" "アプリの仕様" "$(show app docs/spec.md)"
assert_contains "配り先だけのスキルは残る" "$files" ".claude/skills/mine/SKILL.md"
if [ -d "$ROOT/.claude/skills" ]; then
  first_skill=$(cd "$ROOT" && find .claude/skills -type f | sort | head -1)
  assert_contains "共通のスキルが入る" "$files" "${first_skill#./}"
fi
assert_eq "main は変えない" "古い" "$(git --git-dir="$T/remotes/o/app.git" show main:.github/scripts/after-ci.sh)"
assert_eq "PRを1つ作る" "100:pipeline-sync/$sha:open" "$(pulls app)"
assert_contains "配布の印（進行役がレビューなしでマージする目印）" "$(cat "$T/state.json")" "<!-- pipeline-sync -->"
assert_contains "main に向ける" "$(cat "$T/state.json")" '"base": "main"'

echo "== 同じ版をもう一度配る：PRを増やさない"
out=$(sync)
assert_contains "更新と言う" "$out" "配った（PRを更新）: o/app"
assert_eq "PRは1つのまま" "100:pipeline-sync/$sha:open" "$(pulls app)"

echo "== 前の配布のPRが開いている：閉じて、新しい物に置き換える"
python3 - "$T/state.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
s["pulls"]["o/app"] = [{"number": 7, "state": "open", "head": {"ref": "pipeline-sync/0ld0ld0"}, "title": "", "body": "", "base": "main"},
                       {"number": 8, "state": "open", "head": {"ref": "claude/issue-3"}, "title": "", "body": "", "base": "main"}]
json.dump(s, open(sys.argv[1], "w"))
PY
: > "$T/calls.log"
sync > /dev/null
assert_contains "古い配布のPRを閉じる" "$(pulls app)" "7:pipeline-sync/0ld0ld0:closed"
assert_contains "古いブランチを消す" "$(cat "$T/calls.log")" "DELETE repos/o/app/git/refs/heads/pipeline-sync/0ld0ld0"
assert_contains "ほかのPRは閉じない" "$(pulls app)" "8:claude/issue-3:open"
assert_contains "新しいPRを作る" "$(pulls app)" "pipeline-sync/$sha:open"

echo "== もう同じ中身：何もしない"
mkdir -p "$T/seed-same"
bash "$SCRIPTS_DIR/sync-to-apps.sh" --local "$T/seed-same"
make_app same
REPOS=(o/same)
out=$(sync)
assert_contains "変更なしと言う" "$out" "変更なし"
assert_eq "PRを作らない" "" "$(pulls same)"
assert_eq "ブランチを作らない" "" "$(in_branch same)"

echo "== 取得できない配り先があっても、ほかには配る。全体は失敗で終わる"
rm -f "$T/state.json"
mkdir -p "$T/seed-two" && echo x > "$T/seed-two/README.md" && make_app two
REPOS=(o/nothing o/two)
out=$(sync); rc=$?
assert_eq "失敗で終わる" "1" "$rc"
assert_contains "取得できない物を知らせる" "$out" "::error::o/nothing を取得できません"
assert_contains "ほかには配る" "$out" "配った（PR）: o/two"

echo "== 古い配布のPRの一覧を読めない配り先があっても、そのアプリだけ飛ばして、後ろのアプリには配る"
rm -f "$T/state.json"
mkdir -p "$T/seed-three" && echo y > "$T/seed-three/README.md" && make_app three
mkdir -p "$T/seed-four" && echo z > "$T/seed-four/README.md" && make_app four
REPOS=(o/three o/four)
out=$(sync OLDPULLS_FAIL=o/three); rc=$?
assert_eq "失敗で終わる" "1" "$rc"
assert_contains "読めないアプリを知らせる" "$out" "::warning::o/three の古い配布のPRの一覧を読めない"
assert_not_contains "読めないアプリには、配ったと言わない" "$out" "配った（PR）: o/three"
assert_eq "読めないアプリにはPRを作らない" "" "$(pulls three)"
assert_contains "後ろのアプリには配る" "$out" "配った（PR）: o/four"
assert_eq "後ろのアプリにPRを作る" "100:pipeline-sync/$sha:open" "$(pulls four)"

echo "== PRがあるかを調べられない：「PRを更新した」と言わず、失敗で終わる"
REPOS=(o/two)
out=$(sync PULLS_FAIL=1); rc=$?
assert_eq "失敗で終わる" "1" "$rc"
assert_not_contains "更新したと言わない" "$out" "配った（PRを更新）"

echo "== --local：GitHub に触らず、配ったあとの形だけを作る"
mkdir -p "$T/local/.github" && echo "残す" > "$T/local/keep.txt"
: > "$T/calls.log"
env PATH="$T/bin:$PATH" FT="$T" bash "$SCRIPTS_DIR/sync-to-apps.sh" --local "$T/local"; rc=$?
assert_eq "終了コード 0" "0" "$rc"
assert_eq "gh を呼ばない" "" "$(cat "$T/calls.log")"
assert_eq "スクリプトが入る" "yes" "$([ -f "$T/local/.github/scripts/sync-to-apps.sh" ] && echo yes || echo no)"
assert_eq "docs/pipeline.md が入る" "yes" "$([ -f "$T/local/docs/pipeline.md" ] && echo yes || echo no)"
assert_eq "docs/pipeline-setup.md も入る" "yes" "$([ -f "$T/local/docs/pipeline-setup.md" ] && echo yes || echo no)"
assert_eq "docs/factory.md は配らない（本体だけ）" "no" "$([ -f "$T/local/docs/factory.md" ] && echo yes || echo no)"
assert_eq "ほかのファイルは触らない" "残す" "$(cat "$T/local/keep.txt")"

echo "== テンプレートにしか無い物（examples/）に頼るテストは、配り先で飛ばす書き方になっている（配られて、全部のアプリの CI を落とさないように）"
# テストは .github/scripts/tests/ ごと配られ、配り先の CI でも動く。配り先には examples/ が無い
bad=""
for t in "$TESTS_DIR"/test-*.sh; do
  [ "$(basename "$t")" = "$(basename "$0")" ] && continue
  if grep -q 'examples/' "$t" && ! grep -qE '^if \[ ! -[df] "\$ROOT/examples/[^"]*" \]; then echo "[^"]*飛ばします"; finish; exit \$\?; fi' "$t"; then
    bad="$bad $(basename "$t")"
  fi
done
assert_eq "examples/ を使うテストは、先頭で「無ければ飛ばす」" "" "${bad# }"

finish
