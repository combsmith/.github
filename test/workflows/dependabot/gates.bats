#!/usr/bin/env bats
# Unit tests for the pure Dependabot merge / approval gates
# (.github/scripts/dependabot/lib/gates.sh).
#
#   #1399 — the merger must not merge unless EVERY check on the head commit
#           concluded success / neutral / skipped (fail closed otherwise).
#   #1400 — approval / merge must not apply to commits that did not come from
#           Dependabot (or the merge App's own branch updates).

load 'helpers/setup'

setup() {
  # shellcheck source=/dev/null
  . "${TT_LIB_DIR}/gates.sh"
}

_ok_nodes() {
  printf '[%s,%s,%s]' \
    "$(tt_check_run "CodeQL" COMPLETED SUCCESS)" \
    "$(tt_check_run "dev-lead / push" COMPLETED SKIPPED)" \
    "$(tt_status "CodeRabbit" SUCCESS)"
}

# ── dependabot_checks_gate (#1399) ──────────────────────────────────────────

@test "checks: all success / skipped / status success passes" {
  run dependabot_checks_gate "$(tt_pr_state "$(_ok_nodes)")" '[]'
  [ "$status" -eq 0 ]
  [[ "$output" == *"all 3 check(s) succeeded"* ]]
}

@test "checks: neutral conclusion passes" {
  run dependabot_checks_gate "$(tt_pr_state "[$(tt_check_run lint COMPLETED NEUTRAL)]")" '[]'
  [ "$status" -eq 0 ]
}

@test "checks: lowercase REST-style values are accepted" {
  run dependabot_checks_gate "$(tt_pr_state "[$(tt_check_run lint completed success)]")" '[]'
  [ "$status" -eq 0 ]
}

@test "checks: accepts the whole GraphQL response envelope" {
  run dependabot_checks_gate "{\"data\":{\"repository\":{\"pullRequest\":$(tt_pr_state "$(_ok_nodes)")}}}" '[]'
  [ "$status" -eq 0 ]
}

@test "checks: a completed FAILURE blocks (regression #1399)" {
  nodes="[$(tt_check_run CodeQL COMPLETED SUCCESS),$(tt_check_run 'dependency-audit / npm audit' COMPLETED FAILURE)]"
  run dependabot_checks_gate "$(tt_pr_state "$nodes")" '[]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"dependency-audit / npm audit (failure)"* ]]
}

@test "checks: every non-success conclusion blocks" {
  for c in FAILURE CANCELLED TIMED_OUT ACTION_REQUIRED STALE STARTUP_FAILURE SOMETHING_NEW; do
    run dependabot_checks_gate "$(tt_pr_state "[$(tt_check_run ci COMPLETED "$c")]")" '[]'
    [ "$status" -eq 1 ] || { echo "conclusion $c did not block"; return 1; }
  done
}

@test "checks: completed with a null conclusion blocks" {
  run dependabot_checks_gate "$(tt_pr_state "[$(tt_check_run ci COMPLETED "")]")" '[]'
  [ "$status" -eq 1 ]
}

@test "checks: pending / queued / in-progress check runs block" {
  for s in QUEUED IN_PROGRESS WAITING PENDING REQUESTED; do
    run dependabot_checks_gate "$(tt_pr_state "[$(tt_check_run ci "$s" "")]")" '[]'
    [ "$status" -eq 1 ] || { echo "status $s did not block"; return 1; }
  done
}

@test "checks: commit status pending / failure / error / expected blocks" {
  for s in PENDING FAILURE ERROR EXPECTED; do
    run dependabot_checks_gate "$(tt_pr_state "[$(tt_status ext "$s")]")" '[]'
    [ "$status" -eq 1 ] || { echo "status context $s did not block"; return 1; }
  done
}

@test "checks: an unknown context type blocks" {
  run dependabot_checks_gate "$(tt_pr_state '[{"__typename":"Mystery","name":"x"}]')" '[]'
  [ "$status" -eq 1 ]
}

@test "checks: no checks reported blocks" {
  run dependabot_checks_gate "$(tt_pr_state '[]')" '[]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"no checks reported"* ]]
}

@test "checks: a second page of checks blocks (cannot verify them all)" {
  run dependabot_checks_gate "$(tt_pr_state "$(_ok_nodes)" MERGEABLE true "$HEAD_SHA" "$HEAD_SHA" true)" '[]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot verify"* ]]
}

@test "checks: a rollup for a commit other than the head blocks" {
  run dependabot_checks_gate "$(tt_pr_state "$(_ok_nodes)" MERGEABLE true "$HEAD_SHA" "$OTHER_SHA")" '[]'
  [ "$status" -eq 1 ]
}

@test "checks: head differing from the expected SHA blocks" {
  run dependabot_checks_gate "$(tt_pr_state "$(_ok_nodes)")" '[]' "$OTHER_SHA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"head moved"* ]]
}

@test "checks: head matching the expected SHA passes" {
  run dependabot_checks_gate "$(tt_pr_state "$(_ok_nodes)")" '[]' "$HEAD_SHA"
  [ "$status" -eq 0 ]
}

@test "checks: a required check that never reported blocks" {
  run dependabot_checks_gate "$(tt_pr_state "$(_ok_nodes)")" '["CodeQL","SonarCloud"]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"required check(s) not reported"*"SonarCloud"* ]]
}

@test "checks: required checks satisfied by check runs and statuses pass" {
  run dependabot_checks_gate "$(tt_pr_state "$(_ok_nodes)")" '["CodeQL","CodeRabbit"]'
  [ "$status" -eq 0 ]
}

@test "checks: malformed input blocks" {
  run dependabot_checks_gate 'not json' '[]'
  [ "$status" -eq 1 ]
  run dependabot_checks_gate "$(tt_pr_state "$(_ok_nodes)")" 'not json'
  [ "$status" -eq 1 ]
  run dependabot_checks_gate '' '[]'
  [ "$status" -eq 1 ]
}

# ── dependabot_provenance_gate (#1400) ──────────────────────────────────────

_dep_commit() { tt_commit "$1" 'dependabot[bot]' web-flow true 1; }

@test "provenance: a single verified Dependabot commit passes" {
  commits="[$(_dep_commit "$HEAD_SHA")]"
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 1)" "$commits" ""
  [ "$status" -eq 0 ]
}

@test "provenance: committer dependabot[bot] is also accepted" {
  commits="[$(tt_commit "$HEAD_SHA" 'dependabot[bot]' 'dependabot[bot]' true 1)]"
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 1)" "$commits" ""
  [ "$status" -eq 0 ]
}

@test "provenance: Dependabot commit + the App's update-branch merge passes" {
  commits="[$(_dep_commit "$DEP_SHA"),$(tt_commit "$HEAD_SHA" "$APP_LOGIN_FIXTURE" web-flow true 2)]"
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 2)" "$commits" "$APP_LOGIN_FIXTURE" "$HEAD_SHA"
  [ "$status" -eq 0 ]
}

@test "provenance: paginated (slurped) commit pages are flattened" {
  pages="[[$(_dep_commit "$DEP_SHA")],[$(tt_commit "$HEAD_SHA" "$APP_LOGIN_FIXTURE" web-flow true 2)]]"
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 2)" "$pages" "$APP_LOGIN_FIXTURE"
  [ "$status" -eq 0 ]
}

@test "provenance: a later commit pushed by someone else blocks (regression #1400)" {
  commits="[$(_dep_commit "$DEP_SHA"),$(tt_commit "$HEAD_SHA" mallory mallory true 1)]"
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 2)" "$commits" "$APP_LOGIN_FIXTURE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not from Dependabot"*"author mallory"* ]]
}

@test "provenance: a web-UI commit by a person (committer web-flow) blocks" {
  commits="[$(_dep_commit "$DEP_SHA"),$(tt_commit "$HEAD_SHA" alice web-flow true 1)]"
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 2)" "$commits" "$APP_LOGIN_FIXTURE"
  [ "$status" -eq 1 ]
}

@test "provenance: a Dependabot-attributed commit without a verified signature blocks" {
  commits="[$(_dep_commit "$DEP_SHA"),$(tt_commit "$HEAD_SHA" 'dependabot[bot]' web-flow false 1)]"
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 2)" "$commits" ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"unverified"* ]]
}

@test "provenance: a Dependabot-attributed commit committed by someone else blocks" {
  commits="[$(_dep_commit "$DEP_SHA"),$(tt_commit "$HEAD_SHA" 'dependabot[bot]' mallory true 1)]"
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 2)" "$commits" ""
  [ "$status" -eq 1 ]
}

@test "provenance: an App commit that is not a merge blocks" {
  commits="[$(_dep_commit "$DEP_SHA"),$(tt_commit "$HEAD_SHA" "$APP_LOGIN_FIXTURE" web-flow true 1)]"
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 2)" "$commits" "$APP_LOGIN_FIXTURE"
  [ "$status" -eq 1 ]
}

@test "provenance: an App merge commit blocks when no trusted login is given" {
  commits="[$(_dep_commit "$DEP_SHA"),$(tt_commit "$HEAD_SHA" "$APP_LOGIN_FIXTURE" web-flow true 2)]"
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 2)" "$commits" ""
  [ "$status" -eq 1 ]
}

@test "provenance: a merge commit by another bot blocks" {
  commits="[$(_dep_commit "$DEP_SHA"),$(tt_commit "$HEAD_SHA" 'other-app[bot]' web-flow true 2)]"
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 2)" "$commits" "$APP_LOGIN_FIXTURE"
  [ "$status" -eq 1 ]
}

@test "provenance: a commit with no linked author account blocks" {
  commits="[$(_dep_commit "$DEP_SHA"),$(tt_commit "$HEAD_SHA" '' web-flow true 1)]"
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 2)" "$commits" ""
  [ "$status" -eq 1 ]
}

@test "provenance: only App merge commits (no Dependabot commit) blocks" {
  commits="[$(tt_commit "$HEAD_SHA" "$APP_LOGIN_FIXTURE" web-flow true 2)]"
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 1)" "$commits" "$APP_LOGIN_FIXTURE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no Dependabot commit"* ]]
}

@test "provenance: an incomplete commit list (fewer than the PR's count) blocks" {
  commits="[$(_dep_commit "$HEAD_SHA")]"
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 251)" "$commits" ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot verify them all"* ]]
}

@test "provenance: head not in the commit list blocks" {
  commits="[$(_dep_commit "$DEP_SHA")]"
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 1)" "$commits" ""
  [ "$status" -eq 1 ]
}

@test "provenance: head differing from the expected SHA blocks" {
  commits="[$(_dep_commit "$HEAD_SHA")]"
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 1)" "$commits" "" "$OTHER_SHA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"head moved"* ]]
}

@test "provenance: empty or malformed input blocks" {
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 0)" '[]' ""
  [ "$status" -eq 1 ]
  run dependabot_provenance_gate 'nope' '[]' ""
  [ "$status" -eq 1 ]
  run dependabot_provenance_gate "$(tt_pr_rest)" 'nope' ""
  [ "$status" -eq 1 ]
}

@test "provenance: a long commit list (beyond the argv size limit) is evaluated" {
  local i commits="" pad
  pad=$(printf 'x%.0s' $(seq 1 3000))
  for i in $(seq 1 99); do
    commits+="$(tt_commit "$(printf '%040d' "$i")" 'dependabot[bot]' web-flow true 1 | jq -c --arg p "$pad" '.commit.message = $p'),"
  done
  commits="[${commits}$(_dep_commit "$HEAD_SHA")]"
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 100)" "$commits" ""
  [ "$status" -eq 0 ]
}

# ── dependabot_required_contexts ────────────────────────────────────────────

@test "required: collects unique required check names across rulesets and pages" {
  rules='[[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"CodeQL"},{"context":"SonarCloud"}]}},{"type":"pull_request","parameters":{}}],[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"CodeQL","integration_id":1}]}}]]'
  run dependabot_required_contexts "$rules"
  [ "$status" -eq 0 ]
  [ "$output" = '["CodeQL","SonarCloud"]' ]
}

@test "required: no rules yields an empty list" {
  run dependabot_required_contexts '[]'
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "required: a non-array response fails" {
  run dependabot_required_contexts '{"message":"Not Found"}'
  [ "$status" -eq 1 ]
  run dependabot_required_contexts 'garbage'
  [ "$status" -eq 1 ]
}
