#!/usr/bin/env bash
# 撮影の準備：日本語のフォント（Noto CJK）が無ければ入れる。GitHub の Ubuntu のランナーには日本語のフォントが無く、
# 画面が Web フォントを読まない物（ゲームの canvas など）では、撮った画像の日本語が □ になるため。
# factory.yml の design ジョブと claude-implement.yml（画面を撮るとき）から呼ぶ。入れられなくても止めない
# JA_FONTS_CACHE（任意）：.deb を置くフォルダ（ランナーの人の物。ワークフローが actions/cache で戻す・残す。#255 の2つ目）
#   /var/cache/apt/archives は root の物で actions/cache が書き戻せず、ランナーの設定で入れた後に .deb が消されるので、別のフォルダにする
#   置いてある .deb は apt-get install がそのまま使う（apt の一覧のハッシュと合う物だけ。合わなければ取り直す）＝ふだんはミラーに行かない
#   入れた後、フォルダをランナーの人の物に戻し、.deb があれば GITHUB_OUTPUT に ja_fonts_deb=true を書く（キャッシュに残す段の条件）
set -uo pipefail
if command -v fc-list > /dev/null 2>&1 && [ -n "$(fc-list :lang=ja 2> /dev/null | head -1)" ]; then
  echo "日本語のフォントは入っています"
  exit 0
fi
cache="${JA_FONTS_CACHE:-}"
opts=(-y -qq --no-install-recommends)
if [ -n "$cache" ]; then
  mkdir -p "$cache/partial" 2> /dev/null || true
  opts+=(-o "Dir::Cache::Archives=${cache%/}/" -o APT::Keep-Downloaded-Packages=true)
  if compgen -G "${cache%/}/fonts-noto-cjk*.deb" > /dev/null; then
    echo "日本語のフォントの .deb がキャッシュにあるので、ミラーから取らずに入れます"
  fi
fi
# 取りに行く先が遅いと30分近く止まるので、それぞれ4分で諦める（日本語が □ になるだけで、先へ進む）
if sudo timeout 240 apt-get install "${opts[@]}" fonts-noto-cjk > /dev/null 2>&1 ||
  { sudo timeout 240 apt-get update -qq > /dev/null 2>&1 && sudo timeout 240 apt-get install "${opts[@]}" fonts-noto-cjk > /dev/null 2>&1; }; then
  echo "日本語のフォント（Noto CJK）を入れました"
else
  echo "::warning::日本語のフォントを入れられませんでした（撮った画像の日本語が □ になることがあります）"
fi
if [ -n "$cache" ] && [ -d "$cache" ]; then
  # apt（root）が書いた物を、キャッシュに残せるよう、ランナーの人の物に戻す
  sudo chown -R "$(id -u):$(id -g)" "$cache" > /dev/null 2>&1 || true
  rm -f "${cache%/}/lock" 2> /dev/null || true
  if compgen -G "${cache%/}/fonts-noto-cjk*.deb" > /dev/null && [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "ja_fonts_deb=true" >> "$GITHUB_OUTPUT"
  fi
fi
exit 0
