#!/usr/bin/env bash
# パイプラインのスクリプトのテストの共通部分。各 test-*.sh から `source` して使う。
# 本物の gh の代わりに tests/bin/gh（疑似GitHub）を PATH の先頭に置き、
# ラベル・コメント・PRの状態は JSON ファイルに持たせて、スクリプトを実際に動かして結果を確かめる。

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../../.." && pwd)"
SCRIPTS="$REPO_ROOT/.github/scripts"
# 疑似の gh・sleep を、実行できる状態にしておく（ファイルの権限が落ちていても動くように）
chmod +x "$TESTS_DIR/bin/gh" "$TESTS_DIR/bin/sleep"
PASS=0
FAIL=0
WORK=""

# 自動の印（pipeline-lib.sh と同じ物）
AUTO_FIX_MARK="<!-- auto-fix -->"
RESUME_MARK="<!-- auto-resume -->"
RETRY_MARK="<!-- auto-retry -->"
VISUAL_MARK="<!-- auto-visual-update -->"

ago() { date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ; }

# ---- 場面の始め ----

# 新しい疑似GitHub（空）を作って、環境を整える。name：場面の名前
scene() {
  echo "- $1"
  WORK=$(mktemp -d)
  export FAKE_GH_STATE="$WORK/state.json"
  cat > "$FAKE_GH_STATE" << 'JSON'
{"issues":{},"pulls":{},"comments":{},"runs":[],"jobs":{},"behind":{},"commit_dates":{},"branches":{},"events":[],"next_id":100,"update_branch_fails":false}
JSON
  export PATH="$TESTS_DIR/bin:$PATH"
  export GITHUB_REPOSITORY="owner/repo" GH_TOKEN="test-token" READ_TOKEN="read-token"
  unset NTFY_TOPIC NOTIFY_EVENTS MAX_AUTO_FIX MAX_RETRY RETRY_COOLDOWN_MIN
  cd "$REPO_ROOT" || exit 1
}

# 疑似GitHubの状態を jq で書き換える
st() {
  local t="$FAKE_GH_STATE.tmp"
  jq "$@" "$FAKE_GH_STATE" > "$t" && mv "$t" "$FAKE_GH_STATE"
}

# ---- 場面の用意 ----

# seed_issue 番号 タイトル 作成者 "ラベル,ラベル" [最後の動きから何分前]
seed_issue() {
  st --arg n "$1" --arg t "$2" --arg u "$3" --arg l "$4" --arg at "$(ago "${5:-0}")" \
    '.issues[$n] = {title: $t, user: $u, state: "open", pr: false, updated_at: $at,
      labels: (if $l == "" then [] else ($l | split(",")) end)}'
}

# seed_pr 番号 ブランチ 先頭コミット "ラベル" 説明文 [最後の動きから何分前]
seed_pr() {
  st --arg n "$1" --arg ref "$2" --arg sha "$3" --arg l "$4" --arg body "$5" --arg at "$(ago "${6:-0}")" \
    '.issues[$n] = {title: ("PR " + $n), user: "claude[bot]", state: "open", pr: true, updated_at: $at,
        labels: (if $l == "" then [] else ($l | split(",")) end)}
     | .pulls[$n] = {state: "open", body: $body, head: {ref: $ref, sha: $sha}}'
}

# seed_comment 番号 本文 [何分前に書かれたか] [書いた人]
seed_comment() {
  st --arg n "$1" --arg b "$2" --arg at "$(ago "${3:-0}")" --arg u "${4:-owner}" \
    '.next_id += 1 | .comments[$n] += [{id: .next_id, body: $b, user: {login: $u}, created_at: $at, updated_at: $at}]'
}

# seed_run ワークフロー名 コミット status conclusion(空ならnull) 何分前 id
seed_run() {
  st --arg name "$1" --arg sha "$2" --arg status "$3" --arg c "$4" --arg at "$(ago "${5:-0}")" --argjson id "${6:-1}" \
    '.runs += [{id: $id, name: $name, head_sha: $sha, status: $status, created_at: $at,
        conclusion: (if $c == "" then null else $c end)}]'
}

# seed_steps 実行のid '[{"name":"…","conclusion":"failure"}]'
seed_steps() {
  st --arg id "$1" --argjson steps "$2" '.jobs[$id] = $steps'
}

# seed_retry_record 番号 回数 kind [何分前に書き換えられたか]（見張り役が書く「やり直し」の記録）
seed_retry_record() {
  seed_comment "$1" "$(printf '🔁 AIが止まったので、時間をおいて自動でやり直します（やり直し %s/10回）。\n理由：テスト用の理由\n\n%s\n<!-- count=%s kind=%s -->' "$2" "$RETRY_MARK" "$2" "$3")" "${4:-0}"
}

# seed_auto_fixes 番号 個数（AIに直させた記録を、古い順に並べる）
seed_auto_fixes() {
  local k
  for ((k = 1; k <= $2; k++)); do
    seed_comment "$1" "@claude 直して（過去の依頼）

$AUTO_FIX_MARK" $((200 - k))
  done
}

# ---- 実行 ----

# run コマンド…：出力を OUT、終了コードを RC に入れる
run() {
  OUT=$("$@" 2>&1)
  RC=$?
}

# ---- 確かめる ----

pass() { PASS=$((PASS + 1)); }
fail() {
  FAIL=$((FAIL + 1))
  echo "  ✗ 失敗：$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'
}

check() { # check メッセージ -- 条件のコマンド…
  local msg="$1"
  shift
  if "$@"; then pass; else fail "$msg" "${OUT:-}"; fi
}

# 条件が「成り立たない」ことを確かめる用
not() { ! "$@"; }

labels_of() { jq -r --arg n "$1" '.issues[$n].labels[]?' "$FAKE_GH_STATE"; }
_has_label() { labels_of "$1" | grep -qx "$2"; }
_comment_count() { jq -r --arg n "$1" --arg p "$2" '[.comments[$n][]? | select(.body | contains($p))] | length' "$FAKE_GH_STATE"; }
_has_comment() { [ "$(_comment_count "$1" "$2")" -gt 0 ]; }
_has_event() { jq -e --arg e "$1" 'any(.events[]; contains($e))' "$FAKE_GH_STATE" > /dev/null; }

assert_label() { check "#$1 にラベル $2 が付いているはず" _has_label "$1" "$2"; }
assert_no_label() { check "#$1 にラベル $2 は付いていないはず（今：$(labels_of "$1" | tr '\n' ' ')）" not _has_label "$1" "$2"; }
assert_comment() { check "#$1 に「$2」を含むコメントがあるはず" _has_comment "$1" "$2"; }
assert_no_comment() { check "#$1 に「$2」を含むコメントは無いはず" not _has_comment "$1" "$2"; }
assert_comment_count() { # 番号 文字列 個数
  local got
  got=$(_comment_count "$1" "$2")
  [ "$got" = "$3" ] && pass || fail "#$1 の「$2」を含むコメントは $3 個のはず（実際：$got）"
}
assert_event() { check "「$1」という操作が行われたはず" _has_event "$1"; }
assert_no_event() { check "「$1」という操作は行われないはず" not _has_event "$1"; }
assert_rc() { [ "$RC" = "$1" ] && pass || fail "終了コードは $1 のはず（実際：$RC）" "$OUT"; }
assert_out() { # 出力に文字列を含む
  case "$OUT" in *"$1"*) pass ;; *) fail "出力に「$1」があるはず" "$OUT" ;; esac
}

# 最後に呼ぶ。失敗があれば 1 で終わる
finish() {
  echo "  → 成功 ${PASS} / 失敗 ${FAIL}"
  [ "$FAIL" -eq 0 ]
}
