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
  [[ "$output" == *"all 2 check(s) succeeded"*"(1 agent job(s) not counted)"* ]]
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

@test "checks: a required check is satisfied by a GitHub Actions check run" {
  run dependabot_checks_gate "$(tt_pr_state "$(_ok_nodes)")" '["CodeQL"]'
  [ "$status" -eq 0 ]
}

# A required check counts only as a CheckRun from GitHub Actions: a commit status
# or another app's check with the same name must not satisfy it (#1399 review).
@test "checks: a same-name commit status does not satisfy a required check" {
  nodes="[$(tt_check_run Lint COMPLETED SUCCESS),$(tt_status CodeQL SUCCESS)]"
  run dependabot_checks_gate "$(tt_pr_state "$nodes")" '["CodeQL"]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"required check(s) not reported by GitHub Actions"*"CodeQL"* ]]
}

@test "checks: a same-name check from another app does not satisfy a required check" {
  nodes="[$(tt_check_run Lint COMPLETED SUCCESS),$(tt_check_run CodeQL COMPLETED SUCCESS some-other-app)]"
  run dependabot_checks_gate "$(tt_pr_state "$nodes")" '["CodeQL"]'
  [ "$status" -eq 1 ]
}

@test "checks: a required check run whose app cannot be read does not satisfy it" {
  node=$(jq -cn '{__typename:"CheckRun",name:"CodeQL",status:"COMPLETED",conclusion:"SUCCESS"}')
  nodes="[$(tt_check_run Lint COMPLETED SUCCESS),$node]"
  run dependabot_checks_gate "$(tt_pr_state "$nodes")" '["CodeQL"]'
  [ "$status" -eq 1 ]
}

@test "checks: the Actions run satisfies a required check beside a same-name run from another app" {
  nodes="[$(tt_check_run CodeQL COMPLETED SUCCESS),$(tt_check_run CodeQL COMPLETED SUCCESS github-advanced-security)]"
  run dependabot_checks_gate "$(tt_pr_state "$nodes")" '["CodeQL"]'
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

# ── agent jobs: not counted, and only on an exact match from GitHub Actions ──

@test "checks: a cancelled or failed agent job does not block" {
  local job
  for job in 'dev-lead / dispatch' 'dev-lead / ci-relay' 'pr-auto-review / check-and-dispatch' \
             'pr-review / review' 'review / review'; do
    nodes="[$(tt_check_run CodeQL COMPLETED SUCCESS),$(tt_check_run "$job" COMPLETED CANCELLED),$(tt_check_run 'dev-lead / resume' COMPLETED FAILURE)]"
    run dependabot_checks_gate "$(tt_pr_state "$nodes")" '[]'
    [ "$status" -eq 0 ]
    [[ "$output" == *"all 1 check(s) succeeded"*"(2 agent job(s) not counted)"* ]]
  done
}

@test "checks: a pending agent job does not block" {
  nodes="[$(tt_check_run CodeQL COMPLETED SUCCESS),$(tt_check_run 'dev-lead / dispatch' IN_PROGRESS '')]"
  run dependabot_checks_gate "$(tt_pr_state "$nodes")" '[]'
  [ "$status" -eq 0 ]
}

@test "checks: a similarly named check from GitHub Actions still blocks" {
  local job
  for job in 'dev-lead' 'dev-lead / ' 'dev-leads / dispatch' 'my dev-lead / dispatch' 'dev-lead/dispatch' \
             'pr-auto-review' 'pr-review / lint' 'review / lint' 'review' 'Dev-Lead / dispatch'; do
    nodes="[$(tt_check_run CodeQL COMPLETED SUCCESS),$(tt_check_run "$job" COMPLETED FAILURE)]"
    run dependabot_checks_gate "$(tt_pr_state "$nodes")" '[]'
    [ "$status" -eq 1 ]
  done
}

@test "checks: an agent job name from another app still blocks" {
  nodes="[$(tt_check_run CodeQL COMPLETED SUCCESS),$(tt_check_run 'dev-lead / dispatch' COMPLETED FAILURE some-other-app)]"
  run dependabot_checks_gate "$(tt_pr_state "$nodes")" '[]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"dev-lead / dispatch (failure)"* ]]
}

@test "checks: an agent job with no app data still blocks" {
  node=$(jq -cn '{__typename:"CheckRun",name:"dev-lead / dispatch",status:"COMPLETED",conclusion:"FAILURE"}')
  nodes="[$(tt_check_run CodeQL COMPLETED SUCCESS),$node]"
  run dependabot_checks_gate "$(tt_pr_state "$nodes")" '[]'
  [ "$status" -eq 1 ]
}

@test "checks: a commit status named like an agent job still blocks" {
  nodes="[$(tt_check_run CodeQL COMPLETED SUCCESS),$(tt_status 'dev-lead / dispatch' FAILURE)]"
  run dependabot_checks_gate "$(tt_pr_state "$nodes")" '[]'
  [ "$status" -eq 1 ]
}

@test "checks: an agent job the rules require is counted" {
  nodes="[$(tt_check_run CodeQL COMPLETED SUCCESS),$(tt_check_run 'dev-lead / dispatch' COMPLETED FAILURE)]"
  run dependabot_checks_gate "$(tt_pr_state "$nodes")" '["dev-lead / dispatch"]'
  [ "$status" -eq 1 ]
}

@test "checks: agent jobs alone do not count as checks reported" {
  nodes="[$(tt_check_run 'dev-lead / dispatch' COMPLETED SUCCESS),$(tt_check_run 'pr-auto-review / check-and-dispatch' COMPLETED SKIPPED)]"
  run dependabot_checks_gate "$(tt_pr_state "$nodes")" '[]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"no checks reported"* ]]
}

@test "checks: a failing non-agent check still blocks beside an exempt agent job" {
  nodes="[$(tt_check_run 'Secret scan (gitleaks)' COMPLETED FAILURE),$(tt_check_run CodeQL COMPLETED SUCCESS),$(tt_check_run 'dev-lead / dispatch' COMPLETED CANCELLED)]"
  run dependabot_checks_gate "$(tt_pr_state "$nodes")" '[]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 check(s) not successful"*"gitleaks"* ]]
}

# ── superseded check runs (#1399 review) ─────────────────────────────────────

@test "checks: a cancelled run superseded by a later successful run of the same check passes" {
  nodes="[$(tt_run 101 guard COMPLETED CANCELLED),$(tt_run 102 guard COMPLETED SUCCESS),$(tt_run 103 CodeQL COMPLETED SUCCESS)]"
  run dependabot_checks_gate "$(tt_pr_state "$nodes")" '[]'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "checks: a later failing run of the same check still blocks" {
  nodes="[$(tt_run 101 guard COMPLETED SUCCESS),$(tt_run 102 guard COMPLETED FAILURE)]"
  run dependabot_checks_gate "$(tt_pr_state "$nodes")" '[]'
  [ "$status" -eq 1 ]
}

@test "checks: a later pending run of the same check still blocks" {
  nodes="[$(tt_run 101 guard COMPLETED SUCCESS),$(tt_run 102 guard IN_PROGRESS '')]"
  run dependabot_checks_gate "$(tt_pr_state "$nodes")" '[]'
  [ "$status" -eq 1 ]
}

@test "checks: the newest run wins by databaseId, not by order in the response" {
  nodes="[$(tt_run 102 guard COMPLETED SUCCESS),$(tt_run 101 guard COMPLETED CANCELLED)]"
  run dependabot_checks_gate "$(tt_pr_state "$nodes")" '[]'
  [ "$status" -eq 0 ]
  nodes="[$(tt_run 102 guard COMPLETED FAILURE),$(tt_run 101 guard COMPLETED SUCCESS)]"
  run dependabot_checks_gate "$(tt_pr_state "$nodes")" '[]'
  [ "$status" -eq 1 ]
}

@test "checks: the same job name in two workflows is two checks" {
  nodes="[$(tt_run 101 'Lint and bats' COMPLETED FAILURE 1),$(tt_run 102 'Lint and bats' COMPLETED SUCCESS 2)]"
  run dependabot_checks_gate "$(tt_pr_state "$nodes")" '[]'
  [ "$status" -eq 1 ]
}

@test "checks: runs without a databaseId are never collapsed" {
  nodes="[$(tt_check_run guard COMPLETED CANCELLED),$(tt_check_run guard COMPLETED SUCCESS)]"
  run dependabot_checks_gate "$(tt_pr_state "$nodes")" '[]'
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

@test "provenance: an incomplete commit list (fewer than the PR's count) is unreadable, not a verdict" {
  commits="[$(_dep_commit "$HEAD_SHA")]"
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 251)" "$commits" ""
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot verify them all"* ]]
}

@test "provenance: head not in the commit list is unreadable, not a verdict" {
  commits="[$(_dep_commit "$DEP_SHA")]"
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 1)" "$commits" ""
  [ "$status" -eq 2 ]
}

@test "provenance: head differing from the expected SHA blocks" {
  commits="[$(_dep_commit "$HEAD_SHA")]"
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 1)" "$commits" "" "$OTHER_SHA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"head moved"* ]]
}

@test "provenance: empty or malformed input is unreadable, not a verdict" {
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 0)" '[]' ""
  [ "$status" -eq 2 ]
  run dependabot_provenance_gate 'nope' '[]' ""
  [ "$status" -eq 2 ]
  run dependabot_provenance_gate "$(tt_pr_rest)" 'nope' ""
  [ "$status" -eq 2 ]
}

@test "provenance: a foreign commit is still a verdict (1)" {
  commits="[$(_dep_commit "$DEP_SHA"),$(tt_commit "$HEAD_SHA" mallory mallory true 1)]"
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 2)" "$commits" ""
  [ "$status" -eq 1 ]
}

# Sandbox evidence (combsmith/software-factory-canary, 2026-11-03): commits made
# through the Contents or Git Data API with Dependabot's noreply email are
# attributed to dependabot[bot] by GitHub, but are unsigned. Only the
# verified-signature requirement refuses them.
@test "provenance: forged Dependabot author via the Contents API (committer is the pusher, unsigned) blocks" {
  commits="[$(tt_commit "$HEAD_SHA" 'dependabot[bot]' don-petry false 1)]"
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 1)" "$commits" ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"not from Dependabot"*"unverified"* ]]
}

@test "provenance: forged Dependabot author and committer via the Git Data API (unsigned) blocks" {
  commits="[$(tt_commit "$HEAD_SHA" 'dependabot[bot]' 'dependabot[bot]' false 1)]"
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 1)" "$commits" ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"not from Dependabot"*"unverified"* ]]
}

@test "provenance: a forged unsigned commit on top of a genuine one blocks" {
  commits="[$(tt_commit "$DEP_SHA" 'dependabot[bot]' web-flow true 1),$(tt_commit "$HEAD_SHA" 'dependabot[bot]' 'dependabot[bot]' false 1)]"
  run dependabot_provenance_gate "$(tt_pr_rest "$HEAD_SHA" 2)" "$commits" ""
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
