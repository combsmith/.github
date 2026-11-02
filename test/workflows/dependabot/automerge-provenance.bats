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
  tt_fixture "repos/owner/repo/pulls/5/reviews?per_page=100" '[]'
}

_dep_commit() { tt_commit "$HEAD_SHA" 'dependabot[bot]' web-flow true 1; }

# _push_during_approval HEAD COMMITS_JSON — the head moves to HEAD once the
# approval POST lands, so the run's post-write read sees the new revision.
_push_during_approval() {
  printf '%s\n' "$(tt_pr_rest "$1" "$(jq 'length' <<<"$2")")" > "${FIX_DIR}/moved_pr.json"
  printf '%s\n' "$2" > "${FIX_DIR}/moved_commits.json"
  cat > "${FIX_DIR}/on_write" <<'HOOK'
#!/usr/bin/env bash
cp "${FIX_DIR}/moved_pr.json" "${FIX_DIR}/repos_owner_repo_pulls_5.json"
cp "${FIX_DIR}/moved_commits.json" "${FIX_DIR}/repos_owner_repo_pulls_5_commits_per_page_100.json"
HOOK
  chmod +x "${FIX_DIR}/on_write"
}

_app_approval_of() { # ID COMMIT_ID
  printf '{"id":%s,"state":"APPROVED","commit_id":"%s","user":{"login":"%s"}}' "$1" "$2" "$APP_LOGIN_FIXTURE"
}

_foreign_commits() {
  printf '[%s,%s]' \
    "$(tt_commit "$DEP_SHA" 'dependabot[bot]' web-flow true 1)" \
    "$(tt_commit "$HEAD_SHA" mallory mallory true 1)"
}

@test "tt_extract_run rejects a missing step and a step with no run block" {
  run tt_extract_run "$REUSABLE" dependabot "No such step"
  [ "$status" -ne 0 ]
  run tt_extract_run "$REUSABLE" dependabot "Generate app token"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no run block"* ]]
}

@test "automerge: the approval step sources the gate libraries" {
  [ -s "$RUN_SCRIPT" ]
  grep -F '.dependabot-tooling/.github/scripts/dependabot/lib/gates.sh' "$RUN_SCRIPT"
  grep -F '.dependabot-tooling/.github/scripts/dependabot/lib/gh-io.sh' "$RUN_SCRIPT"
}

@test "automerge: tooling checkout runs at the reusable's own commit, eligible or not" {
  run yq -r '.jobs.dependabot.steps[] | select(.name == "Checkout Dependabot gate tooling") | .with.ref' "$REUSABLE"
  [ "$output" = '${{ job.workflow_sha }}' ]
  # An ineligible update still needs the libraries and the App token to withdraw
  # earlier automation.
  for step in "Checkout Dependabot gate tooling" "Generate app token" "Check app secrets"; do
    run yq -r ".jobs.dependabot.steps[] | select(.name == \"$step\") | .if" "$REUSABLE"
    [ "$output" = "null" ]
  done
}

@test "automerge: approval runs only when eligible, withdrawal only when not" {
  run yq -r '.jobs.dependabot.steps[] | select(.name == "Approve and enable auto-merge") | .if' "$REUSABLE"
  [ "$output" = "steps.eligible.outputs.eligible == 'true'" ]
  run yq -r '.jobs.dependabot.steps[] | select(.name == "Withdraw automation from an ineligible update") | .if' "$REUSABLE"
  [ "$output" = "steps.eligible.outputs.eligible == 'false'" ]
}

# _run_withdraw_step — the real withdrawal step for an ineligible update.
_run_withdraw_step() {
  local script="${TT_TMP}/withdraw.sh"
  tt_extract_run "$REUSABLE" dependabot "Withdraw automation from an ineligible update" > "$script"
  cd "$TT_WORK" || return 1
  REPO="owner/repo" PR_NUMBER=5 APP_SLUG="$APP_SLUG_FIXTURE" READ_TOKEN="read-token" GH_TOKEN="app-token" \
    run bash -eo pipefail "$script"
}

_pr_with_auto_merge_by() { # LOGIN
  jq -cn --arg head "$HEAD_SHA" --arg by "$1" \
    '{number:5,head:{sha:$head},base:{ref:"main"},commits:1,
      auto_merge:{merge_method:"squash",enabled_by:{login:$by}}}'
}

@test "automerge: an update that became ineligible loses the App's approval and auto-merge" {
  _seed "[$(_dep_commit)]"
  tt_fixture "repos/owner/repo/pulls/5/reviews?per_page=100" "[$(_app_approval_of 11 "$DEP_SHA")]"
  # The withdrawal turns auto-merge off, so the read-back sees it off.
  tt_fixture "repos/owner/repo/pulls/5" "$(_pr_with_auto_merge_by "$APP_LOGIN_FIXTURE")"
  printf '%s\n' "$(tt_pr_rest "$HEAD_SHA" 1)" > "${FIX_DIR}/after_disable.json"
  _run_withdraw_step
  [ "$status" -eq 0 ]
  run _writes
  [[ "$output" == *"pr merge 5 --repo owner/repo --disable-auto"* ]]
  [[ "$output" == *"PUT repos/owner/repo/pulls/5/reviews/11/dismissals"* ]]
}

@test "automerge: auto-merge a human enabled on an ineligible update is left alone" {
  _seed "[$(_dep_commit)]"
  tt_fixture "repos/owner/repo/pulls/5/reviews?per_page=100" \
    "[$(_app_approval_of 11 "$DEP_SHA"),{\"id\":12,\"state\":\"APPROVED\",\"commit_id\":\"${HEAD_SHA}\",\"user\":{\"login\":\"alice\"}}]"
  tt_fixture "repos/owner/repo/pulls/5" "$(_pr_with_auto_merge_by alice)"
  _run_withdraw_step
  [ "$status" -eq 0 ]
  run _writes
  [[ "$output" != *"--disable-auto"* ]]
  [[ "$output" == *"reviews/11/dismissals"* ]]
  [[ "$output" != *"reviews/12/dismissals"* ]]
}

@test "automerge: an ineligible update with no automation on it writes nothing" {
  _seed "[$(_dep_commit)]"
  _run_withdraw_step
  [ "$status" -eq 0 ]
  [ -z "$(_writes)" ]
}

@test "automerge: an ineligible update whose state cannot be read fails the step" {
  _seed "[$(_dep_commit)]"
  tt_fixture "repos/owner/repo/pulls/5" '{"message":"Server Error"}' 1
  _run_withdraw_step
  [ "$status" -ne 0 ]
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

@test "automerge: --disable-auto failing on a PR with no auto-merge is not an error" {
  _seed "$(_foreign_commits)"
  printf '1\n' > "${FIX_DIR}/pr_merge.rc"
  _run_approve_step
  [ "$status" -eq 0 ]
  [[ "$(_writes)" != *"event=APPROVE"* ]]
}

@test "automerge: revocation that leaves auto-merge enabled fails the step" {
  _seed "$(_foreign_commits)"
  tt_fixture "repos/owner/repo/pulls/5" "$(tt_pr_rest "$HEAD_SHA" 2 true)"
  printf '1\n' > "${FIX_DIR}/pr_merge.rc"
  _run_approve_step
  [ "$status" -ne 0 ]
  [[ "$output" == *"auto-merge is still enabled"* ]]
}

@test "automerge: revocation that cannot list or dismiss approvals fails the step" {
  _seed "$(_foreign_commits)"
  tt_fixture "repos/owner/repo/pulls/5/reviews?per_page=100" '{"message":"Server Error"}' 1
  _run_approve_step
  [ "$status" -ne 0 ]

  _seed "$(_foreign_commits)"
  tt_fixture "repos/owner/repo/pulls/5/reviews?per_page=100" "[$(_app_approval_of 11 "$DEP_SHA")]"
  tt_fixture "repos/owner/repo/pulls/5/reviews/11/dismissals" '{}' 1
  _run_approve_step
  [ "$status" -ne 0 ]
}

@test "automerge: a foreign push landing during approval revokes the approval and auto-merge" {
  _seed "[$(_dep_commit)]"
  tt_fixture "repos/owner/repo/pulls/5/reviews?per_page=100" "[$(_app_approval_of 11 "$HEAD_SHA")]"
  _push_during_approval "$OTHER_SHA" "[$(_dep_commit),$(tt_commit "$OTHER_SHA" mallory mallory true 1)]"
  _run_approve_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"not from Dependabot"* ]]
  run _writes
  [[ "$output" == *"event=APPROVE"*"commit_id=${HEAD_SHA}"* ]]
  [[ "$output" == *"pr merge 5 --repo owner/repo --disable-auto"* ]]
  [[ "$output" == *"PUT repos/owner/repo/pulls/5/reviews/11/dismissals"* ]]
}

@test "automerge: a verified Dependabot push during approval keeps auto-merge and drops only the stale approval" {
  _seed "[$(_dep_commit)]"
  tt_fixture "repos/owner/repo/pulls/5/reviews?per_page=100" \
    "[$(_app_approval_of 11 "$HEAD_SHA"),$(_app_approval_of 12 "$OTHER_SHA")]"
  _push_during_approval "$OTHER_SHA" "[$(tt_commit "$OTHER_SHA" 'dependabot[bot]' web-flow true 1)]"
  printf '1\n' > "${FIX_DIR}/pr_merge.rc" # --match-head-commit refuses the stale head
  _run_approve_step
  [ "$status" -eq 0 ]
  run _writes
  [[ "$output" != *"--disable-auto"* ]]
  [[ "$output" == *"PUT repos/owner/repo/pulls/5/reviews/11/dismissals"* ]]
  [[ "$output" != *"reviews/12/dismissals"* ]]
}

@test "automerge: an unreadable post-write state revokes and fails the step" {
  _seed "[$(_dep_commit)]"
  tt_fixture "repos/owner/repo/pulls/5/reviews?per_page=100" "[$(_app_approval_of 11 "$HEAD_SHA")]"
  cat > "${FIX_DIR}/on_write" <<'HOOK'
#!/usr/bin/env bash
printf '1
' > "${FIX_DIR}/repos_owner_repo_pulls_5_commits_per_page_100.rc"
HOOK
  chmod +x "${FIX_DIR}/on_write"
  _run_approve_step
  [ "$status" -ne 0 ]
  run _writes
  [[ "$output" == *"--disable-auto"* ]]
  [[ "$output" == *"PUT repos/owner/repo/pulls/5/reviews/11/dismissals"* ]]
}

@test "automerge: auto-merge refused at an unchanged head fails the step and keeps the approval" {
  _seed "[$(_dep_commit)]"
  printf '1\n' > "${FIX_DIR}/pr_merge.rc"
  _run_approve_step
  [ "$status" -ne 0 ]
  [[ "$(_writes)" != *"dismissals"* ]]
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
