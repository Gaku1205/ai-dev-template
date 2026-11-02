#!/usr/bin/env bash
# 工場のデザイン担当が、自由に使える写真（CC0・パブリックドメインだけ）を取ってくる。
#   .github/scripts/fetch-photos.sh "<英語の検索語>" [枚数（1〜6、既定 4）]
# Openverse（https://openverse.org、鍵は要らない）で探し（届かない・見つからなければ Wikimedia Commons で探し）、横幅 1200px 以上の写真を public/photos/ に入れる（作っている画面からそのまま /photos/… で使える）。
# 出どころは public/photos/CREDITS.md に足す（CC0・パブリックドメインは表記の義務は無いが、元を残す）。
# 置き場所は決まっていて変えられない。合わせて 20 枚まで、1枚 5MB まで、JPEG・PNG・WebP だけ。
# 環境変数（テスト用）：OPENVERSE_API（既定 https://api.openverse.org）、COMMONS_API（既定 https://commons.wikimedia.org/w/api.php）、PHOTOS_DIR（既定 public/photos）
set -uo pipefail
API="${OPENVERSE_API:-https://api.openverse.org}"
COMMONS_API="${COMMONS_API:-https://commons.wikimedia.org/w/api.php}"
DIR="${PHOTOS_DIR:-public/photos}"
MAX_TOTAL=20
MAX_BYTES=5242880

query="${1:-}"
want="${2:-4}"
if [ -z "$query" ] || [ "${#query}" -gt 100 ] || ! [[ "$want" =~ ^[1-6]$ ]]; then
  echo "使い方：.github/scripts/fetch-photos.sh \"<英語の検索語（100文字まで）>\" [枚数 1〜6]" >&2
  exit 2
fi
mkdir -p "$DIR"
have=$(find "$DIR" -maxdepth 1 -type f \( -name '*.jpg' -o -name '*.png' -o -name '*.webp' \) | wc -l)
if [ "$have" -ge "$MAX_TOTAL" ]; then
  echo "もう ${MAX_TOTAL} 枚あります。要らない写真を消してから取ってください" >&2
  exit 1
fi

slug=$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//' | cut -c1-30)
[ -n "$slug" ] || slug=photo
UA="ai-dev-template-factory/1.0 (https://github.com/Gaku1205/ai-dev-template)"
# 1. Openverse（CC0・パブリックドメインだけを探せる）
list=""
if res=$(curl -sS --max-time 30 -A "$UA" -G "$API/v1/images/" \
  --data-urlencode "q=$query" --data-urlencode "license=cc0,pdm" --data-urlencode "size=large" \
  --data-urlencode "mature=false" --data-urlencode "page_size=20" 2> /dev/null); then
  list=$(printf '%s' "$res" | jq -c '.results // [] | .[] | select((.width // 0) >= 1200 and (.license == "cc0" or .license == "pdm"))
    | {url, title: (.title // ""), creator: (.creator // "不明"), license, page: (.foreign_landing_url // ""), w: .width, h: .height}' 2> /dev/null)
else
  echo "Openverse に届きませんでした。Wikimedia Commons で探します" >&2
fi
# 2. 見つからない・届かないときは Wikimedia Commons（鍵は要らない。CC0・パブリックドメインの物だけ。大きい物は 2400px に縮めた物を取る）
if [ -z "$list" ]; then
  if res=$(curl -sS --max-time 30 -A "$UA" -G "$COMMONS_API" \
    --data-urlencode "action=query" --data-urlencode "format=json" --data-urlencode "formatversion=2" \
    --data-urlencode "generator=search" --data-urlencode "gsrnamespace=6" --data-urlencode "gsrlimit=30" \
    --data-urlencode "gsrsearch=$query filetype:bitmap" \
    --data-urlencode "prop=imageinfo" --data-urlencode "iiprop=url|size|mime|extmetadata" --data-urlencode "iiurlwidth=2400" 2> /dev/null); then
    list=$(printf '%s' "$res" | jq -c '.query.pages // [] | sort_by(.index) | .[] | .imageinfo[0] as $i | select($i != null)
      | ($i.extmetadata.LicenseShortName.value // "" | ascii_downcase) as $lic
      | select(($i.width // 0) >= 1200 and ($i.mime | test("^image/(jpeg|png|webp)$")))
      | select($lic | test("^(cc0|public domain|pd\\b|pd-)"))
      | {url: ($i.thumburl // $i.url), title: (.title | sub("^File:"; "") | sub("\\.[A-Za-z]+$"; "")),
         creator: (($i.extmetadata.Artist.value // "不明") | gsub("<[^>]*>"; "") | .[0:80]),
         license: (if ($lic | startswith("cc0")) then "cc0" else "pdm" end), page: ($i.descriptionurl // ""),
         w: $i.width, h: $i.height}' 2> /dev/null)
  else
    echo "Wikimedia Commons にも届きませんでした" >&2
  fi
fi
if [ -z "$list" ]; then
  echo "「$query」で、使える写真が見つかりませんでした。検索語を変えてください" >&2
  exit 1
fi

got=0
n=$((have + 1))
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
while IFS= read -r item; do
  [ "$got" -ge "$want" ] && break
  [ $((have + got)) -ge "$MAX_TOTAL" ] && break
  url=$(printf '%s' "$item" | jq -r .url)
  case "$url" in https://*) ;; *) continue ;; esac
  curl -sSL --max-time 60 --max-filesize "$MAX_BYTES" -A "$UA" -o "$tmp" "$url" 2> /dev/null || continue
  size=$(wc -c < "$tmp")
  [ "$size" -gt 10000 ] && [ "$size" -le "$MAX_BYTES" ] || continue
  magic=$(head -c 12 "$tmp" | od -An -tx1 | tr -d ' \n')
  case "$magic" in
    ffd8ff*) ext=jpg ;;
    89504e470d0a1a0a*) ext=png ;;
    52494646????????57454250) ext=webp ;;
    *) continue ;;
  esac
  name=$(printf '%02d-%s.%s' "$n" "$slug" "$ext")
  cp "$tmp" "$DIR/$name"
  printf '%s' "$item" | jq -r --arg f "$name" '"- `\($f)`：\(.title)（\(.creator)、\(if .license == "cc0" then "CC0" else "パブリックドメイン" end)、\(.w)×\(.h)）\(.page)"' >> "$DIR/CREDITS.md"
  echo "$DIR/$name（$(printf '%s' "$item" | jq -r '"\(.w)×\(.h)"')）"
  got=$((got + 1))
  n=$((n + 1))
done <<< "$list"
if [ "$got" -eq 0 ]; then
  echo "写真を取れませんでした（どれも取れないか、形が違いました）。検索語を変えてください" >&2
  exit 1
fi
echo "${got} 枚取りました。Read で見て、良い物だけを画面で使ってください（画面で名前を使った写真だけが新しいリポジトリに入ります）"
