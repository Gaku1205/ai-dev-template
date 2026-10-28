# ai-dev-template

**Issueにやりたいことを1行書くだけで、AIが清書・実装・レビュー・修正・マージ・公開まで進める**、個人開発用のリポジトリの土台です。

人間がやるのは「何を作るか決める」ことと、AIが判断に迷って止まったときの確認だけ。合否はAIではなくCI（型チェック・リント・テスト・ビルド）が決めます。

## 流れ

```
メモを書く ─▶ 企画AIが清書 ─▶ 実装AI ─▶ PR ─▶ CI ─▶ レビューAI ─▶ 自動マージ ─▶ Vercelで公開 ─▶ スマホに通知
 (人間)                                           ▲            │           │
                                                  └── AIが修正 ◀┴── 失敗・指摘（3回まで。最後の1回は opus）
                                                                  │
                                                      直らなければ ai:stuck ─▶ 人間に通知して止まる

止まったら自動で再開する
  使用量の上限・AIのエラー・時間切れ ─▶ ai:retry ─▶ 見張り役が30分以上あけてやり直す（10回まで）
  人間が ai:stuck を外す ─▶ 止まった所から続ける
```

- **自動**：清書、実装、PR作成、CI、レビュー、修正、マージ、公開、通知、一時的な失敗からのやり直し
- **人間が判断**：何を作るか（メモを書く）。止まって通知が来たとき（`ai:stuck`）の確認。`ai:hold` を付けた大事な変更の最後のマージ
- 順番待ち（`ai:queue`）を付けると、前の作業が終わってから番号順に始まります。まとめて頼んで寝ておけます

詳しい流れ・ラベル・止まる条件は [docs/pipeline.md](docs/pipeline.md)。

## 使い方

1. このリポジトリの **Use this template** から新しいリポジトリを作る
2. GitHubの Claude アプリを、そのリポジトリに入れる
3. Settings → Secrets and variables → Actions に次の3つのSecretを登録する（詳細は [docs/pipeline.md](docs/pipeline.md#必要な設定リポジトリの-settings--secrets-and-variables--actions)）

   | 名前 | 役割 |
   | --- | --- |
   | `CLAUDE_CODE_OAUTH_TOKEN` | `claude setup-token` で作るトークン。ClaudeのサブスクでAIを動かす |
   | `PIPELINE_TOKEN` | オーナーのFine-grained トークン。ラベル・コメント・PR作成・マージに使う |
   | `NTFY_TOPIC` | スマホ通知（ntfyアプリ）のトピック名。無ければ通知しない |

4. Actions → **Setup Labels** を1回実行して、`ai:` などのラベルを作る
5. `CLAUDE.md` の1行目と `docs/spec.md`・`docs/design.md` にアプリのことを書く
6. Vercelでリポジトリを読み込む（mainにマージされるたびに公開される）
7. Issueの「メモ（AIにおまかせ）」から、やりたいことを書く

### Vercelの公開回数について

Vercelの無料プランには、1日に公開できる回数の上限があります。AIは `claude/*` ブランチに何度もpushするので、そのたびにプレビューを作ると上限をすぐ使い切ってしまいます。`vercel.json` は、`claude/*` ブランチのプレビューを作らず、mainにマージされたときだけ公開するための設定です。

## 安全のしくみ

- 合否を決めるのはCI。AIの「できました」は信じない
- `.github/`・`docs/pipeline.md`・`CLAUDE.md`・`AGENTS.md` を変えるPRは、CIとレビューが通っても自動でマージせず、人間に任せて通知する。仕組みそのものがAIの判断だけで書き換わらないようにするため
- AIは `.github/`・`docs/pipeline.md`・`CLAUDE.md`・依存パッケージを触らない
- 進行役（`pipeline.yml`）はmainにある版が動くので、PRの中身で判断を書き換えられない
- 自動の修正は3回まで（最後の1回は opus）、自動のやり直しは10回まで。無限に回らない。超えたら `ai:stuck` で人間に回す
- `ai:hold` を付けると、最後のマージだけ人間が押す
- 公開後に壊れていたら、Vercelの画面から前の版にすぐ戻せる

詳細は [docs/pipeline.md](docs/pipeline.md#安全のしくみ)。

実際に動いた例：[agent-desk](https://github.com/Gaku1205/agent-desk)（AIに開発を任せるときの進行状況と「人間の判断待ち」を1画面で見るダッシュボード）は、このテンプレートで作りました。

## 中身

| 場所 | 内容 |
| --- | --- |
| `.github/workflows/` | 企画・実装・レビュー・修正のAI（[anthropics/claude-code-action](https://github.com/anthropics/claude-code-action)）、CI、進行役、公開通知 |
| `.github/scripts/` | 進行役の判断（PR作成、CI後・レビュー後・修正後の次の一手、通知） |
| `CLAUDE.md` | AIが守るルール（触ってはいけない場所、作業の終わらせ方、PRの書き方） |
| `docs/` | 仕様書・デザイン仕様・パイプラインの説明 |
| `src/` | 最小の Next.js（App Router）＋TypeScript＋Vitest |
| `vercel.json` | `claude/*` ブランチのVercelプレビューを作らない設定 |
