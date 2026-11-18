# ai-dev-template

**Issueにやりたいことを1行書くだけで、AIが清書・実装・レビュー・修正・マージ・公開まで進める**、個人開発用のリポジトリの土台です。

人間がやるのは「何を作るか決める」ことと、AIが判断に迷って止まったときの確認だけ。合否はAIではなくCI（確認コマンド。Next.js なら型チェック・リント・テスト・ビルド）が決めます。

**言語も公開先も選べます。** 何も書かなければ Next.js＋Vercel。リポジトリ直下の `pipeline.json` に書けば、Python・Go・Java・.NET などで動き、公開先は AWS App Runner（Web・API）、GitHub Releases（exe などの配布物）、Expo（スマホアプリ）から選べます（`docs/pipeline-setup.md`「言語と公開先」）。

## 流れ

```
メモを書く ─▶ 企画AIが清書 ─▶ 実装AI ─▶ PR ─▶ CI ─▶ レビューAI ─▶ 自動マージ ─▶ 公開（Vercel／App Runner／Releases／Expo）─▶ スマホに通知
 (人間)                                           ▲            │           │
                                                  └── AIが修正 ◀┴── 失敗・指摘（3回まで。最後の1回は opus）
                                                                  │
                                                      直らなければ ai:stuck ─▶ 人間に通知して止まる

止まったら自動で再開する
  使用量の上限・AIのエラー・時間切れ ─▶ ai:retry ─▶ 見張り役が30分以上あけてやり直す（10回まで）
  人間が ai:stuck を外す ─▶ 止まった所から続ける

自分で問題を見つける
  使ってみる役（公開があった日）・監査役（毎週）─▶ 壊れている所・仕様の食い違いを Issue（ai:found）にする ─▶ いつもの流れで直す
```

- **自動**：清書、実装、PR作成、CI、レビュー、修正、マージ、公開、通知、一時的な失敗からのやり直し
- **人間が判断**：何を作るか（メモを書く）。止まって通知が来たとき（`ai:stuck`）の確認。`ai:hold` を付けた大事な変更の最後のマージ
- 順番待ち（`ai:queue`）を付けると、前の作業が終わってから順に始まります（`priority:high` が先）。触るファイルが重ならない物は3つまで（`MAX_PARALLEL`、既定 3）並べて進むので、まとめて頼んで寝ておけます
- **個人アカウントのリポジトリ専用**です（Organization では、人の Issue が動かず、質問の答えも拾われません）

不具合と改善の記録は、毎日自動で Excel にまとめて [Releases の pipeline-report](../../releases/tag/pipeline-report) に置く（`pipeline-report.xlsx`。集計・一覧・止まった記録・洗い出しの4シート。洗い出しで見つけた物には `audit` ラベルを付ける）。

詳しい流れ・ラベル・止まる条件は [docs/pipeline.md](docs/pipeline.md)（AIも読む）。最初の設定・言語と公開先は [docs/pipeline-setup.md](docs/pipeline-setup.md)、工場は [docs/factory.md](docs/factory.md)。

## 1行で新しいサービスを作る（工場）

最初の1回だけ準備（[docs/factory.md](docs/factory.md)）をしたら、あとはこのリポジトリに **「新サービス：〜」というタイトルのIssueを1行書くだけ**。リポジトリの作成・鍵の登録・main の保護・Vercel・最初のIssueまで自動で進み、そこからはいつものパイプラインが実装・公開まで進める。下の「使い方」は、手で1つずつ作るときの手順。

見た目は、デザイン担当のAIが決めて、**本物の画面まで作る**。工場は作る前に、何を作るか・見た目の方向・ざっくり画面を Issue のコメントで相談する（選択肢を選ぶだけ。agent-desk からも答えられる）。見た目を作る所は全部「考え → 関門 → 審査」を通す：作るAIが、色や文字より先に、その題材にしか無い物から考えを決めて設計メモに書く。スクリプトが本物の絵の枚数などを測り、作ったAIとは別のAIが**画像だけ**を見て点を付ける。届かなければ1回だけ直し、直す前より悪くなったら直す前の物を使う（`docs/pipeline.md`「デザインの仕組み」）。Issue にリールのスクショや好きなサイトの画像を貼れば、それがいちばん大事な実例になる。確認コマンドが通った物が、そのまま新しいリポジトリの最初の中身になる。動き・3D の道具は [GSAP](https://gsap.com)・[Lenis](https://github.com/darkroomengineering/lenis)・[Motion](https://motion.dev)・[three.js](https://threejs.org)・[PixiJS](https://pixijs.com) から選べる。ゲームを頼めば、ブラウザの技術で作り、Electron で Windows の exe にして Releases に置くか（[examples/game](examples/game)）、Vercel に出してスマホでもすぐ遊べる Web のゲームにする（[examples/webgame](examples/webgame)）。会員登録と月額の有料プランがあるサービス（サブスク）を頼めば、ログイン（Supabase）と課金（Stripe のテストモード）の土台を入れ、Supabase のプロジェクト・Stripe の値段・Vercel の鍵まで工場が用意する（[examples/saas](examples/saas)）。写真・古い地図・図版は、商用で使えて出どころを記録できる物だけを使う（[docs/factory.md](docs/factory.md)）。

## 使い方

Next.js＋Vercel なら、必須は次の3つだけ。ほかの設定は既定値で動く。

1. **Claude のトークンを登録する**：このリポジトリの **Use this template** から新しいリポジトリを作り、GitHub の Claude アプリを入れる。Settings → Secrets and variables → Actions に登録する。最初の push で「Bootstrap」が自動で動き、ラベルを作って診断（Doctor）の結果を実行画面の Summary に出す（手で実行する物はない）

   | 名前 | 種類 | 作り方 |
   | --- | --- | --- |
   | `CLAUDE_CODE_OAUTH_TOKEN` | Secret | パソコンに Claude Code を入れ（入れ方は [Claude Code の説明](https://docs.claude.com/en/docs/claude-code/overview)）、ターミナル（Windows なら PowerShell）で `claude setup-token` を実行し、出てきたトークンを貼る。Claude のサブスクで AI を動かす |

2. **パイプラインの鍵（GitHub App）を登録する**：[作り方](docs/pipeline-setup.md#パイプライン用の-github-app-の作り方1回だけ)（10分・1回だけ。期限切れなし）。App ID を Variable `PIPELINE_APP_ID` に、秘密鍵を Secret `PIPELINE_APP_PRIVATE_KEY` に入れる
3. **公開先をつなぎ、main を守る**
   - 公開先：Vercel でこのリポジトリを読み込む（main にマージされるたびに公開される）。まず試すだけなら、公開はつながなくてよい
   - main を守る：Settings → Branches → **Add classic branch protection rule** で、Branch name pattern に `main`、「Require a pull request before merging」（承認の人数は 0 のまま）と「Require status checks to pass」（検索欄で `check` を選ぶ。CI のジョブの名前）を付けて Create。無いと、AI が PR とレビューを通さずに main へ入れられてしまう

あとは、`CLAUDE.md` の1行目と `docs/spec.md`・`docs/design.md` にアプリのことを書き、Actions の **Doctor** を手で実行して Summary の ✅／⚠️／❌ を確かめる（❌ は「→」のとおり直してもう一度実行）。そして Issue の「メモ（AIにおまかせ）」にやりたいことを書けば動く。

通知や見張り役の設定、Python・AWS・スマホアプリ・ゲームなど、ほかの設定と上級者向けの使い方は [docs/pipeline-setup.md「変えたい人向けの設定」](docs/pipeline-setup.md#変えたい人向けの設定)と[「上級者向け」](docs/pipeline-setup.md#上級者向け)にまとめてある。

### 言葉

| 言葉 | 意味 |
| --- | --- |
| 進行役 | AIの作業のあいだをつなぐスクリプト（`pipeline.yml`・`.github/scripts/`）。次にどのAIを動かすか、マージするかを決める |
| 見張り役 | 30分ごとと、ほかの作業が終わるたびに動き、止まった物・取りこぼした物を拾ってやり直す（`watchdog.yml`） |
| 配る・配り先 | テンプレートの仕組み（`.github/`）の更新を、テンプレートから作ったリポジトリへ PR で届けること |
| 清書 | 1行のメモを、AIが実装できる Issue（やること・受け入れ条件）に書き直すこと |
| opus・sonnet・haiku | Claude のモデルの名前。大きい作業ほど強いモデルを使う |

**補足：Setup Labels（必要なら）**
ラベルが足りないときだけ、Actions の **Setup Labels** を手で1回実行する。ただし、Bootstrap より先にこれを実行すると、Bootstrap は「ラベルがもうある」として何もしないので、`CLAUDE.md` の節の削除と診断も飛ばされる。その場合は、`CLAUDE.md` の「ai-dev-template 自身の作業」の節を手で消し、Doctor を手で実行する。

テンプレート（本体）の更新（`.github/`・`docs/pipeline.md`・`docs/pipeline-setup.md`・`.claude/skills/`）は、本体の main でCIが通った版だけが、このテンプレートから作ったリポジトリ（自動）と、本体の `.github/sync-targets` に書いた配り先へ自動で配られる（この自動配布は本体だけが動かす）。

**自動配布の範囲：** 自動で配られるのは、作者（Gaku1205）のアカウントにあるテンプレートから作ったリポジトリだけ。他の人が、このリポジトリをコピー（Use this template・フォーク）して作った写しには、更新は届かない。写しでは、最初の準備（Bootstrap）のときに `.github/sync-targets` の配り先を空にする（作者の配り先が、写しから配られないようにするため）。

**写しで更新を取り込むには：** 自分のリポジトリで、テンプレートの更新を手で取り込む。

```sh
git remote add template https://github.com/Gaku1205/ai-dev-template.git
git fetch template main
git merge template/main --allow-unrelated-histories   # 2回目からは --allow-unrelated-histories は要らない
```

コンフリクトしたら、`.github/sync-targets` は自分の側（空）を残し、ほかは両方の変更を残して解消する。`.github/workflows/` の更新は、手で push するときにワークフローの書き込み権限が要る。

また、「新サービス：〜」の Issue で新しいサービスを作る工場は、**Template repository** のチェックを入れたリポジトリ（Settings → General）でだけ動く。チェックが無い所では、理由をコメントして `ai:skip` で止める。

### Vercelの公開回数について

Vercelの無料プランには、1日に公開できる回数の上限があります。AIは `claude/*` ブランチに何度もpushするので、そのたびにプレビューを作ると上限をすぐ使い切ってしまいます。`vercel.json` は、`claude/*` ブランチのプレビューを作らず、mainにマージされたときだけ公開するための設定です。また、直前のコミットが `.github/` と `docs/pipeline.md`・`docs/pipeline-setup.md`・`docs/factory.md` の変更だけなら、アプリは変わらないので公開を飛ばします（`ignoreCommand`）。

## 安全のしくみ

- 合否を決めるのはCI。AIの「できました」は信じない
- オーナー以外が作った Issue・コメントでは、AIは動かない
- `.github/`・`docs/pipeline.md`・`docs/pipeline-setup.md`・`CLAUDE.md`・`AGENTS.md`・`pipeline.json` を変えるPRは、CIとレビューが通っても自動でマージせず、人間に任せて通知する。仕組みそのものがAIの判断だけで書き換わらないようにするため。例外はテンプレートから配られた更新の PR（人間が書いてテンプレートの CI を通った物なので、配り先の CI が通れば自動でマージする）
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
| `docs/` | 仕様書（`spec.md`）・デザイン仕様（`design.md`）・パイプラインの説明（`pipeline.md`・`pipeline-setup.md`・`factory.md`） |
| `.claude/skills/` | AIが使うスキル（AIが作った感を消す taste-skill など）。パイプラインと一緒に配る |
| `examples/` | 工場の土台（ゲーム・Web のゲーム・Python・サブスク） |
| `src/` | 最小の Next.js（App Router）＋TypeScript＋Vitest |
| `vercel.json` | `claude/*`・`pipeline-sync/*` ブランチのVercelプレビューを作らない設定と、パイプラインの物だけの変更では公開を飛ばす設定（`ignoreCommand`） |
| `LICENSE` | MIT License（Copyright (c) 2026 Gaku1205） |
