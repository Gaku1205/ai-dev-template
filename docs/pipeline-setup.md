# パイプラインの設定（言語・公開先・Secrets と Variables）

流れそのものは `docs/pipeline.md`。ここは、最初に入れるとき・公開先を変えるときに読む。

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

公開先（`deploy.yml`。main の CI が通ったら動く。パイプラインの更新だけのコミットでは動かない。ただし、その前のアプリの変更がまだ公開されていなければ動く：公開は1つずつ順に動き、待っている古い公開は新しい公開が来ると取り消されるので、アプリの変更のすぐあとに配布のコミットが入ると、アプリの変更が公開されないまま残る。`deploy-plan.sh` が、公開の結果（`deploy/*` の success・failure・error）が付いた一番新しいコミットからの差で決め直す）：

| `kind` | 公開のしかた | 要る設定 | 書く物 |
| --- | --- | --- | --- |
| `vercel` | `deploy-vercel.yml` が、main の CI が通ってから3分（変数 `VERCEL_DEPLOY_DELAY_MIN`）待ち、その間にまたマージされたら新しい方だけが、最新の main を1回だけ本番に公開する（Vercel の無料プランは「1日100回まで」なので、マージのたびに公開しない）。最後に公開に成功したコミットから、パイプラインの物（`.github/`・`docs/pipeline.md`）しか変わっていなければ公開しない。Secret `VERCEL_TOKEN` が無いときは何もせず、Vercel が自分で公開する（今までの形）。`VERCEL_TOKEN` が無いのに `vercel.json` が `deploymentEnabled: false` のままだと、どこからも公開されないので、失敗としてスマホに知らせる。公開を頼めなかったとき（鍵の期限切れ・プロジェクトが見つからない など）は、スマホに知らせる（`deploy_failed`）。3時間ごとに、最新の main が公開されているかを確かめ、まだなら頼み直す（回数の上限に当たったときのため。同じコミットの公開が3回失敗していたら、頼み直しても直らないので、次のマージか手で動かすまで頼まない）。`pipeline.json` が無いときの既定 | Vercel でリポジトリを読み込み、`vercel.json` を `"git": { "deploymentEnabled": false }` にし、`ignoreCommand` を消す（Vercel が自分で公開するのを止める。`ignoreCommand` は直前のコミットとの差しか見ないので、まとめて公開すると間の変更を見落として公開が飛ばされる）。`VERCEL_TOKEN` は工場（新しいサービス）と配布（`sync.yml` の vercel-token。`vercel.json` があるリポジトリだけ）が入れる | `VERCEL_TOKEN`（任意）、変数 `VERCEL_TEAM_ID`（チームのとき） |
| `github-pages` | 静的なサイトを作って GitHub Pages に出す（`<ユーザー名>.github.io` という名前のリポジトリなら、そのアドレスのトップに出る）。Next.js なら `next.config` で `output: "export"`・`images: { unoptimized: true }` にする（サーバーで動く機能は使えない） | Settings → Pages の Source を **GitHub Actions** にする。工場が作るサービスは、工場が `FACTORY_TOKEN` で自動で有効にする（`build_type=workflow`）。それ以外は手で1回だけ。Doctor が、有効で Source が GitHub Actions かを確かめる（無効や別の Source は ❌ と直し方、読めないときは ⚠️）。公開が失敗したときの知らせ（`deploy/pages`）には、設定のページの URL が付く | `build`（作るコマンド。既定 `npm run build`）、`dir`（出すフォルダ。既定 `out`） |
| `aws-apprunner` | Docker のイメージを作って ECR に置き、App Runner で動かす。最初の公開でサービスを作り、2回目から差し替える。言語を選ばない（Web・API） | 下の「AWS App Runner」 | `service`（サービス名・小文字の英数字と `-` `_`。ECR の名前にも使う）、`port`（既定 8080）、`dockerfile`（既定 `Dockerfile`）、`cpu`（既定 256）、`memory`（既定 512）、`health`（HTTPのヘルスチェックのパス。省くとTCP） |
| `github-release` | OS ごとに配布物（exe など）を作り、GitHub Releases に置く。ファイル名に OS が付く（`hello.exe` → `hello-windows.exe`）。同じ名前のファイルが別のフォルダにあれば、浅い方はそのまま、ぶつかった方にフォルダの名前を付ける（`sub/README.txt` → `sub-README-windows.txt`。上書きしない）。タグは `build-<日時>-<コミット>`（同じ分にやり直してタグがもうあれば、`-2`・`-3` … を付けて別のリリースにする） | なし | `build`（作るコマンド）、`files`（置くファイル。例 `dist/*`）、`os`（既定 `["windows-latest"]`。`macos-latest`・`ubuntu-latest` も） |
| `expo` | スマホアプリを Expo（EAS）で配る。既定は `eas update`（アプリを入れ直さずに中身を更新） | Secret の `EXPO_TOKEN` | `command`（既定 `npx --yes eas-cli@latest update --auto --non-interactive`。ストアに出すなら `eas build --auto-submit ...`） |
| `supabase` | `supabase/migrations/*.sql` のうち、まだ流していない物を番号の順に1ファイルずつ流す（`deploy-supabase.sh`。流した印は `app_meta.migrations`。1ファイル1まとまりで、失敗したら後ろは流さない）。Vercel の公開より先に動く | Secret の `SUPABASE_DB_URL`（工場が saas を作るときに入れる） | なし |
| `none` | 公開しない | なし | なし |

結果はコミットの状態（`deploy/<kind>`）に書き、スマホに通知する（`deploy-status.sh`。説明は GitHub の上限の140文字まで。通知の題は PR のタイトル：マージコミットなら3行目、まとめてマージ（squash）や直接のコミットなら1行目）。

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

## セットアップの診断

新しいリポジトリを作ったら、Actions の「Doctor」を1回実行する。Secret・ラベル・設定・`CLAUDE.md` やスクリプトの名前を調べて、✅／⚠️／❌ で、直し方つきで Summary に出す（`.github/scripts/doctor.sh`）。❌ が無くなれば Issue を書くだけで動く。要るラベルは `labels.sh` に書いてある物の全部（診断は別の一覧を持たない）。`labels.sh` は目印の `ai:plan` を最後に作る：Bootstrap と Setup Labels は「`ai:plan` があれば最初の準備は済んでいる」とみなすので、途中で失敗しても「準備ずみ」にならず、次の push でやり直せる。

## 必要な設定（リポジトリの Settings → Secrets and variables → Actions）

| 名前 | 種類 | 内容 |
| --- | --- | --- |
| `CLAUDE_CODE_OAUTH_TOKEN` | Secret | `claude setup-token` で作るトークン（Claudeのサブスクで動かす） |
| `PIPELINE_APP_ID` | Variable | パイプライン用の GitHub App の App ID（おすすめ）。これと下の鍵があれば、`PIPELINE_TOKEN` の代わりに App の1時間だけの鍵を使う。回数制限がオーナーと別になり、期限切れが無く、操作が「App名[bot]」の名義になる |
| `PIPELINE_APP_PRIVATE_KEY` | Secret | その App の秘密鍵（.pem の中身をそのまま） |
| `PIPELINE_TOKEN` | Secret | オーナーのFine-grained トークン。ラベル・コメント・PR作成・マージに使う。これで操作すると次のワークフローが動く（Actions標準のトークンだと動かない）。無い間は、PR作成とマージを人間がする |
| `NTFY_TOPIC` | Secret | スマホ通知（ntfyアプリ）のトピック名。無ければ通知しない |
| `AWS_ROLE_ARN`・`AWS_APPRUNNER_ACCESS_ROLE_ARN`・`AWS_REGION` | Variable | 公開先が `aws-apprunner` のとき（上の「AWS App Runner」） |
| `EXPO_TOKEN` | Secret | 公開先が `expo` のとき |
| `FACTORY_TOKEN`・`VERCEL_TOKEN` | Environment「factory」の Secret | 工場（1行から新しいサービスを作る）。ai-dev-template にだけ入れる（テンプレート本体の `docs/factory.md` の「工場」。factory.md はテンプレート本体だけにある） |

入れなくても動く設定（`NOTIFY_EVENTS`・`RETRY_TIMER`・`AGENT_DESK_URL`・`VERCEL_DEPLOY_DELAY_MIN` など）は、下の「変えたい人向けの設定」。

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

### 従来の方法：`PIPELINE_TOKEN`

README の手順は GitHub App に一本化している。すでに Secret `PIPELINE_TOKEN` で動いている人は、そのまま動く（コードは変えていない。Doctor は ⚠️ で App への切り替えを勧めるだけ）。作るなら、GitHub の Settings → Developer settings → Fine-grained tokens で、このリポジトリだけを選び、Actions・Checks・Commit statuses を Read、Contents・Issues・Pull requests・Workflows を Read and write にする。回数制限をオーナーと共有し、期限がある。

## 変えたい人向けの設定

README には載せていない。どれも**入れなくても既定値で動く**。変えたいときだけ、Settings → Secrets and variables → Actions に入れる。

| 名前 | 種類 | 既定値 | 意味 |
| --- | --- | --- | --- |
| `NOTIFY_EVENTS` | Variable | `stuck,question,hold,manual,deployed,deploy_failed,limit,intake,repeat_fail` | 鳴らす通知の種類（カンマ区切り）。ほかに `merged`・`ci_failed` がある。意味は `.github/scripts/notify.sh` |
| `RETRY_TIMER` | Variable | 未設定＝on | `off` にすると、やり直しの目覚まし（`retry-timer.yml`）を使わず、定期の見張りだけでやり直す。目覚ましは待つあいだランナーを使うので、公開していないリポジトリで Actions の時間を節約したいとき |
| `VERCEL_DEPLOY_DELAY_MIN` | Variable | `3`（分） | main の CI が通ってから Vercel に公開するまで待つ分。待つ間にまたマージされれば新しい方だけ公開する（無料プランの「1日100回」対策） |
| `SYNC_DELAY_MIN` | Variable | `15`（分） | テンプレート本体が、配り先への更新を配るまで待つ分（本体だけが使う） |
| `AGENT_DESK_URL` | Variable | なし | 通知を押したときに開く画面（agent-desk）のアドレス。無ければ Issue・PR を開く |

ほかに、Vercel をチームで使うときは Variable `VERCEL_TEAM_ID`（チーム ID。個人のアカウントなら要らない）。スマホ通知の `NTFY_TOPIC`（上の「必要な設定」）は、好きな英数字のトピック名を ntfy アプリで購読する（無くても動く。Doctor は ⚠️ を出す）。

## 上級者向け

README の3つ（Claude のトークン・GitHub App・Vercel）だけで動く。次の機能は消していない。要るときだけ読む。

- 別の言語（Python・Go・Java・.NET など）と公開先の選び方：上の「言語と公開先（`pipeline.json`）」。Python（FastAPI）の見本は テンプレート本体の `examples/python/README.md`
- AWS App Runner（Variable `AWS_ROLE_ARN` ほか）：「AWS App Runner」
- Expo（スマホアプリ、Secret `EXPO_TOKEN`）：「Expo」
- exe などの配布（`github-release`）とゲーム：「言語と公開先」の表と、テンプレート本体の `docs/factory.md` の「工場」の「ゲームのとき」（見本は テンプレート本体の `examples/game`・テンプレート本体の `examples/webgame`）
- 会員と課金（Supabase・Stripe の saas）：テンプレート本体の `docs/factory.md` の「会員と課金（saas）」（見本は テンプレート本体の `examples/saas`）
- 1行から新しいサービスを作る工場（`FACTORY_TOKEN`・`VERCEL_TOKEN`）：テンプレート本体の `docs/factory.md` の「工場」と「最初の1回だけの準備」

## main の保護を Bootstrap で自動化できるか（調べた結果。実装はしない）

**結論：技術的には可能だが、自動化しない。README の手順（手で1回。Settings → Branches で1分）に残す。** 工場で作るリポジトリだけ、`FACTORY_TOKEN` で自動で保護する。

**AIレビューが通るまで、人間もマージできないようにする（任意・#144）**：Settings → Branches → main の規則 →「Require status checks to pass」で `AIレビュー` を選ぶ（承認は0人のまま）。`AIレビュー` は、レビューAIが動くと pending、指摘なしで success、指摘ありで failure になるコミットのステータス。一度ステータスが付いたあとでないと検索欄に出ないので、パイプラインでPRを1つ通してから選ぶ。配布のPR（`pipeline-sync/`）は、CIが通ると success が付くので止まらない

- 保護の設定（`PUT /repos/{owner}/{repo}/branches/main/protection`）には Administration（Read and write）が要るが、パイプラインの鍵（GitHub App・`PIPELINE_TOKEN`）には無い（任意で Read を足せるだけ）
- パイプラインの App に足す案は取らない：保護は「AI を PR とレビューに通すための柵」で、柵を外せる鍵を AI の近くに置くことになる
- 別の強い鍵を Environment に入れて main のワークフローからだけ使う案（工場と同じ形）は安全だが、初めての人に「強い鍵をもう1つ作る」手順が増え、必須3つの方針に反する。付け忘れは Doctor が ⚠️ で教える
