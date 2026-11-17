#!/usr/bin/env bash
# 並列の上限を時間帯・手の上書きで決める純粋な関数（parallel_limit）のテスト（ai-dev-template #122）
source "$(dirname "$0")/lib.sh"
setup_mock
source "$SCRIPTS_DIR/pipeline-lib.sh"; trap - ERR; set +e

# 東京の時刻（JST）から epoch 秒にする
t() { date -d "$1 +0900" +%s; }
# 設定を全部消してから、指定した環境変数で上限を求める：lim 時刻 [VAR=値 ...]
lim() {
  local at="$1"; shift
  env -u MAX_PARALLEL -u PARALLEL_DAY -u PARALLEL_NIGHT -u PARALLEL_NIGHT_HOURS -u PARALLEL_TZ -u PARALLEL_OVERRIDE "$@" \
    bash -c "source '$SCRIPTS_DIR/pipeline-lib.sh'; parallel_limit '$at'" 2> /dev/null | tail -1
}
info() {
  local at="$1"; shift
  env -u MAX_PARALLEL -u PARALLEL_DAY -u PARALLEL_NIGHT -u PARALLEL_NIGHT_HOURS -u PARALLEL_TZ -u PARALLEL_OVERRIDE "$@" \
    bash -c "source '$SCRIPTS_DIR/pipeline-lib.sh'; parallel_limit_decide '$at'" 2> /dev/null | tail -1
}

noon=$(t "2026-11-17 12:00")
echo "== 設定が無ければ3、MAX_PARALLEL・PARALLEL_DAY を指定すればその値"
assert_eq "既定" "3" "$(lim "$noon")"
assert_eq "MAX_PARALLEL" "5" "$(lim "$noon" MAX_PARALLEL=5)"
assert_eq "PARALLEL_DAY が MAX_PARALLEL に勝つ" "4" "$(lim "$noon" MAX_PARALLEL=5 PARALLEL_DAY=4)"
assert_eq "夜の時間帯が無ければ夜中も昼の上限" "3" "$(lim "$(t '2026-11-17 03:00')")"

echo "== 夜の時間帯（01-08）：開始を含み終了を含まない"
h="PARALLEL_NIGHT_HOURS=01-08"
assert_eq "0:59 は昼" "3" "$(lim "$(t '2026-11-17 00:59')" $h)"
assert_eq "1:00 は夜（既定 1）" "1" "$(lim "$(t '2026-11-17 01:00')" $h)"
assert_eq "7:59 は夜" "1" "$(lim "$(t '2026-11-17 07:59')" $h)"
assert_eq "8:00 は昼" "3" "$(lim "$(t '2026-11-17 08:00')" $h)"
assert_eq "夜の上限を指定" "2" "$(lim "$(t '2026-11-17 03:00')" $h PARALLEL_NIGHT=2)"

echo "== 日またぎ（22-06）"
h="PARALLEL_NIGHT_HOURS=22-06"
assert_eq "21:59 は昼" "3" "$(lim "$(t '2026-11-17 21:59')" $h)"
assert_eq "22:00 は夜" "1" "$(lim "$(t '2026-11-17 22:00')" $h)"
assert_eq "0:30 は夜" "1" "$(lim "$(t '2026-11-18 00:30')" $h)"
assert_eq "5:59 は夜" "1" "$(lim "$(t '2026-11-18 05:59')" $h)"
assert_eq "6:00 は昼" "3" "$(lim "$(t '2026-11-18 06:00')" $h)"

echo "== 基準のタイムゾーン（既定は東京）"
utc_3=$(date -u -d "2026-11-17 03:00" +%s)
assert_eq "UTC 3:00 は東京12:00なので昼" "3" "$(lim "$utc_3" PARALLEL_NIGHT_HOURS=01-08)"
assert_eq "PARALLEL_TZ=UTC なら夜" "1" "$(lim "$utc_3" PARALLEL_NIGHT_HOURS=01-08 PARALLEL_TZ=UTC)"

echo "== 手の上書き：期限まで時間帯に勝ち、過ぎたら戻る"
ov="night until 2026-11-18T08:00+09:00"
assert_eq "昼でも night の上書きなら夜の上限" "1" "$(lim "$noon" "PARALLEL_OVERRIDE=$ov")"
assert_eq "期限の直前も有効" "1" "$(lim "$(t '2026-11-18 07:59')" "PARALLEL_OVERRIDE=$ov")"
assert_eq "期限ちょうどで切れて昼に戻る" "3" "$(lim "$(t '2026-11-18 08:00')" "PARALLEL_OVERRIDE=$ov")"
assert_eq "期限後は時間帯の決まりに戻る（夜の時間）" "1" "$(lim "$(t '2026-11-18 09:00')" "PARALLEL_OVERRIDE=$ov" PARALLEL_NIGHT_HOURS=09-10)"
assert_eq "day の上書きは夜の時間でも昼の上限" "4" "$(lim "$(t '2026-11-17 03:00')" "PARALLEL_OVERRIDE=day until 2026-11-18T08:00+09:00" PARALLEL_NIGHT_HOURS=01-08 PARALLEL_DAY=4)"
assert_eq "night の上書きは夜の上限の値を使う" "2" "$(lim "$noon" "PARALLEL_OVERRIDE=$ov" PARALLEL_NIGHT=2)"
assert_contains "上書き中と分かる説明" "$(info "$noon" "PARALLEL_OVERRIDE=$ov")" "手で上書き中"
assert_contains "夜の説明" "$(info "$(t '2026-11-17 03:00')" PARALLEL_NIGHT_HOURS=01-08)" "夜の上限"
assert_contains "昼の説明" "$(info "$noon")" "昼の上限"

echo "== 不正な値は無視して既定に戻る"
night_t=$(t '2026-11-17 03:00')
assert_eq "上書きの形が違う" "3" "$(lim "$noon" "PARALLEL_OVERRIDE=night 2026-11-18")"
assert_eq "上書きの時刻が違う" "3" "$(lim "$noon" "PARALLEL_OVERRIDE=night until あした")"
assert_eq "上書きの種類が違う" "3" "$(lim "$noon" "PARALLEL_OVERRIDE=evening until 2026-11-18T08:00+09:00")"
assert_eq "時間帯の形が違う" "3" "$(lim "$night_t" PARALLEL_NIGHT_HOURS=abc)"
assert_eq "時間帯が範囲外" "3" "$(lim "$night_t" PARALLEL_NIGHT_HOURS=01-99)"
assert_eq "開始と終了が同じなら夜は無し" "3" "$(lim "$night_t" PARALLEL_NIGHT_HOURS=03-03)"
assert_eq "昼の上限が数でない" "3" "$(lim "$noon" PARALLEL_DAY=many)"
assert_eq "昼の上限が0" "3" "$(lim "$noon" PARALLEL_DAY=0)"
assert_eq "昼の上限が負" "3" "$(lim "$noon" PARALLEL_DAY=-2)"
assert_eq "夜の上限が数でない" "1" "$(lim "$night_t" PARALLEL_NIGHT_HOURS=01-08 PARALLEL_NIGHT=x)"
assert_eq "夜の上限が0" "1" "$(lim "$night_t" PARALLEL_NIGHT_HOURS=01-08 PARALLEL_NIGHT=0)"
assert_eq "08 のような0付きの数も読める" "8" "$(lim "$noon" PARALLEL_DAY=08)"

echo "== 夜になっても動いている作業は止めない・新しく始める数だけ減らす（順番待ち）"
body() { printf '本文\n<!-- ai-touches: %s -->' "$1"; }
init_state "$(python3 -c "
import json
print(json.dumps({'labels':{'1':['ai:implement'],'2':['ai:implement'],'3':['ai:queue']},
 'issues_meta':{'1':{'title':'a','body':'''$(body src/lib/a.ts)'''},'2':{'title':'a2','body':'''$(body src/lib/a2.ts)'''},'3':{'title':'b','body':'''$(body src/lib/b.ts)'''}}}))")"
out=$(PARALLEL_OVERRIDE="night until 2999-01-01T00:00+09:00" run_script queue-next.sh)
assert_eq "動いている #1 のラベルはそのまま" "ai:implement" "$(labels_of 1)"
assert_eq "動いている #2 のラベルはそのまま" "ai:implement" "$(labels_of 2)"
assert_eq "夜の上限1を超えているので #3 は始めない" "ai:queue" "$(labels_of 3)"
assert_contains "上限の表示に夜と上書き中が出る" "$out" "夜の上限（手で上書き中）"
finish
