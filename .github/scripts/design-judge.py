#!/usr/bin/env python3
"""デザインの関門と審査（docs/pipeline.md「デザインの仕組み」）。

作ったAIは自分の画面を甘く見る。そこで、機械で測れる事はこのスクリプトが測り（関門）、絵を見ないと分からない事は別のAI（審査役。.github/factory/judge.md）が
「はい・いいえ」で答え、合格かどうかはこのスクリプトが決める（AIに自分で合格と言わせない）。入力から出力が決まる。テストは tests/test-design-judge.sh。

  design-judge.py gate [--concept FILE [--part looks]] [--lint LINT.json] [--min-real N] [--phone-height PX] [--credits FILE]... --out GATE.json 対象...
      関門。対象は HTML のファイルか、画面のソースのフォルダ（src など）。
      ・設計メモ（concept.md）に、持ち物・考え・通し表があるか
      ・本物の絵（出どころの記録がある写真・古い地図・図版、撮った実在の画面）が何枚、画面で使われているか
      ・--phone-height：390 幅で撮ったページ全体の高さ（測れたときだけ。5,000px 超なら short は「いいえ」）
      ・taste-skill の lint.mjs --json の FAIL
      結果を GATE.json に書き、直すAIが読む文（problems）も入れる。終了コードは常に 0。GITHUB_OUTPUT に ok=true|false
  design-judge.py brief --state STATE.json [--concept FILE] [--stage looks|mocks]
      工場の相談の state から、審査役に渡す紙（何のサービスか・オーナーが決めた事）を出す
  design-judge.py verdict --mode looks|screen|change VERDICT.json [--gate GATE.json] --out RESULT.json [--fix FIX.md] [--critique FILE]
      審査役が書いた VERDICT.json を確かめ、上限を当てはめて点を出し、合格かどうかを決める。
      FIX.md は直すAIが読む紙。--critique は実装の審査の形（1行目「点数: 7.5」）で書く。GITHUB_OUTPUT に pass=true|false|none と score
  design-judge.py summary RESULT.json [RESULT2.json]
      オーナーに見せる1〜数行（1回目と、直した後の2回目）
  design-judge.py summary --picked N|"" RESULT0.json RESULT1.json [RESULT2.json]
      案が複数のとき：各案の点と、選んだ案（N は 0 始まり。空なら選べなかった）
  design-judge.py pick RESULT0.json RESULT1.json [RESULT2.json]
      複数の案の審査結果（verdict の --out）から使う案を選ぶ。合格した案の中で最高点、合格が無ければ最高点、同点は番号が小さい方。
      審査できなかった案は選ばない。GITHUB_OUTPUT に index（0 始まり。全部審査できなければ空）と fix=true|false
      （合格した案が無く、最高点が合格の点より 1.5 点以上低いときだけ true）
"""
import json
import os
import re
import sys

PASS_LINE = 7.5
PICK_FIX_GAP = 1.5  # 複数案：最高点が PASS_LINE よりこれ以上低いときだけ直しの回を行う
WEIGHTS = {"design": 0.4, "use": 0.3, "idea": 0.2, "content": 0.1}
SCORE_NAMES = {"design": "見た目", "use": "使いやすさ", "idea": "考え", "content": "中身"}

# 審査役が「はい・いいえ」で答える問い。id：(問いの名前, 必ず通す物か, いいえのときに点の上限を掛ける欄, 上限)
CHECKS = {
    "one": ("1秒で主役が1つ見える", False, "design", 7.0),
    "swap": ("この題材だけの考えがある（名前と題材をほかの業種に入れ替えたら成り立たない）", True, "idea", 6.0),
    "real": ("本物の素材が主役の位置にある（描いた代用品・灰色の箱・偽の画面ではない）", True, "design", 6.5),
    "through": ("考えが、最初の1画面だけでなく、下の欄・ほかの画面まで通っている", True, "idea", 6.5),
    "full": ("地味でない（空の帯・片寄り・小さい灰色の文字ばかりの画面が無く、大きい文字・色の面・絵・中身で埋まっている）", True, "design", 6.5),
    "tells": ("AIが作った画面の型が見えない", True, "overall", 6.5),
    "broken": ("崩れが無い（重なり・はみ出し・揃っていない列・読めない文字）", True, "use", 5.0),
    "owner": ("オーナーが決めた事が、絵に出ている", True, "overall", 6.0),
    "variety": ("同じ構図の欄が続いていない", False, "design", 7.0),
    "phone": ("スマホの画面が、PC を縮めただけでなく1画面として成立している", False, "use", 7.0),
    "beside": ("実例の隣に置いても、どれがAIの作った物か一目では分からない", False, "overall", 7.0),
    "world": ("題材の世界観が最初の1画面で伝わる（白地・灰色の角丸・英字ロゴの無難な SaaS の見た目ではない）", True, "design", 6.5),
    "sample": ("例の値が入力欄に見える（本物のような値が最初から入っていて入力欄と分からない、ということが無い。空欄・薄い例・「例」の表示は「はい」）", False, "use", 7.0),
    "short": ("スマホのページが長すぎない（縦 5,000px 以下で、主な操作が最初の1画面に入っている）", False, "use", 7.0),
    "fits": ("新しく足した所が、このサービスらしさ（docs/design.md）の通し方で作られている", True, "idea", 6.5),
}
MODES = {
    # 見た目の方向の板（最初の1画面だけ）
    "looks": ["one", "swap", "real", "full", "tells", "owner", "world", "sample"],
    # ざっくり画面・工場が作った本物の画面（ページの全部）
    "screen": ["one", "swap", "real", "through", "full", "tells", "broken", "owner", "variety", "phone", "beside", "world", "sample", "short"],
    # 今あるアプリへの変更（Issue の実装）
    "change": ["fits", "full", "tells", "broken", "phone", "world", "sample", "short"],
}
SET_CHECKS = {"looks": {"distinct": "3つの方向が、色違いではなく、考え（題材のどの持ち物を主役にするか）から違う"}}

RASTER = (".jpg", ".jpeg", ".png", ".webp", ".avif")
MIN_BYTES = 15 * 1024
PHONE_MAX_HEIGHT = 5000


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(2)


def text(v, limit):
    if not isinstance(v, str):
        return ""
    v = re.sub(r"[\r\n\t]+", " ", v).replace("`", "'").replace("<", "＜").replace(">", "＞").replace("@", "＠").strip()
    return v[:limit]


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def output(**kv):
    path = os.environ.get("GITHUB_OUTPUT")
    for k, v in kv.items():
        print(f"{k}={v}")
        if path:
            with open(path, "a", encoding="utf-8") as f:
                f.write(f"{k}={v}\n")


def args_of(a, flags, multi=()):
    """--name 値 の形の引数を取り出す。残りは対象"""
    opts = {k: ([] if k in multi else None) for k in flags}
    rest = []
    i = 0
    while i < len(a):
        if a[i].startswith("--") and a[i][2:] in opts:
            k = a[i][2:]
            if i + 1 >= len(a):
                die(f"{a[i]} の値が無い")
            if k in multi:
                opts[k].append(a[i + 1])
            else:
                opts[k] = a[i + 1]
            i += 2
        else:
            rest.append(a[i])
            i += 1
    return opts, rest


# ---- 関門：設計メモ ----

def concept_check(path, part="all"):
    """設計メモに、持ち物（8個以上）・考え・通し表（3行以上）があるか。種類（ページか道具の画面か）も読む。
    part が looks（見た目の方向の段階）のときは、持ち物と「考えの候補」3つだけを見る（考えと通し表は、方向を選んだ後に書く）"""
    problems = []
    kind = "page"
    try:
        with open(path, encoding="utf-8", errors="ignore") as f:
            s = f.read(60000)
    except OSError:
        return kind, ["設計メモ（concept.md）が無い。.github/factory/concept.md のとおりに、作る前に書く"]
    m = re.search(r"^種類[:：]\s*(.+)$", s, re.M)
    if m and re.search(r"道具|アプリ|管理|app", m.group(1)):
        kind = "app"

    def section(name):
        mm = re.search(r"^##\s*" + name + r"[ \t]*(?:[（(][^\n]*)?\n(.*?)(?=^##\s|\Z)", s, re.S | re.M)
        return mm.group(1) if mm else ""

    have = [l for l in section("持ち物").splitlines() if re.match(r"\s*([-*]|\d+[.)])\s+\S", l)]
    if len(have) < 8:
        problems.append(f"設計メモの「## 持ち物」が {len(have)} 個しかない（この題材にしか無い物を 8 個以上、1行1つの箇条書きで）")
    if part == "looks":
        cands = [l for l in section("考えの候補").splitlines() if "が" in l and "になる" in l]
        if len(cands) < 3:
            problems.append(f"設計メモの「## 考えの候補」が {len(cands)} 個しかない（「（持ち物）が（仕掛け）になる」の文を3つ。3つは別々の持ち物から）")
        return kind, problems
    idea = [l for l in section("考え").splitlines() if l.strip()]
    if not idea or not any("が" in l and "になる" in l for l in idea):
        problems.append("設計メモの「## 考え」に、「この画面では、（題材の持ち物）が（画面の仕掛け）になる」の1文が無い")
    rows = [l for l in section("通し表").splitlines() if l.strip().startswith("|") and not re.match(r"\s*\|[\s:|-]+\|\s*$", l)]
    if len(rows) < 4:  # 見出しの行 + 3行
        problems.append("設計メモの「## 通し表」が足りない（欄・画面ごとに1行、3行以上。考えがその欄でどう出るか・主役・使う本物の素材）")
    return kind, problems


# ---- 関門：本物の絵 ----

def credited_names(files):
    """出どころの記録（fetch-photos.sh の CREDITS.md、assets.mjs の credits.json）にあるファイル名"""
    names = set()
    for p in files:
        try:
            with open(p, encoding="utf-8", errors="ignore") as f:
                s = f.read(400000)
        except OSError:
            continue
        for m in re.finditer(r"[\w.()%+-]+\.(?:jpe?g|png|webp|avif)", s, re.I):
            names.add(m.group(0).lower())
    return names


def source_files(targets):
    out = []
    for t in targets:
        if os.path.islink(t):
            continue
        if os.path.isdir(t):
            for root, dirs, files in os.walk(t):
                dirs[:] = [d for d in dirs if d not in ("node_modules", ".next", ".git", "dist", "build")]
                for f in files:
                    if f.endswith((".html", ".htm", ".tsx", ".jsx", ".ts", ".js", ".css", ".mdx", ".vue", ".svelte")) and not os.path.islink(os.path.join(root, f)):
                        out.append(os.path.join(root, f))
        elif os.path.isfile(t):
            out.append(t)
    return out[:400]


def image_refs(path):
    try:
        with open(path, encoding="utf-8", errors="ignore") as f:
            s = f.read(2000000)
    except OSError:
        return [], 0
    refs = re.findall(r"""["'(=\s]([^"'()\s<>]+?\.(?:jpe?g|png|webp|avif))(?=["')\s?#])""", s, re.I)
    drawn = len(re.findall(r"<svg\b", s))
    return refs, drawn


def resolve(ref, src, public_dirs):
    if re.match(r"^(https?:)?//|^data:", ref):
        return None
    if ref.startswith("/"):
        for p in public_dirs:
            c = os.path.join(p, ref.lstrip("/"))
            if os.path.isfile(c):
                return c
        return os.path.join(public_dirs[0], ref.lstrip("/")) if public_dirs else None
    return os.path.normpath(os.path.join(os.path.dirname(src), ref))


def gate(a):
    opts, targets = args_of(a, ["concept", "part", "lint", "min-real", "phone-height", "out", "credits"], multi=("credits",))
    if not opts["out"] or not targets:
        die(__doc__)
    problems = []
    kind = "page"
    if opts["concept"]:
        kind, cp = concept_check(opts["concept"], opts["part"] or "all")
        problems += cp
    files = source_files(targets)
    public_dirs = [p for p in ("public",) if os.path.isdir(p)]
    credit_files = list(opts["credits"])
    seen, real, uncredited, missing, drawn = set(), [], [], [], 0
    for src in files:
        refs, d = image_refs(src)
        drawn += d
        for ref in refs:
            p = resolve(ref, src, public_dirs)
            if not p or p in seen:
                continue
            seen.add(p)
            if os.path.islink(p) or not os.path.isfile(p):
                missing.append(ref)
                continue
            d0 = os.path.dirname(p)
            for c in (os.path.join(d0, "CREDITS.md"), os.path.join(d0, "credits.json")):
                if c not in credit_files and os.path.isfile(c):
                    credit_files.append(c)
    names = credited_names(credit_files)
    for p in sorted(seen):
        if not os.path.isfile(p) or os.path.islink(p) or not p.lower().endswith(RASTER):
            continue
        if os.path.getsize(p) < MIN_BYTES:
            continue
        # 出どころの記録がある物（探して取ってきた写真・地図・図版）と、shot.mjs で撮った実在の画面（shots・refs・screens の中）を本物と数える
        if os.path.basename(p).lower() in names or re.search(r"(^|/)(shots|refs|screens|screenshots)(/|$)", p.replace(os.sep, "/")):
            real.append(p)
        else:
            uncredited.append(p)
    # 道具の画面は、写真の枚数を問わない（本物らしいデータで見る。審査役の real）
    want = 0 if kind == "app" else int(opts["min-real"] if opts["min-real"] is not None else 3)
    if missing:
        problems.append("画面が使っている画像のファイルが無い：" + "、".join(missing[:6]))
    if len(real) < want:
        msg = f"本物の絵が {len(real)} 枚しか使われていない（{want} 枚以上要る）。題材の世界の本物の写真・古い地図・図版を assets.mjs か fetch-photos.sh で探して取り、主役の位置に大きく使う。描いた絵や色の箱で代用しない"
        if uncredited:
            msg += f"（出どころの記録が無い画像が {len(uncredited)} 枚ある：{'、'.join(os.path.basename(p) for p in uncredited[:4])}。記録の無い画像は本物と数えない）"
        problems.append(msg)
    lint_fail = []
    if opts["lint"]:
        try:
            for f in load(opts["lint"]).get("findings", []):
                if isinstance(f, dict) and f.get("level") == "FAIL":
                    lint_fail.append({"id": text(str(f.get("id")), 40), "file": text(str(f.get("file")), 120), "line": f.get("line") if isinstance(f.get("line"), int) else 0,
                                      "match": text(str(f.get("match")), 80)})
        except Exception:
            problems.append("lint.mjs の結果が読めない（測れていない）")
    if lint_fail:
        ids = sorted({f["id"] for f in lint_fail})
        problems.append(f"lint.mjs の FAIL が {len(lint_fail)} 個（{'・'.join(ids)}）。消すだけにせず、消した所は大きい文字・色の面・本物の絵・中身で埋める："
                        + "；".join(f"{f['file']}:{f['line']} {f['match']}" for f in lint_fail[:8]))
    phone_height = 0
    if opts["phone-height"]:
        try:
            phone_height = max(0, int(float(opts["phone-height"])))
        except ValueError:
            problems.append("--phone-height が数字でない（測れていない）")
    result = {"ok": not problems, "kind": kind, "phone_height": phone_height, "real": len(real), "min_real": want, "drawn": drawn, "uncredited": len(uncredited), "missing": missing[:20],
              "lint_fail": lint_fail[:40], "problems": problems}
    with open(opts["out"], "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=1)
    output(ok=str(result["ok"]).lower(), kind=kind, real=len(real))


# ---- 審査役に渡す紙 ----

def brief(a):
    opts, _ = args_of(a, ["state", "concept", "stage"])
    if not opts["state"]:
        die(__doc__)
    st = load(opts["state"])
    L = ["# 審査役に渡す紙（何のサービスか・オーナーが決めた事）", ""]
    ideas = st.get("ideas") or []
    idea = ideas[st["idea"]] if isinstance(st.get("idea"), int) and 0 <= st["idea"] < len(ideas) else {}
    L.append(f"- オーナーの1行：{text(st.get('memo'), 300)}")
    if idea:
        L.append(f"- 作る物：{text(idea.get('title'), 60)}。{text(idea.get('pitch'), 300)}")
        if idea.get("who"):
            L.append(f"- 使う人：{text(idea['who'], 200)}")
        if idea.get("screen"):
            L.append(f"- 画面：{text(idea['screen'], 200)}")
    if opts["stage"] == "mocks" and st.get("look") and st.get("looks"):
        l = next((x for x in st["looks"] if x.get("n") == st["look"]), None)
        if l:
            L.append(f"- オーナーが選んだ見た目の方向：{text(l.get('title'), 60)}。{text(l.get('idea'), 200)}")
    # 見た目の段階（looks・mocks）の答えと注文だけが「絵に出るはずの決め」。案の段階の答え（データの持ち方・お金・遅刻の数え方など）は、
    # 静止画に出せないので owner には使わない（11/19 の #250：全部を渡したら、画面の中に仕様書のような欄を足して答えを絵に出そうとした）。
    # 古い state（stage が無い答え）は、今の段階より前の答えとして中身の決まりに入れる
    visual = ("looks", "mocks")
    answers = [x for x in st.get("answers") or [] if isinstance(x, dict)]
    notes = [n for n in st.get("notes") or [] if isinstance(n, dict)]
    decided = [f"{text(x.get('q'), 120)} → {text(x.get('a'), 200)}" for x in answers if x.get("stage") in visual]
    decided += [f"注文（{text(n.get('stage'), 20)}）：{text(n.get('note'), 400)}" for n in notes]
    content = [f"{text(x.get('q'), 120)} → {text(x.get('a'), 200)}" for x in answers if x.get("stage") not in visual]
    L += ["", "## オーナーが決めた事（見た目の決めと注文。絵に出ていなければ owner は「いいえ」。押した後の動きなど静止画に出せない物は「はい」）", ""]
    L += [f"- {d}" for d in decided] or ["- （まだ無い。owner は「はい」にする）"]
    if content:
        L += ["", "## 中身の決まり（絵に出ていなくてよい。owner の判定に使わない。何のサービスかを知るためだけに読む）", ""]
        L += [f"- {d}" for d in content]
    if opts["concept"] and os.path.isfile(opts["concept"]) and not os.path.islink(opts["concept"]):
        with open(opts["concept"], encoding="utf-8", errors="ignore") as f:
            c = f.read(6000)
        L += ["", "## 作った側が書いた設計メモ（絵を見て「見えた物」を書き終えてから読む。書いてあっても、絵に出ていなければ無いのと同じ）", "", c]
    print("\n".join(L))


# ---- 審査の結果 ----

def score(v):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f if 1 <= f <= 10 else None


def judge_item(raw, mode, gate_result):
    name = text(str(raw.get("name", "")), 40) or "画面"
    checks = raw.get("checks") if isinstance(raw.get("checks"), dict) else {}
    scores = {}
    for k in WEIGHTS:
        s = score((raw.get("scores") or {}).get(k) if isinstance(raw.get("scores"), dict) else None)
        if s is None:
            return None
        scores[k] = s
    answers = {}
    for cid in MODES[mode]:
        c = checks.get(cid)
        ok = c.get("ok") if isinstance(c, dict) else None
        # 答えていない問いは「いいえ」と扱う（答えを飛ばして通さない）
        answers[cid] = {"ok": ok is True, "note": text(c.get("note") if isinstance(c, dict) else "", 300) or ("" if ok is True else "審査役が答えていない")}
    # 構図の言葉が続いていたら、審査役の答えにかかわらず variety は「いいえ」
    layouts = [text(x, 20) for x in raw.get("layouts") or [] if isinstance(x, str)][:16]
    if "variety" in answers and layouts:
        repeat = any(layouts[i] == layouts[i + 1] for i in range(len(layouts) - 1)) or any(layouts.count(x) >= 3 for x in set(layouts))
        if repeat and answers["variety"]["ok"]:
            answers["variety"] = {"ok": False, "note": "構図の言葉が続いている：" + " / ".join(layouts)}
    # 関門で本物の絵が足りないときは、real は「いいえ」
    if "real" in answers and gate_result and gate_result.get("real", 0) < gate_result.get("min_real", 0) and answers["real"]["ok"]:
        answers["real"] = {"ok": False, "note": f"関門：本物の絵が {gate_result.get('real', 0)} 枚（{gate_result.get('min_real', 0)} 枚以上要る）"}
    # スマホのページが 5,000px を超えていたら、審査役の答えにかかわらず short は「いいえ」（測れたときだけ）
    height = gate_result.get("phone_height", 0) if gate_result else 0
    if "short" in answers and isinstance(height, int) and height > PHONE_MAX_HEIGHT and answers["short"]["ok"]:
        answers["short"] = {"ok": False, "note": f"関門：スマホのページの縦が {height}px（{PHONE_MAX_HEIGHT}px 以下にする）"}
    capped = dict(scores)
    overall_cap = 10.0
    failed = []
    for cid, ans in answers.items():
        if ans["ok"]:
            continue
        title, hard, field, cap = CHECKS[cid]
        failed.append({"id": cid, "title": title, "hard": hard, "note": ans["note"]})
        if field == "overall":
            overall_cap = min(overall_cap, cap)
        else:
            capped[field] = min(capped[field], cap)
    if gate_result and gate_result.get("lint_fail"):
        overall_cap = min(overall_cap, 6.5)
    overall = min(sum(capped[k] * w for k, w in WEIGHTS.items()), overall_cap)
    overall = round(overall + 1e-9, 1)
    fixes = []
    for f in (raw.get("fixes") or [])[:5]:
        if isinstance(f, dict) and text(f.get("what"), 300):
            fixes.append({"where": text(f.get("where"), 160), "what": text(f.get("what"), 300), "how": text(f.get("how"), 300)})
    ok = overall >= PASS_LINE and not any(f["hard"] for f in failed)
    return {"name": name, "pass": ok, "overall": overall, "scores": capped, "given": scores, "failed": failed, "fixes": fixes,
            "seen": text(raw.get("seen"), 200), "idea_seen": text(raw.get("idea_seen"), 300), "layouts": layouts}


def fix_text(result, gate_result):
    L = ["# 直すこと（審査役と関門の結果）", "",
         "作った本人とは別のAI（審査役）が、画像だけを見て答えた結果です。合格は、必ず通す問いが全部「はい」で、点が " + f"{PASS_LINE}" + " 以上。",
         "直すときは、消すだけにしない。消した所は、大きい文字・色の面・本物の絵・中身で埋める（.github/factory/concept.md「埋める物」）。指摘が無い所は変えない。", ""]
    if gate_result and gate_result.get("problems"):
        L += ["## 関門（機械で測った物。全部直す）", ""] + [f"- {p}" for p in gate_result["problems"]] + [""]
    for s in result.get("set_failed", []):
        L += [f"## 全体：{s['title']} → いいえ", "", f"- {s['note']}", ""]
    for it in result.get("items", []):
        L += [f"## {it['name']}：{it['overall']} 点（{'合格' if it['pass'] else '直す'}）", ""]
        if it.get("seen"):
            L.append(f"- 審査役が1秒で見た物：{it['seen']}")
        if it.get("idea_seen"):
            L.append(f"- 審査役が絵から読み取った考え：{it['idea_seen']}")
        for f in it["failed"]:
            L.append(f"- 【{'必ず通す' if f['hard'] else '点の上限'}】{f['title']} → いいえ：{f['note']}")
        for n, f in enumerate(it["fixes"], 1):
            L.append(f"- 直し{n}（{f['where']}）：{f['what']}" + (f" → {f['how']}" if f["how"] else ""))
        L.append("")
    return "\n".join(L)


def critique_text(result):
    """実装の審査（open-pr.sh がPRの本文に入れる形）"""
    items = result.get("items", [])
    low = min((it["overall"] for it in items), default=0)
    L = [f"点数: {low}", f"判定: {'通す' if result.get('pass') else '直す'}", "", "## 直すこと", ""]
    n = 0
    for it in items:
        for f in it["failed"]:
            n += 1
            L.append(f"{n}. {f['title']} → いいえ：{f['note']}")
        for f in it["fixes"]:
            n += 1
            L.append(f"{n}. （{f['where']}）{f['what']}" + (f" → {f['how']}" if f["how"] else ""))
    if n == 0:
        L.append("（なし）")
    return "\n".join(L) + "\n"


def verdict(a):
    opts, rest = args_of(a, ["mode", "gate", "out", "fix", "critique"])
    mode = opts["mode"]
    if mode not in MODES or not rest or not opts["out"]:
        die(__doc__)
    gate_result = None
    if opts["gate"] and os.path.isfile(opts["gate"]):
        try:
            gate_result = load(opts["gate"])
        except Exception:
            gate_result = None
    result = {"mode": mode, "pass": False, "judged": False, "items": [], "set_failed": [], "gate_ok": gate_result.get("ok", True) if gate_result else True}
    raw = None
    if os.path.isfile(rest[0]) and not os.path.islink(rest[0]):
        try:
            raw = load(rest[0])
        except Exception:
            raw = None
    items = [judge_item(x, mode, gate_result) for x in (raw.get("items") or [])[:4] if isinstance(x, dict)] if isinstance(raw, dict) else []
    items = [x for x in items if x]
    if items:
        result["judged"] = True
        result["items"] = items
        for sid, title in SET_CHECKS.get(mode, {}).items():
            c = (raw.get("set") or {}).get(sid) if isinstance(raw.get("set"), dict) else None
            if not (isinstance(c, dict) and c.get("ok") is True):
                result["set_failed"].append({"id": sid, "title": title, "note": text(c.get("note") if isinstance(c, dict) else "", 300) or "審査役が答えていない"})
        result["pass"] = all(x["pass"] for x in items) and not result["set_failed"] and result["gate_ok"]
    with open(opts["out"], "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=1)
    if opts["fix"]:
        with open(opts["fix"], "w", encoding="utf-8") as f:
            f.write(fix_text(result, gate_result) + "\n")
    if opts["critique"] and result["judged"]:
        with open(opts["critique"], "w", encoding="utf-8") as f:
            f.write(critique_text(result))
    # 審査役が結果を書かなかった：合格とは言わない（none）。関門が通っていなければ、関門の分だけ直させる
    state = ("true" if result["pass"] else "false") if result["judged"] else ("none" if result["gate_ok"] else "false")
    output(**{"pass": state, "score": min((x["overall"] for x in items), default="")})


def summary_line(result):
    if not result.get("judged"):
        return "審査できなかった（審査役が結果を書かなかった）"
    parts = []
    for it in result["items"]:
        s = f"{it['name']} {it['overall']} 点"
        if not it["pass"]:
            left = [f["title"].split("（")[0] for f in it["failed"] if f["hard"]] or ["点が足りない"]
            s += "（残った指摘：" + "・".join(left[:3]) + "）"
        parts.append(s)
    for s in result.get("set_failed", []):
        parts.append("全体：" + s["title"].split("、")[0] + " → いいえ")
    if not result.get("gate_ok", True):
        parts.append("関門（本物の絵・lint）が通っていない")
    return ("✅ " if result["pass"] else "⚠️ ") + " ／ ".join(parts)


def result_score(r):
    """審査結果の点：見た目の悪い方（verdict の score と同じ）"""
    return min((x["overall"] for x in r.get("items", [])), default=0)


def pick(a):
    """複数の案の審査結果から、使う案を選ぶ。合格した案の中で最高点、合格が無ければ最高点。同点は番号が小さい方。
    審査できなかった案は選ばない。直しが要るのは、最高点が PASS_LINE より 1.5 点以上低く、合格した案が無いときだけ"""
    if not a:
        die(__doc__)
    cands = []
    for i, p in enumerate(a):
        r = None
        if os.path.isfile(p) and not os.path.islink(p):
            try:
                r = load(p)
            except Exception:
                r = None
        if isinstance(r, dict) and r.get("judged") and r.get("items"):
            cands.append((i, bool(r.get("pass")), result_score(r)))
    if not cands:
        output(index="", fix="false")
        return
    pool = [c for c in cands if c[1]] or cands
    best = min(pool, key=lambda c: (-c[2], c[0]))
    fix = not best[1] and best[2] <= PASS_LINE - PICK_FIX_GAP + 1e-9
    output(index=best[0], fix=str(fix).lower())


def summary_multi(paths, picked):
    parts = []
    for i, p in enumerate(paths):
        r = None
        if os.path.isfile(p) and not os.path.islink(p):
            try:
                r = load(p)
            except Exception:
                r = None
        mark = "★" if picked is not None and i == picked else ""
        if isinstance(r, dict) and r.get("judged") and r.get("items"):
            parts.append(f"案{i + 1} {result_score(r)} 点{'（合格）' if r.get('pass') else ''}{mark}")
        else:
            parts.append(f"案{i + 1} 審査できなかった")
    chosen = f"選んだ案：案{picked + 1}" if picked is not None else "選べる案が無かった（審査できなかった）"
    print(f"審査役（作ったAIとは別のAIが、画像だけを見て採点。合格は {PASS_LINE} 点以上で、必ず通す問いが全部「はい」）：" + " ／ ".join(parts) + f" → {chosen}")


def summary(a):
    if not a:
        die(__doc__)
    opts, a = args_of(a, ["picked"])
    if opts["picked"] is not None or len(a) > 2:
        try:
            picked = int(opts["picked"]) if opts["picked"] not in (None, "") else None
        except ValueError:
            picked = None
        summary_multi(a, picked if picked is not None and 0 <= picked < len(a) else None)
        return
    results = []
    for p in a[:2]:
        if os.path.isfile(p) and not os.path.islink(p):
            try:
                results.append(load(p))
            except Exception:
                pass
    if not results:
        return
    line = f"審査役（作ったAIとは別のAIが、画像だけを見て採点。合格は {PASS_LINE} 点以上で、必ず通す問いが全部「はい」）："
    if len(results) == 1:
        print(line + summary_line(results[0]))
    else:
        print(line + f"1回目 {summary_line(results[0])} → 直した後 {summary_line(results[1])}")


def main():
    a = sys.argv[1:]
    if not a:
        die(__doc__)
    cmd, rest = a[0], a[1:]
    if cmd == "gate":
        gate(rest)
    elif cmd == "brief":
        brief(rest)
    elif cmd == "verdict":
        verdict(rest)
    elif cmd == "summary":
        summary(rest)
    elif cmd == "pick":
        pick(rest)
    else:
        die(__doc__)


if __name__ == "__main__":
    main()
