#!/usr/bin/env bash
# 「使ってみる役」「監査役」のAIに渡す、もう報告してある問題の一覧を作る（claude-try.yml・claude-audit.yml が、AIを動かす前に呼ぶ）。
#   found-known.sh 出力のファイル
# AIは毎回ちがう題名を付けるので、題名の重複（found-report.sh）だけでは、同じ問題の Issue が何度も作られる。
# 開いている ai:found の Issue と、直近 FOUND_KNOWN_DAYS（既定 14）日に閉じた物の題名を渡し、AIに「同じ物は書かない」と頼む。
# 題名はAIが書いた文なので、1行・100文字までにし、記号（` < > @）を落としてから渡す。最大 40 行。
# 読めなかったときも、空の一覧を書いて 0 で終わる（一覧が無いだけで、役は動かす）。
# 環境変数：GITHUB_REPOSITORY、GH_TOKEN（issues: read）、NOW（テスト用。UNIX秒）
set -uo pipefail
out="${1:?出力のファイルを指定}"
REPO="${GITHUB_REPOSITORY:?}"
now="${NOW:-$(date +%s)}"
since=$(date -u -d "@$((now - ${FOUND_KNOWN_DAYS:-14} * 86400))" +%Y-%m-%dT%H:%M:%SZ)
clean() { tr -d '`<>@\r' | cut -c1-300 | awk '{ print substr($0, 1, 100) }'; }

open=$(gh api "repos/$REPO/issues?state=open&labels=ai%3Afound&per_page=100" --paginate \
  --jq '.[] | select(.pull_request | not) | .title' 2> /dev/null || true)
closed=$(gh api "repos/$REPO/issues?state=closed&labels=ai%3Afound&since=$since&per_page=100" --paginate \
  --jq ".[] | select(.pull_request | not) | select((.closed_at // \"\") >= \"$since\") | .title" 2> /dev/null || true)
mkdir -p "$(dirname "$out")"
{
  echo "# もう報告してある問題（同じ物は、言い方が違っても書かない）"
  echo
  lines=$({ printf '%s\n' "$open" | awk 'NF { print "- （対応中）" $0 }'; printf '%s\n' "$closed" | awk 'NF { print "- （最近閉じた）" $0 }'; } | LC_ALL=C.UTF-8 clean | head -n 40)
  if [ -n "$lines" ]; then printf '%s\n' "$lines"; else echo "（まだありません）"; fi
} > "$out"
echo "もう報告してある問題：$(grep -c '^- ' "$out" || true) 件を $out に書きました"
exit 0
