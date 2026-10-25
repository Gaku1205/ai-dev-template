# 開発の流れ（全自動パイプライン）

人間がやるのは「何を作るか決める」ことだけ。あとはAIとGitHub Actionsが進め、人間の判断が要るときだけ止まって知らせる。

```
メモを書く（ai:plan）
  → 企画AIが清書して ai:implement を付ける        claude-plan.yml
     （進行中の作業とぶつかると企画AIが判断したら ai:queue で順番待ち。別の場所なら最大2つまで並列）
  → 実装AIがブランチに実装し、PRを自動で作る        claude-implement.yml
  → CI（型チェック・リント・テスト・ビルド）         ci.yml
  → main が進んでいたら取り込んでCIをやり直す         pipeline.yml
  → 通ったらレビューAI（ai:review）                 pipeline.yml → claude-review.yml
  → 指摘なし：自動でマージ → Vercelが本番に公開      pipeline.yml
     指摘あり／CI失敗：AIが直す（@claude）→ CIから   pipeline.yml → claude-mention.yml
  → 公開されたらスマホに通知                        deploy-notify.yml
  → 順番待ち（ai:queue）があれば次を始める           queue.yml
```

## ラベル

| ラベル | 付けるのは | 意味 |
| --- | --- | --- |
| `ai:plan` | 人間（「メモ」で書くと自動で付く） | 企画AIが清書して、実装に回す |
| `ai:implement` | 人間か企画AI | 実装AIが作業を始める |
| `size:S` / `size:L` | 人間か企画AI | 実装AIのモデルと作業回数の上限を変える（S：haiku・25回、無印：sonnet・50回、L：opus・80回） |
| `ai:review` | パイプライン（人間も可） | レビューAIが確認する |
| `ai:queue` | 人間 | 順番待ち。前のPRが自動でマージされ、進行中・停止中の物が無くなったら、番号の小さい順に実装が始まる。まとめて頼んで寝ておける |
| `ai:hold` | 人間 | 最後のマージだけ人間が押す（大事な変更用） |
| `ai:stuck` | パイプライン | 自動で進められず止まった。人間が確認して外す |

## 人間に回る（止まる）とき

- 企画AIが意図を読み取れない、または1つのPRに収まらない（Issueに質問が書かれる）
- 実装AIが変更を作れなかった
- CIの失敗とレビューの指摘を合わせて、AIが2回直しても解決しない
- 直すよう頼んだのに、AIが変更を入れなかった（指摘が誤りだと判断した、など）
- レビューAIがエラーで止まった
- `ai:hold` のPRで、CIもレビューもOKになった

止まったら `ai:stuck` が付き、スマホに通知が来る。確認して、続けるなら `ai:stuck` を外して対応する。

## 安全のしくみ

- 合否を決めるのはCI。AIの「できました」は信じない
- 進行役（pipeline.yml）は `workflow_run` で main にある版が動くので、PRの中身で判断を書き換えられない
- AIは `.github/`・`docs/`・`CLAUDE.md`・依存パッケージを触らない（CLAUDE.md）
- レビューAIは毎回、前の指摘が直ったかも含めて見直し、必ず「## Code review」で始まるまとめを残す（進行役はこれで判断する）
- 自動の修正は2回まで。無限に回らない
- AI（claude[bot]）のpushでCIが「承認待ち」になったら、進行役がオーナーのトークンで空のコミットを足してCIを動かし直す
- 公開後に壊れていたら、Vercelの画面から前の版にすぐ戻せる

## 必要な設定（リポジトリの Settings → Secrets and variables → Actions）

| 名前 | 種類 | 内容 |
| --- | --- | --- |
| `CLAUDE_CODE_OAUTH_TOKEN` | Secret | `claude setup-token` で作るトークン（Claudeのサブスクで動かす） |
| `PIPELINE_TOKEN` | Secret | オーナーのFine-grained トークン。ラベル・コメント・PR作成・マージに使う。これで操作すると次のワークフローが動く（Actions標準のトークンだと動かない）。無い間は、PR作成とマージを人間がする |
| `NTFY_TOPIC` | Secret | スマホ通知（ntfyアプリ）のトピック名。無ければ通知しない |
| `AGENT_DESK_URL` | Variable | 通知を押したときに開く画面（省略可） |

ほかに、GitHubの Claude アプリをこのリポジトリに入れる。ラベルは Actions の「Setup Labels」を1回実行すると作られる。
