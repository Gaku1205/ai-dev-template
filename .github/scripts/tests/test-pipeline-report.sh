#!/usr/bin/env bash
# パイプラインの不具合と改善の表（pipeline-report.py）：一覧・止まった記録・洗い出し・集計ができる
source "$(dirname "$0")/lib.sh"
if ! python3 -c "import openpyxl" 2> /dev/null; then echo "openpyxl が無いので飛ばします"; finish; exit 0; fi
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
python3 - "$T" <<'PY'
import json, sys, os
d = sys.argv[1]
def w(name, data): json.dump(data, open(os.path.join(d, name), "w", encoding="utf-8"), ensure_ascii=False)
L = lambda *n: [{"name": x} for x in n]
w("repos_o_t_issues_state_all_per_page_100_page_1.json", [
  {"number": 1, "title": "CIが落ちたら止まるのを直す", "state": "closed", "state_reason": "completed", "labels": L(), "created_at": "2026-11-01T00:00:00Z", "closed_at": "2026-11-01T02:00:00Z", "html_url": "https://x/1"},
  {"number": 2, "title": "並列の上限を3に上げる", "state": "open", "labels": L("ai:queue"), "created_at": "2026-11-02T00:00:00Z", "closed_at": None, "html_url": "https://x/2"},
  {"number": 3, "title": "AIの許可の不足（自動の記録）", "state": "closed", "labels": L("ai:skip"), "created_at": "2026-11-02T00:00:00Z", "closed_at": "2026-11-02T00:00:00Z", "html_url": "https://x/3"},
  {"number": 4, "title": "取り違えを直す", "state": "open", "labels": L("ai:plan", "audit", "priority:high"), "created_at": "2026-11-03T00:00:00Z", "closed_at": None, "html_url": "https://x/4"},
  {"number": 5, "title": "取り違えを直す", "state": "closed", "labels": L(), "created_at": "2026-11-03T00:00:00Z", "closed_at": "2026-11-03T01:00:00Z", "html_url": "https://x/5", "pull_request": {"merged_at": "2026-11-03T01:00:00Z"}}])
w("repos_o_t_issues_comments_since_2026-10-26T00:00:00Z_per_page_100_page_1.json", [
  {"body": "⏸ 自動で進めるのを止めました：AIに直すよう頼みましたが、変更が入りませんでした", "created_at": "2026-11-01T01:00:00Z", "issue_url": "https://api/x/issues/1", "html_url": "https://x/c1"},
  {"body": "ふつうのコメント", "created_at": "2026-11-01T01:00:00Z", "issue_url": "https://api/x/issues/1", "html_url": "https://x/c2"}])
w("repos_o_a_issues_comments_since_2026-10-26T00:00:00Z_per_page_100_page_1.json", [
  {"body": "⚠️ テンプレートから配られたパイプラインの更新で、このリポジトリのCIが落ちました。", "created_at": "2026-11-02T01:00:00Z", "issue_url": "https://api/a/issues/9", "html_url": "https://a/c"}])
PY
out=$(REPORT_FIXTURE="$T" GITHUB_REPOSITORY=o/t REPORT_REPOS="o/t o/a" python3 "$SCRIPTS_DIR/pipeline-report.py" "$T/r.xlsx" 2>&1)
assert_contains "作れた" "$out" "一覧 4 件・止まった記録 2 件・洗い出し 1 件"
read_cell() { python3 -c "from openpyxl import load_workbook as l; print(l('$T/r.xlsx')['$1']['$2'].value)"; }
assert_eq "シートの順" "['集計', '一覧', '止まった記録', '洗い出し']" "$(python3 -c "from openpyxl import load_workbook as l; print(l('$T/r.xlsx').sheetnames)")"
assert_eq "自動の記録Issueは載せない" "4" "$(python3 -c "from openpyxl import load_workbook as l; print(l('$T/r.xlsx')['一覧'].max_row - 1)")"
assert_eq "題名から不具合と分ける" "不具合" "$(read_cell 一覧 C2)"
assert_eq "改善" "改善" "$(read_cell 一覧 C3)"
assert_eq "順番待ち" "順番待ち" "$(read_cell 一覧 E3)"
assert_eq "マージ済みのPRは完了" "完了" "$(read_cell 一覧 E5)"
assert_eq "かかった時間は式" '=IF(G2="","",(G2-F2)*24)' "$(read_cell 一覧 H2)"
assert_eq "止まった記録の種類" "修正AIの変更が入らない" "$(read_cell 止まった記録 D2)"
assert_eq "配り先の記録も載る" "a" "$(read_cell 止まった記録 B3)"
assert_eq "洗い出し：audit のラベル・重さ" "高" "$(read_cell 洗い出し A2)"
assert_contains "集計は式で数える" "$(read_cell 集計 B5)" "COUNTIFS(一覧!"
# Issue の一覧が読めなければ、表を作らず終了コード1で止める（前日の表を上書きしない）
touch "$T/repos_o_t_issues_state_all_per_page_100_page_1.json.error"
rc=0
REPORT_FIXTURE="$T" GITHUB_REPOSITORY=o/t python3 "$SCRIPTS_DIR/pipeline-report.py" "$T/r2.xlsx" > /dev/null 2>&1 || rc=$?
assert_eq "一覧が読めなければ失敗する" "1" "$rc"
assert_eq "表も作らない" "no" "$([ -e "$T/r2.xlsx" ] && echo yes || echo no)"
finish
