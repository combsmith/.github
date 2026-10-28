#!/usr/bin/env bats
# End-to-end tests for the approval step of dependabot-automerge-reusable.yml
# (issue #1400).
#
# dependabot/fetch-metadata describes only the Dependabot commit, but the
# workflow approved and enabled auto-merge for the WHOLE PR — including any
# commits pushed to the branch later by someone else. These tests run the
# workflow's real "Approve and enable auto-merge" run-block against a
# fixture-driven `gh` stub and assert on what it approves.

load 'helpers/setup'

REUSABLE="${TT_REPO_ROOT}/.github/workflows/dependabot-automerge-reusable.yml"

setup() {
  tt_setup
  RUN_SCRIPT="${TT_TMP}/run.sh"
  tt_extract_run "$REUSABLE" dependabot "Approve and enable auto-merge" > "$RUN_SCRIPT"
}

teardown() {
  tt_teardown
}

# _run_approve_step [EVENT_HEAD_SHA]
_run_approve_step() {
  cd "$TT_WORK" || return 1
  REPO="owner/repo" PR_NUMBER=5 EVENT_HEAD_SHA="${1:-$HEAD_SHA}" \
    APP_SLUG="$APP_SLUG_FIXTURE" READ_TOKEN="read-token" GH_TOKEN="app-token" \
    PR_URL="https://github.com/owner/repo/pull/5" \
    run bash -eo pipefail "$RUN_SCRIPT"
}

_writes() { cat "${FIX_DIR}/writes.log" 2>/dev/null || true; }

_seed() { # COMMITS_JSON
  tt_seed_pr "$(tt_pr_state "[$(tt_check_run ci COMPLETED SUCCESS)]")" "$1"
}

_foreign_commits() {
  printf '[%s,%s]' \
    "$(tt_commit "$DEP_SHA" 'dependabot[bot]' web-flow true 1)" \
    "$(tt_commit "$HEAD_SHA" mallory mallory true 1)"
}

@test "automerge: the approval step sources the gate libraries" {
  [ -s "$RUN_SCRIPT" ]
  grep -F '.dependabot-tooling/.github/scripts/dependabot/lib/gates.sh' "$RUN_SCRIPT"
  grep -F '.dependabot-tooling/.github/scripts/dependabot/lib/gh-io.sh' "$RUN_SCRIPT"
}

@test "automerge: tooling checkout runs at the reusable's own commit, only when eligible" {
  run yq -r '.jobs.dependabot.steps[] | select(.name == "Checkout Dependabot gate tooling") | .with.ref' "$REUSABLE"
  [ "$output" = '${{ job.workflow_sha }}' ]
  run yq -r '.jobs.dependabot.steps[] | select(.name == "Checkout Dependabot gate tooling") | .if' "$REUSABLE"
  [ "$output" = "steps.eligible.outputs.eligible == 'true'" ]
}

@test "automerge: Dependabot-only PR is approved at the head SHA and auto-merge is bound to it" {
  _seed "[$(tt_commit "$HEAD_SHA" 'dependabot[bot]' web-flow true 1)]"
  _run_approve_step
  [ "$status" -eq 0 ]
  run _writes
  [[ "$output" == *"TOKEN=app-token POST repos/owner/repo/pulls/5/reviews"*"event=APPROVE"*"commit_id=${HEAD_SHA}"* ]]
  [[ "$output" == *"TOKEN=app-token pr merge 5 --repo owner/repo --auto --squash --match-head-commit ${HEAD_SHA}"* ]]
}

@test "automerge: the App's update-branch merge commit does not block re-approval" {
  _seed "[$(tt_commit "$DEP_SHA" 'dependabot[bot]' web-flow true 1),$(tt_commit "$HEAD_SHA" "$APP_LOGIN_FIXTURE" web-flow true 2)]"
  _run_approve_step
  [ "$status" -eq 0 ]
  [[ "$(_writes)" == *"event=APPROVE"* ]]
}

@test "automerge: a later non-Dependabot commit is NOT approved (regression #1400)" {
  _seed "$(_foreign_commits)"
  _run_approve_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"Not approving PR #5"*"not from Dependabot"* ]]
  run _writes
  [[ "$output" != *"event=APPROVE"* ]]
  [[ "$output" != *"--approve"* ]]
  [[ "$output" != *"--auto --squash"* ]]
}

@test "automerge: a non-Dependabot commit disables auto-merge and dismisses only the App's approvals" {
  _seed "$(_foreign_commits)"
  tt_fixture "repos/owner/repo/pulls/5/reviews?per_page=100" \
    "[{\"id\":11,\"state\":\"APPROVED\",\"user\":{\"login\":\"${APP_LOGIN_FIXTURE}\"}},{\"id\":12,\"state\":\"APPROVED\",\"user\":{\"login\":\"alice\"}},{\"id\":13,\"state\":\"COMMENTED\",\"user\":{\"login\":\"${APP_LOGIN_FIXTURE}\"}}]"
  _run_approve_step
  [ "$status" -eq 0 ]
  run _writes
  [[ "$output" == *"pr merge 5 --repo owner/repo --disable-auto"* ]]
  [[ "$output" == *"PUT repos/owner/repo/pulls/5/reviews/11/dismissals"* ]]
  [[ "$output" != *"reviews/12/dismissals"* ]]
  [[ "$output" != *"reviews/13/dismissals"* ]]
}

@test "automerge: revocation is best effort (failures do not fail the step)" {
  _seed "$(_foreign_commits)"
  printf '1\n' > "${FIX_DIR}/pr_merge.rc"
  _run_approve_step
  [ "$status" -eq 0 ]
  [[ "$(_writes)" != *"event=APPROVE"* ]]
}

@test "automerge: a stale event (head moved since) approves nothing and revokes nothing" {
  _seed "[$(tt_commit "$HEAD_SHA" 'dependabot[bot]' web-flow true 1)]"
  _run_approve_step "$OTHER_SHA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"head moved"* ]]
  [ -z "$(_writes)" ]
}

@test "automerge: unreadable commits fail the step without approving or revoking" {
  _seed "[$(tt_commit "$HEAD_SHA" 'dependabot[bot]' web-flow true 1)]"
  tt_fixture "repos/owner/repo/pulls/5/commits?per_page=100" '{"message":"Server Error","status":"500"}' 1
  _run_approve_step
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not read the pull request's commits"* ]]
  [ -z "$(_writes)" ]
}

@test "automerge: provenance reads use the job token, writes use the App token" {
  _seed "[$(tt_commit "$HEAD_SHA" 'dependabot[bot]' web-flow true 1)]"
  _run_approve_step
  [ "$status" -eq 0 ]
  run grep -E 'api repos/owner/repo/pulls/5($| |/commits)' "${FIX_DIR}/calls.log"
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -v '^TOKEN=read-token '
}
