# 工場（1行から新しいサービスを作る）

テンプレート本体（ai-dev-template）でだけ動く。流れ全体は `docs/pipeline.md`、設定は `docs/pipeline-setup.md`。デザインの仕組みは `docs/pipeline.md`「デザインの仕組み」。

ai-dev-template に、タイトルが **`新サービス：`** で始まるIssueを書くと（例：「新サービス：毎朝の天気と予定を1枚で見られるページ」）、`factory.yml` が新しいサービスのリポジトリを作って、いつものパイプラインに渡す。テンプレート本体で、オーナーが書いたIssueでだけ動く。Issue の本文は「詳しいメモ」として、名前決め・デザイン担当・最初のIssueに渡る（載せたい中身や、見た目の雰囲気。3000文字まで）。本文に**画像（リールのスクショ・好きなサイトの画面など）を貼ると**、デザイン担当がいちばん大事な実例として見る（`.github/scripts/fetch-issue-images.sh` が AI の前に取ってくる。10 枚まで）。URL を書けば、それも撮って見る。

## 相談してから作る（`factory-talk.yml`。ふつうはこちら）

いきなり作らず、オーナーに選んでもらいながら、作る物と見た目を最初に大まかに決める（あとの作り直しを減らすため）。AIの決まりは `.github/factory/talk.md`、形の確かめとコメントは `.github/scripts/factory-talk.py`・`factory-talk-publish.sh`。

1. **案**：AIが、作る物の案を5つ（名前・種類・使う人・新しい所・有料の分け方・画面）と、選択式の質問を Issue のコメントに書く
2. **見た目の方向**：選んだ案の方向を3つ。色違いではなく、題材の持ち物から作った考えが3つ。それぞれ、本物の素材で組んだ「最初の1画面」を、色・文字の見本と実例と一緒に1枚の板の画像にする（審査あり。上の「デザインの仕組み」）
3. **ざっくり画面**：選んだ方向で、トップの画面を下の欄まで全部、2案（1枚の HTML。PC とスマホを撮る。審査あり）
4. **最終確認**：名前・説明・無料と有料・値段・最初に作る画面・決まった事を1枚にまとめる。「作る」と返事すると、`factory.yml` を動かす（相談で決めた事をそのまま使い、名前をAIに決め直させない。デザイン担当は、選んだざっくり画面と方向の板を土台に本物を作る）

- 各段階で、コメントの最後に選択式の質問を付ける。オーナーの返事（番号・「全部ちがう。もっと〇〇」・注文）は、AIが「選んだ物・質問の答え・注文」に読み替える（agent-desk のボタンからの返事は、印 `<!-- factory-answer:… -->` の形が決まっているので、AIを通さない）
- 返事を待つ間は `factory:wait` が付く（答えるまで待つ。スマホに通知 `question`）。今までに決まった事はコメントの印 `<!-- factory-talk:v1:… -->` に入れて、毎回そこから読む
- 板とざっくり画面の画像・HTML は、テンプレートの `factory-talk` ブランチの `issue-<番号>/r<回>-<段階>/` に置く（コメントの画像と、作り始めたときのデザイン担当が使う）
- 作れなかったときは、そう書いて待つ。「もう一回」と返事すると、同じ段階をやり直す
- 案はいくつかを1つのサービスにまとめて選べる（`1,3`・`1〜4`）。前の段階の選び直し（「やっぱり案は 1,2」）もでき、その段階から先を作り直す
- AIが作っている途中に書いた返事も捨てない（同じ Issue の実行は順番待ちになり、出る前の選択肢への返事として読む）。作り始めた後（`factory.yml` を動かした後）のコメントは、相談の返事として読まない
- Issue に「全部おまかせ」とある（Issue のテンプレートのチェック）と、相談せずに下の流れで全部決めて作る

## 全部おまかせ（`factory.yml`）

1. AIが、名前（英語の小文字と -）・種類（画面のあるWebなら Next.js、会員登録と月額の有料プランがあるWebなら saas、処理が中心なら Python、exe のゲームなら game、ブラウザで遊ぶゲームなら webgame）・1行の説明を決める（AIは名前を書くだけで、鍵は持たない）。メモが中身を任せているときは、ありきたりでない案を10個考えて1つ選ぶ（ToDo・家計簿・タイマー・割り勘・サブスク管理などは選ばない）
2. **デザイン担当**（Next.js とゲームのとき。細かい決まりは `.github/factory/design-department.md`）：AIが見た目を決めて、**本物の Next.js の画面を最後まで作る**。それがそのまま新しいリポジトリの最初の中身になる（別のAIに作り直させない。伝言で質が落ちるため）
   - **設計メモから始める**：色や文字を選ぶ前に `factory-refs/concept.md`（題材の持ち物・考え・埋める物・通し表）を書く。作った画面は、確認コマンドが通ったあと、関門と審査役が見る（上の「デザインの仕組み」。作った本人だけでは「最初の1画面だけ凝る」「本物と答えたのに描いた絵で済ます」を止められないので、合格はスクリプトが決める）。結果の点は、できたときのコメントに載る
   - **実例から作る**：描く前に、題材と雰囲気に近い実在のサイトを 8〜15 個探して（日本のギャラリー（SANKOU! など）から先に。Issue にギャラリーの URL を書けば、そこから拾う） `shot.mjs --scrolls` で撮り、良い所と、どれのどこを混ぜるかを `factory-refs/board.md` に書く（言葉だけで考えると平均的な画面になるため）。Issue に貼った画像がいちばん大事な実例
   - **決まりは最低限＋AI感を出す前に弾く**：読める・押せる・スマホで崩れない・動きを止められる・目的が果たせる・実在のブランドを写さない。そのうえで、`.claude/skills/taste-skill/`（方向を配り、AIが作った感を測って弾くスキル）を使う：方向は `draw.mjs` に配ってもらう（ページは `--options 3`、道具の画面は `--app`）、AIが作った感の一覧（`references/tells.md`）を使わない、本物の写真・古い地図・図版を `assets.mjs` で探して使う、出す前に `lint.mjs`・`inspect.mjs` で測って FAIL を直す。工場の相談（見た目の方向・ざっくり画面）でも同じ（`.github/factory/talk.md`）。禁止を足すだけにせず、飾りを消した分を、大きい文字・色の面・本物の写真・中身で埋める（地味にしない）
   - **作って、撮って、実例と見比べて直す**（最低3回）。写真は `.github/scripts/fetch-photos.sh "<英語の検索語>" <枚数>` で Openverse（届かなければ Wikimedia Commons）から CC0・パブリックドメインの物だけを `public/photos/` に取る（鍵は要らない。画面のあるアプリの実装AIも使える。合わせて 20 枚まで、出どころは CREDITS.md。画面で使った写真だけが入る）。動き・3D の道具は `.github/scripts/factory-add-lib.sh <名前>` で、決まった物（`gsap`・`lenis`・`motion`・`three`・`pixi.js` など。一覧は `.github/scripts/factory-libs.sh`）だけをその場で入れ、新しいリポジトリにも同じ物が入る（アプリのAIは依存を足せないため）
   - 最後に `docs/design.md`（あとのIssueで同じ見た目を作るための決まり）を書き直す。ワークフローが確認コマンド（typecheck・lint・test・build）をAIとは別に動かし（`.github/scripts/factory-checks.sh`）、通らなければ1回だけ直させる。**通った物だけ**を、`.github/scripts/factory-site.py` が形を確かめてから新しいリポジトリの `src/`・`public/` に入れ、最後に撮った画像を `docs/design-ref/` に入れる。通らなかったときは、メモの1行を最初のIssueにして、実装AIが作る
   - **ゲームのとき**：design ジョブは最初に `.github/scripts/factory-game.sh` で見本（`examples/game`。TypeScript・Vite・Canvas／WebGL・Vitest・Electron）に切り替えてから、デザイン担当に渡す。デザイン担当はタイトル → 遊ぶ → 終わりまで作り、`/?scene=play` のように途中の場面を URL で開けるようにして、1280・1920 の幅で撮る。確認コマンドは `pipeline.json` にある物だけ（lint は無い）。exe は、新しいリポジトリの公開（`github-release`、Windows のランナーで `npm run dist`）が作って Releases に置く
   - **ゲームはありきたりにしない**：作る前に遊び方の案を 10 個出し、有名なゲームの遊び方そのまま（積み上げ・Flappy・ランナー・2048・マッチ3 など）や、見た目を変えただけの物は捨てて、見たことのない一ひねりがある物を選ぶ（`board.md` の「## アイデア」。結果のコメントに畳んで載せる）
   - **会員と課金（saas）のとき**：design ジョブは最初に `.github/scripts/factory-saas.sh . install` で、ログイン（Supabase）と有料プラン（Stripe）の土台（`examples/saas`）を入れてから、デザイン担当に渡す。デザイン担当は無料と有料の違いを決め、トップ・料金（`/pricing`）・ログイン・アカウントの画面を作り、月額の値段を `factory-price.txt` に書く（課金の土台のファイルは変えない。下の「会員と課金」）
   - **Web のゲーム（webgame）のとき**：見本は `examples/webgame`（Electron を入れない）。スマホの縦画面をいちばん大事にして、タッチで遊べ、結果を共有できるように作る（`design-department.md`「Web のゲームのとき」）。390・1440 の幅で撮る。公開は Next.js と同じく Vercel（プロジェクトの種類は Vite）
   - **ゲームの日本語の書体**（game・webgame とも）：`factory-game.sh` が M PLUS 1 の可変フォント（`examples/game-fonts/`。OFL）を `assets/fonts/` に入れる。`npm run build`・`npm run dev` の前に `npm run fonts`（`scripts/subset-fonts.mjs`、開発用の依存 `subset-font`）が、`src/` と `index.html` に出る文字と、かな・記号・英数字だけを抜き出して `public/fonts/mplus1.woff2` を作る（300KB を超えたら失敗。`public/fonts/` は git に入れない）。見本の `index.html` に `@font-face`（"GameJP"、太さ 100〜900）、`src/main.ts` に `JP_FONT` と読み込み待ちがある。実装AIは `curl`・`python3` を使えず書体を作れないので、最初から入れておく（文言を変えても作り直し不要。どの PC・ブラウザでも同じ見た目になる）
3. `factory.sh` が、テンプレートからリポジトリを作る（同じ名前があれば `-2` …）。作った直後に、どの Issue のために作ったかの印（新しいリポジトリの変数 `FACTORY_ISSUE`＝`テンプレート#Issueの番号`）を付ける
4. パイプラインの秘密（`CLAUDE_CODE_OAUTH_TOKEN`・`PIPELINE_APP_PRIVATE_KEY`・`PIPELINE_TOKEN`・`NTFY_TOPIC`）と変数（`PIPELINE_APP_ID`・`NOTIFY_EVENTS`・`AGENT_DESK_URL`）を、テンプレートの物から写す
5. Next.js・saas・Web のゲームで `VERCEL_TOKEN` があれば、Vercel のプロジェクトを作ってつなぐ。saas なら続けて、Supabase のプロジェクト・Stripe の商品と値段を作り、鍵を Vercel の環境変数に入れる（`factory-saas-provision.sh init`。最初の公開より前）
6. `CLAUDE.md` の1行目・仕様書の「目的」・README に説明を書き、デザイン担当が作った画面とデザイン仕様と道具を入れ、種類に合う見本に切り替えて（Python：`examples/python`・公開先は none／ゲーム：`examples/game`・GitHub Releases の exe／Web のゲーム：`examples/webgame`・Vercel／saas：会員と課金の土台・Vercel と、表の変更の supabase）、main に push する。この push で Bootstrap が動く。そのあと、新しいリポジトリの `pipeline.json` の公開先に `github-pages` があれば、`FACTORY_TOKEN` で GitHub Pages を有効にする（`POST repos/<新しいリポジトリ>/pages`、`build_type=workflow`。もう有効（409）なら成功として扱い、失敗したら結果のコメントに設定のページの URL 付きで直し方を書く。ワークフローのトークンでは有効にできないため、ここで行う）。`github-pages` が無ければ呼ばない
7. main を守る（PRと CI の `check` を必須にする。管理者は通れる）
8. 最初のIssueを作る（自動で企画に回る）。デザイン担当が画面を作れていれば、作りきれなかった残り（`factory-todo.md`、3つまで）だけをIssueにする（無ければ作らない）。作れていなければ、1行のメモを最初のIssueにする（最初の画面を一から作るので `size:L`＝強いモデルで実装する）。Vercel につないだときは、本番の公開アドレスを調べて報告に書き、リポジトリの Website 欄にも入れる（同じ名前がほかの人に使われていると、アドレスの後ろに文字が付く）。saas なら、公開アドレスで Stripe の通知の受け口とログインの戻り先を登録し（`factory-saas-provision.sh url`）、環境変数を効かせるため公開をやり直す。元のIssueに結果を書いて閉じる（デザイン担当が撮った画面の画像も貼るので、公開を待たずにどんな画面か見られる）

途中で止まったとき（リポジトリを作れない・push できない・時間切れ・取り消し・スクリプトのエラー）は、元の Issue に、できた所までと、何が残っているかを書き、スマホに知らせる（`stuck`）。中身を push する前に止まったら「作りかけのリポジトリが残っている。要らなければ消す。消さずに同じ Issue でもう一度作ると、続きから作る」、push のあとに止まったら「リポジトリは使える。❌ の所だけ手で続きをする」と書く（工場は、作りかけのリポジトリを自分では消さない）。

同じ Issue でもう一度動かしたとき（Actions の Factory の実行を Re-run する、など）、同じ名前のリポジトリが、前の実行の作りかけなら、新しく作らずに続きから作る（`-2` を増やさない）。続きにするのは、次の全部が確かなときだけ（`factory.sh` の `is_my_leftover`）。1つでも違えば、`-2` … の別の名前で作る（人が作ったリポジトリ・もう中身のあるリポジトリには触らない）：

- 印 `FACTORY_ISSUE` が、この Issue の物（変数はリポジトリの管理者しか書けないので、外の人は作れない）
- main の `CLAUDE.md` が、まだテンプレートのまま（最初の準備を push していない）
- saas ではない（Supabase・Stripe の物を二重に作らないため。saas は今までどおり `-2`）

テンプレートの受付（intake）は、`新サービス：` のIssueを企画に回さない。工場は最初にIssueへ `factory` の印を付け、企画AI・実装AIは、題が `新サービス：` で始まるか、この印があるIssueを、テンプレート自身では受けない（題が書き換えられても止まる）。

## 会員と課金（saas）

会員登録・ログインと、月額の有料プランがあるサービス。Next.js に、Supabase（ログインとデータベース）と Stripe（課金）の土台（`examples/saas`。説明は新しいリポジトリの `docs/billing.md`）が入る。

- 最初の1回だけ、Environment「factory」の Secret に2つ入れる
  - `SUPABASE_ACCESS_TOKEN`：supabase.com → Account preferences → Access Tokens。Resource access は **Organization**（自分の組織。新しく作るプロジェクトにも効く）。Permissions は Project Settings（Read and write。ログインの設定を変えるのに Auth Config と両方要る）・Database と Migrations（Read and write）・Connection Pooling（Read）・API Keys（Read and write）・API Key Secrets（Read）・Auth Config（Read and write）・Organizations（Read）・Organization Projects（Read and write）・Projects (account-wide)（Read）。ほかは None
  - `STRIPE_SECRET_KEY`：Stripe のダッシュボード（テスト環境）→ 開発者 → API キーのシークレットキー（**`sk_test_` だけ**。本番の鍵は工場が使わない）
- 工場がサービスごとに作る物：Supabase のプロジェクト（東京。最初の表と、確認メールを送らない設定）、Stripe の商品・月額の値段（デザイン担当が決めた円。既定 500 円）・会員ページの設定・通知の受け口（`<公開アドレス>/api/stripe/webhook`）、Vercel の環境変数（`docs/billing.md` の表）、新しいリポジトリの Secret `SUPABASE_DB_URL`（あとで表を足す公開が使う）
- あとのIssueで表を足すときは、AIが `supabase/migrations/0002_〜.sql` を足し、マージ後の公開（`supabase`）が流す。RLS は必須
- Supabase の無料プランは、動いているプロジェクトが2つまで。3つ目を作るときは、使わないプロジェクトを一時停止する（工場は作れなかった理由を Issue に書く）
- 本物の課金にするのは人間の作業：Stripe の本人確認と口座、特定商取引法に基づく表記・利用規約・プライバシーポリシーのページ、Vercel の `STRIPE_SECRET_KEY`・`STRIPE_PRICE_ID`・`STRIPE_WEBHOOK_SECRET` を本番の物に差し替え

## 最初の1回だけの準備

- **Environment「factory」**を作る：ai-dev-template の Settings → Environments → New environment で名前 `factory`。Deployment branches and tags を **Selected branches and tags** にして `main` だけを足す（強い鍵を、main のワークフローからだけ使えるようにする。AIが作ったブランチからは読めない）。下の2つの Secret は、リポジトリではなくこの Environment の Secrets に入れる
- **`FACTORY_TOKEN`**：リポジトリを作れる鍵。github.com → Settings → Developer settings → Fine-grained tokens で作る。Resource owner は自分、Expiration は **90日くらい**（切れたら作り直して入れ直す）、Repository access は **All repositories**、Permissions（Repository）は **Administration・Contents・Secrets・Variables・Issues を Read and write**（Metadata は自動で Read）。Administration は、リポジトリの削除までできる強い権限なので、この鍵はほかに使わない
- **パイプラインの GitHub App** を、**All repositories** に入れておく（新しいリポジトリでも、すぐ鍵が使えるように）。App の画面 → Install App → 自分のアカウントの Configure
- **Next.js を公開するなら**：`VERCEL_TOKEN`（Environment「factory」の Secret。Vercel → Account Settings → Tokens）と、Vercel の GitHub 連携を **All repositories** にしておく。チームで使うなら変数 `VERCEL_TEAM_ID`
- **会員と課金（saas）を作るなら**：Environment「factory」の Secret に `SUPABASE_ACCESS_TOKEN` と `STRIPE_SECRET_KEY` を入れる（上の「会員と課金」）
- 無い物があっても、作れる所までは作り、元のIssueに「何が無くて何をしなかったか」を書く
- あとから Vercel につなぐとき（作ったときに VERCEL_TOKEN が無かった物など）：Actions → **Factory Vercel** → Run workflow で、リポジトリの名前を入れる（つないだあと、今の main で本番の公開を1回始め、公開アドレスを Website 欄に入れる。もうつないであるリポジトリなら、公開とアドレスの調べ直しだけ）
