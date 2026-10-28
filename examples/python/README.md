# hello-python（Python の見本）

ai-dev-template を Next.js 以外で使う見本。`pipeline.json` で言語と公開先を選んでいる。

- `app/`：API（FastAPI）。`/health` と `/hello?name=...`。**AWS App Runner** で動かす（`Dockerfile`）
- `cli.py`：同じ処理の CLI。**exe にして GitHub Releases** に置く（Windows・Mac）
- 確認コマンド：`ruff check .`・`mypy`・`pytest -q`（CI で全部回し、AI にもこれだけ許す）

テンプレート本体では、`.github/workflows/stack-selftest.yml` がこの見本を本物の GitHub のランナーで通す（確認・Windows と Mac の exe・Docker のイメージの起動）。

## Python のアプリを作るとき

1. ai-dev-template から新しいリポジトリを作る（Use this template）
2. Next.js の物を消す：`src/`・`package.json`・`package-lock.json`・`next.config.ts`・`next-env.d.ts`・`tsconfig.json`・`eslint.config.mjs`・`vitest.config.ts`・`vercel.json`・`AGENTS.md` の Next.js の節
3. この `examples/python/` の中身をリポジトリのルートに移し、`examples/` を消す
4. `pipeline.json` の `service`（App Runner のサービス名）をアプリの名前にする。要らない公開先は消す
5. `CLAUDE.md` の1行目の説明と「コードの書き方」を Python 向けに直す（例：型ヒントを付ける、ロジックは `app/`、テストは `tests/`）
6. Actions の Doctor を実行する。App Runner を使うなら `docs/pipeline.md`「AWS App Runner」の手順で Variable を3つ入れる

手元で動かす：

```bash
python -m venv .venv && . .venv/bin/activate
pip install -r requirements-dev.txt
pytest -q
uvicorn app.main:app --reload       # http://localhost:8000/hello?name=you
python cli.py you                   # Hello, you!
```
