#!/usr/bin/env bash
# 子プロセスの鍵消しの自己テスト（scrub-selftest.yml）の答え合わせ。作業フォルダで動かす。
#   - AIが撮った画像（.shots/scrub-page-1440.png）がある → 囲いの中でも Chrome が動いた
#   - AIが動かしたコマンドから見えた環境変数の名前（scrub-env-names.txt）に、鍵の名前が無い
#   - ふつうの名前（GITHUB_WORKSPACE）はある → 名前の一覧がちゃんと取れている
# 結果はログと GITHUB_STEP_SUMMARY に書き、どれかがだめなら 1 で終わる。
set -uo pipefail

summary=${GITHUB_STEP_SUMMARY:-/dev/null}
names=scrub-env-names.txt
shot=.shots/scrub-page-1440.png
# 鍵消しで消えるはずの名前（AIの鍵・Actions の鍵）
SECRET_NAMES="CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_RUNTIME_TOKEN DEFAULT_WORKFLOW_TOKEN OVERRIDE_GITHUB_TOKEN INPUT_CLAUDE_CODE_OAUTH_TOKEN"

ok=true
lines=()
lines+=("- AIの実行：${OUTCOME:-不明}")

if [ -s "$shot" ]; then
  lines+=("- ✅ 撮影：囲いの中でも Chrome が動いた（$shot）")
else
  lines+=("- ❌ 撮影：画像が無い（$shot）。囲いの中で Chrome が立たないかもしれない")
  ok=false
fi

if [ ! -s "$names" ]; then
  lines+=("- ❌ 環境変数：名前の一覧（$names）が無い")
  ok=false
elif ! grep -qx GITHUB_WORKSPACE "$names"; then
  lines+=("- ❌ 環境変数：GITHUB_WORKSPACE も無い（一覧の取り方がおかしい）")
  ok=false
else
  seen=()
  for n in $SECRET_NAMES; do
    if grep -qx "$n" "$names"; then seen+=("$n"); fi
  done
  if [ "${#seen[@]}" -eq 0 ]; then
    lines+=("- ✅ 環境変数：鍵の名前は見えなかった（$(wc -l < "$names") 個の名前を確かめた）")
  else
    lines+=("- ❌ 環境変数：鍵の名前が見えた：${seen[*]}")
    ok=false
  fi
fi

# 実行のログにも出す（summary は REST で読めないので、ログで結果が分かるように）
printf '%s\n' "${lines[@]}"
[ -f "$names" ] && echo "見えた名前：$(wc -l < "$names") 個"
ls -la .shots 2> /dev/null || echo ".shots が無い"
echo "bwrap：$(command -v bwrap || echo 無い)"
{
  echo "## 子プロセスの鍵消しの自己テスト"
  echo
  printf '%s\n' "${lines[@]}"
} >> "$summary"

[ "$ok" = true ]
