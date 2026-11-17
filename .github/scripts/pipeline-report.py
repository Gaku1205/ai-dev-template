#!/usr/bin/env python3
"""パイプラインの不具合と改善の表（Excel）を作る。テンプレート本体だけで動く（pipeline-report.yml が毎日動かし、Releases に置く）。

  集計：状態ごとの数（不具合／改善）、止まった記録の種類ごとの回数、完了までの時間（どれも式で数える）
  一覧：テンプレートの Issue・PR 全部（自動の記録Issue「AIの許可の不足（自動の記録）」は除く）
  止まった記録：配り先も含めた全リポジトリの「⏸ 止めた／🔁 やり直す／⚠️ 警告」のコメント
  洗い出し：ラベル audit の Issue・PR（不具合の洗い出しで見つけた物）と、本文に「不具合の洗い出し」と書かれた Issue

使い方：pipeline-report.py 出力先.xlsx
  環境変数：GITHUB_REPOSITORY（テンプレート）、REPORT_REPOS（調べるリポジトリ。空白区切りの owner/name。無ければテンプレートだけ）、
           REPORT_SINCE（止まった記録をいつから。既定 2026-10-26）、REPORT_FIXTURE（テスト用：API の代わりに読むフォルダ）
"""
import datetime as dt
import json
import os
import re
import subprocess
import sys

from openpyxl import Workbook
from openpyxl.styles import Alignment, Font, PatternFill
from openpyxl.utils import get_column_letter
from openpyxl.worksheet.table import Table, TableStyleInfo

JST = dt.timezone(dt.timedelta(hours=9))
FIXTURE = os.environ.get("REPORT_FIXTURE", "")


def api(path):
    """GET を1回。テストでは REPORT_FIXTURE のファイル（path の / と ? と & を _ にした名前.json）を読む"""
    if FIXTURE:
        name = re.sub(r"[/?&=]", "_", path) + ".json"
        p = os.path.join(FIXTURE, name)
        if os.path.exists(p + ".error"):
            return None
        return json.load(open(p, encoding="utf-8")) if os.path.exists(p) else []
    r = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    if not r.stdout.strip():
        return []
    return json.loads(r.stdout)


def api_all(path, must=False):
    """全ページ読む。読めなかったとき、must なら終了コード1で止める（前日の正しい表を上書きしないため）。そうでなければ標準エラーに出して、そこまでを返す"""
    out, page = [], 1
    while True:
        d = api(f"{path}&page={page}")
        if d is None:
            print(f"読めませんでした: {path} (page {page})", file=sys.stderr)
            if must:
                sys.exit(1)
            break
        if not d:
            break
        out += d
        if len(d) < 100:
            break
        page += 1
    return out


def t(s):
    if not s:
        return None
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(JST).replace(tzinfo=None)


BUG = re.compile(r"直す|直し|止ま|止め|落ち|エラー|取り違え|読み違え|消え|失敗|不具合|二重|壊れ|見逃|抜け|間違|誤|漏れ|拒否|足りない|不足|動かない|入らない|切れ|脆弱|崩れ|fix", re.I)
F = Font(name="Arial", size=10)
FBOLD = Font(name="Arial", size=10, bold=True)
FH = Font(name="Arial", size=10, bold=True, color="FFFFFF")
HDR = PatternFill("solid", fgColor="1F2937")


def category(text):
    rules = [("変更が入りませんでした", "修正AIの変更が入らない"), ("パイプライン自体のテスト", "テンプレートでしか通らないテスト"),
             ("配られたパイプラインの更新で", "テンプレートでしか通らないテスト"), ("マージできませんでした", "GitHub の一時的なエラー"),
             ("許可", "許可の不足"), ("画面案", "画面案が作れない"), ("撮り直し", "基準画像の撮り直し"),
             ("変更が作られませんでした", "実装AIが変更を残さない"), ("レビューAIの結果", "レビューの結果が無い"), ("AIが止まった", "AIの一時的な停止")]
    for key, name in rules:
        if key in text:
            return name
    return "その他"


def header(ws, cols, widths):
    for i, (c, w) in enumerate(zip(cols, widths), 1):
        x = ws.cell(row=1, column=i, value=c)
        x.font, x.fill, x.alignment = FH, HDR, Alignment(vertical="center", wrap_text=True)
        ws.column_dimensions[get_column_letter(i)].width = w
    ws.freeze_panes = "A2"


def as_table(ws, name, cols, rows):
    if rows < 1:
        return
    tb = Table(displayName=name, ref=f"A1:{get_column_letter(cols)}{rows + 1}")
    tb.tableStyleInfo = TableStyleInfo(name="TableStyleLight1", showRowStripes=True)
    ws.add_table(tb)


def main(out):
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    repos = os.environ.get("REPORT_REPOS", "").split() or [repo]
    since = os.environ.get("REPORT_SINCE", "2026-10-26")
    items = api_all(f"repos/{repo}/issues?state=all&per_page=100", must=True)
    items = [x for x in items if not x["title"].startswith("AIの許可の不足（自動の記録）")]
    items.sort(key=lambda x: x["number"])
    wb = Workbook()

    # ---- 一覧
    ws = wb.active
    ws.title = "一覧"
    header(ws, ["番号", "区分", "種類", "題名", "状態", "作成日時", "完了日時", "かかった時間（h）", "ラベル", "URL"],
           [7, 7, 8, 70, 12, 17, 17, 12, 28, 44])
    for r, it in enumerate(items, 2):
        labels = [lb["name"] for lb in it.get("labels", [])]
        is_pr = "pull_request" in it
        merged = (it.get("pull_request") or {}).get("merged_at")
        if is_pr:
            st = "完了" if merged else ("見送り" if it["state"] == "closed" else "マージ待ち" if "ai:hold" in labels else "進行中")
            done = merged
        else:
            if it["state"] == "closed":
                st = "見送り" if it.get("state_reason") == "not_planned" else "完了"
            elif "ai:stuck" in labels:
                st = "止まっている"
            elif "ai:queue" in labels or "ai:blocked" in labels:
                st = "順番待ち"
            elif "ai:question" in labels:
                st = "質問待ち"
            else:
                st = "進行中"
            done = it.get("closed_at") if st == "完了" else None
        vals = [it["number"], "PR" if is_pr else "Issue", "不具合" if BUG.search(it["title"]) else "改善", it["title"], st,
                t(it["created_at"]), t(done), f'=IF(G{r}="","",(G{r}-F{r})*24)', ", ".join(labels), it["html_url"]]
        for c, v in enumerate(vals, 1):
            ws.cell(row=r, column=c, value=v).font = F
        ws.cell(row=r, column=6).number_format = ws.cell(row=r, column=7).number_format = "yyyy/mm/dd hh:mm"
        ws.cell(row=r, column=8).number_format = "0.0"
        ws.cell(row=r, column=10).hyperlink = it["html_url"]
    as_table(ws, "一覧表", 10, len(items))

    # ---- 止まった記録
    ws2 = wb.create_sheet("止まった記録")
    header(ws2, ["日時", "リポジトリ", "番号", "種類", "止まり方", "内容", "URL"], [17, 18, 7, 26, 10, 90, 44])
    events = []
    for rp in repos:
        for c in api_all(f"repos/{rp}/issues/comments?since={since}T00:00:00Z&per_page=100"):
            first = (c.get("body") or "").strip().split("\n")[0]
            m = re.match(r"^(⏸|🔁|⚠️|❌)", first)
            if m:
                events.append((c["created_at"], rp.split("/")[-1], int(c["issue_url"].rsplit("/", 1)[1]), first, m.group(1), c["html_url"]))
    events.sort()
    kinds = {"⏸": "止まった", "🔁": "やり直し", "⚠️": "警告", "❌": "失敗"}
    for r, (at, rp, num, text, k, url) in enumerate(events, 2):
        for c, v in enumerate([t(at), rp, num, category(text), kinds.get(k, k), text[:300], url], 1):
            ws2.cell(row=r, column=c, value=v).font = F
        ws2.cell(row=r, column=1).number_format = "yyyy/mm/dd hh:mm"
        ws2.cell(row=r, column=7).hyperlink = url
    as_table(ws2, "止まった記録表", 7, len(events))

    # ---- 洗い出し
    ws3 = wb.create_sheet("洗い出し")
    header(ws3, ["重さ", "不具合", "Issue", "状態", "作成日", "URL"], [7, 80, 9, 12, 12, 44])
    found = [x for x in items if "audit" in [lb["name"] for lb in x.get("labels", [])]
             or ("pull_request" not in x and "不具合の洗い出し" in (x.get("body") or ""))]
    for r, it in enumerate(found, 2):
        labels = [lb["name"] for lb in it.get("labels", [])]
        if "pull_request" in it:
            st = "完了" if (it.get("pull_request") or {}).get("merged_at") else ("見送り" if it["state"] == "closed" else "対応中")
        else:
            st = "完了" if it["state"] == "closed" and it.get("state_reason") != "not_planned" else ("見送り" if it["state"] == "closed" else "対応中")
        for c, v in enumerate(["高" if "priority:high" in labels else "中", it["title"], f"#{it['number']}", st, t(it["created_at"]), it["html_url"]], 1):
            ws3.cell(row=r, column=c, value=v).font = F
        ws3.cell(row=r, column=5).number_format = "yyyy/mm/dd"
        ws3.cell(row=r, column=6).hyperlink = it["html_url"]
    as_table(ws3, "洗い出し表", 6, len(found))

    # ---- 集計（いちばん前）
    s = wb.create_sheet("集計", 0)
    s["A1"] = "AI開発パイプラインの不具合と改善のまとめ"
    s["A1"].font = Font(name="Arial", size=14, bold=True)
    s["A2"] = f"{dt.datetime.now(JST):%Y-%m-%d %H:%M} 時点（毎日自動で作り直す）。種類は題名から自動で分けた目安"
    s["A2"].font = Font(name="Arial", size=9, italic=True, color="6B7280")
    s.column_dimensions["A"].width = 30
    for c in "BCD":
        s.column_dimensions[c].width = 12

    def head(row, vals):
        for i, v in enumerate(vals, 1):
            x = s.cell(row=row, column=i, value=v)
            x.font, x.fill = FH, HDR

    head(4, ["状態", "不具合", "改善", "合計"])
    states = ["完了", "進行中", "順番待ち", "マージ待ち", "止まっている", "質問待ち", "見送り"]
    for i, st in enumerate(states, 5):
        s.cell(row=i, column=1, value=st).font = F
        s.cell(row=i, column=2, value=f'=COUNTIFS(一覧!$C:$C,"不具合",一覧!$E:$E,$A{i})').font = F
        s.cell(row=i, column=3, value=f'=COUNTIFS(一覧!$C:$C,"改善",一覧!$E:$E,$A{i})').font = F
        s.cell(row=i, column=4, value=f"=B{i}+C{i}").font = F
    tr = 5 + len(states)
    s.cell(row=tr, column=1, value="合計").font = FBOLD
    for c in "BCD":
        s[f"{c}{tr}"] = f"=SUM({c}5:{c}{tr - 1})"
        s[f"{c}{tr}"].font = FBOLD
    r0 = tr + 2
    head(r0, ["止まった記録の種類", "回数"])
    cats = sorted({category(e[3]) for e in events})
    for i, cn in enumerate(cats, r0 + 1):
        s.cell(row=i, column=1, value=cn).font = F
        s.cell(row=i, column=2, value=f"=COUNTIF(止まった記録!$D:$D,$A{i})").font = F
    rt = r0 + 1 + len(cats)
    s.cell(row=rt, column=1, value="合計").font = FBOLD
    s[f"B{rt}"] = f"=SUM(B{r0 + 1}:B{max(rt - 1, r0 + 1)})" if cats else 0
    s[f"B{rt}"].font = FBOLD
    r1 = rt + 2
    head(r1, ["指標", "値"])
    metrics = [("完了までの時間（中央値・h）", "=IFERROR(MEDIAN(一覧!H:H),0)", "0.0"), ("完了までの時間（平均・h）", "=IFERROR(AVERAGE(一覧!H:H),0)", "0.0"),
               ("完了した不具合", "=B5", None), ("完了した改善", "=C5", None),
               ("洗い出しで見つかった不具合", "=COUNTA(洗い出し!B:B)-1", None), ("そのうち対応中", '=COUNTIF(洗い出し!D:D,"対応中")', None)]
    for i, (k, f, nf) in enumerate(metrics, r1 + 1):
        s.cell(row=i, column=1, value=k).font = F
        c = s.cell(row=i, column=2, value=f)
        c.font = F
        if nf:
            c.number_format = nf
    # Excel で開いたときに式を計算し直す（このスクリプトは値を入れない）
    wb.calculation.fullCalcOnLoad = True
    wb.save(out)
    print(f"{out}：一覧 {len(items)} 件・止まった記録 {len(events)} 件・洗い出し {len(found)} 件")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "pipeline-report.xlsx")
