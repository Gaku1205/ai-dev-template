#!/usr/bin/env bash
# ワークフローの渡し忘れの確認（#304）：スクリプトが読む Variable を、呼ぶ側のワークフローが渡しているか。
#   設定したのにスクリプトまで届かないと、黙って既定の動きになる（PARALLEL_SCOPE が実際にそうだった）。
#   1. docs/pipeline-setup.md の表で「Variable」とある名前のうち、.github/scripts/ が読む物は、どこかのワークフローで vars.名前 として渡す
#   2. request_fix_or_stop を run: で呼ぶ段は、env に直す回数の Variable（MAX_AUTO_FIX・MAX_AUTO_FIX_TOTAL・MAX_CONFLICT_FIX）を持つ
source "$(dirname "$0")/lib.sh"
WORKFLOWS="$(cd "$SCRIPTS_DIR/../workflows" && pwd)"
SETUP_DOC="$SCRIPTS_DIR/../../docs/pipeline-setup.md"

# 知っている抜け（理由つき）。ワークフローが直ったら、ここから消す。消せば、以後は渡し忘れでこのテストが落ちる
#   #304 の2つ（PARALLEL_SCOPE・visual-update.yml の直す回数）は、マネージャーがワークフローを直したので空
KNOWN_UNPASSED_VARS=""
KNOWN_MISSING_FIX_ENV=""

# 引数：ワークフローのフォルダ 設定の文書 スクリプトのフォルダ 知っている抜け（Variable） 知っている抜け（ワークフロー）
# 出力：1行ずつ「unpassed:名前」か「fixenv:ファイル:段の名前:足りない名前」。無ければ何も出さない
check_vars() {
  python3 - "$@" <<'PY'
import os, re, sys, yaml
wf, doc, scripts, known_vars, known_fix = sys.argv[1:6]
known_vars = known_vars.split(); known_fix = known_fix.split()

# 1. 表で Variable とある名前（先頭の列の `名前`・`名前` ... をすべて拾う）
names = []
for line in open(doc, encoding="utf-8"):
    cells = [c.strip() for c in line.split("|")]
    if len(cells) > 3 and cells[2] == "Variable":
        names += re.findall(r"`([A-Z][A-Z0-9_]+)`", cells[1])
text = ""
for root, dirs, files in os.walk(scripts):
    dirs[:] = [d for d in dirs if d != "tests"]
    for f in files:
        if f.endswith((".sh", ".py", ".mjs")):
            text += open(os.path.join(root, f), encoding="utf-8", errors="ignore").read()
flows = {f: open(os.path.join(wf, f), encoding="utf-8").read() for f in sorted(os.listdir(wf)) if f.endswith(".yml")}
alltext = "\n".join(flows.values())
for n in sorted(set(names)):
    reads = re.search(r"\$\{?" + n + r"\b", text)
    passed = re.search(r"vars\." + n + r"\b", alltext)
    if reads and not passed and n not in known_vars:
        print("unpassed:" + n)

# 2. request_fix_or_stop を run: で呼ぶ段
need = ["MAX_AUTO_FIX", "MAX_AUTO_FIX_TOTAL", "MAX_CONFLICT_FIX"]
for f in flows:
    if f in known_fix: continue
    d = yaml.safe_load(flows[f]) or {}
    for jn, job in (d.get("jobs") or {}).items():
        for st in job.get("steps") or []:
            if "request_fix_or_stop" in str(st.get("run", "")):
                env = st.get("env") or {}
                for k in need:
                    if ("vars." + k) not in str(env.get(k, "")):
                        print("fixenv:%s:%s:%s" % (f, st.get("name", jn), k))
PY
}

echo "== 今のワークフロー：スクリプトが読む Variable は渡してあり、直す回数を使う段は直す回数の Variable を持つ（知っている抜けを除く）"
assert_eq "渡し忘れが無い" "" "$(check_vars "$WORKFLOWS" "$SETUP_DOC" "$SCRIPTS_DIR" "$KNOWN_UNPASSED_VARS" "$KNOWN_MISSING_FIX_ENV")"

echo "== わざと抜いた見本で、渡し忘れを見つけられる"
fx=$(mktemp -d); mkdir -p "$fx/wf" "$fx/scripts"
cat > "$fx/doc.md" <<'EOF'
| 名前 | 種類 | 既定値 | 意味 |
| --- | --- | --- | --- |
| `FOO_LIMIT` | Variable | 1 | 渡し忘れる物 |
| `BAR_LIMIT` | Variable | 1 | 渡してある物 |
| `BAZ_TOKEN` | Secret | なし | Variable ではない |
EOF
cat > "$fx/scripts/a.sh" <<'EOF'
echo "${FOO_LIMIT:-1} ${BAR_LIMIT:-1} ${BAZ_TOKEN:-}"
EOF
cat > "$fx/wf/a.yml" <<'EOF'
name: a
on: push
env:
  BAR_LIMIT: ${{ vars.BAR_LIMIT }}
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: 直させる（足りない）
        env:
          MAX_AUTO_FIX: ${{ vars.MAX_AUTO_FIX }}
        run: request_fix_or_stop 1 abc "x" "y"
      - name: 直させる（そろっている）
        env:
          MAX_AUTO_FIX: ${{ vars.MAX_AUTO_FIX }}
          MAX_AUTO_FIX_TOTAL: ${{ vars.MAX_AUTO_FIX_TOTAL }}
          MAX_CONFLICT_FIX: ${{ vars.MAX_CONFLICT_FIX }}
        run: request_fix_or_stop 1 abc "x" "y"
EOF
sample=$(check_vars "$fx/wf" "$fx/doc.md" "$fx/scripts" "" "")
assert_eq "見本：読むのに渡していない Variable と、足りない直す回数だけが出る" \
  "$(printf 'unpassed:FOO_LIMIT\nfixenv:a.yml:直させる（足りない）:MAX_AUTO_FIX_TOTAL\nfixenv:a.yml:直させる（足りない）:MAX_CONFLICT_FIX')" "$sample"
assert_eq "見本：知っている抜けに入れれば出ない" "" "$(check_vars "$fx/wf" "$fx/doc.md" "$fx/scripts" "FOO_LIMIT" "a.yml")"
rm -rf "$fx"

finish
