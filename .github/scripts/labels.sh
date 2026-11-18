#!/usr/bin/env bash
# パイプラインで使うラベルを作る（すでにあれば色と説明をそろえる）。
# 必要な環境変数：GH_TOKEN、REPO（owner/name）
set -euo pipefail
make_label() {
  gh label create "$1" -R "$REPO" --color "$2" --description "$3" --force
}
make_label "ai:implement" "5E9BF7" "実装AIが作業を始める"
make_label "ai:review" "5E9BF7" "レビューAIが確認する"
make_label "ai:queue" "BFD4F2" "順番待ち。並列の上限に空きがあり、触るファイルが進行中の物と重ならなければ、自動で実装が始まる"
make_label "ai:blocked" "BFD4F2" "他のIssue・PRの完了待ち。待ち先が全部閉じたら、見張り役が自動で企画に戻す"
make_label "ai:found" "C5DEF5" "使ってみる役（公開後に本番を試す）・監査役（仕様書の食い違いを探す）が見つけて作った Issue"
make_label "priority:high" "D93F0B" "急ぎ。順番待ちから先に実装に回す"
make_label "ai:hold" "E8A33D" "自動で進めるが、最後のマージだけ人間が押す"
make_label "ai:stuck" "F2555A" "自動で進められず止まった。人間の確認待ち"
make_label "ai:question" "E8A33D" "企画AIが質問している。コメントで答えると、自動で清書の続きをする"
make_label "ai:mocks" "8B5CF6" "作る前に、ざっくり画面を2案作ってオーナーに選んでもらう"
make_label "ai:skip" "EDEDED" "まだ自動で動かさない（外すと企画に回る）"
make_label "ai:retry" "BFD4F2" "AIが一時的に止まった（使用量の上限など）。見張り役が時間をおいて自動でやり直す"
make_label "visual:update" "C5DEF5" "見た目のテストの基準の画像を、CIの環境で撮り直す"
make_label "size:S" "C5DEF5" "小さい作業（軽いモデル）"
make_label "size:L" "0E8A16" "大きい作業（重いモデル）"
# ai:plan は必ず最後に作る：Bootstrap と Setup Labels は「ai:plan があれば、最初の準備は済んでいる」とみなす。
# 先に作ると、途中で失敗したとき（GitHub の不調など）に、残りのラベルが無いまま「準備ずみ」になり、二度と作られない
make_label "ai:plan" "8B5CF6" "企画AIが短いメモをIssueに清書し、実装に回す"
