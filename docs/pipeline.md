# 開発の流れ（全自動パイプライン）

人間がやるのは「何を作るか決める」ことだけ。あとはAIとGitHub Actionsが進め、人間の判断が要るときだけ止まって知らせる。

```
Issueを作る（メモ）。ラベルが無ければ自動で ai:plan が付く   intake.yml（見落としは watchdog.yml が拾う）
  → 企画AIが清書して ai:implement を付ける        claude-plan.yml
     （進行中の作業とぶつかると企画AIが判断したら ai:queue で順番待ち。別の場所なら最大2つまで並列）
  → 実装AIがブランチに実装し、PRを自動で作る        claude-implement.yml
  → CI（pipeline.json の checks。無ければ型チェック・リント・テスト・ビルド）   ci.yml
  → main が進んでいたら取り込んでCIをやり直す         pipeline.yml
  → 通ったらレビューAI（ai:review）                 pipeline.yml → claude-review.yml
  → 指摘なし：自動でマージ → 公開（Vercel／App Runner／GitHub Releases／Expo）   pipeline.yml → deploy.yml
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
| `size:S` / `size:L` | 人間か企画AI | 実装AIのモデルと作業回数の上限を変える（S：haiku・40回、無印：sonnet・60回、L：opus・100回） |
| `ai:review` | パイプライン（人間も可） | レビューAIが確認する |
| `ai:queue` | 人間 | 順番待ち。前のPRが自動でマージされ、実装中の物・openのPRが無くなったら（企画の段階で止まった物は待たない）、番号の小さい順に実装が始まる。まとめて頼んで寝ておける |
| `ai:hold` | 人間 | 最後のマージだけ人間が押す（大事な変更用）。`.github/`・`docs/pipeline.md`・`CLAUDE.md`・`AGENTS.md` を触るPRには、進行役が自動で付ける（ただし ai-dev-template 自身は、スクリプト・テスト・`docs/pipeline.md` だけの変更なら付けず、自動でマージする。下の「安全のしくみ」） |
| `ai:retry` | パイプライン | AIが一時的に止まった（使用量の上限など）。見張り役が30分以上あけて自動でやり直す（失敗のコメントに、原因の分類とログのURLが付く）。人間は何もしなくてよい |
| `ai:stuck` | パイプライン | 自動で進められず止まった。人間が確認して、続けるなら外す（外すと自動で再開） |
| `visual:update` | 人間 | 見た目のテストの基準の画像を、CIの環境で撮り直してPRにコミットする（終わると外れる） |

見張り役は、ありえないラベルの組み合わせ（`ai:queue` と `ai:implement`、`ai:plan` と `ai:implement`、記録の無い `ai:retry`、直近7日に閉じた物に残った `ai:stuck`・`ai:retry`・`ai:queue`）を直し、その Issue・PR に1行コメントする（1回に20件まで）。

## 人間に回る（止まる）とき

- 企画AIが「人間にしかできない作業」が要ると判断した（依存パッケージの追加、`.github/`・`docs/pipeline.md`・CLAUDE.md の変更、秘密情報の登録、外部サービスの設定。Issueに、してほしいことが書かれる。そのコメントの1行目は `<!-- human-request -->`、2行目が要点の1文で、agent-desk の「あなたの番」にはこの1文が出る）。意図が読み取れないだけなら止まらず、AIが無難に仮決めして「### 仮定」に書く。大きすぎるときは、最初の分だけをこのIssueにして、残りは新しいIssueとして自動で作る
- 実装AIが変更を作れなかった
- CIの失敗とレビューの指摘を合わせて、AIが3回直しても解決しない（2回は普通のモデル、最後の1回はいちばん強いモデル opus で直す）
- 直すよう頼んだのに、AIが変更を入れなかった（指摘が誤りだと判断した、など）
- レビューAIがエラーで止まった
- `ai:hold` のPRで、CIもレビューもOKになった

止まったら `ai:stuck` が付き、スマホに通知が来る。確認して、続けるなら `ai:stuck` を外す。外すと resume.yml が、そのときのCIの状態から自動で続ける（通っていればレビューへ、落ちていればAIが直す。AIに直させる回数もリセットされる）。自分で直す・マージする・閉じるときは、外さなくてよい。

## 自動でやり直す（人間に回さない）とき

次は一時的な失敗かもしれないので、すぐ人間に回さず `ai:retry` を付ける。見張り役（watchdog.yml）が、失敗から30分以上あけてやり直す。見張り役は、定期の起動（GitHubの都合で数時間あくことがある）に加えて、AIやCIのワークフローが終わるたびにも動く。10回やり直しても直らなければ `ai:stuck` で人間に回す。

使用量の上限が原因と分かったとき（企画AI・実装AIの実行記録に「usage limit」などが出ているとき）は、回数を使わずに待つ。リセット時刻が読めれば、その1分後にやり直す。読めなければ60分あけてやり直す。待ちに入った最初の1回だけ、スマホに「使用量の上限で待っています」と通知する（通知の種類 `limit`）。上限が24時間以上続いたら、本物のエラーと同じに数えて、10回で `ai:stuck` にする。レビューAI・修正AIは、実行記録をこの段階では読めないので、これまでどおり30分あけて、回数に数える。

- 企画AI・実装AI・レビューAI・修正AIが、エラーで終わった（使用量の上限に当たったときなど。リセットされるまで待ちながらやり直す）
- 実装AIが時間切れなどで終わり、失敗の知らせも無いまま45分以上動きが無い
- レビューAIの結果が出ないまま30分以上たった
- mainが進んでPRのブランチに取り込めない（コンフリクト）：AIに解消させる（直す回数に数える）。CIのあと、レビューの間に別のPRが先にマージされ、マージの時点でコンフリクトになったときも同じ（`merge_or_handle`）。コンフリクト以外の理由でマージできなかったときは、やり直し待ち（`ai:retry`）にする（黙って止まらない）
- CIが「承認待ち」で止まった（空のコミットを足してCIを動かし直す）
- 見た目のテストだけが落ちていて、PRに「見た目を変えた（`visual:update`）」と書いてある（意図した変更なので、AIに直させず `visual:update` を付けて基準の画像を撮り直す。1つのPRで2回まで。意図していない崩れは、AIに直させる）

AIが正常に終わったのに変更が無いとき（質問した、指摘が誤りだと判断した、など）はAIの判断なので、やり直さず人間に回す。

## 安全のしくみ
- レビューAIは普段 sonnet。追加＋削除が300行を超える変更と、ログイン・トークン・秘密・権限・依存（`package.json`）・ワークフローを触る変更は opus でレビューする（`claude-review.yml` の「レビューのモデルを決める」）
- AIが動くジョブには `PIPELINE_TOKEN` を渡さない。企画・実装のあとの処理（次へ進める・PRを作る）は別のジョブで、main から取り直したスクリプトを動かす。AIが作業フォルダのスクリプトを書き換えても、強いトークンでは動かない（AIの結果は、実行記録と `plan-result.txt` をデータとして受け渡すだけ）
- パイプラインの更新を配る（`sync.yml`）のは、テンプレートの main でCIが通った版だけ。配り先は、このテンプレートから作られ、パイプラインの鍵（App）が見えるリポジトリ（自動。新しいアプリを作っても書き足さなくてよい）と、`.github/sync-targets` に書いた物（テンプレートより前からあるリポジトリなど）。配りたくない物は `.github/sync-targets` に `!owner/repo` と書く（`sync-targets.sh`）。配り先の main には直接入れず、`pipeline-sync/<sha>` のPRを作る。配り先のCIが通ったら、進行役がレビューなしでマージする（落ちたら `ai:stuck` で人間に回す。AIが作ったPRや、印の無いPRはこの扱いにしない）

- `.github/`・`docs/pipeline.md`・CLAUDE.md・AGENTS.md・`pipeline.json` を変えるPRは、CIとレビューが通っても自動でマージしない（マージを人間に任せて通知する）。仕組みそのものが、AIの判断だけで書き換わらないようにするため。普通のIssueは今までどおり全自動
- 合否を決めるのはCI。AIの「できました」は信じない
- 進行役（pipeline.yml）は `workflow_run` で main にある版が動くので、PRの中身で判断を書き換えられない
- AIは `.github/`・`docs/pipeline.md`・`CLAUDE.md`・依存パッケージを触らない。`docs/spec.md`・`docs/design.md` は、見た目や挙動を決めるIssueのとき、実装の前に更新して同じPRに入れる（CLAUDE.md）。レビューAIが、書いた内容がIssueの範囲かを見る
- レビューAIは毎回、前の指摘が直ったかも含めて見直し、必ず「## Code review」で始まるまとめを残す（進行役はこれで判断する）
- 自動の修正は3回まで（最後の1回は opus）、自動のやり直しは10回まで。無限に回らない
- AI（claude[bot]）のpushでCIが「承認待ち」になったら、進行役がオーナーのトークンで空のコミットを足してCIを動かし直す
- ai-dev-template 自身は、AIがスクリプト・テスト・`docs/pipeline.md` を直し、CI（`script-tests`・`shellcheck`）とレビューが通れば自動でマージされる。印は main の `CLAUDE.md` の `pipeline-self-edit: auto` で、進行役は main の物を見るので、PRで印を足してもすり抜けられない。ワークフロー・`CLAUDE.md`・`AGENTS.md`（AIの許可とルール）は、どのリポジトリでもAIが無人で書き換えない（人間側のClaudeが行い、マージは `ai:hold`）
- 公開後に壊れていたら、Vercelの画面から前の版にすぐ戻せる

## AIの許可（`--allowedTools`）

各AIが使ってよい操作は、ワークフローの `--allowedTools` に書いてある。AIは、ここに無い操作をしようとすると拒否されて止まる。次の表が一覧（`.github/scripts/tests/test-permissions.sh` が、ワークフローと表が食い違っていないか確かめる）。

| AI（ワークフロー） | 許可している操作 | 許可していない操作と理由 |
| --- | --- | --- |
| 企画AI（`claude-plan.yml`） | `Bash(gh issue view:*)`、`Bash(gh issue edit:*)`、`Bash(gh issue comment:*)`、`Bash(gh issue create:*)`、`Bash(gh issue list:*)`、`Bash(gh pr list:*)`、`Bash(gh pr diff:*)`、`Read`、`Glob`、`Grep`、`Write` | コードを変えるgit操作・npm（企画はIssueを書くだけ。`Write` は結果ファイル `plan-result.txt` のため） |
| 実装AI（`claude-implement.yml`） | pipeline.json の checks のコマンド（無ければ npm run typecheck・lint・test・build。下の「言語と公開先」）、`Bash(.github/scripts/tests/run-all.sh)`、`Bash(git status:*)`、`Bash(git diff:*)`、`Bash(git add:*)`、`Bash(git commit:*)`、`Bash(git push:*)`、`Bash(bash .github/scripts/tests/run-all.sh)`、`Bash(shellcheck:*)` | `gh`（PRやコメントは進行役が作る）、`npm run readme:shots` などの重い物（ブラウザの撮影はCIのワークフローでやる）。ファイルの編集は、このツールの標準で許可される。gitは、標準に任せると拒否されて止まったことがあるので、明示して許可している。`git push --force`・`git rebase` は許可しない |
| レビューAI（`claude-review.yml`） | `Bash(gh pr view:*)`、`Bash(gh pr diff:*)`、`Bash(gh issue view:*)`、`Bash(gh pr comment:*)`、`Read`、`Glob`、`Grep`、`Write`、`mcp__github_inline_comment__create_inline_comment` | コードの変更・git操作・npm（レビューは読むだけ。コードは直さない） |
| 修正AI（`claude-mention.yml`） | `Bash(gh pr view:*)`、`Bash(gh pr edit:*)`、`Bash(gh pr comment:*)`、`Bash(git fetch:*)`、`Bash(git merge:*)`、`Bash(git status:*)`、`Bash(git diff:*)`、`Bash(git add:*)`、`Bash(git commit:*)`、`Bash(git push:*)`、pipeline.json の checks のコマンド（無ければ npm run typecheck・lint・test・build）、`Bash(.github/scripts/tests/run-all.sh)`、`Bash(bash .github/scripts/tests/run-all.sh)`、`Bash(shellcheck:*)` | `git rebase`・`git push --force`（履歴を書き換えない）、`gh pr merge`（マージは進行役だけ）。`gh pr edit` はPRの説明の直し、`git merge` はコンフリクトの解消のために許可している |

許可が足りなくて止まったときは、次のようになる。

- 企画AI・実装AIは、実行記録から拒否された操作を読み取り、「足りない許可：`Bash(git merge:*)`」のように、通知とコメントに書いて人間に回す（やり直しても直らないので、自動のやり直しはしない）
- 修正AIは、AIのコメントに「許可されていない」などと書かれていれば、その行と、出てくるコマンドから足りない許可の候補を書いて人間に回す
- 同じ許可の不足が2回起きたら、直すためのIssue（`AIの許可が足りない：…`）を自動で作る（`ai:skip` 付き。マネージャーが `--allowedTools` と上の表を直す）。回数の記録は、閉じたままの「AIの許可の不足（自動の記録）」Issueのコメントに残る

## 言語と公開先（`pipeline.json`）

リポジトリ直下の `pipeline.json` に、言語・確認コマンド・公開先を書く。**無ければ今までどおりの Next.js（Node 22・`npm ci`・型チェック／リント／テスト／ビルド・Vercel）**として動くので、既存のアプリは何もしなくてよい。読み取りは `.github/scripts/stack.sh`、実行環境を入れるのは `.github/actions/setup-stack`（CI・実装AI・修正AI・公開で共通）。

```json
{
  "tools":  { "python": "3.12" },
  "setup":  [ "pip install -r requirements-dev.txt" ],
  "checks": [
    { "name": "リント", "run": "ruff check ." },
    { "name": "テスト", "run": "pytest -q" }
  ],
  "deploy": [
    { "kind": "aws-apprunner", "service": "hello-api", "port": 8000, "health": "/health" },
    { "kind": "github-release", "os": ["windows-latest", "macos-latest"], "build": "pyinstaller --onefile cli.py", "files": "dist/*" }
  ]
}
```

| 項目 | 内容 |
| --- | --- |
| `tools` | 入れる実行環境と版。`node`・`python`・`go`・`java`（Temurin）・`dotnet`。Rust・C/C++ などはランナーに最初から入っている物を使う |
| `setup` | 依存を入れるコマンド（CIとAIの前に1回ずつ動く） |
| `checks` | CIで順に**全部**回すコマンド（1つ落ちても最後まで回し、落ちた物をまとめて出す）。**実装AI・修正AIに許すコマンドもこれになる**（`"`・`,`・`(`・`)`・`` ` ``・`$`・`\` は許可の書き方を壊すので使えない。複雑な物はスクリプトにまとめて呼ぶ） |
| `deploy` | 公開先の配列。同じ種類は最初の1つだけ使う |

AIに許すコマンドを決めるので、`pipeline.json` と `.github/actions/` を触るPRは、どのリポジトリでも自動でマージしない（`ai:hold`）。書き間違いは、CI・公開の最初で `::error::` になり、Doctor でも ❌ で出る。

公開先（`deploy.yml`。main の CI が通ったら動く。パイプラインの更新だけのコミットでは動かない）：

| `kind` | 公開のしかた | 要る設定 | 書く物 |
| --- | --- | --- | --- |
| `vercel` | Vercel が自分で公開する（ここでは何もしない）。`pipeline.json` が無いときの既定 | Vercel でリポジトリを読み込む | なし |
| `aws-apprunner` | Docker のイメージを作って ECR に置き、App Runner で動かす。最初の公開でサービスを作り、2回目から差し替える。言語を選ばない（Web・API） | 下の「AWS App Runner」 | `service`（サービス名・英数字と `-` `_`）、`port`（既定 8080）、`dockerfile`（既定 `Dockerfile`）、`cpu`（既定 256）、`memory`（既定 512）、`health`（HTTPのヘルスチェックのパス。省くとTCP） |
| `github-release` | OS ごとに配布物（exe など）を作り、GitHub Releases に置く。ファイル名に OS が付く（`hello.exe` → `hello-windows.exe`）。タグは `build-<日時>-<コミット>` | なし | `build`（作るコマンド）、`files`（置くファイル。例 `dist/*`）、`os`（既定 `["windows-latest"]`。`macos-latest`・`ubuntu-latest` も） |
| `expo` | スマホアプリを Expo（EAS）で配る。既定は `eas update`（アプリを入れ直さずに中身を更新） | Secret の `EXPO_TOKEN` | `command`（既定 `npx --yes eas-cli@latest update --auto --non-interactive`。ストアに出すなら `eas build --auto-submit ...`） |
| `none` | 公開しない | なし | なし |

結果はコミットの状態（`deploy/<kind>`）に書き、スマホに通知する（`deploy-status.sh`）。

### AWS App Runner（1つの AWS アカウントで1回だけ）

鍵（アクセスキー）は GitHub に置かない。GitHub の OIDC で、main からの実行だけが AWS の役割を一時的に借りる。

1. AWS の画面 → **CloudFormation** → **スタックの作成**（新しいリソースを使用）→ **テンプレートファイルのアップロード** で `.github/deploy/aws-apprunner-setup.yml` を選ぶ
2. スタックの名前は好きに（例：`github-apprunner`）。`GitHubOwner` は自分の GitHub のユーザー名。このアカウントに GitHub の OIDC（`token.actions.githubusercontent.com`）をもう作ってあれば `CreateOidcProvider` を `false`
3. 「IAM リソースが作成される場合があることを承認します」にチェックして作成。数十秒で終わる
4. スタックの **出力** に出る3つを、公開するリポジトリの Settings → Secrets and variables → Actions → **Variables** に入れる：`AWS_ROLE_ARN`・`AWS_APPRUNNER_ACCESS_ROLE_ARN`・`AWS_REGION`
5. Doctor を実行して「✅ 公開先：AWS App Runner」が出れば完了。次に main にマージされたとき、最初の公開でサービスができる（数分）。URL は通知と agent-desk に出る

料金：App Runner は動いている間（いちばん小さい 0.25 vCPU・0.5 GB）と、イメージの置き場（ECR）の分がかかる。使わないサービスは App Runner の画面で「一時停止」すると、置き場の分だけになる。

### Expo（スマホアプリ）

1. expo.dev にログインし、アプリを作る（`npx eas-cli init` をパソコンで1回）
2. expo.dev → Account settings → **Access tokens** で作り、Secret の `EXPO_TOKEN` に入れる
3. `pipeline.json` の `deploy` に `{ "kind": "expo" }`（ストアに出すときは `command` を書く）

## スクリプトのテスト

`.github/scripts/tests/` に、進行役のスクリプトのテストがある。本物の GitHub には触らず、疑似の `gh`（`tests/fake-gh`）が状態をファイルに持つ。

- 全部実行：`.github/scripts/tests/run-all.sh`（CIの `script-tests`、`shellcheck` も同じ物を見る）
- 書き方は `tests/lib.sh` の冒頭。スクリプトを変えたら、場面に合うテストを足す
- 変更を入れる前にテストを壊してみて（わざとバグを入れる）、テストが落ちることを確かめると確実

## セットアップの診断

新しいリポジトリを作ったら、Actions の「Doctor」を1回実行する。Secret・ラベル・設定・`CLAUDE.md` やスクリプトの名前を調べて、✅／⚠️／❌ で、直し方つきで Summary に出す（`.github/scripts/doctor.sh`）。❌ が無くなれば Issue を書くだけで動く。

## 必要な設定（リポジトリの Settings → Secrets and variables → Actions）

| 名前 | 種類 | 内容 |
| --- | --- | --- |
| `CLAUDE_CODE_OAUTH_TOKEN` | Secret | `claude setup-token` で作るトークン（Claudeのサブスクで動かす） |
| `PIPELINE_APP_ID` | Variable | パイプライン用の GitHub App の App ID（おすすめ）。これと下の鍵があれば、`PIPELINE_TOKEN` の代わりに App の1時間だけの鍵を使う。回数制限がオーナーと別になり、期限切れが無く、操作が「App名[bot]」の名義になる |
| `PIPELINE_APP_PRIVATE_KEY` | Secret | その App の秘密鍵（.pem の中身をそのまま） |
| `PIPELINE_TOKEN` | Secret | オーナーのFine-grained トークン。ラベル・コメント・PR作成・マージに使う。これで操作すると次のワークフローが動く（Actions標準のトークンだと動かない）。無い間は、PR作成とマージを人間がする |
| `NTFY_TOPIC` | Secret | スマホ通知（ntfyアプリ）のトピック名。無ければ通知しない |
| `AGENT_DESK_URL` | Variable | 通知を押したときに開く画面（省略可） |
| `AWS_ROLE_ARN`・`AWS_APPRUNNER_ACCESS_ROLE_ARN`・`AWS_REGION` | Variable | 公開先が `aws-apprunner` のとき（上の「AWS App Runner」） |
| `EXPO_TOKEN` | Secret | 公開先が `expo` のとき |
| `NOTIFY_EVENTS` | Variable | 鳴らす通知の種類（カンマ区切り）。省略時は `stuck,question,hold,manual,deployed,deploy_failed,limit,intake,repeat_fail`。ほかに `merged`・`ci_failed` がある。種類の意味は `.github/scripts/notify.sh` |

ほかに、Settings → General → Pull Requests の「Automatically delete head branches」をオンにする（マージ後のブランチが溜まらない。オンにしなくても、進行役がマージ後に `claude/*` ブランチを消し、見張り役が古い物を掃除する）。

ほかに、GitHubの Claude アプリをこのリポジトリに入れる。テンプレートから作った最初の push で「Bootstrap」が自動で動き、ラベルを作り、`CLAUDE.md` から「ai-dev-template 自身の作業」の節を消し、診断（Doctor）の結果を実行画面の Summary に出す（ラベルがもうあれば何もしない）。❌ が出たら、Summary の「→」のとおり直し、Actions の「Doctor」をもう一度実行する。

### パイプライン用の GitHub App の作り方（1回だけ）

1. GitHub の Settings → Developer settings → GitHub Apps → **New GitHub App**
2. 名前は好きに（例：`gaku-pipeline`）。Homepage URL はリポジトリのURLでよい。**Webhook の Active は外す**
3. Repository permissions：Actions（Read）、Checks（Read）、Commit statuses（Read）、Contents（Read and write）、Issues（Read and write）、Pull requests（Read and write）、Workflows（Read and write）。Administration（Read）は任意（Doctor がブランチ削除の設定を見るのに使う）
4. Where can this GitHub App be installed? は **Only on this account** → Create
5. 出てきた **App ID** を、リポジトリの Variable `PIPELINE_APP_ID` に入れる
6. ページ下の **Generate a private key** で .pem をダウンロードし、中身を Secret `PIPELINE_APP_PRIVATE_KEY` に入れる
7. 左の **Install App** → このアカウントに Install → 使うリポジトリを選ぶ（ai-dev-template と、自動で配る先も全部）
8. Doctor を実行して「GitHub App の鍵でこのリポジトリに書き込める」が出れば完了。`PIPELINE_TOKEN` は消してよい（残っていても App が優先）
