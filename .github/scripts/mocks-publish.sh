#!/usr/bin/env bash
# 画面案（claude-mocks.yml の publish）：AIが作ったざっくり画面2案の形を確かめ、ai-mocks ブランチに置き、
# Issue に選択肢と質問を書いて答えを待つ（ai:mocks → ai:question）。AIは動かない。
#   入力：out/（mocks.json・mock-a.html・mock-a-1440.png・mock-a-390.png・b も）
#   環境変数：GH_TOKEN、GITHUB_REPOSITORY、ISSUE、NTFY_TOPIC など（通知）、ASSETS_REMOTE（テスト用。画像の置き場の git の場所）
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/pipeline-lib.sh"
repo="$GITHUB_REPOSITORY"
out="${OUT_DIR:-out}"
title=$(issue_title "$ISSUE" 2> /dev/null || echo "")
remove_label "$ISSUE" "ai:mocks" || true

if ! [ -f "$out/mocks.json" ] || [ -L "$out/mocks.json" ] || ! python3 "$here/factory-talk.py" check mocks "$out" > "$out/checked.json" 2> "$out/check.err"; then
  gh api "repos/$repo/issues/$ISSUE/comments" -f body="⚠️ 画面案を作れませんでした（$(head -c 300 "$out/check.err" 2> /dev/null || echo 'AIが画面を書きませんでした')）。案なしで進めるなら、このIssueに ai:plan を付け直してください。" > /dev/null
  add_label "$ISSUE" "ai:stuck" || true
  notify stuck "画面案を作れませんでした" "#${ISSUE} ${title}" 4
  exit 0
fi

# 置き場：ai-mocks ブランチの issue-<番号>/r<回>/（回は、前に置いた数 + 1）
a="${RUNNER_TEMP:-/tmp}/ai-mocks"
url="${ASSETS_REMOTE:-https://x-access-token:${GH_TOKEN}@github.com/${repo}.git}"
rm -rf "$a"
if git ls-remote --exit-code "$url" refs/heads/ai-mocks > /dev/null 2>&1; then
  git clone -q --depth 1 --branch ai-mocks "$url" "$a"
else
  git init -q "$a"; git -C "$a" checkout -q -b ai-mocks; git -C "$a" remote add origin "$url"
fi
n=1
while [ -d "$a/issue-$ISSUE/r$n" ]; do n=$((n + 1)); done
dir="issue-$ISSUE/r$n"
mkdir -p "$a/$dir"
for f in "$out"/mock-[ab].html "$out"/mock-[ab]-1440.png "$out"/mock-[ab]-390.png; do
  [ -f "$f" ] && [ ! -L "$f" ] && cp "$f" "$a/$dir/"
done
git -C "$a" add -A
git -C "$a" -c user.name=github-actions -c user.email=github-actions@users.noreply.github.com commit -qm "画面案：#$ISSUE（$n 回目）"
pushed=false
for _ in 1 2 3; do
  if git -C "$a" push -q origin ai-mocks 2> /dev/null; then pushed=true; break; fi
  git -C "$a" pull -q --rebase origin ai-mocks || true
done
[ "$pushed" = true ] || echo "::warning::画像を ai-mocks ブランチに置けませんでした（コメントの画像が出ません）"

raw="https://raw.githubusercontent.com/$repo/ai-mocks/$dir"
body=$(python3 - "$out/checked.json" "$raw" "$dir" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); raw, d = sys.argv[2], sys.argv[3]
L = ["<!-- ai-question -->", f"<!-- ai-mocks: {d} -->", "## 🖼 作る前に、画面を2案作りました（左が PC、右がスマホ）", ""]
for m in c["mocks"]:
    k = m["key"]
    L += [f"### {k.upper()}. {m['title']}", m["note"], "",
          f"<img src=\"{raw}/mock-{k}-1440.png\" width=\"560\" alt=\"{k.upper()} PC\"> <img src=\"{raw}/mock-{k}-390.png\" width=\"150\" alt=\"{k.upper()} スマホ\">", ""]
if c.get("questions"):
    L += ["## ❓ 質問", ""]
    for n, q in enumerate(c["questions"], 1):
        L.append(f"**Q{n}. {q['q']}**")
        L += [f"- {chr(65 + i)}. {o}{'（おすすめ）' if i == q['recommend'] else ''}" for i, o in enumerate(q["options"])]
        L.append("")
L += ["---", "答え方：`A`・`A の配置で B の色` のように（質問は `Q1はA`）。どちらも違えば「両方ちがう。もっと〇〇」と書くと出し直します。答えると、選んだ画面を目標にして作り始めます。"]
print("\n".join(L))
PY
)
gh api "repos/$repo/issues/$ISSUE/comments" -f body="$body" > /dev/null
add_label "$ISSUE" "ai:question"
notify question "画面を選んでください" "#${ISSUE} ${title}" 4
