#!/usr/bin/env bash
# 配布のPR（pipeline-sync/*）のCIが落ちたとき、同じ配布（同じ sha）の失敗を、テンプレート側の Issue 1つにまとめる。
# 使い方: sync-failure-report.sh PR番号
# 必要な環境変数: GITHUB_REPOSITORY（配り先のリポジトリ）、GH_TOKEN、HEAD_BRANCH（あれば。印の無い古いPRの sha を読む）
# 終了コード：0 = 通知を送ってよい（最初の1件・まとめられなかったとき）／ 1 = 送らない（まとめ先の Issue にコメントした）
# テンプレートの Issue を読めない・作れないとき（権限なし・印なし）は、通知が消えないよう 0（送ってよい）を返す。
set -uo pipefail

pr="${1:?PR番号を指定}"
app="${GITHUB_REPOSITORY:?}"

body=$(gh api "repos/$app/pulls/$pr" -q '.body // ""' 2> /dev/null) || exit 0
# 印：<!-- pipeline-sync-src: owner/repo@sha -->
read -r src sha < <(printf '%s' "$body" | sed -n 's/.*pipeline-sync-src: \([^@ ]*\)@\([0-9a-f]*\) -->.*/\1 \2/p' | head -n 1) || true
[ -n "${src:-}" ] || exit 0
# 印の無い古いPRも、sha だけはブランチ名 pipeline-sync/<sha> から読める
if [ -z "${sha:-}" ]; then
  sha="${HEAD_BRANCH:-}"; sha="${sha#pipeline-sync/}"
fi
grep -Eq '^[0-9a-f]+$' <<< "$sha" || exit 0

title="配布 ${sha} が配り先で落ちています"

# まとめ先（同じタイトルの Issue のうち、いちばん番号が小さい物）。読めなければ失敗
find_target() {
  local list
  list=$(gh api "repos/$src/issues?state=all&per_page=100" --paginate -q ".[] | select(.title == \"$title\") | .number" 2> /dev/null) || return 1
  # 1件も無いときは grep が1で終わるので、「読めなかった」と取り違えないよう、ここでは失敗にしない
  printf '%s\n' "$list" | { grep -E '^[0-9]+$' || true; } | sort -n | head -n 1
}

target=$(find_target) || exit 0
mine=""
if [ -z "$target" ]; then
  issue_body="テンプレート（\`${src}\`）の main のCIは通っていますが、配布 \`${sha}\` が配り先のリポジトリで落ちています。テンプレートの CI では見つからない、配り先の形でだけ起きる不具合の可能性があります。

落ちた配り先は、下のコメントに1行ずつ書きます。原因を直したら、人間がこの Issue を閉じてください（自動では閉じません）。"
  mine=$(gh api "repos/$src/issues" -f title="$title" -f body="$issue_body" -q .number 2> /dev/null) || exit 0
  # 同時に落ちた別アプリが同時に作ったときは、いちばん番号が小さい Issue をまとめ先にする。
  # 作った直後は、一覧に自分の Issue がまだ出ないことがある（GitHub の一覧は少し遅れる）。そのときは自分の Issue をまとめ先にする
  # （ここで止めると、落ちた配り先が1行も書かれない Issue だけが残る。ai-dev-template#298・#300）
  target=$(find_target) || target=""
  if [ -z "$target" ] || [ "$target" -gt "$mine" ]; then target="$mine"; fi
fi

if [ "$mine" = "$target" ]; then
  # 自分が作った（まとめ先になった）ので、この1件は通知する。落ちたアプリも1行残す
  gh api "repos/$src/issues/$target/comments" -f body="\`${app}\` PR #${pr}：CIが落ちました" > /dev/null \
    || echo "::warning::${src} の Issue #${target} に、落ちた配り先（${app} PR #${pr}）を書けませんでした"
  exit 0
fi

# すでにあった（または、同時に作って番号が大きかった）：重複した自分の Issue は閉じ、まとめ先に1行コメントして、通知は送らない
if [ -n "$mine" ]; then
  gh api -X PATCH "repos/$src/issues/$mine" -f state=closed > /dev/null 2>&1 || true
fi
gh api "repos/$src/issues/$target/comments" -f body="\`${app}\` PR #${pr}：CIが落ちました" > /dev/null 2>&1 || exit 0
echo "配布 ${sha} の失敗は、${src} の Issue #${target} にまとめました（通知は送りません）"
exit 1
