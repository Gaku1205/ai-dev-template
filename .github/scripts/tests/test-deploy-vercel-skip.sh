#!/usr/bin/env bash
# 「寝なくてよいか」の判定（deploy-vercel-skip.sh）：寝ずに終わってよいときだけ 0、それ以外は 1
# 疑似 gh は test-deploy-vercel.sh と同じ作り
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'PY'
#!/usr/bin/env python3
import sys, os, json, subprocess, re
if os.environ.get("GH_FAIL"):
    sys.stderr.write("gh: boom\n"); sys.exit(1)
st = json.load(open(os.environ["FT"] + "/state.json"))
a = sys.argv[1:]; assert a[0] == "api"
q = a[a.index("-q") + 1] if "-q" in a else None
path = [x for x in a[1:] if x.startswith("repos/")][0]
base = re.sub(r"^repos/o/r", "", path.split("?")[0])
def out(o):
    sys.stdout.write(subprocess.run(["jq", "-r", q], input=json.dumps(o), capture_output=True, text=True).stdout if q else json.dumps(o))
commits = st["commits"]
if base == "/commits/main": out({"sha": commits[0]["sha"]})
elif base == "/commits": out([{"sha": c["sha"]} for c in commits])
elif m := re.match(r"/commits/(\w+)/status$", base):
    c = [c for c in commits if c["sha"] == m.group(1)][0]
    out({"statuses": [{"context": "Vercel", "state": "success" if c["state"] == "ignored" else c["state"], "description": "Canceled by Ignored Build Step" if c["state"] == "ignored" else "Deployment has completed", "updated_at": "2026-01-01T00:00:00Z"}] if c.get("state") else []})
elif m := re.match(r"/compare/(\w+)\.\.\.(\w+)$", base): out({"files": [{"filename": f} for f in st["changed"]]})
else: sys.stderr.write("UNHANDLED " + path + "\n"); sys.exit(1)
PY
chmod +x "$T/bin/gh"
run() { # 状態のJSON [追加の環境変数...]
  printf '%s' "$1" > "$T/state.json"
  env PATH="$T/bin:$PATH" FT="$T" GITHUB_REPOSITORY=o/r GH_TOKEN=x VERCEL_TOKEN=v "${@:2}" bash "$SCRIPTS_DIR/deploy-vercel-skip.sh" > /dev/null 2>&1
  echo $?
}

echo "== 寝ずに終わってよい（0）"
assert_eq "パイプラインの更新しか変わっていない" "0" "$(run '{"commits":[{"sha":"c3"},{"sha":"c2","state":"success"}],"changed":[".github/scripts/x.sh","docs/pipeline.md"]}')"
assert_eq "最新がもう公開済み" "0" "$(run '{"commits":[{"sha":"c3","state":"success"},{"sha":"c2"}],"changed":["src/a.ts"]}')"

echo "== 寝て、deploy-vercel.sh に任せる（1）"
assert_eq "アプリのファイルも変わった" "1" "$(run '{"commits":[{"sha":"c3"},{"sha":"c2","state":"success"}],"changed":["src/a.ts",".github/x.yml"]}')"
assert_eq "公開に成功したコミットが見つからない" "1" "$(run '{"commits":[{"sha":"c3"},{"sha":"c2"}],"changed":[".github/x.yml"]}')"
assert_eq "飛ばされた物は公開に数えない" "1" "$(run '{"commits":[{"sha":"c3"},{"sha":"c2","state":"ignored"}],"changed":[".github/x.yml"]}')"
assert_eq "gh が失敗" "1" "$(run '{"commits":[{"sha":"c3"},{"sha":"c2","state":"success"}],"changed":[".github/x.yml"]}' GH_FAIL=1)"
assert_eq "VERCEL_TOKEN が無い" "1" "$(run '{"commits":[{"sha":"c3"},{"sha":"c2","state":"success"}],"changed":[".github/x.yml"]}' VERCEL_TOKEN=)"
assert_eq "VERCEL_FORCE=1" "1" "$(run '{"commits":[{"sha":"c3"},{"sha":"c2","state":"success"}],"changed":[".github/x.yml"]}' VERCEL_FORCE=1)"

finish
