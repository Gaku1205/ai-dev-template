#!/usr/bin/env bash
# 企画AIに「いま進行中の作業」を渡す前に、信頼できる書き手の物だけの中身を集める（他人の PR の差分・本文を AI に読ませない）。
#
# 企画AI（claude-plan.yml）は、清書するIssueと同時に作業してよいかを決めるため、開いている ai:implement の Issue と
# 開いている PR を見比べる。以前は AI が自分で `gh pr list`・`gh pr diff` を動かしていたので、他人の PR（fork・dependabot など）の
# タイトル・差分に書かれた指示が、Issue を書き換えられる企画AIに届いた（2026-11-24 のセキュリティ監査）。
# そこで AI が動く前にこのスクリプトでファイルを作って渡し、`gh pr list`・`gh pr diff`・`gh issue list` は使わせない。
#
# 信頼できる書き手の決まりは trusted-comments.sh と同じ：
#   （1）author_association が OWNER・MEMBER・COLLABORATOR （2）github-actions[bot]・claude[bot]
#   （3）パイプラインの App（performed_via_github_app.id が PIPELINE_APP_ID と同じ。PR には付かないので main が apps/<slug> で番号を引いて付ける）
# 出す物：
#   - Issue：信頼できる人の物は、タイトルと本文（本文の最後の ai-touches の印を含む）。それ以外は番号だけ
#   - PR：信頼できる人の物は、タイトルと変えたファイルの名前。それ以外は番号と、変えたファイルの名前だけ
#     （ファイルの名前は、英数字と . _ / - 以外の文字を _ に置き換える。名前に指示を書かれても文にならないように）
#   差分の中身は、だれの物でも渡さない（同時に作業してよいかは、触るファイルで決まる）
#
# 使い方：inflight.sh <いま清書する Issue の番号>   → 標準出力に書く（ファイルにするなら > file）
# 環境変数：GH_TOKEN、GITHUB_REPOSITORY、PIPELINE_APP_ID（任意）
# 読めなかったとき（gh の失敗・形が違う）は、何も出さず失敗（終了コード 1）で終わる。黙って全部は渡さない。
#
# 判定は inflight_render（入力の JSON と App の番号から出力が決まる純粋な関数）。gh を呼ぶのは main だけ。
set -u

# 入力：{"current": 番号, "issues": [...], "pulls": [{..., "files": ["a", ...]}]}（標準入力）、引数 1：PIPELINE_APP_ID。出力：AIに渡す文章
inflight_render() {
  jq -r --arg app "${1:-}" '
    def trusted:
      ((.author_association // "") | IN("OWNER", "MEMBER", "COLLABORATOR"))
      or ((.user.login // "") | IN("github-actions[bot]", "claude[bot]"))
      or ($app != "" and ((.performed_via_github_app.id // "") | tostring) == $app);
    def safe: gsub("[^A-Za-z0-9._/-]"; "_");
    .current as $cur
    | [.issues[] | select(.pull_request == null) | select(.number != $cur)] as $is
    | .pulls as $ps
    | "# いま進行中の作業（ai:implement の Issue と、開いている PR）",
      "\n## ai:implement の Issue",
      ( if ($is | length) == 0 then "\n（無い）" else empty end ),
      ( $is[] | if trusted then
            "\n### Issue #\(.number)：\(.title // "")\n\n\(.body // "")"
          else
            "\n### Issue #\(.number)（信頼できない人が作ったので、タイトルと本文は省略）"
          end ),
      "\n## 開いている PR",
      ( if ($ps | length) == 0 then "\n（無い）" else empty end ),
      ( $ps[] | (if trusted then "\n### PR #\(.number)：\(.title // "")" else "\n### PR #\(.number)（信頼できない人が作ったので、タイトルは省略）" end),
          "\n変えたファイル：",
          ( if ((.files // []) | length) == 0 then "（読めなかった・無い）" else ((.files // [])[] | "- \(safe)") end ) )
  '
}

# PR には performed_via_github_app が付かないので、名前が「〜[bot]」の書き手は App の番号を公開の API で引いて付ける（引けなければ付けない）
fix_app() {
  local all="$1" app="$2" login id
  [ -n "$app" ] || { printf '%s\n' "$all"; return; }
  while IFS= read -r login; do
    [ -n "$login" ] || continue
    id=$(gh api "apps/${login%\[bot\]}" --jq .id 2> /dev/null) || continue
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    all=$(jq --arg l "$login" --argjson id "$id" '
      def fix: if (.user.login // "") == $l and .performed_via_github_app == null then .performed_via_github_app = {id: $id} else . end;
      .issues |= map(fix) | .pulls |= map(fix)' <<< "$all") || return 1
  done < <(jq -r '[.issues[], .pulls[]] | map(select(.performed_via_github_app == null) | .user.login // "" | select(endswith("[bot]")) | select(IN("github-actions[bot]", "claude[bot]") | not)) | unique | .[]' <<< "$all")
  printf '%s\n' "$all"
}

main() {
  local n="${1:-}" repo="${GITHUB_REPOSITORY:-}" issues pulls nums p files all result
  case "$n" in '' | *[!0-9]*) echo "使い方：inflight.sh <Issue の番号>" >&2; return 1 ;; esac
  [ -n "$repo" ] || { echo "GITHUB_REPOSITORY が無い" >&2; return 1; }
  issues=$(gh api --paginate --slurp "repos/$repo/issues?state=open&labels=ai:implement&per_page=100") || { echo "Issue を読めなかった" >&2; return 1; }
  issues=$(jq '[.[] | if type == "array" then .[] else . end]' <<< "$issues") || return 1
  pulls=$(gh api --paginate --slurp "repos/$repo/pulls?state=open&per_page=100") || { echo "PR を読めなかった" >&2; return 1; }
  pulls=$(jq '[.[] | if type == "array" then .[] else . end]' <<< "$pulls") || return 1
  # PR ごとに、変えたファイルの名前だけを足す（読めなければ空のまま。中身は渡さない）
  nums=$(jq -r '.[].number' <<< "$pulls") || return 1
  for p in $nums; do
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    files=$(gh api --paginate --slurp "repos/$repo/pulls/$p/files?per_page=100" 2> /dev/null | jq -c '[.[] | if type == "array" then .[] else . end | .filename // empty]' 2> /dev/null) || files='[]'
    [ -n "$files" ] || files='[]'
    pulls=$(jq --argjson n "$p" --argjson f "$files" 'map(if .number == $n then .files = $f else . end)' <<< "$pulls") || return 1
  done
  # JSON は引数ではなく標準入力で渡す（引数1つは約128KBまでで、本文が長いと超える）
  all=$( { printf '%s\n' "$issues"; printf '%s\n' "$pulls"; } | jq -s --argjson cur "$n" '{current: $cur, issues: .[0], pulls: .[1]}') || return 1
  all=$(fix_app "$all" "${PIPELINE_APP_ID:-}") || return 1
  result=$(inflight_render "${PIPELINE_APP_ID:-}" <<< "$all") || { echo "文章を組み立てられなかった" >&2; return 1; }
  [ -n "$result" ] || { echo "文章が空" >&2; return 1; }
  printf '%s\n' "$result"
}

# source されたとき（テスト）は動かさない
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
