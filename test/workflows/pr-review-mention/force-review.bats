#!/usr/bin/env bats
# Tests for the force_review decision in the pr-review-mention listener
# (issue #1281, item 1 of petry-projects/.github-private#2082).
#
# pr-review.yml in .github-private sets FORCE_REVIEW (skip the advisory-bot and
# comment-disposition waiting gates) only when the repository_dispatch carries
# client_payload.force_review == true. A trusted human's `@donpetry-bot` comment
# is the documented break-glass, so it must send the flag. Nothing else may:
# the review_requested path never does, and a comment carrying an automation
# marker never does either. Agents post as the owner account, so the author
# association alone cannot tell them from a person.
#
# Two layers are covered:
#   1. the pure decision function in
#      .github/scripts/pr-review-mention/lib/force-review.sh, over the whole matrix;
#   2. the shipped "Trigger review agent" step, extracted from the workflow and
#      run against the fake `gh`. The assertions are on the exact dispatch argv.

load 'helpers/setup'

LIB="${TT_REPO_ROOT}/.github/scripts/pr-review-mention/lib/force-review.sh"

setup() {
  tt_make_tmpdir
  GH_STUB_LOG="${TT_TMP}/gh.log"
  export GH_STUB_LOG
  : >"$GH_STUB_LOG"
  # shellcheck source=/dev/null
  . "$LIB"
}

teardown() {
  tt_cleanup_tmpdir
}

decide() { pr_review_mention_force_decision "$@"; }

MARKERS=(
  '<!-- pr-review-agent'
  '<!-- pr-review-claim'
  '<!-- persona:'
  '<!-- dev-lead'
  '<!-- dependency-advisory'
  '<!-- maintainer-resolve'
  '<!-- auto-rebase-conflict'
)

# ── pure decision function ───────────────────────────────────────────────────

@test "decision: OWNER comment mention → force" {
  run decide issue_comment OWNER don-petry '@donpetry-bot please review'
  [ "$status" -eq 0 ]
  [ "$output" = "force trusted-human-comment-mention" ]
}

@test "decision: MEMBER and COLLABORATOR comment mentions → force" {
  run decide issue_comment MEMBER alice '@donpetry-bot please review'
  [ "$status" -eq 0 ]
  [ "$output" = "force trusted-human-comment-mention" ]
  run decide issue_comment COLLABORATOR bob '@donpetry-bot please review'
  [ "$status" -eq 0 ]
  [ "$output" = "force trusted-human-comment-mention" ]
}

@test "decision: OWNER review-comment mention → force" {
  run decide pull_request_review_comment OWNER don-petry '@donpetry-bot look again'
  [ "$status" -eq 0 ]
  [ "$output" = "force trusted-human-comment-mention" ]
}

@test "decision: review_requested (pull_request) → plain, never force" {
  run decide pull_request "" don-petry ""
  [ "$status" -eq 0 ]
  [ "$output" = "plain review-requested" ]
}

@test "decision: review_requested stays plain even with a trusted-looking body" {
  run decide pull_request OWNER don-petry '@donpetry-bot please review'
  [ "$status" -eq 0 ]
  [ "$output" = "plain review-requested" ]
}

@test "decision: OWNER comment carrying a <!-- dev-lead marker → plain" {
  run decide issue_comment OWNER don-petry $'<!-- dev-lead status -->\n@donpetry-bot please review'
  [ "$status" -eq 0 ]
  [ "$output" = "plain automation-marker" ]
}

@test "decision: every automation marker → plain" {
  local m
  for m in "${MARKERS[@]}"; do
    run decide issue_comment OWNER don-petry "${m} x -->"$'\n''@donpetry-bot review'
    [ "$status" -eq 0 ]
    [ "$output" = "plain automation-marker" ] || {
      echo "marker not honoured: $m → $output"
      return 1
    }
  done
}

@test "decision: a marker anywhere in the body (not just the start) → plain" {
  run decide issue_comment OWNER don-petry $'@donpetry-bot please review\n\n<!-- maintainer-resolve id=1 -->'
  [ "$status" -eq 0 ]
  [ "$output" = "plain automation-marker" ]
}

@test "decision: CONTRIBUTOR comment → none (no dispatch)" {
  run decide issue_comment CONTRIBUTOR mallory '@donpetry-bot please review'
  [ "$status" -eq 0 ]
  [ "$output" = "none untrusted-association" ]
}

@test "decision: NONE / FIRST_TIME_CONTRIBUTOR / empty association → none" {
  local a
  for a in NONE FIRST_TIME_CONTRIBUTOR FIRST_TIMER MANNEQUIN ""; do
    run decide issue_comment "$a" mallory '@donpetry-bot please review'
    [ "$status" -eq 0 ]
    [ "$output" = "none untrusted-association" ]
  done
}

@test "decision: comment by donpetry-bot itself → none" {
  run decide issue_comment OWNER donpetry-bot '@donpetry-bot please review'
  [ "$status" -eq 0 ]
  [ "$output" = "none bot-author" ]
}

@test "decision: unknown event → none" {
  run decide workflow_dispatch OWNER don-petry '@donpetry-bot'
  [ "$status" -eq 0 ]
  [ "$output" = "none unsupported-event" ]
}

@test "decision: a body full of glob/shell metacharacters is treated literally" {
  run decide issue_comment OWNER don-petry "@donpetry-bot \$(touch ${TT_TMP}/pwned) * ? [a] \`id\`"
  [ "$status" -eq 0 ]
  [ "$output" = "force trusted-human-comment-mention" ]
  [ ! -e "${TT_TMP}/pwned" ]
}

# ── shipped "Trigger review agent" step ──────────────────────────────────────

# Run the extracted step from a scratch cwd where the tooling checkout path
# resolves to this repo, with the env a GitHub run: block would receive.
run_trigger() {
  tt_install_gh_stub
  tt_step_run "Trigger review agent" >"${TT_TMP}/trigger.sh"
  ln -s "$TT_REPO_ROOT" "${TT_TMP}/.pr-review-mention-tooling"
  (
    cd "$TT_TMP"
    GH_TOKEN="x" \
    PR_URL="https://github.com/petry-projects/.github/pull/1" \
    EVENT_NAME="${EVENT_NAME:-issue_comment}" \
    COMMENT_ASSOC="${COMMENT_ASSOC:-}" \
    COMMENT_USER="${COMMENT_USER:-}" \
    COMMENT_BODY="${COMMENT_BODY:-}" \
      bash -e "${TT_TMP}/trigger.sh"
  )
}

gh_log() { cat "$GH_STUB_LOG"; }

@test "step: OWNER comment mention dispatches force_review=true as a JSON boolean (-F)" {
  EVENT_NAME=issue_comment COMMENT_ASSOC=OWNER COMMENT_USER=don-petry \
    COMMENT_BODY='@donpetry-bot please review' run run_trigger
  [ "$status" -eq 0 ]
  [[ "$(gh_log)" == *"-F client_payload\[force_review\]=true"* ]]
  [[ "$(gh_log)" == *"client_payload\[pr_url\]="* ]]
  [[ "$output" == *"force_review=true (rule: trusted-human-comment-mention)"* ]]
}

@test "step: the flag is never sent as a raw string (-f / --raw-field)" {
  EVENT_NAME=issue_comment COMMENT_ASSOC=OWNER COMMENT_USER=don-petry \
    COMMENT_BODY='@donpetry-bot please review' run run_trigger
  [[ "$(gh_log)" != *"-f client_payload\[force_review\]"* ]]
  [[ "$(gh_log)" != *"--raw-field client_payload\[force_review\]"* ]]
}

@test "step: review_requested dispatches without force_review" {
  EVENT_NAME=pull_request COMMENT_ASSOC="" COMMENT_USER="" COMMENT_BODY="" run run_trigger
  [ "$status" -eq 0 ]
  [[ "$(gh_log)" == *"/repos/petry-projects/.github-private/dispatches"* ]]
  [[ "$(gh_log)" != *"force_review"* ]]
  [[ "$output" == *"force_review=false (rule: review-requested)"* ]]
}

@test "step: OWNER comment with a <!-- dev-lead marker dispatches a plain review" {
  EVENT_NAME=issue_comment COMMENT_ASSOC=OWNER COMMENT_USER=don-petry \
    COMMENT_BODY=$'<!-- dev-lead fix-reviews -->\n@donpetry-bot please review' run run_trigger
  [ "$status" -eq 0 ]
  [[ "$(gh_log)" == *"/repos/petry-projects/.github-private/dispatches"* ]]
  [[ "$(gh_log)" != *"force_review"* ]]
  [[ "$output" == *"force_review=false (rule: automation-marker)"* ]]
}

@test "step: CONTRIBUTOR comment sends no dispatch at all" {
  EVENT_NAME=issue_comment COMMENT_ASSOC=CONTRIBUTOR COMMENT_USER=mallory \
    COMMENT_BODY='@donpetry-bot please review' run run_trigger
  [ "$status" -eq 0 ]
  [ -z "$(gh_log)" ]
  [[ "$output" == *"untrusted-association"* ]]
}

@test "step: logs exactly one force_review decision line" {
  EVENT_NAME=issue_comment COMMENT_ASSOC=OWNER COMMENT_USER=don-petry \
    COMMENT_BODY='@donpetry-bot please review' run run_trigger
  [ "$(grep -c 'force_review=' <<<"$output")" -eq 1 ]
}

# ── wiring ───────────────────────────────────────────────────────────────────

@test "wiring: tooling is checked out from this reusable's own commit" {
  run yq -r '.jobs.handle-mention.steps[] | select(.name == "Checkout force-review tooling") | .with.ref' "$TT_WORKFLOW"
  [ "$status" -eq 0 ]
  [ "$output" = '${{ github.job_workflow_sha }}' ]
  run yq -r '.jobs.handle-mention.steps[] | select(.name == "Checkout force-review tooling") | .with.path' "$TT_WORKFLOW"
  [ "$status" -eq 0 ]
  [ "$output" = '.pr-review-mention-tooling' ]
}

@test "wiring: comment body reaches the trigger step via env, never inline \${{ }}" {
  run yq -r '.jobs.handle-mention.steps[] | select(.name == "Trigger review agent") | .env.COMMENT_BODY' "$TT_WORKFLOW"
  [ "$status" -eq 0 ]
  [ "$output" = '${{ github.event.comment.body }}' ]
  run tt_step_run "Trigger review agent"
  [ "$status" -eq 0 ]
  [[ "$output" != *'${{'* ]]
}

@test "wiring: the workflow header comment states the force_review rule" {
  head -40 "$TT_WORKFLOW" | grep -q 'force_review'
}

@test "decision: a [bot] account with a trusted association → none" {
  run decide issue_comment COLLABORATOR 'some-app[bot]' '@donpetry-bot please review'
  [ "$status" -eq 0 ]
  [ "$output" = "none bot-author" ]
}

@test "wiring: tooling checkout is best-effort so a failure cannot suppress the dispatch" {
  run yq -r '.jobs.handle-mention.steps[] | select(.name == "Checkout force-review tooling") | .["continue-on-error"]' "$TT_WORKFLOW"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}
