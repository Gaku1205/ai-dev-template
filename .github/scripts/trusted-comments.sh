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

main() {
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
