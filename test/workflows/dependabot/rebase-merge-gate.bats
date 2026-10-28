#!/usr/bin/env bats
# End-to-end tests for the merge step of dependabot-rebase-reusable.yml
# (issues #1399, #1400).
#
# The reusable merges Dependabot PRs with a GitHub App that bypasses the
# branch rulesets, so its own gate is the only thing standing between a PR and
# the default branch. It used to merge once checks were merely COMPLETE (a
# failed check passed) and never looked at who authored the commits. These
# tests run the workflow's real "Update and merge Dependabot PRs" run-block
# against a fixture-driven `gh` stub and assert on the merge call it makes.

load 'helpers/setup'

REUSABLE="${TT_REPO_ROOT}/.github/workflows/dependabot-rebase-reusable.yml"

setup() {
  tt_setup
  RUN_SCRIPT="${TT_TMP}/run.sh"
  tt_extract_run "$REUSABLE" update-and-merge "Update and merge Dependabot PRs" > "$RUN_SCRIPT"
}

teardown() {
  tt_teardown
}

_run_merge_step() {
  cd "$TT_WORK" || return 1
  GH_TOKEN="read-token" APP_TOKEN="app-token" APP_SLUG="$APP_SLUG_FIXTURE" \
    REPO="owner/repo" run bash -eo pipefail "$RUN_SCRIPT"
}

_green_nodes() {
  printf '[%s,%s,%s]' \
    "$(tt_check_run CodeQL COMPLETED SUCCESS)" \
    "$(tt_check_run 'dev-lead / push' COMPLETED SKIPPED)" \
    "$(tt_status CodeRabbit SUCCESS)"
}

_dependabot_only() { printf '[%s]' "$(tt_commit "$HEAD_SHA" 'dependabot[bot]' web-flow true 1)"; }

_rules_requiring() { # NAME...
  local ctx
  ctx=$(printf '%s\n' "$@" | jq -R '{context: .}' | jq -cs .)
  printf '[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":%s}}]' "$ctx"
}

_merge_calls() { grep -F '/pulls/5/merge' "${FIX_DIR}/writes.log" 2>/dev/null || true; }

@test "rebase: run-block exists and sources the gate libraries" {
  [ -s "$RUN_SCRIPT" ]
  grep -F '.dependabot-tooling/.github/scripts/dependabot/lib/gates.sh' "$RUN_SCRIPT"
  grep -F '.dependabot-tooling/.github/scripts/dependabot/lib/gh-io.sh' "$RUN_SCRIPT"
}

@test "rebase: the job checks out the gate tooling at the reusable's own commit" {
  run yq -r '.jobs.update-and-merge.steps[] | select(.name == "Checkout Dependabot gate tooling") | .with.ref' "$REUSABLE"
  [ "$status" -eq 0 ]
  [ "$output" = '${{ job.workflow_sha }}' ]
  run yq -r '.jobs.update-and-merge.steps[] | select(.name == "Checkout Dependabot gate tooling") | .with.path' "$REUSABLE"
  [ "$output" = ".dependabot-tooling" ]
}

@test "rebase: all checks green + Dependabot-only commits merges, bound to the head SHA" {
  tt_seed_pr "$(tt_pr_state "$(_green_nodes)")" "$(_dependabot_only)" "$(_rules_requiring CodeQL)"
  _run_merge_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"Merged PR #5"* ]]
  run _merge_calls
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
  [[ "$output" == "TOKEN=app-token PUT repos/owner/repo/pulls/5/merge"* ]]
  [[ "$output" == *"merge_method=squash"* ]]
  [[ "$output" == *"sha=${HEAD_SHA}"* ]]
}

@test "rebase: a completed but FAILED check is not merged (regression #1399)" {
  nodes="[$(tt_check_run CodeQL COMPLETED SUCCESS),$(tt_check_run 'dependency-audit / npm audit' COMPLETED FAILURE)]"
  tt_seed_pr "$(tt_pr_state "$nodes")" "$(_dependabot_only)"
  _run_merge_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping"*"dependency-audit / npm audit (failure)"* ]]
  run _merge_calls
  [ -z "$output" ]
}

@test "rebase: cancelled / timed-out / action-required / stale checks are not merged" {
  for c in CANCELLED TIMED_OUT ACTION_REQUIRED STALE STARTUP_FAILURE; do
    rm -f "${FIX_DIR}/writes.log"
    tt_seed_pr "$(tt_pr_state "[$(tt_check_run ci COMPLETED "$c")]")" "$(_dependabot_only)"
    _run_merge_step
    [ "$status" -eq 0 ]
    [ -z "$(_merge_calls)" ] || { echo "merged despite $c"; return 1; }
  done
}

@test "rebase: a failing commit status is not merged" {
  tt_seed_pr "$(tt_pr_state "[$(tt_check_run CodeQL COMPLETED SUCCESS),$(tt_status ext FAILURE)]")" "$(_dependabot_only)"
  _run_merge_step
  [ "$status" -eq 0 ]
  [ -z "$(_merge_calls)" ]
}

@test "rebase: a pending check is not merged" {
  tt_seed_pr "$(tt_pr_state "[$(tt_check_run ci IN_PROGRESS "")]")" "$(_dependabot_only)"
  _run_merge_step
  [ "$status" -eq 0 ]
  [ -z "$(_merge_calls)" ]
}

@test "rebase: a required check that never reported is not merged" {
  tt_seed_pr "$(tt_pr_state "$(_green_nodes)")" "$(_dependabot_only)" "$(_rules_requiring CodeQL SonarCloud)"
  _run_merge_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"required check(s) not reported"*"SonarCloud"* ]]
  [ -z "$(_merge_calls)" ]
}

@test "rebase: unreadable base-branch rules fail closed" {
  tt_seed_pr "$(tt_pr_state "$(_green_nodes)")" "$(_dependabot_only)"
  tt_fixture "repos/owner/repo/rules/branches/main?per_page=100" '{"message":"Server Error","status":"500"}' 1
  _run_merge_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not read the required checks"* ]]
  [ -z "$(_merge_calls)" ]
}

@test "rebase: a non-Dependabot commit on the branch is not merged (#1400)" {
  commits="[$(tt_commit "$DEP_SHA" 'dependabot[bot]' web-flow true 1),$(tt_commit "$HEAD_SHA" mallory mallory true 1)]"
  tt_seed_pr "$(tt_pr_state "$(_green_nodes)")" "$commits"
  _run_merge_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"not from Dependabot"* ]]
  [ -z "$(_merge_calls)" ]
}

@test "rebase: the App's own update-branch merge commit does not block" {
  commits="[$(tt_commit "$DEP_SHA" 'dependabot[bot]' web-flow true 1),$(tt_commit "$HEAD_SHA" "$APP_LOGIN_FIXTURE" web-flow true 2)]"
  tt_seed_pr "$(tt_pr_state "$(_green_nodes)")" "$commits"
  _run_merge_step
  [ "$status" -eq 0 ]
  [[ "$(_merge_calls)" == *"sha=${HEAD_SHA}"* ]]
}

@test "rebase: auto-merge not requested is not merged" {
  tt_seed_pr "$(tt_pr_state "$(_green_nodes)" MERGEABLE false)" "$(_dependabot_only)"
  _run_merge_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"auto-merge not enabled"* ]]
  [ -z "$(_merge_calls)" ]
}

@test "rebase: a conflicting PR is not merged" {
  tt_seed_pr "$(tt_pr_state "$(_green_nodes)" CONFLICTING)" "$(_dependabot_only)"
  _run_merge_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"not mergeable (CONFLICTING)"* ]]
  [ -z "$(_merge_calls)" ]
}

@test "rebase: a rejected merge (head moved) is logged and the run continues" {
  tt_seed_pr "$(tt_pr_state "$(_green_nodes)")" "$(_dependabot_only)"
  tt_fixture "repos/owner/repo/pulls/5/merge" '{"message":"Head branch was modified"}' 1
  _run_merge_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"Warning: failed to merge PR #5"* ]]
}

@test "rebase: gate reads use the job token, only the merge uses the App token" {
  tt_seed_pr "$(tt_pr_state "$(_green_nodes)")" "$(_dependabot_only)"
  _run_merge_step
  [ "$status" -eq 0 ]
  run grep -E 'graphql|/rules/|/commits' "${FIX_DIR}/calls.log"
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -v '^TOKEN=read-token '
}
