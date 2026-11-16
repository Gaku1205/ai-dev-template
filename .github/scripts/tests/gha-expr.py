#!/usr/bin/env python3
# GitHub Actions の式（ジョブの if など）を、テストの中で評価する小さい道具。
# 使うのは、ワークフローの条件が「誰のどのイベントで真になるか」を確かめるテストだけ（test-workflows.sh）。
# 対応：文字列（'…'）・数・true/false/null、文脈（github.event.x.y・vars.X）、==・!=・&&・||・!・かっこ、contains()・startsWith()・fromJSON()
# 比べ方は GitHub と同じ「ゆるい比較」：型が違えば両方を数にする（null→0、''→0、数に読めない文字列→NaN）。文字列どうしは大文字小文字を区別しない
#   使い方：gha-expr.py '式' '文脈のJSON'   → true / false を出す
import json, math, re, sys

TOKEN = re.compile(r"\s*(?:(?P<str>'(?:[^']|'')*')|(?P<num>-?\d+(?:\.\d+)?)|(?P<op>==|!=|&&|\|\||[()!,])|(?P<name>[A-Za-z_][\w.\-*]*))")


def tokenize(src):
    pos, out = 0, []
    src = src.strip()
    while pos < len(src):
        m = TOKEN.match(src, pos)
        if not m:
            raise SystemExit(f"式を読めません：{src[pos:pos + 30]}")
        pos = m.end()
        kind = m.lastgroup
        out.append((kind, m.group(kind)))
    return out


def to_num(v):
    if v is None:
        return 0.0
    if isinstance(v, bool):
        return 1.0 if v else 0.0
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        if v.strip() == '':
            return 0.0
        try:
            return float(json.loads(v))
        except (ValueError, TypeError):
            return math.nan
    return math.nan


def loose_eq(a, b):
    if isinstance(a, str) and isinstance(b, str):
        return a.lower() == b.lower()
    if type(a) is type(b) and not isinstance(a, (dict, list)):
        return a == b
    x, y = to_num(a), to_num(b)
    return not math.isnan(x) and not math.isnan(y) and x == y


def truthy(v):
    return not (v is None or v is False or v == 0 or v == '' or (isinstance(v, float) and math.isnan(v)))


class Parser:
    def __init__(self, tokens, ctx):
        self.t, self.i, self.ctx = tokens, 0, ctx

    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else (None, None)

    def take(self, value=None):
        kind, v = self.peek()
        if value is not None and v != value:
            raise SystemExit(f"式の形が違います：{value} が要る所に {v}")
        self.i += 1
        return kind, v

    def expr(self):
        left = self.and_()
        while self.peek()[1] == '||':
            self.take()
            right = self.and_()
            left = left if truthy(left) else right
        return left

    def and_(self):
        left = self.cmp()
        while self.peek()[1] == '&&':
            self.take()
            right = self.cmp()
            left = right if truthy(left) else left
        return left

    def cmp(self):
        left = self.unary()
        while self.peek()[1] in ('==', '!='):
            _, op = self.take()
            right = self.unary()
            left = loose_eq(left, right) if op == '==' else not loose_eq(left, right)
        return left

    def unary(self):
        if self.peek()[1] == '!':
            self.take()
            return not truthy(self.unary())
        return self.atom()

    def atom(self):
        kind, v = self.take()
        if kind == 'str':
            return v[1:-1].replace("''", "'")
        if kind == 'num':
            return float(v)
        if v == '(':
            r = self.expr()
            self.take(')')
            return r
        if kind == 'name':
            if self.peek()[1] == '(':
                self.take('(')
                args = []
                while self.peek()[1] != ')':
                    args.append(self.expr())
                    if self.peek()[1] == ',':
                        self.take()
                self.take(')')
                return self.call(v, args)
            if v in ('true', 'false', 'null'):
                return {'true': True, 'false': False, 'null': None}[v]
            cur = self.ctx
            for part in v.split('.'):
                cur = cur.get(part) if isinstance(cur, dict) else None
            return cur
        raise SystemExit(f"式の形が違います：{v}")

    @staticmethod
    def call(name, args):
        name = name.lower()
        if name == 'fromjson':
            return json.loads(args[0])
        if name == 'contains':
            hay, needle = args
            if isinstance(hay, list):
                return any(loose_eq(x, needle) for x in hay)
            return str(needle if needle is not None else '').lower() in str(hay if hay is not None else '').lower()
        if name == 'startswith':
            return str(args[0] or '').lower().startswith(str(args[1] or '').lower())
        raise SystemExit(f"知らない関数：{name}")


p = Parser(tokenize(sys.argv[1]), json.loads(sys.argv[2]))
result = p.expr()
if p.i != len(p.t):
    raise SystemExit("式の終わりに余りがあります")
print('true' if truthy(result) else 'false')
