#!/usr/bin/env bash
# パイプで grep -q に流す書き方（printf … | grep -q）を、スクリプトに残さない
# pipeline-lib.sh は pipefail で動く。grep -q は見つけた所で読むのをやめるので、書く側が切られて（Broken pipe）
# パイプ全体が「失敗」になり、見つかったのに「無い」と判定されることがある（2026-11-22、after-review.sh で
# .github/ を触るPRに ai:hold が付かずマージに進むケースが、配り先の CI で実際に落ちた）。<<< で渡せば起きない
source "$(dirname "$0")/lib.sh"

echo "== スクリプトに「| grep -q」が無い（コメントは除く）"
hits=""
for f in "$SCRIPTS_DIR"/*.sh; do
  while IFS= read -r line; do
    hits+="$(basename "$f"): $line"$'\n'
  done < <(grep -nE '(^|[^|])\|[[:space:]]*grep[[:space:]]+-[A-Za-z]*q' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
done
assert_eq "見つかった所" "" "${hits%$'\n'}"

echo "== 変更ファイルが多くても、.github/ を触るPRはパイプライン物と判定される（pipefail の下で何度やっても同じ）"
hold_pattern='^(\.github/|\.claude/|docs/pipeline(-setup)?\.md$|CLAUDE\.md$|AGENTS\.md$|pipeline\.json$)'
files=".github/scripts/watchdog.sh"$'\n'"$(seq 1 20000 | sed 's|^|src/f|')"
ng=0
for _ in $(seq 1 20); do
  if ! (set -o pipefail; grep -qE "$hold_pattern" <<< "$files"); then ng=$((ng + 1)); fi
done
assert_eq "20回とも見つかる" "0" "$ng"
finish
