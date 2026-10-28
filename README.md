# ai-dev-template

**Issueにやりたいことを1行書くだけで、AIが清書・実装・レビュー・修正・マージ・公開まで進める**、個人開発用のリポジトリの土台です。

人間がやるのは「何を作るか決める」ことと、AIが判断に迷って止まったときの確認だけ。合否はAIではなくCI（型チェック・リント・テスト・ビルド）が決めます。

```
メモを書く ─▶ 企画AIが清書 ─▶ 実装AI ─▶ PR ─▶ CI ─▶ レビューAI ─▶ 自動マージ ─▶ Vercelで公開 ─▶ スマホに通知
                                          ▲            │           │
                                          └── AIが修正 ◀┴── 失敗・指摘（2回まで。超えたら人間に通知して止まる）
```

詳しい流れ・ラベル・止まる条件・安全のしくみは [docs/pipeline.md](docs/pipeline.md)。

## 使い方

1. このリポジトリの **Use this template** から新しいリポジトリを作る
2. GitHubの Claude アプリを、そのリポジトリに入れる
3. Settings → Secrets and variables → Actions に `CLAUDE_CODE_OAUTH_TOKEN`・`PIPELINE_TOKEN`・`NTFY_TOPIC` を登録する（[docs/pipeline.md](docs/pipeline.md#必要な設定リポジトリの-settings--secrets-and-variables--actions)）
4. Actions → **Setup Labels** を1回実行する
5. `CLAUDE.md` の1行目と `docs/spec.md`・`docs/design.md` にアプリのことを書く
6. Vercelでリポジトリを読み込む（mainにマージされるたびに公開される）
7. Issueの「メモ（AIにおまかせ）」から、やりたいことを書く

## Vercelの公開回数について

Vercelの無料プランには、1日に公開できる回数の上限があります。AIは `claude/*` ブランチに何度もpushするので、そのたびにプレビューを作ると上限をすぐ使い切ってしまいます。

`vercel.json` は、それを防ぐための設定です。`claude/*` ブランチのプレビューは作らず、mainにマージされたときだけ公開されます。

## 中身

| 場所 | 内容 |
| --- | --- |
| `.github/workflows/` | 企画・実装・レビュー・修正のAI（[anthropics/claude-code-action](https://github.com/anthropics/claude-code-action)）、CI、進行役、公開通知 |
| `.github/scripts/` | 進行役の判断（PR作成、CI後・レビュー後・修正後の次の一手、通知） |
| `CLAUDE.md` | AIが守るルール（触ってはいけない場所、作業の終わらせ方、PRの書き方） |
| `docs/` | 仕様書・デザイン仕様・パイプラインの説明。AIは読むだけで書き換えない |
| `src/` | 最小の Next.js（App Router）＋TypeScript＋Vitest |
| `vercel.json` | `claude/*` ブランチのVercelプレビューを作らない設定（Vercelの公開回数の上限を守るため） |

## このテンプレートで作ったもの

- [agent-desk](https://github.com/Gaku1205/agent-desk)：AIに開発を任せるときの進行状況と「人間の判断待ち」を1画面で見るダッシュボード
