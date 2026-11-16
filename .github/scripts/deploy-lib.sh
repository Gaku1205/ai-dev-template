#!/usr/bin/env bash
# 公開のスクリプト（deploy-*.sh・deploy-notify.yml）が共通で使う関数。source して使う。

# コミットの説明から、通知やリリースに出す題（PR のタイトル）を取り出す。使い方：commit_title "コミットの説明の全部"
#   - パイプラインのマージ（マージコミット）：1行目は「Merge pull request #12 from …」、3行目が PR のタイトル
#   - まとめてマージ（squash）・直接のコミット：1行目が題。3行目は本文の続き（「Closes #12」など）なので使わない
commit_title() {
  local first third
  first=$(printf '%s\n' "$1" | sed -n '1p')
  third=$(printf '%s\n' "$1" | sed -n '3p')
  case "$first" in
    "Merge pull request "* | "Merge branch "*) [ -n "$third" ] && { printf '%s\n' "$third"; return 0; } ;;
  esac
  printf '%s\n' "$first"
}
