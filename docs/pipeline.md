# 開発の流れ（全自動パイプライン）

人間がやるのは「何を作るか決める」ことだけ。あとはAIとGitHub Actionsが進め、人間の判断が要るときだけ止まって知らせる。

```
Issueを作る（メモ）。ラベルが無ければ自動で ai:plan が付く   intake.yml（見落としは watchdog.yml が拾う）
  → 企画AIが清書して ai:implement を付ける        claude-plan.yml
     （進行中の作業とぶつかると企画AIが判断したら ai:queue で順番待ち。別の場所なら最大2つまで並列）
  → 実装AIがブランチに実装し、PRを自動で作る        claude-implement.yml
  → CI（型チェック・リント・テスト・ビルド）         ci.yml
  → main が進んでいたら取り込んでCIをやり直す         pipeline.yml
  → 通ったらレビューAI（ai:review）                 pipeline.yml → claude-review.yml
  → 指摘なし：自動でマージ → Vercelが本番に公開      pipeline.yml
     指摘あり／CI失敗：AIが直す（@claude、3回目は opus）→ CIから   pipeline.yml → claude-mention.yml
  → 公開されたらスマホに通知                        deploy-notify.yml
  → 順番待ち（ai:queue）があれば次を始める           queue.yml

止まったときの自動再開
  使用量の上限・AIのエラー・時間切れ → ai:retry を付けて、見張り役がやり直す（10回まで）   watchdog.yml
  人間が ai:stuck を外す → 止まった所から続ける（直す回数もリセット）                              resume.yml
```

## ラベル

| ラベル | 付けるのは | 意味 |
| --- | --- | --- |
| `ai:plan` | 受付（intake.yml）。人間が付けてもよい | 企画AIが清書して、実装に回す |
| `ai:skip` | 人間 | まだ自動で動かさない。Issueを作るとき付けておく。外すと企画に回る（人間の下準備が先に要る物用） |
| `ai:implement` | 人間か企画AI | 実装AIが作業を始める |
| `size:S` / `size:L` | 人間か企画AI | 実装AIのモデルと作業回数の上限を変える（S：haiku・25回、無印：sonnet・50回、L：opus・80回） |
| `ai:review` | パイプライン（人間も可） | レビューAIが確認する |
| `ai:queue` | 人間 | 順番待ち。前のPRが自動でマージされ、進行中・停止中の物が無くなったら、番号の小さい順に実装が始まる。まとめて頼んで寝ておける |
| `ai:hold` | 人間 | 最後のマージだけ人間が押す（大事な変更用） |
| `ai:retry` | パイプライン | AIが一時的に止まった（使用量の上限など）。見張り役が30分以上あけて自動でやり直す（失敗のコメントに、原因の分類とログのURLが付く）。人間は何もしなくてよい |
| `ai:stuck` | パイプライン | 自動で進められず止まった。人間が確認して、続けるなら外す（外すと自動で再開） |
| `visual:update` | 人間 | 見た目のテストの基準の画像を、CIの環境で撮り直してPRにコミットする（終わると外れる） |

## 人間に回る（止まる）とき

- 企画AIが「人間にしかできない作業」が要ると判断した（依存パッケージの追加、`.github/`・`docs/pipeline.md`・CLAUDE.md の変更、秘密情報の登録、外部サービスの設定。Issueに、してほしいことが書かれる）。意図が読み取れないだけなら止まらず、AIが無難に仮決めして「### 仮定」に書く。大きすぎるときは、最初の分だけをこのIssueにして、残りは新しいIssueとして自動で作る
- 実装AIが変更を作れなかった
- CIの失敗とレビューの指摘を合わせて、AIが3回直しても解決しない（2回は普通のモデル、最後の1回はいちばん強いモデル opus で直す）
- 直すよう頼んだのに、AIが変更を入れなかった（指摘が誤りだと判断した、など）
- レビューAIがエラーで止まった
- `ai:hold` のPRで、CIもレビューもOKになった

止まったら `ai:stuck` が付き、スマホに通知が来る。確認して、続けるなら `ai:stuck` を外す。外すと resume.yml が、そのときのCIの状態から自動で続ける（通っていればレビューへ、落ちていればAIが直す。AIに直させる回数もリセットされる）。自分で直す・マージする・閉じるときは、外さなくてよい。

## 自動でやり直す（人間に回さない）とき

次は一時的な失敗かもしれないので、すぐ人間に回さず `ai:retry` を付ける。見張り役（watchdog.yml）が、失敗から30分以上あけてやり直す。見張り役は、定期の起動（GitHubの都合で数時間あくことがある）に加えて、AIやCIのワークフローが終わるたびにも動く。10回やり直しても直らなければ `ai:stuck` で人間に回す。

- 企画AI・実装AI・レビューAI・修正AIが、エラーで終わった（使用量の上限に当たったときなど。リセットされるまで待ちながらやり直す）
- 実装AIが時間切れなどで終わり、失敗の知らせも無いまま45分以上動きが無い
- レビューAIの結果が出ないまま30分以上たった
- mainが進んでPRのブランチに取り込めない（コンフリクト）：AIに解消させる（直す回数に数える）
- CIが「承認待ち」で止まった（空のコミットを足してCIを動かし直す）
- 見た目のテストだけが落ちていて、PRに「見た目を変えた（`visual:update`）」と書いてある（意図した変更なので、AIに直させず `visual:update` を付けて基準の画像を撮り直す。1つのPRで2回まで。意図していない崩れは、AIに直させる）

AIが正常に終わったのに変更が無いとき（質問した、指摘が誤りだと判断した、など）はAIの判断なので、やり直さず人間に回す。

## 安全のしくみ

- `.github/`・`docs/pipeline.md`・CLAUDE.md・AGENTS.md を変えるPRは、CIとレビューが通っても自動でマージしない（マージを人間に任せて通知する）。仕組みそのものが、AIの判断だけで書き換わらないようにするため。普通のIssueは今までどおり全自動
- 合否を決めるのはCI。AIの「できました」は信じない
- 進行役（pipeline.yml）は `workflow_run` で main にある版が動くので、PRの中身で判断を書き換えられない
- AIは `.github/`・`docs/pipeline.md`・`CLAUDE.md`・依存パッケージを触らない。`docs/spec.md`・`docs/design.md` は、見た目や挙動を決めるIssueのとき、実装の前に更新して同じPRに入れる（CLAUDE.md）。レビューAIが、書いた内容がIssueの範囲かを見る
- レビューAIは毎回、前の指摘が直ったかも含めて見直し、必ず「## Code review」で始まるまとめを残す（進行役はこれで判断する）
- 自動の修正は3回まで（最後の1回は opus）、自動のやり直しは10回まで。無限に回らない
- AI（claude[bot]）のpushでCIが「承認待ち」になったら、進行役がオーナーのトークンで空のコミットを足してCIを動かし直す
- 公開後に壊れていたら、Vercelの画面から前の版にすぐ戻せる

## 必要な設定（リポジトリの Settings → Secrets and variables → Actions）

| 名前 | 種類 | 内容 |
| --- | --- | --- |
| `CLAUDE_CODE_OAUTH_TOKEN` | Secret | `claude setup-token` で作るトークン（Claudeのサブスクで動かす） |
| `PIPELINE_TOKEN` | Secret | オーナーのFine-grained トークン。ラベル・コメント・PR作成・マージに使う。これで操作すると次のワークフローが動く（Actions標準のトークンだと動かない）。無い間は、PR作成とマージを人間がする |
| `NTFY_TOPIC` | Secret | スマホ通知（ntfyアプリ）のトピック名。無ければ通知しない |
| `AGENT_DESK_URL` | Variable | 通知を押したときに開く画面（省略可） |
| `NOTIFY_EVENTS` | Variable | 鳴らす通知の種類（カンマ区切り）。省略時は `stuck,question,hold,manual,deployed,deploy_failed`。ほかに `merged`・`ci_failed` がある。種類の意味は `.github/scripts/notify.sh` |

ほかに、Settings → General → Pull Requests の「Automatically delete head branches」をオンにする（マージ後のブランチが溜まらない。オンにしなくても、進行役がマージ後に `claude/*` ブランチを消し、見張り役が古い物を掃除する）。

ほかに、GitHubの Claude アプリをこのリポジトリに入れる。ラベルは Actions の「Setup Labels」を1回実行すると作られる。
