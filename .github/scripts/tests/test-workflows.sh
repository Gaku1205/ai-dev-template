#!/usr/bin/env bash
# ワークフローの安全の確認：秘密（PIPELINE_TOKEN・AIのトークン）を使うワークフローが、
# PRの中身で書き換えられる版（pull_request）で動かないこと。
#   pull_request は、PRのブランチにある版のワークフローが動く。PRが書き換えたワークフローで秘密を使われる恐れがある。
#   pull_request_target は、main にある版が動くので安全。
source "$(dirname "$0")/lib.sh"
WORKFLOWS="$(cd "$SCRIPTS_DIR/../workflows" && pwd)"

# pull_request で動かしてよい物（理由つき）。増やすときは、秘密がPRの変更で使われないかを確かめてから
#   visual-update.yml：同じリポジトリのPR（フォークではない）だけを、if で絞っている
#   claude-review.yml：同じリポジトリのPRだけが秘密を受け取る（フォークのPRには GitHub が秘密を渡さない）。レビューは読むだけで、トークンでは書き換えない
ALLOWED_PULL_REQUEST="visual-update.yml claude-review.yml"

echo "== 秘密を使うワークフローは、pull_request で動かない（許可の一覧にある物だけ例外）"
for f in "$WORKFLOWS"/*.yml; do
  name=$(basename "$f")
  uses_secret=$(grep -cE 'secrets\.(PIPELINE_TOKEN|CLAUDE_CODE_OAUTH_TOKEN)' "$f" || true)
  [ "$uses_secret" -eq 0 ] && continue
  triggers=$(python3 -c "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d.get(True, d.get('on', {}))
print(' '.join(on if isinstance(on, (list, dict)) else [on]))" "$f")
  if printf ' %s ' "$triggers" | grep -q ' pull_request '; then
    case " $ALLOWED_PULL_REQUEST " in
      *" $name "*) assert_eq "$name：pull_request（許可の一覧にある）" "ok" "ok" ;;
      *) assert_eq "$name：秘密を使うのに pull_request で動く（pull_request_target にするか、許可の一覧に理由つきで足す）" "pull_request_target" "pull_request" ;;
    esac
  else
    assert_eq "$name：pull_request で動かない" "ok" "ok"
  fi
done

echo "== 再開・順番待ちは pull_request_target"
for name in queue.yml resume.yml; do
  assert_contains "$name：pull_request_target を使う" "$(cat "$WORKFLOWS/$name")" "pull_request_target:"
done

echo "== visual-update.yml：PRのコードを動かすジョブには Secret を渡さない"
result=$(python3 - "$WORKFLOWS/visual-update.yml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
bad = []
for name, job in d['jobs'].items():
    text = yaml.dump(job)
    runs_code = any(w in text for w in ('npm ci', 'npm run', 'npx '))
    uses_secret = 'secrets.' in text
    if runs_code and uses_secret:
        bad.append(name)
print(','.join(bad) or 'ok')
PY
)
assert_eq "npm を動かすジョブが Secret を使わない" "ok" "$result"
assert_contains "撮り直しはトークンを残さない" "$(cat "$WORKFLOWS/visual-update.yml")" "persist-credentials: false"

echo "== doctor.yml：診断の失敗（❌）が、tee で隠れず、実行の失敗になる"
assert_contains "pipefail を使う" "$(cat "$WORKFLOWS/doctor.yml")" "set -o pipefail"

echo "== AIが動くジョブには PIPELINE_TOKEN を渡さない（AIの後の処理は、main の版を別のジョブで動かす）"
result=$(python3 - "$WORKFLOWS" <<'PY'
import sys, os, yaml
bad = []
for f in sorted(os.listdir(sys.argv[1])):
    if not f.endswith('.yml'): continue
    d = yaml.safe_load(open(os.path.join(sys.argv[1], f)))
    for name, job in (d.get('jobs') or {}).items():
        text = yaml.dump(job)
        if 'claude-code-action' in text and 'secrets.PIPELINE_TOKEN' in text:
            bad.append(f + ':' + name)
print(','.join(bad) or 'ok')
PY
)
assert_eq "AIのジョブに PIPELINE_TOKEN が無い" "ok" "$result"
for name in claude-plan.yml claude-implement.yml; do
  assert_contains "$name：AIのジョブが飛ばされたら後の処理も動かない" "$(cat "$WORKFLOWS/$name")" ".result != 'skipped'"
  assert_contains "$name：後の処理は main を取り直して動かす" "$(cat "$WORKFLOWS/$name")" "ref: \${{ github.event.repository.default_branch }}"
done

echo "== sync.yml：CIが通った版だけを配る"
sync="$(cat "$WORKFLOWS/sync.yml")"
assert_contains "CIの完了で動く" "$sync" "workflows: [CI]"
assert_contains "成功のときだけ" "$sync" "conclusion == 'success'"
assert_not_contains "push では動かない" "$sync" "  push:"

echo "== claude-review.yml：大きい・危ない変更は強いモデルでレビューする"
review="$(cat "$WORKFLOWS/claude-review.yml")"
assert_contains "モデルを決める段がある" "$review" "steps.weight.outputs.model"
assert_not_contains "sonnet 固定ではない" "$review" "--model sonnet --max-turns"

echo "== パイプラインの鍵を使うジョブは、GitHub App の鍵を先に作る（無ければ PIPELINE_TOKEN）"
result=$(python3 - "$WORKFLOWS" <<'PY'
import sys, os, yaml
bad = []
for f in sorted(os.listdir(sys.argv[1])):
    if not f.endswith('.yml'): continue
    d = yaml.safe_load(open(os.path.join(sys.argv[1], f)))
    for name, job in (d.get('jobs') or {}).items():
        # 工場（factory.yml）は PIPELINE_TOKEN を新しいリポジトリへ写すだけで、使わない（S_ で始まる名前で渡す）
        text = yaml.dump(job).replace('S_PIPELINE_TOKEN: ${{ secrets.PIPELINE_TOKEN }}', '')
        if 'secrets.PIPELINE_TOKEN' in text and 'create-github-app-token' not in text:
            bad.append(f + ':' + name)
        for st in job.get('steps') or []:
            if 'create-github-app-token' in str(st.get('uses', '')) and not st.get('continue-on-error'):
                bad.append(f + ':' + name + '(鍵が作れないと止まる)')
print(','.join(bad) or 'ok')
PY
)
assert_eq "鍵を使うジョブに App の鍵の段がある" "ok" "$result"

echo "== AIのアクションは、パイプラインの App が起こした実行を断らない（AI自身は除く）"
for name in claude-plan.yml claude-implement.yml claude-review.yml claude-mention.yml; do
  wf="$(cat "$WORKFLOWS/$name")"
  assert_contains "$name：allowed_bots を渡す" "$wf" "allowed_bots: \${{ steps.bots.outputs.list }}"
done
for name in claude-plan.yml claude-implement.yml claude-review.yml; do
  assert_contains "$name：claude[bot] は許可しない" "$(cat "$WORKFLOWS/$name")" '"$SENDER" != "claude[bot]"'
done

echo "== @claude を呼べるのは、人間のオーナー・メンバー・共同作業者と、このパイプラインの App だけ（ほかのボットは呼べない）"
# ジョブの条件（if）を、GitHub と同じ比べ方で評価する（gha-expr.py）。誰のどのイベントで動くかを、場面ごとに確かめる
mention_if=$(python3 -c "
import sys, yaml
print(' '.join(yaml.safe_load(open(sys.argv[1]))['jobs']['claude']['if'].split()))" "$WORKFLOWS/claude-mention.yml")
# 引数：イベント 書いた人 種類（User/Bot） 立場 書いた App の番号（無ければ null） PIPELINE_APP_ID [本文] [App の client_id]
mention_runs() {
  local app="null"
  if [ "$5" != null ]; then app='{"id":'"$5"',"client_id":"'"${8:-Iv1.other}"'"}'; fi
  local comment='{"body":"'"${7:-@claude 直して}"'","user":{"login":"'"$2"'","type":"'"$3"'"},"author_association":"'"$4"'"'
  # 行へのコメント（pull_request_review_comment）のイベントには、どの App が書いたかの項目が無い
  if [ "$1" = issue_comment ]; then comment="$comment"',"performed_via_github_app":'"$app"; fi
  python3 "$TESTS_DIR/gha-expr.py" "$mention_if" '{"github":{"event_name":"'"$1"'","event":{"comment":'"$comment"'}}},"vars":{"PIPELINE_APP_ID":"'"$6"'"}}'
}
assert_eq "オーナー（人間）のコメント" "true" "$(mention_runs issue_comment gaku User OWNER null 5506863)"
assert_eq "オーナーの、行へのコメント" "true" "$(mention_runs pull_request_review_comment gaku User OWNER null 5506863)"
assert_eq "共同作業者" "true" "$(mention_runs issue_comment friend User COLLABORATOR null 5506863)"
assert_eq "App を使っていない（PIPELINE_TOKEN だけ）リポジトリのオーナー" "true" "$(mention_runs issue_comment gaku User OWNER null "")"
assert_eq "@claude が無いコメントでは動かない" "false" "$(mention_runs issue_comment gaku User OWNER null 5506863 "直して")"
assert_eq "通りすがりの人は呼べない" "false" "$(mention_runs issue_comment stranger User NONE null 5506863)"
assert_eq "前にPRを出しただけの人は呼べない" "false" "$(mention_runs issue_comment someone User CONTRIBUTOR null 5506863)"
assert_eq "パイプラインの App（番号が PIPELINE_APP_ID と同じ）" "true" "$(mention_runs issue_comment 'gaku-ai-pipeline[bot]' Bot CONTRIBUTOR 5506863 5506863)"
assert_eq "PIPELINE_APP_ID に Client ID を入れていても見分けられる" "true" "$(mention_runs issue_comment 'gaku-ai-pipeline[bot]' Bot CONTRIBUTOR 5506863 Iv23liABC "@claude 直して" Iv23liABC)"
assert_eq "ほかの App のボットは呼べない" "false" "$(mention_runs issue_comment 'dependabot[bot]' Bot NONE 29110 5506863)"
assert_eq "名前だけ似せたボットは呼べない（番号で見る）" "false" "$(mention_runs issue_comment 'gaku-ai-pipeline[bot]' Bot CONTRIBUTOR 999 5506863)"
assert_eq "共同作業者の立場が付いたボットでも、ほかの App なら呼べない" "false" "$(mention_runs issue_comment 'helper[bot]' Bot COLLABORATOR 4242 5506863)"
assert_eq "AI自身（claude[bot]）は呼べない" "false" "$(mention_runs issue_comment 'claude[bot]' Bot NONE 1236702 5506863)"
assert_eq "AI自身は、番号が同じに設定されていても呼べない" "false" "$(mention_runs issue_comment 'claude[bot]' Bot NONE 1236702 1236702)"
assert_eq "ボットは、行へのコメントでは呼べない（パイプラインの App でも）" "false" "$(mention_runs pull_request_review_comment 'gaku-ai-pipeline[bot]' Bot CONTRIBUTOR 5506863 5506863)"
assert_eq "PIPELINE_APP_ID が空なら、どのボットも呼べない（App の印が無いボット）" "false" "$(mention_runs issue_comment 'some[bot]' Bot NONE null "")"
assert_eq "PIPELINE_APP_ID が空なら、どのボットも呼べない（行へのコメント）" "false" "$(mention_runs pull_request_review_comment 'some[bot]' Bot NONE null "")"
assert_eq "App の印が無いボットは呼べない" "false" "$(mention_runs issue_comment 'some[bot]' Bot NONE null 5506863)"

# AIのアクションに渡す許可（allowed_bots）も、同じ決まり：ワークフローの「起こしたボットを許可に入れる」の中身を、そのまま動かす
bots_run=$(python3 -c "
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))['jobs']['claude']['steps']
print(next(st['run'] for st in steps if st.get('id') == 'bots'))" "$WORKFLOWS/claude-mention.yml")
bots_list() { # イベント 書いた人 種類 書いた App の番号 PIPELINE_APP_ID
  local f; f=$(mktemp)
  EVENT="$1" AUTHOR="$2" AUTHOR_TYPE="$3" COMMENT_APP_ID="$4" COMMENT_APP_CLIENT_ID="" PIPELINE_APP_ID="$5" GITHUB_OUTPUT="$f" bash -c "$bots_run" > /dev/null 2>&1
  cat "$f"; rm -f "$f"
}
assert_eq "許可：パイプラインの App" "list=gaku-ai-pipeline[bot],gaku-ai-pipeline" "$(bots_list issue_comment 'gaku-ai-pipeline[bot]' Bot 5506863 5506863)"
assert_eq "許可：人間のコメントでは空" "list=" "$(bots_list issue_comment gaku User "" 5506863)"
assert_eq "許可：ほかの App のボットは入れない" "list=" "$(bots_list issue_comment 'dependabot[bot]' Bot 29110 5506863)"
assert_eq "許可：AI自身は入れない" "list=" "$(bots_list issue_comment 'claude[bot]' Bot 1236702 1236702)"
assert_eq "許可：行へのコメントのボットは入れない" "list=" "$(bots_list pull_request_review_comment 'gaku-ai-pipeline[bot]' Bot "" 5506863)"
assert_eq "許可：PIPELINE_APP_ID が空なら入れない" "list=" "$(bots_list issue_comment 'some[bot]' Bot "" "")"

echo "== 清書AIの質問には、ダッシュボードが拾う印を付けさせる"
wf="$(cat "$WORKFLOWS/claude-plan.yml")"
assert_contains "claude-plan.yml：質問の1行目は <!-- human-request -->" "$wf" "<!-- human-request -->"

echo "== 配り先は sync-targets.sh で決める（テンプレートから作ったリポジトリは自動）"
wf="$(cat "$WORKFLOWS/sync.yml")"
assert_contains "sync.yml：sync-targets.sh を使う" "$wf" "list=\$(.github/scripts/sync-targets.sh .github/sync-targets)"
assert_not_contains "sync.yml：配り先の失敗をプロセス置換で隠さない" "$wf" "< <(.github/scripts/sync-targets.sh"

echo "== 実装AI・修正AIは、push の前に main を取り込む（作業中に配布でワークフローが変わっても push が拒否されない）"
for name in claude-implement.yml claude-mention.yml; do
  wf="$(cat "$WORKFLOWS/$name")"
  assert_contains "$name：履歴を全部取る" "$wf" "fetch-depth: 0"
  assert_contains "$name：git fetch を許す" "$wf" "Bash(git fetch:*)"
  assert_contains "$name：git merge を許す" "$wf" "Bash(git merge:*)"
done
assert_contains "部品：push の前に main を取り込む指示" "$(cat "$SCRIPTS_DIR/prompts/merge-main.md")" "git merge origin/main で最新の main を取り込んでから"

echo "== AIへの指示は、部品から組んで渡す（compose-prompt.sh。docs/pipeline.md「指示を部品で組む」）"
for pair in claude-implement.yml:implement claude-mention.yml:mention; do
  name=${pair%%:*}; mode=${pair##*:}
  wf="$(cat "$WORKFLOWS/$name")"
  assert_contains "$name：部品から組む" "$wf" "compose-prompt.sh"
  assert_contains "$name：mode" "$wf" "--mode $mode --auto"
  assert_contains "$name：組んだ指示を渡す" "$wf" '--append-system-prompt \"${{ steps.prompt.outputs.text }}'
  assert_not_contains "$name：長い指示を直接書かない" "$wf" "git merge origin/main で最新の main を取り込んでから"
done
assert_eq "実装AI：2か所とも組んだ指示" "2" "$(grep -c 'steps.prompt.outputs.text }}${{ steps.shots.outputs.prompt }}' "$WORKFLOWS/claude-implement.yml")"
assert_contains "修正AI：部品を main から取る" "$(cat "$WORKFLOWS/claude-mention.yml")" "prompts/pr-body.md"

echo "== 修正AIは、見た目のテストの差分の画像を見てから決める"
wf="$(cat "$WORKFLOWS/claude-mention.yml")"
assert_contains "claude-mention.yml：差分の画像を取ってくる（main から取った版で）" "$wf" 'bash "$RUNNER_TEMP/pipeline-tools/fetch-visual-diff.sh"'
assert_not_contains "claude-mention.yml：作業フォルダ（PRのコード）の版では取らない" "$wf" "run: .github/scripts/fetch-visual-diff.sh"
assert_contains "部品：画像を見る指示" "$(cat "$SCRIPTS_DIR/prompts/visual-diff.md")" "Read で開いて見る"
assert_contains "claude-mention.yml：artifact を読む権限" "$wf" "actions: read"

echo "== 見張り役は、何もしなかった実行（skipped）の後には動かない"
wf="$(cat "$WORKFLOWS/watchdog.yml")"
assert_contains "watchdog.yml：skipped の後は動かない" "$wf" "github.event.workflow_run.conclusion != 'skipped'"

echo "== 配る（sync.yml）は、待ってから。新しい方が来たら古い待ちは止まり、配る本体は途中で止めない"
result=$(python3 - "$WORKFLOWS/sync.yml" <<'PY2'
import sys, yaml
j = yaml.safe_load(open(sys.argv[1]))['jobs']
w, s = j['wait'], j['sync']
print('wait-cancel' if w['concurrency']['cancel-in-progress'] is True else 'wait-no-cancel')
print('sync-needs-wait' if s.get('needs') == 'wait' else 'sync-no-needs')
print('sync-no-cancel' if s['concurrency']['cancel-in-progress'] is False else 'sync-cancel')
print('template-only' if 'is_template' in str(w.get('if', '')) else 'any-repo')
PY2
)
assert_eq "sync.yml の待ちと配る本体" "$(printf 'wait-cancel\nsync-needs-wait\nsync-no-cancel\ntemplate-only')" "$result"

echo "== やり直しの目覚まし：見張り役は目覚ましを動かせる（actions: write）。目覚ましは1つだけ"
assert_contains "watchdog.yml：actions: write" "$(cat "$WORKFLOWS/watchdog.yml")" "actions: write"
assert_contains "retry-timer.yml：新しい物が古い物を止める" "$(cat "$WORKFLOWS/retry-timer.yml")" "cancel-in-progress: true"
assert_contains "retry-timer.yml：見張り役が探す名前" "$(cat "$WORKFLOWS/retry-timer.yml")" "run-name: やり直しの目覚まし \${{ inputs.at }}"

echo "== 見た目の撮り直しは、通っている画像も含めて全部撮り直す（古い基準の画像を残さない）"
assert_contains "visual-update.yml：--update-snapshots=all" "$(cat "$WORKFLOWS/visual-update.yml")" "--update-snapshots=all"

echo "== 工場：強い鍵は Environment「factory」のジョブだけ。AIのジョブには渡さない。オーナーのIssueでだけ動く"
result=$(python3 - "$WORKFLOWS/factory.yml" <<'PY2'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])); j = d["jobs"]
out = []
out.append("build-env" if j["build"].get("environment") == "factory" else "build-no-env")
out.append("plan-no-factory" if "FACTORY_TOKEN" not in yaml.dump(j["plan"]) + yaml.dump(j["design"]) else "plan-has-factory")
out.append("owner-only" if "github.event.issue.user.login == github.repository_owner" in j["plan"]["if"] else "anyone")
out.append("template-only" if "is_template" in j["plan"]["if"] else "any-repo")
print(",".join(out))
PY2
)
assert_eq "factory.yml の守り" "build-env,plan-no-factory,owner-only,template-only" "$result"

echo "== デザイン担当：動かせるコマンドは確認コマンド・撮影・写真・決まった道具だけ。動かす前に手順書とスクリプトを読み取り専用にし、Issue の画像は AI の前に取る"
result=$(python3 - "$WORKFLOWS/factory.yml" <<'PY2'
import sys, re, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["design"]["steps"]
out = []
bash = set()
for st in steps:
    args = (st.get("with") or {}).get("claude_args", "")
    bash |= set(re.findall(r"Bash\(([^)]*)\)", args))
out.append("bash=" + "|".join(sorted(bash)))
names = [st.get("id") or st.get("name") or st.get("uses", "") for st in steps]
ro = names.index("手順書とスクリプトを読み取り専用にする")
out.append("ro-first" if ro < names.index("designer") else "ro-late")
out.append("chmod" if "chmod -R a-w .github .claude CLAUDE.md AGENTS.md" in steps[ro]["run"] else "no-chmod")
img = names.index("Issue に貼られた画像を取る")
out.append("images-first" if img < names.index("designer") and "github.token" in str(steps[img]["env"]) else "images-ng")
print(",".join(out))
PY2
)
assert_eq "factory.yml のデザイン担当" "bash=.github/scripts/factory-add-lib.sh:*|.github/scripts/fetch-photos.sh:*|node .claude/skills/taste-skill/scripts/assets.mjs:*|node .claude/skills/taste-skill/scripts/draw.mjs:*|node .claude/skills/taste-skill/scripts/inspect.mjs:*|node .claude/skills/taste-skill/scripts/lint.mjs:*|node .github/scripts/shot.mjs:*|npm run build|npm run lint|npm run test|npm run typecheck,ro-first,chmod,images-first" "$result"

echo "== デザイン担当の画面：AIとは別に確認コマンドを動かし、通らなければ1回だけ直させる。通った物だけを撮って、新しいリポジトリに渡す"
result=$(python3 - "$WORKFLOWS/factory.yml" <<'PY2'
import sys, yaml
j = yaml.safe_load(open(sys.argv[1]))["jobs"]
steps = j["design"]["steps"]; out = []
ids = [st.get("id") for st in steps]
c1, fx, c2, fin = (steps[ids.index(i)] for i in ("check1", "fixer", "check2", "final"))
out.append("checks:" + ("ok" if c1["run"] == c2["run"] == ".github/scripts/factory-checks.sh" else "ng"))
out.append("fixer:" + ("ok" if "steps.check1.outputs.ok == 'false'" in fx["if"] and "steps.check1.outputs.site == 'true'" in fx["if"] and fx.get("continue-on-error") is True else "ng"))
out.append("recheck:" + ("ok" if "steps.fixer.conclusion == 'success'" in c2["if"] else "ng"))
out.append("final:" + ("ok" if "steps.check1.outputs.ok == 'true'" in fin["if"] and "steps.check2.outputs.ok == 'true'" in fin["if"] and "--serve" in fin["run"] else "ng"))
keep = [st for st in steps if st.get("name") == "作った物を取っておく"][0]
out.append("ship:" + ("ok" if "steps.final.outputs.ok" in str(keep["env"]) and ".checks-ok" in keep["run"] else "ng"))
env = [st for st in j["build"]["steps"] if st.get("name") == "新しいサービスを作る"][0]["env"]
out.append("env:" + ("ok" if all(k in env for k in ("SITE_DIR", "TODO_FILE", "DESIGN_REF_DIR")) else "ng"))
print(",".join(out))
PY2
)
assert_eq "デザイン担当の画面" "checks:ok,fixer:ok,recheck:ok,final:ok,ship:ok,env:ok" "$result"

echo "== デザインの審査：作ったAIとは別のAI（審査役）が画像だけを見る（読む・書くだけ）。合格はスクリプトが決め、届かなければ1回だけ直させて、もう一度審査する"
result=$(python3 - "$WORKFLOWS" <<'PY2'
import sys, yaml
w = sys.argv[1]
out = []
for f, job in (("factory-talk.yml", "work"), ("factory.yml", "design"), ("claude-mocks.yml", "work")):
    steps = yaml.safe_load(open(f"{w}/{f}"))["jobs"][job]["steps"]
    ids = [st.get("id") for st in steps]
    ok = True
    order = [ids.index(i) for i in ("review1", "judge1", "verdict1", "review2", "judge2", "verdict2")]
    ok &= order == sorted(order)
    fix = "jfix" if f == "factory.yml" else "fix"
    ok &= ids.index("verdict1") < ids.index(fix) < ids.index("review2")
    for n in ("1", "2"):
        j = steps[ids.index("judge" + n)]
        # 審査役は、読む・探す・書くだけ（コマンドもネットも無し）。関門と合格の判定はスクリプト
        ok &= '--allowedTools "Read,Glob,Write"' in j["with"]["claude_args"] and ".github/factory/judge.md" in j["with"]["prompt"] and j.get("continue-on-error") is True
        ok &= steps[ids.index("review" + n)]["run"].startswith(".github/scripts/design-review.sh prepare")
        ok &= steps[ids.index("verdict" + n)]["run"].startswith(".github/scripts/design-review.sh verdict")
    # 直すのは、合格に届かなかったときだけ（審査できなかった none では直させない）
    cond = steps[ids.index(fix)].get("if", "") if f != "factory.yml" else steps[ids.index("snapshot")].get("if", "")
    ok &= "steps.verdict1.outputs.pass == 'false'" in cond
    out.append(f"{f}:" + ("ok" if ok else "ng"))
# 工場：直して確認コマンドが通らなくなったら、直す前の物に戻す。2回目の審査は、通ったときだけ
steps = yaml.safe_load(open(f"{w}/factory.yml"))["jobs"]["design"]["steps"]
ids = [st.get("id") for st in steps]
names = [st.get("name") for st in steps]
c3 = steps[ids.index("check3")]; back = steps[names.index("通らなければ、直す前の物に戻す")]
out.append("restore:" + ("ok" if c3["run"] == ".github/scripts/factory-checks.sh" and "steps.check3.outputs.ok != 'true'" in back["if"] and "before-judge-fix" in back["run"]
                         and "steps.check3.outputs.ok == 'true'" in steps[ids.index("review2")]["if"] and ids.index("review2") < ids.index("final") else "ng"))
# ゲームは審査しない（写真や欄の問いが合わない）
out.append("no-game:" + ("ok" if "!= 'game'" in steps[ids.index("review1")]["if"] and "!= 'webgame'" in steps[ids.index("review1")]["if"] else "ng"))
print(",".join(out))
PY2
)
assert_eq "デザインの審査" "factory-talk.yml:ok,factory.yml:ok,claude-mocks.yml:ok,restore:ok,no-game:ok" "$result"

echo "== 実装の審査役：画像だけを見る（読む・書くだけ。コマンドは動かせない）"
result=$(python3 - "$WORKFLOWS" <<'PY2'
import sys, yaml
w = sys.argv[1]
j = yaml.safe_load(open(f"{w}/claude-implement.yml"))["jobs"]["implement"]["steps"]
jid = [st.get("id") for st in j]
c = j[jid.index("critic")]
rj = j[jid.index("review_judge")]
print("implement-critic:" + ("ok" if '--allowedTools "Read,Glob,Write"' in c["with"]["claude_args"] and ".github/factory/judge.md" in c["with"]["prompt"]
                             and "design-judge.py verdict --mode change" in rj["run"] and "--critique .review/critique.md" in rj["run"]
                             and jid.index("review_shots") < jid.index("critic") < jid.index("review_judge") < jid.index("fix") else "ng"))
PY2
)
assert_eq "実装の審査役" "implement-critic:ok" "$result"

echo "== 「新サービス：」のIssue：テンプレート自身の企画・実装には回さない（工場が受け持つ）"
result=$(python3 - "$WORKFLOWS" <<'PY2'
import sys, yaml
w = sys.argv[1]
out = []
for f, job in (("claude-plan.yml", "plan"), ("claude-implement.yml", "implement")):
    cond = yaml.safe_load(open(f"{w}/{f}"))["jobs"][job]["if"]
    out.append(f"{job}:" + ("guarded" if "is_template" in cond and "新サービス：" in cond and "新サービス:" in cond and "'factory'" in cond else "open"))
fj = yaml.safe_load(open(f"{w}/claude-plan.yml"))["jobs"].get("factory-issue")
out.append("factory-issue:" + ("yes" if fj and "is_template" in fj["if"] and "'factory'" in fj["if"] else "no"))
# 工場は最初に factory の印を付ける（題が書き換えられても、印で止まる）
fp = yaml.safe_load(open(f"{w}/factory.yml"))["jobs"]["plan"]
mark = [st for st in fp["steps"] if st.get("name") == "工場の印を付ける"]
out.append("mark:" + ("yes" if mark and "labels[]=factory" in mark[0]["run"] and fp["permissions"].get("issues") == "write" else "no"))
print(",".join(out))
PY2
)
assert_eq "企画・実装は受けず、ラベルを外す" "plan:guarded,implement:guarded,factory-issue:yes,mark:yes" "$result"

echo "== 実装AI：画面を撮って見て直せる（撮影・ビルド・測るだけを許す。撮った画像はコミットしない）"
result=$(python3 - "$WORKFLOWS" <<'PY2'
import sys, yaml, re
w = sys.argv[1]; out = []
j = yaml.safe_load(open(f"{w}/claude-implement.yml"))["jobs"]["implement"]
st = [s for s in j["steps"] if s.get("id") == "shots"]
args = [s for s in j["steps"] if "claude-code-action" in s.get("uses", "")][0]["with"]["claude_args"]
run = st[0]["run"] if st else ""
allowed = re.search(r'echo "allowed=(Bash[^"]*)"', run)
out.append("allowed=" + (allowed.group(1) if allowed else "none"))
out.append("args:" + ("ok" if "${{ steps.shots.outputs.allowed }}" in args and "${{ steps.shots.outputs.prompt }}" in args else "ng"))
out.append("exclude:" + ("ok" if "/.shots/" in run and ".git/info/exclude" in run else "ng"))
out.append("order:" + ("ok" if st and j["steps"].index(st[0]) < [i for i, s in enumerate(j["steps"]) if "claude-code-action" in s.get("uses", "")][0] else "ng"))
d = yaml.safe_load(open(f"{w}/factory.yml"))["jobs"]["design"]
fin = [s for s in d["steps"] if s.get("id") == "final"][0]["run"]
b = yaml.safe_load(open(f"{w}/factory.yml"))["jobs"]["build"]["steps"]
env = [s for s in b if s.get("name") == "新しいサービスを作る"][0]["env"]
out.append("ref:" + ("ok" if '$RUNNER_TEMP/design/ref' in fin and "DESIGN_REF_DIR" in env else "ng"))
print(",".join(out))
PY2
)
assert_eq "撮影の扱い" "allowed=Bash(npm run build),Bash(node .github/scripts/shot.mjs:*),Bash(.github/scripts/fetch-photos.sh:*),args:ok,exclude:ok,order:ok,ref:ok" "$result"

echo "== 見た目のテスト：AIは動かせるが基準の画像は撮り直せない。撮り直しが失敗したらAIに直させる"
result=$(python3 - "$WORKFLOWS" <<'PY2'
import sys, yaml
w = sys.argv[1]; out = []
for f, job in (("claude-implement.yml", "implement"), ("claude-mention.yml", "mention")):
    d = yaml.safe_load(open(f"{w}/{f}"))["jobs"]
    j = d[job] if job in d else list(d.values())[0]
    args = [st for st in j["steps"] if "claude-code-action" in st.get("uses", "")][0]["with"]["claude_args"]
    names = [st.get("name", "") for st in j["steps"]]
    vis = [st for st in j["steps"] if st.get("id") == "visual"]
    ok = ("${{ steps.visual.outputs.allowed }}" in args and vis and "Bash(npm run test:visual)" in vis[0]["run"]
          and "--update-snapshots:*" in args.split("--disallowedTools")[1] and "見た目のテスト用のブラウザを入れる" in names)
    out.append(f"{f.split('.')[0]}:" + ("ok" if ok else "ng"))
steps = yaml.safe_load(open(f"{w}/visual-update.yml"))["jobs"]["unlabel"]["steps"]
h = [st for st in steps if st.get("name") == "撮り直しが失敗したら、AIに直させる"]
out.append("handoff:" + ("ok" if h and "needs.shoot.result == 'failure'" in h[0]["if"] and "request_fix_or_stop" in h[0]["run"] else "ng"))
print(",".join(out))
PY2
)
assert_eq "見た目のテストの扱い" "claude-implement:ok,claude-mention:ok,handoff:ok" "$result"

echo "== 修正AI：ボットが作ったPRでも確認コマンドを動かせる。ただし、このリポジトリの claude/ ブランチのPRだけ（pr-trust.sh）"
result=$(python3 - "$WORKFLOWS" <<'PY3'
import sys, yaml
w = sys.argv[1]
steps = yaml.safe_load(open(f"{w}/claude-mention.yml"))["jobs"]["claude"]["steps"]
names = [st.get("name") or st.get("uses", "") for st in steps]
ai = [i for i, st in enumerate(steps) if str(st.get("uses", "")).startswith("anthropics/claude-code-action")]
trust = [i for i, st in enumerate(steps) if st.get("id") == "trust"]
copy = [i for i, st in enumerate(steps) if st.get("name") == "道具を main から取ってくる" and "?ref=$BASE" in st["run"] and ".github/scripts/$f.sh " not in st["run"]]
out = []
# 既定（拒否する）のままにならないのは、pr-trust.sh が false と言ったときだけ
out.append("restrict:" + ("ok" if ai and steps[ai[0]]["with"].get("restrict_untrusted_prs") == "${{ steps.trust.outputs.restrict != 'false' }}" else "ng"))
out.append("trust:" + ("ok" if trust and copy and copy[0] < trust[0] < ai[0] and "pipeline-tools/pr-trust.sh" in steps[trust[0]]["run"] else "ng"))
# AIのあとの工程は、作業フォルダ（PRのコード）のスクリプトを動かさない
after = [st.get("run", "") for st in steps[ai[0] + 1:]]
out.append("after:" + ("ok" if after and not any(".github/scripts/" in r for r in after) else "ng"))
print(",".join(out))
PY3
)
assert_eq "修正AIの拒否の外し方" "restrict:ok,trust:ok,after:ok" "$result"

echo "== レビューAI：PRのコードがある作業フォルダのスクリプトを動かさない"
result=$(python3 - "$WORKFLOWS" <<'PY4'
import sys, yaml
steps = yaml.safe_load(open(f"{sys.argv[1]}/claude-review.yml"))["jobs"]["review"]["steps"]
print("ok" if not any(".github/scripts/" in st.get("run", "") for st in steps) else "ng")
PY4
)
assert_eq "レビューのジョブ" "ok" "$result"

echo "== 画面案：専用の手順書（mocks.md）を読み、作れなければその場で1回やり直し、それでも無ければ案なしで企画へ（MOCKS_RETRY=1）"
result=$(python3 - "$WORKFLOWS" <<'PY5'
import os, sys, yaml
w = sys.argv[1]
d = yaml.safe_load(open(f"{w}/claude-mocks.yml"))["jobs"]
work = d["work"]["steps"]; pub = d["publish"]["steps"]
ai = [st for st in work if str(st.get("uses", "")).startswith("anthropics/claude-code-action") and st.get("id") in ("claude", "claude_retry")]
out = []
out.append("doc:" + ("ok" if len(ai) == 2 and all(".github/factory/mocks.md" in st["with"]["prompt"] and "talk/" not in st["with"]["prompt"] for st in ai) and os.path.exists(f"{w}/../factory/mocks.md") else "ng"))
out.append("retry:" + ("ok" if len(ai) == 2 and ai[1].get("if") and "steps.retry.outputs.redo == 'true'" in ai[1]["if"] else "ng"))
p = [st for st in pub if st.get("run") == ".github/scripts/mocks-publish.sh"]
out.append("publish:" + ("ok" if p and p[0]["env"].get("MOCKS_RETRY") == "1" and "steps.app-token.outputs.token" in p[0]["env"]["GH_TOKEN"] else "ng"))
print(",".join(out))
PY5
)
assert_eq "画面案のやり直し" "doc:ok,retry:ok,publish:ok" "$result"

echo "== 進捗ログ：企画・画面案・実装・CI・レビュー・修正の全部が step-log.sh を呼ぶ（オーナーの名義にならないよう、ワークフローのトークンで）"
result=$(python3 - "$WORKFLOWS" <<'PY6'
import re, sys, yaml
w = sys.argv[1]
found = {}
for f in ["claude-plan.yml", "claude-mocks.yml", "claude-implement.yml", "claude-mention.yml", "pipeline.yml"]:
    for job in yaml.safe_load(open(f"{w}/{f}"))["jobs"].values():
        for st in job["steps"]:
            for m in re.finditer(r"step-log\.sh.*?--step (\w+)", st.get("run", "")):
                found.setdefault(m.group(1), []).append(st.get("env", {}).get("GH_TOKEN"))
want = ["plan", "mocks", "implement", "ci", "review", "fix"]
print(",".join(f"{k}:" + ("ok" if found.get(k) and all(t == "${{ github.token }}" for t in found[k]) else "ng") for k in want))
PY6
)
assert_eq "進捗ログの呼び出し" "plan:ok,mocks:ok,implement:ok,ci:ok,review:ok,fix:ok" "$result"

echo "== 企画：置き換えられて取り消された実行は、あとの工程（after-plan）を動かさない（先へ進んだ Issue に ai:retry を付けない）"
assert_contains "after-plan の条件" "$(grep -n "needs.plan.result" "$WORKFLOWS/claude-plan.yml")" "needs.plan.result != 'cancelled'"

echo "== 企画AI：他の Issue・PR の完了待ち（BLOCKED）の書き方がプロンプトにある"
assert_contains "BLOCKED" "$(cat "$WORKFLOWS/claude-plan.yml")" '`BLOCKED`：'

echo "== 読む量を減らす：企画AIが Issue に「読む所」を書き、実装AI・修正AIはそこだけを読む"
assert_contains "企画のプロンプト" "$(cat "$WORKFLOWS/claude-plan.yml")" "### 読む所"
assert_contains "部品：読む所の指示" "$(cat "$SCRIPTS_DIR/prompts/read-sections.md")" "「読む所」の見出しがあれば、docs/spec.md と docs/design.md は最初から全部は読まない"

echo "== 工場の審査：直した後の点が下がったら、直す前の物に戻してから最後の画面を撮る"
names=$(python3 -c "import yaml;print('\n'.join(st.get('name','') for st in yaml.safe_load(open('$WORKFLOWS/factory.yml'))['jobs']['design']['steps']))")
rv=$(printf '%s\n' "$names" | grep -n "直した後の方が悪ければ" | cut -d: -f1)
ft=$(printf '%s\n' "$names" | grep -n "^最後の画面を撮る$" | cut -d: -f1)
assert_eq "戻す手順がある" "yes" "$([ -n "$rv" ] && echo yes || echo no)"
assert_eq "最後の画面を撮る前に戻す" "yes" "$([ -n "$rv" ] && [ -n "$ft" ] && [ "$rv" -lt "$ft" ] && echo yes || echo no)"

echo "== ai:skip が付いた Issue では、ラベルが付け直されても企画・実装を始めない（オーナー以外の Issue を、やり直しで動かさない）"
result=$(python3 - "$WORKFLOWS" <<'PY'
import sys, yaml
bad = []
for f, job in (("claude-plan.yml", "plan"), ("claude-implement.yml", "implement")):
    cond = yaml.safe_load(open(f"{sys.argv[1]}/{f}"))["jobs"][job].get("if", "")
    if "!contains(github.event.issue.labels.*.name, 'ai:skip')" not in cond: bad.append(f)
print(",".join(bad))
PY
)
assert_eq "企画と実装のジョブの条件にある" "" "$result"

echo "== レビューのあとの処理に、レビューAIの実行記録を渡す（使用量の上限を見分けて、回数を使わずに待つ）"
result=$(python3 - "$WORKFLOWS" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(f"{sys.argv[1]}/pipeline.yml"))["jobs"]["after-review"]["steps"]
run = [s for s in steps if "after-review.sh" in str(s.get("run", ""))][0]
print(run.get("env", {}).get("EXECUTION_FILE", ""))
PY
)
assert_contains "after-review.sh に EXECUTION_FILE" "$result" "ai-result/execution.json"

finish
