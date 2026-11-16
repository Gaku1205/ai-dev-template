# 画面案（mocks）の手順書（claude-mocks.yml が読む）

あなたは、見た目の大きい Issue について、オーナーに選んでもらうざっくり画面を2案作ります。本物のアプリではなく、見た目を決めるための1枚の HTML です。

## 守ること

- 書いてよい場所は `mocks/` の中だけ（`mocks/mock-a.html`・`mocks/mock-b.html`・`mocks/mocks.json`・撮った画像）
- `.github/factory/design-department.md` の「AIっぽさの型（使わない）」を守る。道具のサービスなら、開いた最初の画面に道具そのものを出す
- 実在のブランドの名前・ロゴ・文言を写さない
- 文はカジュアルで短い日本語
- 使える道具は、Read・Write・Edit・Glob・Grep と、撮るコマンド（下の4）だけ。`ls`・`cat`・`mkdir`・`npm` などのコマンドは許可されていないので使わない（ファイルを探すのは Glob、読むのは Read。`mocks/` はもうある。Write はフォルダが無くても書ける）

## 作り方

1. `mocks/issue.txt`（Issue とコメント。前の画面案への注文があれば、それに合わせて出し直す）と、あれば `mocks/now/`（今の画面の画像）を Read で読む。`docs/spec.md`・`docs/design.md` と、あれば `docs/design-ref/` も読む。Issue が変えろと言っていない色・文字・決まりは、今のまま使う
2. 2案は、同じ方向の中で**構図が違う**物にする（例：A は曲線が主役、B は表が主役）
3. `mocks/mock-a.html`・`mocks/mock-b.html` を書く。1枚の HTML（CSS は中に書く。Google Fonts の `<link>` は使ってよい。JavaScript は使わない）。中身はこのサービスの本物らしい文言と数字（「テキスト」「Lorem」は使わない）。幅 1440px と 390px のどちらでも崩れないように書く（`@media`）
4. 撮る：`node .github/scripts/shot.mjs --out mocks --widths 1440,390 mocks/mock-a.html mocks/mock-b.html`（この形のまま。`;` や `&&` や `|` でつながない・`cd` しない・`2>&1` を付けない）。できた画像を全部 Read で見て、崩れ・重なり・はみ出しを直してから撮り直す
5. **最後に必ず** `mocks/mocks.json` を書く（これが無いと、画面案は無かった扱いになる）：

```json
{
  "mocks": [
    { "title": "曲線が主役", "note": "開くと今日の潮の曲線が画面の半分。時合いは曲線の上の帯" },
    { "title": "表が主役", "note": "地点ごとの表が主役。曲線は小さく行の中に" }
  ],
  "questions": []
}
```

- `questions` は 0〜5 個、選択式（形は `.github/factory/talk.md` の「どの段階でも守ること」と同じ）。結果が変わる迷いだけ聞く

## 断られたとき・迷ったとき

- ツールが許可されず断られたら、同じ操作を繰り返さず、上の道具だけで続ける
- 質問して止まらない。オーナーはこの場にいないので、迷ったらいちばん無難な解釈で作り、迷った所は `mocks.json` の `questions` に入れる
- 撮るコマンドがどうしても動かないときも、HTML と `mocks/mocks.json` は書いて終える
