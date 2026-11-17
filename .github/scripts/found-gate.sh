#!/usr/bin/env bash
# 「使ってみる役」（claude-try.yml）と「監査役」（claude-audit.yml）を、今日動かすかを決める。
#   found-gate.sh try    公開しているサイトの URL があり、直近24時間の main に、アプリの中身（.github/・docs/pipeline.md・docs/pipeline-setup.md・.claude/ 以外）が変わったコミットがあれば動かす
#   found-gate.sh audit  進行中の作業（企画・実装・審査・順番待ち・AIのPR）が無ければ動かす
# 環境変数：GITHUB_REPOSITORY（REPO でもよい）、GH_TOKEN、FORCE（1 なら時間・進行中の条件を見ない。手で動かすとき）、
#           NOW（テスト用。UNIX秒）、GITHUB_OUTPUT（run・url・reason を書く。無ければ標準出力）
# docs/pipeline.md「使ってみる役・監査役」
set -uo pipefail
kind="${1:-}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
out="${GITHUB_OUTPUT:-/dev/stdout}"
now="${NOW:-$(date +%s)}"
force="${FORCE:-0}"

emit() { # run url reason
  { echo "run=$1"; echo "url=$2"; echo "reason=$3"; } >> "$out"
  echo "$3"
}

# そのコミットで変わったファイルが、パイプラインの物（.github/・docs/pipeline.md・docs/pipeline-setup.md・.claude/）だけなら 0。
# 読めなかった・中身が無いときは 1（アプリの変更として扱う）。同じコミットを2回読まない（結果を覚えておく）
declare -A _pl_only=()
pipeline_only_commit() {
  local sha="$1" files
  if [ -z "${_pl_only[$sha]:-}" ]; then
    files=$(gh api "repos/$REPO/commits/$sha" --jq '[.files[].filename] | join("\n")' 2> /dev/null || true)
    if [ -n "$files" ] && ! printf '%s\n' "$files" | grep -vqE '^(\.github/|\.claude/|docs/pipeline(-setup)?\.md$)'; then
      _pl_only[$sha]=yes
    else
      _pl_only[$sha]=no
    fi
  fi
  [ "${_pl_only[$sha]}" = yes ]
}

case "$kind" in
  try)
    # 公開先の URL：GitHub Pages の公開があればその URL、無ければリポジトリの「Website」（工場が公開先を書く）
    url=$(gh api "repos/$REPO/deployments?environment=github-pages&per_page=1" --jq '.[0].statuses_url // empty' 2> /dev/null || true)
    if [ -n "$url" ]; then
      url=$(gh api "${url#https://api.github.com/}?per_page=1" --jq '.[0].environment_url // empty' 2> /dev/null || true)
    fi
    [ -z "$url" ] && url=$(gh api "repos/$REPO" --jq '.homepage // empty' 2> /dev/null || true)
    case "$url" in
      https://*) ;;
      *) emit false "" "公開しているサイトの URL が無いので、使ってみる役は動かしません（リポジトリの Website が空）"; exit 0 ;;
    esac
    # 直近24時間の main に、アプリの中身が変わったコミットがあるか。パイプラインの配布（pipeline-sync/… のPRのマージ）は
    # .github/・docs/pipeline.md・docs/pipeline-setup.md・.claude/ しか変えず、本番は変わらない。配布だけの日に毎日試すと、AIの使用量だけが減る。
    # 変わったファイルを読めなかったコミット（API の失敗・中身の無いコミット）は、アプリの変更として数える（試さない方へは倒さない）。
    # コミットが30件（1ページ）に達したら、それ以上は読まずに動かす（API の回数を増やさない）
    if [ "$force" != 1 ]; then
      since=$(date -u -d "@$((now - 86400))" +%Y-%m-%dT%H:%M:%SZ)
      recent=$(gh api "repos/$REPO/commits?sha=main&since=$since&per_page=30" --jq '.[].sha' 2> /dev/null || true)
      if [ -z "$recent" ]; then
        emit false "$url" "直近24時間に公開（main の変更）が無いので、今日は使ってみる役を動かしません"; exit 0
      fi
      app_changed=0
      [ "$(printf '%s\n' "$recent" | wc -l)" -ge 30 ] && app_changed=1
      for sha in $recent; do
        [ "$app_changed" = 1 ] && break
        pipeline_only_commit "$sha" || app_changed=1
      done
      if [ "$app_changed" != 1 ]; then
        emit false "$url" "直近24時間の main の変更は、パイプラインの更新（.github/・docs/pipeline.md・docs/pipeline-setup.md・.claude/）だけなので、今日は使ってみる役を動かしません（本番は変わっていないため）"; exit 0
      fi
    fi
    # 本番が main の最新に追いついているか：公開は、マージが落ち着いてから最新の main を1回だけ行うので、
    # main が先に進んでいる間に試すと、main ではもう直っている不具合を Issue にしてしまう（tochi-rirekisho #9・#11）。
    # 公開のステータス（context が Vercel・deploy/ で始まる物）が main の先頭に無く、それより前のコミットにはある
    # ＝本番が追いついていない。先頭にあっても、成功していなければ（公開中・失敗）待つ。どこにも無ければ（公開の仕組みが違う）見ない
    if [ "$force" != 1 ]; then
      shas=$(gh api "repos/$REPO/commits?sha=main&per_page=15" --jq '.[].sha' 2> /dev/null || true)
      first=1 behind=""
      for sha in $shas; do
        states=$(gh api "repos/$REPO/commits/$sha/status" --jq '[.statuses[] | select(.context | test("^(Vercel|deploy/)")) | .state] | join(" ")' 2> /dev/null || true)
        if [ -n "$states" ]; then
          if [ "$first" = 1 ]; then
            case " $states " in
              *" pending "* | *" failure "* | *" error "*) behind="本番の公開がまだ終わっていない（公開中か失敗）" ;;
            esac
          else
            behind="本番が main の最新にまだ追いついていない"
          fi
          break
        fi
        # パイプラインの物（.github/・docs/pipeline.md・docs/pipeline-setup.md・.claude/）しか変わっていないコミットは公開されず、ステータスが付かない。飛ばす
        pipeline_only_commit "$sha" && continue
        first=0
      done
      if [ -n "$behind" ]; then
        emit false "$url" "${behind}ので、今日は使ってみる役を動かしません（main で直った物を Issue にしないため。次の回にもう一度見ます）"; exit 0
      fi
    fi
    emit true "$url" "公開があったので、使ってみる役を動かします：$url"
    ;;
  audit)
    if [ "$force" != 1 ]; then
      busy=0
      for l in ai:plan ai:implement ai:review ai:queue; do
        n=$(gh api "repos/$REPO/issues?state=open&labels=$(printf '%s' "$l" | sed 's/:/%3A/')&per_page=1" --jq 'length' 2> /dev/null || echo 0)
        busy=$((busy + ${n:-0}))
      done
      prs=$(gh api "repos/$REPO/pulls?state=open&per_page=100" --jq '[.[] | select(.head.ref | startswith("claude/"))] | length' 2> /dev/null || echo 0)
      busy=$((busy + ${prs:-0}))
      if [ "$busy" -gt 0 ]; then
        emit false "" "進行中の作業があるので、今週の監査は見送ります（次の週にもう一度見ます）"; exit 0
      fi
    fi
    emit true "" "進行中の作業が無いので、監査役を動かします"
    ;;
  *) echo "使い方：found-gate.sh try|audit" >&2; exit 2 ;;
esac
