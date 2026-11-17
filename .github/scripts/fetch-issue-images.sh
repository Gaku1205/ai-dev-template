#!/usr/bin/env bash
# Issue の本文に貼られた画像（リールのスクショ・好きなサイトの画面など）を取ってきて、AIに渡す。
# AIが動く前に動かす（AIはネットに出ずに画像を見られる）：工場のデザイン担当（factory.yml の design）、
# 企画AI・実装AI（issue-images-prompt.sh から。claude-plan.yml・claude-implement.yml）。
#   BODY（Issue の本文）を読み、![..](URL) と <img src="URL"> の https の画像を、OUT_DIR（既定 factory-refs/issue）に 01.png のように入れる。
#   github.com の画像（Issue に貼った物）だけ、GH_TOKEN を付けて取る（ほかのサイトには鍵を送らない）。
#   このリポジトリ（GITHUB_REPOSITORY）のファイルの画像（github.com/<o>/<r>/raw/<ref>/<path>・…/blob/…?raw=true・
#   raw.githubusercontent.com/<o>/<r>/<ref>/<path>。agent-desk が issue-images ブランチに置く画像）は、Contents API で取る
#   （非公開のリポジトリでも、鍵を api.github.com にだけ送って取れる。github.com/…/raw は鍵のヘッダーでは開けず、
#   別のサイトへ回されると curl は鍵を外すため）。ref に / を含むブランチは扱わない（最初の区切りまでを ref とみなす）
#   10 枚まで、1枚 10MB まで、JPEG・PNG・WebP・GIF だけ。どこから取ったかを INDEX.md に残す
set -uo pipefail
OUT="${OUT_DIR:-factory-refs/issue}"
MAX=10
MAX_BYTES=10485760

urls=$(printf '%s' "${BODY:-}" | python3 -c '
import re, sys
text = sys.stdin.read()
# 書かれた順に拾う（Markdown の画像と <img>）
pat = re.compile(r"!\[[^\]]*\]\((https://[^\s)]+)\)|<img[^>]*\bsrc=[\"\x27](https://[^\"\x27\s>]+)", re.I)
found = [m.group(1) or m.group(2) for m in pat.finditer(text)]
seen = []
for u in found:
    if u not in seen:
        seen.append(u)
print("\n".join(seen))
')
if [ -z "$urls" ]; then
  echo "Issue に画像は貼られていません"
  exit 0
fi
mkdir -p "$OUT"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
# このリポジトリのファイルの画像なら「ref<TAB>path」を出す（Contents API で取る）。違えば何も出さない
repo_file() { # url
  printf '%s' "$1" | REPO="${GITHUB_REPOSITORY:-}" python3 -c '
import os, re, sys, urllib.parse
u = sys.stdin.read().strip()
repo = os.environ.get("REPO", "").lower()
p = urllib.parse.urlsplit(u)
m = None
if p.netloc == "github.com":
    m = re.match(r"^/([^/]+)/([^/]+)/(?:raw|blob)/([^/]+)/(.+)$", p.path)
    if m and "/blob/" in p.path and "raw=true" not in p.query:
        m = None
elif p.netloc == "raw.githubusercontent.com":
    m = re.match(r"^/([^/]+)/([^/]+)/([^/]+)/(.+)$", p.path)
if m and repo and f"{m.group(1)}/{m.group(2)}".lower() == repo:
    path = urllib.parse.unquote(m.group(4))
    if ".." not in path.split("/"):
        print(urllib.parse.quote(m.group(3), safe="") + "\t" + urllib.parse.quote(path, safe="/"))
'
}
n=0
while IFS= read -r url; do
  [ "$n" -ge "$MAX" ] && break
  rf=$(repo_file "$url")
  if [ -n "$rf" ]; then
    # gh api は中身を文字として扱い、画像では壊れる（transform: short source buffer）ので curl で取る
    api="https://api.github.com/repos/$GITHUB_REPOSITORY/contents/${rf#*$'\t'}?ref=${rf%%$'\t'*}"
    curl -sSLf --proto '=https' --max-time 60 --max-filesize "$MAX_BYTES" -A "ai-dev-template-factory/1.0" -H "Accept: application/vnd.github.raw+json" -H "Authorization: Bearer ${GH_TOKEN:-}" -o "$tmp" "$api" 2> /dev/null || { echo "取れませんでした：$url"; continue; }
  else
    host=$(printf '%s' "$url" | sed -E 's#^https://([^/]+).*#\1#')
    auth=()
    [ "$host" = github.com ] && [ -n "${GH_TOKEN:-}" ] && auth=(-H "Authorization: token $GH_TOKEN")
    curl -sSL --proto '=https' --max-time 60 --max-filesize "$MAX_BYTES" -A "ai-dev-template-factory/1.0" "${auth[@]}" -o "$tmp" "$url" 2> /dev/null || { echo "取れませんでした：$url"; continue; }
  fi
  size=$(wc -c < "$tmp")
  [ "$size" -gt 100 ] && [ "$size" -le "$MAX_BYTES" ] || { echo "大きさが合いません：$url"; continue; }
  case "$(head -c 12 "$tmp" | od -An -tx1 | tr -d ' \n')" in
    ffd8ff*) ext=jpg ;;
    89504e470d0a1a0a*) ext=png ;;
    52494646????????57454250) ext=webp ;;
    474946383?61*) ext=gif ;;
    *) echo "画像ではありません：$url"; continue ;;
  esac
  n=$((n + 1))
  name=$(printf '%02d.%s' "$n" "$ext")
  cp "$tmp" "$OUT/$name"
  printf -- '- `%s`：%s\n' "$name" "$url" >> "$OUT/INDEX.md"
  echo "$OUT/$name"
done <<< "$urls"
echo "Issue に貼られた画像を ${n} 枚取りました"
