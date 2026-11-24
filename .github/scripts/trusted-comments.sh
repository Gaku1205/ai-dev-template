#!/usr/bin/env bash
# AIに Issue・PR の文章を渡す前に、信頼できる書き手の物だけを集める（他人のコメントを AI に読ませない）。
#
# 公開リポジトリでは、他人がオーナーの Issue・PR にコメントできる。`gh issue view --comments` で全部読ませると、
# 他人のコメントに書かれた指示が AI に届く。そこで AI が動く前にこのスクリプトでファイルを作って渡し、`--comments` は使わせない。
#
# 残す書き手（docs/pipeline.md「`@claude` を呼べるのは…」と同じ決まり）：
#   （1）author_association が OWNER・MEMBER・COLLABORATOR の人
#   （2）github-actions[bot]・claude[bot]（pipeline.md の trusted_author）
#   （3）パイプラインの App が書いた物（performed_via_github_app.id が PIPELINE_APP_ID と同じ。名前ではなく番号で見分ける。空なら（3）は無し）
# それ以外のコメントは、中身も書き手の名前も出さず、件数だけを書く。本文（Issue・PR の説明）も、書いた人が信頼できないときは、
# タイトルと一緒に出さない（同じ人が書いた物なので）。
#
# 使い方：trusted-comments.sh <Issue または PR の番号>   → 標準出力に書く（ファイルにするなら > file）
#         trusted-comments.sh --count-untrusted <番号>     → 信頼できない書き手の物の数だけを出す（下の「数える」）
#
# 数える（--count-untrusted）：実装AI（claude-implement.yml）と修正AI（claude-mention.yml）は、AIのアクションが自分で
# Issue・PR の本文とコメントを全部集めてAIに渡す（このスクリプトのファイルを渡せない）。そこで、AIを動かす前に、
# 信頼できない書き手の物（本文・コメント・PRなら行へのコメントとレビューの文も）が何件あるかを数え、1件でもあればAIを動かさずに
# 人間に回す（中身を確かめて消してから、ai:stuck を外すと続く）。数は 0 以上の整数1つ。読めなかったときは何も出さず失敗（終了コード 1）
# 環境変数：GH_TOKEN、GITHUB_REPOSITORY、PIPELINE_APP_ID（任意）
# 読めなかったとき（gh の失敗・形が違う）は、何も出さず失敗（終了コード 1）で終わる。黙って全部は渡さない。
#
# 判定は trusted_render（入力の JSON と App の番号から出力が決まる純粋な関数）。gh を呼ぶのは main だけ。
set -u

# 入力：{"issue": {...}, "comments": [...]}（標準入力）、引数 1：PIPELINE_APP_ID。出力：AIに渡す文章
trusted_render() {
  jq -r --arg app "${1:-}" '
    def trusted:
      ((.author_association // "") | IN("OWNER", "MEMBER", "COLLABORATOR"))
      or ((.user.login // "") | IN("github-actions[bot]", "claude[bot]"))
      or ($app != "" and ((.performed_via_github_app.id // "") | tostring) == $app);
    .issue as $i
    | [.comments[] | select(trusted)] as $ok
    | (([.comments[] | select(trusted | not)] | length)) as $hidden
    | ( if ($i | trusted) then
          "# \($i.title // "")\n\n作者：\($i.user.login // "不明")\n\n## 本文\n\n\($i.body // "")"
        else
          "# （信頼できない人が作ったので、タイトルと本文は省略）"
        end ),
      "\n## コメント",
      ( $ok[] | "\n### \(.user.login // "不明")（\(.created_at // "")）\n\n\(.body // "")" ),
      ( if $hidden > 0 then "\n（信頼できない人のコメント \($hidden) 件は省略）" else empty end ),
      ( if ($ok | length) == 0 and $hidden == 0 then "\n（コメントは無い）" else empty end )
  '
}

# 入力：{"issue": {...}, "comments": [...]}（標準入力。comments には行へのコメント・レビューも入れてよい）、引数 1：PIPELINE_APP_ID。
# 出力：信頼できない書き手の物の数（本文の作者が信頼できなければ 1 を足す。中身の無いレビュー（承認だけ等）は数えない）
untrusted_count() {
  jq -r --arg app "${1:-}" '
    def trusted:
      ((.author_association // "") | IN("OWNER", "MEMBER", "COLLABORATOR"))
      or ((.user.login // "") | IN("github-actions[bot]", "claude[bot]"))
      or ($app != "" and ((.performed_via_github_app.id // "") | tostring) == $app);
    (if (.issue | trusted) then 0 else 1 end)
    + ([.comments[] | select((.body // "") != "") | select(trusted | not)] | length)
  '
}

count_main() {
  local n="${1:-}" repo="${GITHUB_REPOSITORY:-}" issue comments extra="[]" more result
  case "$n" in '' | *[!0-9]*) echo "使い方：trusted-comments.sh --count-untrusted <番号>" >&2; return 1 ;; esac
  [ -n "$repo" ] || { echo "GITHUB_REPOSITORY が無い" >&2; return 1; }
  issue=$(gh api "repos/$repo/issues/$n") || { echo "#$n を読めなかった" >&2; return 1; }
  comments=$(gh api --paginate --slurp "repos/$repo/issues/$n/comments?per_page=100") || { echo "#$n のコメントを読めなかった" >&2; return 1; }
  # PR なら、行へのコメントとレビューの文も数える（AIのアクションはこれも読む）
  if [ "$(jq -r '.pull_request != null' <<< "$issue")" = true ]; then
    more=$(gh api --paginate --slurp "repos/$repo/pulls/$n/comments?per_page=100") || { echo "#$n の行へのコメントを読めなかった" >&2; return 1; }
    extra=$(jq -s '[.[] | if (.[0] | type) == "array" then add else . end // [] | .[]]' <<< "$more") || return 1
    more=$(gh api --paginate --slurp "repos/$repo/pulls/$n/reviews?per_page=100") || { echo "#$n のレビューを読めなかった" >&2; return 1; }
    extra=$(jq -s '.[0] + [.[1] | if (.[0] | type) == "array" then add else . end // [] | .[]]' <(printf '%s\n' "$extra") <(printf '%s\n' "$more")) || return 1
  fi
  local all
  all=$( { printf '%s\n' "$issue"; printf '%s\n' "$comments"; printf '%s\n' "$extra"; } \
    | jq -s '{issue: .[0], comments: ((.[1] | if (.[0] | type) == "array" then add else . end // []) + .[2])}') || { echo "#$n を数えられなかった" >&2; return 1; }
  # PR の本文・レビューなどには performed_via_github_app が付かない（App が作った PR でも null）。
  # そこで、App の番号が付いた書き込み（コメントには付く）から「この App のボットの名前」を知り、同じ名前で番号の無い物に番号を付ける。
  # 「〜[bot]」の名前は App にしか付けられず、App ごとに1つなので、番号の付いた書き込みと同じ名前なら同じ App（名前ではなく番号で見分ける決まりのまま）。
  # 名前は、この Issue・PR のコメント → リポジトリの最近のコメント100件 → 公開の API（apps/<slug>。非公開の App は github.token では引けない）の順で探す。
  # 見つからなければ付けない（信頼しない側に倒す）
  local app="${PIPELINE_APP_ID:-}" login id bots recent
  if [ -n "$app" ]; then
    bots=$(jq -c --arg app "$app" '[.comments[] | select(((.performed_via_github_app.id // "") | tostring) == $app) | .user.login // "" | select(endswith("[bot]"))] | unique' <<< "$all") || return 1
    if [ "$(jq -r --argjson b "$bots" '[.issue, .comments[]] | map(select(.performed_via_github_app == null) | .user.login // "" | select(endswith("[bot]")) | select(IN("github-actions[bot]", "claude[bot]") | not) | select(IN($b[]) | not)) | length' <<< "$all")" != 0 ]; then
      if recent=$(gh api "repos/$repo/issues/comments?sort=created&direction=desc&per_page=100" 2> /dev/null); then
        bots=$(jq -c --arg app "$app" --argjson b "$bots" '$b + [.[] | select(((.performed_via_github_app.id // "") | tostring) == $app) | .user.login // "" | select(endswith("[bot]"))] | unique' <<< "$recent" 2> /dev/null || printf '%s' "$bots")
      fi
    fi
    while IFS= read -r login; do
      [ -n "$login" ] || continue
      if jq -e --arg l "$login" 'index($l) != null' <<< "$bots" > /dev/null; then
        id=$app
      else
        id=$(gh api "apps/${login%\[bot\]}" --jq .id 2> /dev/null) || continue
        [[ "$id" =~ ^[0-9]+$ ]] || continue
      fi
      all=$(jq --arg l "$login" --argjson id "$id" '
        def fix: if (.user.login // "") == $l and .performed_via_github_app == null then .performed_via_github_app = {id: $id} else . end;
        .issue |= fix | .comments |= map(fix)' <<< "$all") || return 1
    done < <(jq -r '[.issue, .comments[]] | map(select(.performed_via_github_app == null) | .user.login // "" | select(endswith("[bot]")) | select(IN("github-actions[bot]", "claude[bot]") | not)) | unique | .[]' <<< "$all")
  fi
  result=$(untrusted_count "$app" <<< "$all") || { echo "#$n を数えられなかった" >&2; return 1; }
  [[ "$result" =~ ^[0-9]+$ ]] || { echo "#$n の数が数字でない" >&2; return 1; }
  printf '%s\n' "$result"
}

main() {
  if [ "${1:-}" = "--count-untrusted" ]; then count_main "${2:-}"; return; fi
  local n="${1:-}" repo="${GITHUB_REPOSITORY:-}" issue comments
  case "$n" in '' | *[!0-9]*) echo "使い方：trusted-comments.sh <Issue または PR の番号>" >&2; return 1 ;; esac
  [ -n "$repo" ] || { echo "GITHUB_REPOSITORY が無い" >&2; return 1; }
  issue=$(gh api "repos/$repo/issues/$n") || { echo "#$n を読めなかった" >&2; return 1; }
  comments=$(gh api --paginate --slurp "repos/$repo/issues/$n/comments?per_page=100") || { echo "#$n のコメントを読めなかった" >&2; return 1; }
  # 先に全部組み立ててから出す（途中で失敗したら、何も出さない）
  local result
  # JSON は引数ではなく標準入力で渡す（引数1つは約128KBまでで、コメントが多いと超える）
  result=$( { printf '%s\n' "$issue"; printf '%s\n' "$comments"; } \
    | jq -s '{issue: .[0], comments: (.[1] | if (.[0] | type) == "array" then add else . end // [])}' \
    | trusted_render "${PIPELINE_APP_ID:-}") || { echo "#$n の文章を組み立てられなかった" >&2; return 1; }
  [ -n "$result" ] || { echo "#$n の文章が空" >&2; return 1; }
  printf '%s\n' "$result"
}

# source されたとき（テスト）は動かさない
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
