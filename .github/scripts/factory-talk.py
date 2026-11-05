#!/usr/bin/env python3
"""工場の相談（factory-talk.yml）：案・見た目の方向・ざっくり画面・最終確認を、オーナーに選んでもらいながら決める。

今までに決まった事（state）は、工場が Issue に書いたコメントの印 <!-- factory-talk:v1:BASE64 --> に入れておき、毎回そこから読む。
AIは talk/ にファイルを書くだけ。形を確かめる・コメントを作る・次の段階を決めるのは、このスクリプト（入力から出力が決まる。テストは tests/test-factory-talk.sh）。

  factory-talk.py init MEMO DETAIL                     最初の state（段階は ideas）
  factory-talk.py state COMMENTS.json                  コメントの一覧（gh api の配列）から、いちばん新しい state を取り出す（無ければ {}）
  factory-talk.py answer < 返事の本文                   返事に agent-desk が入れた印 <!-- factory-answer:... --> があれば、その JSON（無ければ空）
  factory-talk.py apply STATE.json REPLY.json          返事を当てはめて {"next": 次にすること, "state": 新しい state, "message": 文}
  factory-talk.py check STAGE DIR                      AIが書いた物（DIR/ideas.json など）の形を確かめ、整えた JSON を出す（だめなら終了コード 1）
  factory-talk.py merge STATE.json STAGE OUT.json PATH 段階の結果を state に入れる（オーナーに聞く選択肢と質問 ask も）。PATH はその段階の画像の置き場（factory-talk ブランチの中）
  factory-talk.py render STATE.json ROOT               オーナーに見せるコメント（印つき）。ROOT は factory-talk ブランチの中身の URL（末尾の / なし）
  factory-talk.py mark STATE.json                      印だけ（作れなかったときのコメントに付けて、次の返事で同じ段階をやり直せるようにする）
  factory-talk.py brief STATE.json                     作り始めるときに工場へ渡す物（name・stack・description・detail・mock）
"""
import base64
import json
import re
import sys

MARK = "factory-talk:v1:"
STAGES = ["ideas", "looks", "mocks", "confirm"]
STACKS = ["nextjs", "saas", "python", "game", "webgame"]
NAME_RE = re.compile(r"^[a-z][a-z0-9-]{2,38}$")
BOT = "github-actions[bot]"


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def text(v, limit):
    """1行の文に整える（改行・バッククォート・HTML の印を消し、長さを切る）"""
    if not isinstance(v, str):
        return ""
    v = re.sub(r"[\r\n\t]+", " ", v).replace("`", "'").replace("<", "＜").replace(">", "＞").strip()
    return v[:limit]


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def encode(state):
    raw = json.dumps(state, ensure_ascii=False, separators=(",", ":")).encode()
    return "<!-- " + MARK + base64.b64encode(raw).decode() + " -->"


def decode(body):
    m = re.search(r"<!-- " + re.escape(MARK) + r"([A-Za-z0-9+/=]+) -->", body or "")
    if not m:
        return None
    try:
        v = json.loads(base64.b64decode(m.group(1)).decode())
        return v if isinstance(v, dict) else None
    except Exception:
        return None


# ---- 質問 ----

def questions(raw):
    out = []
    for q in (raw or [])[:5]:
        if not isinstance(q, dict):
            continue
        qq = text(q.get("q"), 120)
        opts = [text(o, 60) for o in (q.get("options") or []) if text(o, 60)][:4]
        if not qq or len(opts) < 2:
            continue
        rec = q.get("recommend")
        rec = rec if isinstance(rec, int) and 0 <= rec < len(opts) else 0
        out.append({"q": qq, "options": opts, "recommend": rec})
    return out


# ---- AIが書いた物を確かめる ----

def check(stage, d):
    try:
        data = load(f"{d}/{stage}.json")
    except Exception as e:
        die(f"{stage}.json が読めない：{e}")
    if not isinstance(data, dict):
        die(f"{stage}.json がオブジェクトでない")
    out = {"questions": questions(data.get("questions"))}
    if stage == "ideas":
        ideas = []
        for i in data.get("ideas") or []:
            if not isinstance(i, dict):
                continue
            name, stack = str(i.get("name", "")), str(i.get("stack", ""))
            if not NAME_RE.match(name) or stack not in STACKS:
                continue
            ideas.append({"name": name, "stack": stack, "title": text(i.get("title"), 24) or name,
                          "pitch": text(i.get("pitch"), 160), "who": text(i.get("who"), 160),
                          "paid": text(i.get("paid"), 200) if stack == "saas" else "",
                          "novel": text(i.get("novel"), 200), "screen": text(i.get("screen"), 200)})
        if len(ideas) < 3:
            die(f"使える案が {len(ideas)} 個しかない（3個以上要る）")
        out["ideas"] = ideas[:5]
    elif stage == "looks":
        looks = []
        for n, l in enumerate((data.get("looks") or [])[:3], 1):
            if not isinstance(l, dict) or not png(f"{d}/look-{n}-1440.png"):
                continue
            looks.append({"n": n, "title": text(l.get("title"), 30) or f"方向{n}", "idea": text(l.get("idea"), 160),
                          "colors": [c for c in (l.get("colors") or []) if isinstance(c, str) and re.match(r"^#[0-9A-Fa-f]{6}$", c)][:8],
                          "fonts": text(l.get("fonts"), 80),
                          "refs": [u for u in (l.get("refs") or []) if isinstance(u, str) and re.match(r"^https://[^\s<>\"]{4,200}$", u)][:5]})
        if len(looks) < 2:
            die(f"画像のある方向が {len(looks)} 個しかない（2個以上要る）")
        out["looks"] = looks
    elif stage == "mocks":
        mocks = []
        for key, m in zip("ab", (data.get("mocks") or [])[:2]):
            if not isinstance(m, dict) or not png(f"{d}/mock-{key}-1440.png") or not png(f"{d}/mock-{key}-390.png"):
                continue
            mocks.append({"key": key, "title": text(m.get("title"), 30) or key.upper(), "note": text(m.get("note"), 160)})
        if not mocks:
            die("画像のある画面の案が無い")
        out["mocks"] = mocks
    elif stage == "confirm":
        name, stack = str(data.get("name", "")), str(data.get("stack", ""))
        if not NAME_RE.match(name):
            die(f"名前「{name}」の形が違う")
        if stack not in STACKS:
            die(f"種類「{stack}」が違う")
        desc = text(data.get("description"), 120)
        if not desc:
            die("説明が無い")
        price = data.get("price")
        saas = stack == "saas"
        if saas and not (isinstance(price, int) and 100 <= price <= 3000):
            die("saas の値段（100〜3000 の整数）が無い")
        lst = lambda k: [text(x, 80) for x in (data.get(k) or []) if text(x, 80)][:8]
        out.update({"name": name, "stack": stack, "description": desc, "free": lst("free") if saas else [],
                    "paid": lst("paid") if saas else [], "price": price if saas else None, "pages": lst("pages")})
    else:
        die(f"知らない段階：{stage}")
    return out


def png(path):
    try:
        with open(path, "rb") as f:
            head = f.read(8)
            f.seek(0, 2)
            size = f.tell()
        return head == b"\x89PNG\r\n\x1a\n" and 0 < size <= 8 * 1024 * 1024
    except OSError:
        return False


# ---- 返事を当てはめる ----

def apply(state, reply):
    state = json.loads(json.dumps(state))
    stage = state.get("stage")
    action = reply.get("action")
    choice = str(reply.get("choice") or "").strip().lower()
    note = text(reply.get("note"), 400)
    for a in reply.get("answers") or []:
        if isinstance(a, dict) and text(a.get("q"), 120) and text(a.get("a"), 200):
            q = text(a.get("q"), 120)
            state["answers"] = [x for x in state.get("answers", []) if x.get("q") != q] + [{"q": q, "a": text(a.get("a"), 200)}]
    if note:
        state.setdefault("notes", []).append({"stage": stage, "note": note})

    def clarify(msg):
        return {"next": "clarify", "state": state, "message": msg}

    if stage not in STAGES:
        return clarify("いまは選ぶ物がありません。")
    if action == "redo":
        return {"next": stage, "state": state, "message": ""}
    if action == "go" and stage != "confirm" and choice:
        action = "pick"
    if stage == "confirm":
        if action == "go":
            state["stage"] = "go"
            return {"next": "go", "state": state, "message": ""}
        return clarify(text(reply.get("message"), 300) or "作り始めてよければ「作る」、直したい所があればその内容を書いてください。")
    if action != "pick":
        return clarify(text(reply.get("message"), 300) or "どれにするか、番号で書いてください。")
    if stage == "ideas":
        n = int(choice) if choice.isdigit() else 0
        if not 1 <= n <= len(state.get("ideas", [])):
            return clarify(f"案は 1〜{len(state.get('ideas', []))} の番号で選んでください。")
        state["idea"] = n - 1
        # 画面の無い物（python）は、見た目を選ばずに最終確認へ
        state["stage"] = "confirm" if state["ideas"][n - 1]["stack"] == "python" else "looks"
    elif stage == "looks":
        ns = [l["n"] for l in state.get("looks", [])]
        n = int(choice) if choice.isdigit() else 0
        if n not in ns:
            return clarify(f"見た目の方向は {'・'.join(map(str, ns))} の番号で選んでください。")
        state["look"] = n
        state["stage"] = "mocks"
    elif stage == "mocks":
        keys = [m["key"] for m in state.get("mocks", [])]
        if choice not in keys:
            return clarify(f"画面は {'・'.join(k.upper() for k in keys)} で選んでください。")
        state["mock"] = choice
        state["stage"] = "confirm"
    return {"next": state["stage"], "state": state, "message": ""}


def merge(state, stage, out, path):
    state = json.loads(json.dumps(state))
    state["stage"] = stage
    state.setdefault("assets", {})[stage] = path
    state["round"] = int(state.get("round", 0)) + 1
    state["ask"] = {"questions": out.get("questions", [])}
    if stage == "confirm":
        state["confirm"] = {k: v for k, v in out.items() if k != "questions"}
    else:
        state[stage] = out[stage]
    return state


# ---- オーナーに見せるコメント ----

def render(state, root):
    stage = state.get("stage")
    assets = state.get("assets") or {}
    imgbase = f"{root}/{assets.get('mocks' if stage == 'confirm' else stage, '')}"
    r = state.get("round", 0)
    L = []
    if stage == "ideas":
        L.append("## 🧭 作る物の案を5つ考えました\n")
        for n, i in enumerate(state.get("ideas", []), 1):
            L.append(f"### {n}. {i['title']}（`{i['name']}`・{i['stack']}）")
            L.append(i["pitch"] + "\n")
            for label, k in (("使う人", "who"), ("新しい所", "novel"), ("有料", "paid"), ("画面", "screen")):
                if i.get(k):
                    L.append(f"- **{label}**：{i[k]}")
            L.append("")
        how = "番号で1つ選んでください（例：`2`・`2。名前はもっと短く`）。どれも違えば「全部ちがう。もっと〇〇」と書くと出し直します。"
    elif stage == "looks":
        idea = state["ideas"][state["idea"]]
        L.append(f"## 🎨 「{idea['title']}」の見た目の方向を3つ作りました\n")
        for l in state.get("looks", []):
            L.append(f"### {l['n']}. {l['title']}")
            L.append(l["idea"] + "\n")
            if l.get("colors"):
                L.append("- **色**：" + " ".join(f"`{c}`" for c in l["colors"]))
            if l.get("fonts"):
                L.append(f"- **文字**：{l['fonts']}")
            if l.get("refs"):
                L.append("- **参考**：" + "・".join(l["refs"]))
            L.append(f"\n<img src=\"{imgbase}/look-{l['n']}-1440.png\" width=\"720\" alt=\"方向{l['n']}\">\n")
        how = "番号で1つ選んでください（例：`1`・`1。でも色は2の方が好き`）。どれも違えば「全部ちがう。もっと〇〇」。"
    elif stage == "mocks":
        L.append("## 🖼 ざっくり画面を2案作りました（左が PC、右がスマホ）\n")
        for m in state.get("mocks", []):
            L.append(f"### {m['key'].upper()}. {m['title']}")
            L.append(m["note"] + "\n")
            L.append(f"<img src=\"{imgbase}/mock-{m['key']}-1440.png\" width=\"560\" alt=\"{m['key'].upper()} PC\"> "
                     f"<img src=\"{imgbase}/mock-{m['key']}-390.png\" width=\"150\" alt=\"{m['key'].upper()} スマホ\">\n")
        how = "A か B で選んでください（例：`A`・`A の配置で B の色`）。どちらも違えば「両方ちがう。もっと〇〇」。"
    elif stage == "confirm":
        c = state.get("confirm", {})
        L.append("## ✅ これで作り始めます（最終確認）\n")
        L.append(f"- **名前**：`{c.get('name')}`（{c.get('stack')}）")
        L.append(f"- **何のサービス**：{c.get('description')}")
        if c.get("stack") == "saas":
            L.append(f"- **無料**：{'・'.join(c.get('free', []))}")
            L.append(f"- **有料（月 {c.get('price')} 円）**：{'・'.join(c.get('paid', []))}")
        if c.get("pages"):
            L.append(f"- **最初に作る画面**：{'・'.join(c['pages'])}")
        if state.get("answers"):
            L.append("- **決まった事**：" + "／".join(f"{a['q']} → {a['a']}" for a in state["answers"]))
        if state.get("mock"):
            k = state["mock"]
            L.append(f"\n<img src=\"{imgbase}/mock-{k}-1440.png\" width=\"560\" alt=\"選んだ画面\"> "
                     f"<img src=\"{imgbase}/mock-{k}-390.png\" width=\"150\" alt=\"選んだ画面 スマホ\">\n")
        how = "よければ「**作る**」と返事してください。リポジトリや Supabase を作り始めます。直したい所があれば、その内容を書いてください（確認を作り直します）。"
    else:
        die(f"見せる物の無い段階：{stage}")
    qs = state.get("ask", {}).get("questions", [])
    if qs:
        L.append("## ❓ 質問\n")
        for qn, q in enumerate(qs, 1):
            L.append(f"**Q{qn}. {q['q']}**")
            for on, o in enumerate(q["options"]):
                L.append(f"- {chr(65 + on)}. {o}{'（おすすめ）' if on == q['recommend'] else ''}")
            L.append("")
        how += " 質問は `Q1はA、Q2はB` のように（選択肢に無い答えもOK）。"
    L.append("---\n" + how + f"\n\n<sub>工場の相談・{r} 回目。返事を書くと続きを始めます（答えるまで待ちます）</sub>\n")
    L.append(encode(state))
    return "\n".join(L)


def brief(state):
    c = state.get("confirm") or {}
    idea = (state.get("ideas") or [{}])[state.get("idea", 0)] if state.get("ideas") else {}
    lines = [f"オーナーと相談して決めた事（工場の相談で、案・見た目の方向・画面をオーナーが選んだ）："]
    if idea:
        lines.append(f"- 選んだ案：{idea.get('title')}。{idea.get('pitch')}")
        for label, k in (("使う人", "who"), ("新しい所", "novel"), ("画面", "screen")):
            if idea.get(k):
                lines.append(f"- {label}：{idea[k]}")
    if c.get("stack") == "saas":
        lines.append(f"- 無料：{'・'.join(c.get('free', []))}")
        lines.append(f"- 有料（月 {c.get('price')} 円。factory-price.txt にこの数字を書く）：{'・'.join(c.get('paid', []))}")
    if c.get("pages"):
        lines.append(f"- 最初に作る画面：{'・'.join(c['pages'])}")
    if state.get("look") and state.get("looks"):
        l = next((x for x in state["looks"] if x["n"] == state["look"]), None)
        if l:
            lines.append(f"- 見た目の方向：{l['title']}。{l['idea']}（色 {' '.join(l.get('colors', []))}・文字 {l.get('fonts', '')}）")
    for a in state.get("answers", []):
        lines.append(f"- {a['q']} → {a['a']}")
    for n in state.get("notes", []):
        lines.append(f"- オーナーの注文（{n['stage']}）：{n['note']}")
    detail = "\n".join(lines)
    assets = state.get("assets") or {}
    files = []
    if state.get("mock") and assets.get("mocks"):
        k = state["mock"]
        files += [f"{assets['mocks']}/mock-{k}.html", f"{assets['mocks']}/mock-{k}-1440.png", f"{assets['mocks']}/mock-{k}-390.png"]
    if state.get("look") and assets.get("looks"):
        files.append(f"{assets['looks']}/look-{state['look']}-1440.png")
    return {"name": c.get("name") or idea.get("name", ""), "stack": c.get("stack") or idea.get("stack", ""),
            "description": c.get("description", ""), "detail": detail[:6000], "files": files}


def main():
    a = sys.argv[1:]
    if not a:
        die(__doc__)
    cmd = a[0]
    if cmd == "init":
        print(json.dumps({"v": 1, "stage": "ideas", "round": 0, "memo": text(a[1], 300), "detail": (a[2] if len(a) > 2 else "")[:3000],
                          "answers": [], "notes": []}, ensure_ascii=False))
    elif cmd == "state":
        comments = load(a[1])
        found = {}
        for c in comments if isinstance(comments, list) else []:
            if (c.get("user") or {}).get("login") == BOT:
                s = decode(c.get("body"))
                if s:
                    found = s
        print(json.dumps(found, ensure_ascii=False))
    elif cmd == "answer":
        body = sys.stdin.read()
        m = re.search(r"<!-- factory-answer:([A-Za-z0-9+/=]+) -->", body)
        if m:
            try:
                v = json.loads(base64.b64decode(m.group(1)).decode())
                if isinstance(v, dict) and v.get("action") in ("pick", "redo", "go"):
                    print(json.dumps(v, ensure_ascii=False))
            except Exception:
                pass
    elif cmd == "apply":
        print(json.dumps(apply(load(a[1]), load(a[2])), ensure_ascii=False))
    elif cmd == "check":
        print(json.dumps(check(a[1], a[2]), ensure_ascii=False))
    elif cmd == "merge":
        print(json.dumps(merge(load(a[1]), a[2], load(a[3]), a[4]), ensure_ascii=False))
    elif cmd == "render":
        print(render(load(a[1]), a[2].rstrip("/")))
    elif cmd == "mark":
        print(encode(load(a[1])))
    elif cmd == "brief":
        print(json.dumps(brief(load(a[1])), ensure_ascii=False))
    else:
        die(__doc__)


if __name__ == "__main__":
    main()
