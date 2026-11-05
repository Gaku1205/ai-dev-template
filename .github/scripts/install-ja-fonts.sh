#!/usr/bin/env bash
# 撮影の準備：日本語のフォント（Noto CJK）が無ければ入れる。GitHub の Ubuntu のランナーには日本語のフォントが無く、
# 画面が Web フォントを読まない物（ゲームの canvas など）では、撮った画像の日本語が □ になるため。
# factory.yml の design ジョブと claude-implement.yml（画面を撮るとき）から呼ぶ。入れられなくても止めない
set -uo pipefail
if command -v fc-list > /dev/null 2>&1 && [ -n "$(fc-list :lang=ja 2> /dev/null | head -1)" ]; then
  echo "日本語のフォントは入っています"
  exit 0
fi
# 取りに行く先が遅いと30分近く止まるので、それぞれ4分で諦める（日本語が □ になるだけで、先へ進む）
if sudo timeout 240 apt-get install -y -qq --no-install-recommends fonts-noto-cjk > /dev/null 2>&1 ||
  { sudo timeout 240 apt-get update -qq > /dev/null 2>&1 && sudo timeout 240 apt-get install -y -qq --no-install-recommends fonts-noto-cjk > /dev/null 2>&1; }; then
  echo "日本語のフォント（Noto CJK）を入れました"
else
  echo "::warning::日本語のフォントを入れられませんでした（撮った画像の日本語が □ になることがあります）"
fi
exit 0
