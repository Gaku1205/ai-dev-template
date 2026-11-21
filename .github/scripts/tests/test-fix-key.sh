#!/usr/bin/env bash
# 直す回数：同じ指摘が続いた回数で止め、全部の回数には別の上限（MAX_AUTO_FIX_TOTAL）
source "$(dirname "$0")/lib.sh"
setup_mock

AI_MSG="直してください。"

# 直す依頼を、指紋つき（理由の文から作る）で並べた状態にする。引数：PR番号 理由の文...（古い順。"-" は指紋なしの古い依頼）
state_with() {
  local pr="$1"; shift
  init_state '{"labels":{"'"$pr"'":[]},"pulls":[{"number":'"$pr"',"state":"open","body":"","head":{"sha":"abc123","ref":"x"},"labels":[]}]}'
  local i=0 r key
  for r in "$@"; do
    i=$((i + 1))
    if [ "$r" = "-" ]; then
      key=""
    else
      key="\n<!-- auto-fix-key: $(run_lib "fix_key_of '$r'") -->"
    fi
    state_py "
s['comments'].append({'id': 900+$i, 'body': '@claude 直して\n<!-- auto-fix -->$key', 'user': {'login': 'github-actions[bot]'}, 'created_at': '2026-01-01T00:00:0${i}Z', 'updated_at': '2026-01-01T00:00:0${i}Z', 'issue': '$pr'})"
  done
}

echo "== 毎回ちがう指摘が3回続いても止まらず、4回目を頼む"
state_with 80 "指摘A" "指摘B" "指摘C"
run_lib "request_fix_or_stop 80 abc123 '$AI_MSG' '指摘D'" > /dev/null
c=$(comments_of 80)
assert_contains "4回目を頼む" "$c" "@claude $AI_MSG"
assert_contains "指紋が入る" "$c" "auto-fix-key:"
assert_not_contains "止めない" "$(labels_of 80)" "ai:stuck"
assert_contains "普通のモデル（強いモデルの印なし）の1回目" "$c" "自動の依頼 1/3"

echo "== 同じ指摘が MAX_AUTO_FIX+1 回続いたら止まる（最後の1回は強いモデル）"
state_with 81 "指摘A" "指摘A"
run_lib "request_fix_or_stop 81 abc123 '$AI_MSG' '指摘A'" > /dev/null
c=$(comments_of 81)
assert_contains "3回目は強いモデル" "$c" "auto-fix-model: opus"
state_with 82 "指摘A" "指摘A" "指摘A"
run_lib "request_fix_or_stop 82 abc123 '$AI_MSG' '指摘A'" > /dev/null
c=$(comments_of 82)
assert_contains "同じ指摘で止まる" "$c" "同じ指摘が3回（最後の1回は強いモデル）直りませんでした"
assert_contains "ai:stuck が付く" "$(labels_of 82)" "ai:stuck"

echo "== 指摘が変わったら数え直す（強いモデルの回も、同じ指摘が続いたときだけ）"
state_with 83 "指摘A" "指摘A" "指摘B"
run_lib "request_fix_or_stop 83 abc123 '$AI_MSG' '指摘B'" > /dev/null
c=$(comments_of 83)
assert_not_contains "強いモデルにしない" "$c" "auto-fix-model: opus"
assert_contains "2回目" "$c" "自動の依頼 2/3"

echo "== 全部の回数が MAX_AUTO_FIX_TOTAL に届いたら、指摘が変わっていても止まる"
state_with 84 a b c d e f g h
run_lib "request_fix_or_stop 84 abc123 '$AI_MSG' '指摘Z'" > /dev/null
c=$(comments_of 84)
assert_contains "回数で止まると文で分かる" "$c" "直す依頼が8回になりました（毎回ちがう指摘。"
assert_contains "ai:stuck が付く" "$(labels_of 84)" "ai:stuck"
state_with 85 a b c d e f g
run_lib "request_fix_or_stop 85 abc123 '$AI_MSG' '指摘Z'" > /dev/null
assert_not_contains "7回ならまだ止めない" "$(labels_of 85)" "ai:stuck"
state_with 86 a b c
run_lib "MAX_AUTO_FIX_TOTAL=3 request_fix_or_stop 86 abc123 '$AI_MSG' '指摘Z'" > /dev/null
assert_contains "変数で上限を変えられる" "$(comments_of 86)" "直す依頼が3回になりました"

echo "== 指紋の無い古い依頼だけのときは、今までどおり（全部を同じ指摘として数える）"
state_with 87 - - -
run_lib "request_fix_or_stop 87 abc123 '$AI_MSG' '指摘Z'" > /dev/null
assert_contains "3回で止まる" "$(comments_of 87)" "同じ指摘が3回（最後の1回は強いモデル）直りませんでした"
state_with 88 - -
run_lib "request_fix_or_stop 88 abc123 '$AI_MSG' '指摘Z'" > /dev/null
assert_contains "3回目は強いモデル" "$(comments_of 88)" "auto-fix-model: opus"

echo "== 再開（ai:stuck を外す）で、どちらの回数も数え直す"
state_with 89 a b c d e f g h
state_py "
s['comments'].append({'id': 990, 'body': '<!-- auto-resume -->', 'user': {'login': 'github-actions[bot]'}, 'created_at': '2026-01-01T00:01:00Z', 'updated_at': '2026-01-01T00:01:00Z', 'issue': '89'})"
run_lib "request_fix_or_stop 89 abc123 '$AI_MSG' '指摘Z'" > /dev/null
assert_not_contains "止めない" "$(labels_of 89)" "ai:stuck"
assert_contains "1回目から" "$(comments_of 89)" "自動の依頼 1/3"

finish
