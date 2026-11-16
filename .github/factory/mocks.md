# 画面案（mocks）の手順書（claude-mocks.yml が読む）

あなたは、見た目の大きい Issue について、オーナーに選んでもらうざっくり画面を2案作ります。本物のアプリではなく、見た目を決めるための1枚の HTML です。作った画面は、別のAI（審査役。`.github/factory/judge.md`）が画像だけを見て審査し、届かなければ指摘の紙（`.judge/fix.md`）が来ます。

## 2つの場合

`mocks/issue.txt` を読んで、どちらかを決める（`mocks/concept.md` の最初に `場合: 作り直し` か `場合: 追加` と書く）。

- **作り直し**：画面全体の見た目を作り直す Issue（「作り直す」「リデザイン」「AIっぽい」「ださい」「見た目を一新」など）。**今の色・文字・部品の形に縛られない**。今の画面（`mocks/now/`）は「何を載せているか」を知るために見るだけで、見た目は土台にしない。機能を足すたびに部品を足してきた画面は、白い角丸の箱・灰色の文字・塗りのボタンの並びになっていて、「このアプリらしさ」が無い。それを最初に決め直すのが、この Issue の仕事
- **追加**：今ある見た目の中に、新しい画面や大きい部品を足す Issue。`docs/design.md` の色・文字・「このサービスらしさ」をそのまま使い、新しい所にも通す。Issue が変えろと言っていない決まりは変えない

## 守ること

- 書いてよい場所は `mocks/` の中だけ（`mocks/concept.md`・`mocks/mock-a.html`・`mocks/mock-b.html`・`mocks/mocks.json`・`mocks/img/`・`mocks/refs/`・`mocks/draw/`・撮った画像）
- `.github/factory/design-department.md` の「AIっぽさの型（使わない）」を守る。道具のサービスなら、開いた最初の画面に道具そのものを出す。型を消したら、`.github/factory/concept.md` の「3. 何で埋めるか」で埋める（消すだけだと地味になり、それも落ちる）
- 実在のブランドの名前・ロゴ・文言を写さない
- 文はカジュアルで短い日本語
- 使える道具は、Read・Write・Edit・Glob・Grep・WebSearch・WebFetch と、下に書いたコマンド（`shot.mjs`・taste-skill の `draw.mjs`・`assets.mjs`・`lint.mjs`・`inspect.mjs`）だけ。`ls`・`cat`・`mkdir`・`npm` などのコマンドは許可されていないので使わない（ファイルを探すのは Glob、読むのは Read。`mocks/` はもうある。Write はフォルダが無くても書ける）。コマンドは下の形のまま1つずつ（`;` や `&&` や `|` でつながない・`cd` しない・`2>&1` を付けない）

## 作り方

1. 読む：`mocks/issue.txt`（Issue とコメント。前の画面案への注文があれば、それに合わせて出し直す）、あれば `mocks/now/`（今の画面の画像）、`docs/spec.md`・`docs/design.md`、あれば `docs/design-ref/`。そして `.github/factory/concept.md`（全部）
2. **設計メモを書く**（`mocks/concept.md`。形は `concept.md`。`場合:` の次の行に `種類:`）：
   - 作り直し：最初に `## 今の画面の診断` を書く（`mocks/now/` を見て、審査役の問い（`judge.md` の表）に自分で答える。どの型が出ているか・どこが地味か・何が「このアプリの物」に見えないか）。次に、持ち物（このアプリだけの言葉・物・数字・使う場面）→ 考え → 埋める物 → 通し表（今ある全部の画面を1行ずつ）
   - 追加：`docs/design.md` の「このサービスらしさ」を写し（無ければ、今の画面から持ち物と考えを読み取って書く）、通し表に新しい画面・部品の行を足す
3. 作り直しのときは、組み方を配ってもらう：道具の画面なら `node .claude/skills/taste-skill/scripts/draw.mjs --app --kind <種類> --brief "<1行>" --screens <画面> --options 3 --out mocks/draw`（`.claude/skills/taste-skill/references/app-screens.md` を読む。とくに「Give the product a face」）、ページなら `node .claude/skills/taste-skill/scripts/draw.mjs --sector <業種> --brief "<1行>" --options 3 --out mocks/draw`。配られた中から、考えを運べる物を2つ選ぶ（A と B の土台）。実例も見る：`node .github/scripts/shot.mjs --out mocks/refs --widths 1440 <URL> ...`（同じ種類の、実在の良い画面を4〜6個。全部 Read で見る）
4. 本物の素材：ページは `node .claude/skills/taste-skill/scripts/assets.mjs "<英語の検索語>"` で探し、`--get <ref> --to mocks/img` で取って `img/…` で載せる（3枚以上を主役の位置に。描いた絵で代用しない）。道具の画面は、写真の代わりに、このアプリの本物らしいデータ（`mocks/now/` と仕様書に出てくる言葉・件数・状態）を全部の欄に入れる
5. 2案は**構図が違う**物にする（主役にする物が違う。色違いにしない）。作り直しでは、A と B で考えの出し方も変えてよい
6. `mocks/mock-a.html`・`mocks/mock-b.html` を書く。1枚の HTML（CSS は中に書く。Google Fonts の `<link>` は使ってよい。JavaScript は使わない）。最初の1画面だけでなく、その画面のいちばん下まで全部。中身はこのサービスの本物らしい文言と数字（「テキスト」「Lorem」は使わない）。幅 1440px と 390px のどちらでも崩れないように書く（`@media`）
7. 撮る：`node .github/scripts/shot.mjs --out mocks --widths 1440,390 mocks/mock-a.html mocks/mock-b.html` と、下まで見る `node .github/scripts/shot.mjs --out mocks/scroll --widths 1440,390 --scrolls 3 mocks/mock-a.html mocks/mock-b.html`。できた画像を全部 Read で見て、崩れ・重なり・はみ出しを直してから撮り直す。作り直しでは、`mocks/now/` の画像と並べて見て、「色を変えただけ」になっていないかを確かめる
8. 測る：`node .claude/skills/taste-skill/scripts/lint.mjs mocks/mock-a.html mocks/mock-b.html`（道具の画面は最後に `--app`）。FAIL は直す（消すだけにせず、埋める）。追加の場合、`docs/design.md` が決めている物（等幅の数字・区切り線など）への指摘は、`docs/design.md` が勝つ
9. **最後に必ず** `mocks/mocks.json` を書く（これが無いと、画面案は無かった扱いになる）：

```json
{
  "mocks": [
    { "title": "（主役にした物）", "note": "（開くと何が見えるか・考えがどう出ているかを1〜2文）" },
    { "title": "（主役にした物）", "note": "…" }
  ],
  "questions": []
}
```

- `questions` は 0〜5 個、選択式（形は `.github/factory/talk.md` の「どの段階でも守ること」と同じ）。結果が変わる迷いだけ聞く

## 審査の後の直し

指示に「審査の結果を直す」とあるときは、新しく作り直さず、今ある物を直す。`.judge/fix.md`（関門と審査役の結果）と `.judge/made/`（審査に使った画像）を Read で見て、関門の指摘は全部、審査役の「必ず通す」の「いいえ」を先に直す。消すだけにしない（埋める）。合格している案は触らない。直したら、7 と 8 をもう一度やる。

## 断られたとき・迷ったとき

- ツールが許可されず断られたら、同じ操作を繰り返さず、上の道具だけで続ける
- 質問して止まらない。オーナーはこの場にいない。迷ったら、**考えがはっきり出る側**（大きく・濃く・本物の素材を広く）で作り、迷った所は `mocks.json` の `questions` に入れる（無難な側に倒さない。無難な画面は選ばれない）
- 撮るコマンドがどうしても動かないときも、HTML と `mocks/mocks.json` は書いて終える
