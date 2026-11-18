#!/usr/bin/env bats
# The reusable's "Resolve PR URL" step must skip, not fail, when GH_PAT_WORKFLOWS
# is empty (issue #1528). Dependabot-actor and fork pull_request runs get no
# Actions secrets; before the fix the tooling checkout then failed with
# "Input required and not supplied: token".

load 'helpers/setup'

WF="${TT_REPO_ROOT}/.github/workflows/pr-auto-review-reusable.yml"

# Run the step's script the way the runner would, with ${{ }} expressions
# replaced by the given event name. Sets $out to the GITHUB_OUTPUT contents.
run_resolve_step() {
  local token="$1" event="$2" script ghout
  script="$(yq -r '.jobs.check-and-dispatch.steps[] | select(.name == "Resolve PR URL") | .run' "$WF")"
  [ -n "$script" ]
  script="${script//'${{ github.event_name }}'/$event}"
  script="${script//'${{ github.event.pull_request.draft }}'/false}"
  script="${script//'${{ github.event.pull_request.html_url }}'/https://github.com/o/r/pull/1}"
  script="$(sed -E 's/\$\{\{[^}]*\}\}//g' <<< "$script")"
  ghout="$(mktemp "$BATS_TEST_TMPDIR/out.XXXXXX")"
  # gh must never be reached on the empty-secret path.
  run env -i PATH="$BATS_TEST_TMPDIR/nogh:/usr/bin:/bin" GH_TOKEN="$token" GITHUB_OUTPUT="$ghout" "$BASH" -c "$script"
  out="$(cat "$ghout")"
}

setup() {
  mkdir -p "$BATS_TEST_TMPDIR/nogh"
  printf '#!/bin/sh\necho "gh called" >&2\nexit 99\n' > "$BATS_TEST_TMPDIR/nogh/gh"
  chmod +x "$BATS_TEST_TMPDIR/nogh/gh"
}

@test "no secret: a pull_request run skips green before any API call" {
  run_resolve_step "" pull_request
  [ "$status" -eq 0 ]
  [[ "$out" == *"skip=true"* ]]
  [[ "$output" != *"gh called"* ]]
}

@test "no secret: a pull_request_review run skips green" {
  run_resolve_step "" pull_request_review
  [ "$status" -eq 0 ]
  [[ "$out" == *"skip=true"* ]]
}

@test "no secret: the notice names the missing secret" {
  run_resolve_step "" pull_request
  [[ "$output" == *"GH_PAT_WORKFLOWS is not available"* ]]
}

@test "with a secret: a pull_request_review run resolves the PR and does not skip" {
  run_resolve_step "token-present" pull_request_review
  [ "$status" -eq 0 ]
  [[ "$out" == *"skip=false"* ]]
  [[ "$out" == *"pr_url=https://github.com/o/r/pull/1"* ]]
}

@test "every later step is guarded by the skip output or runs only on a decision" {
  run yq -r '.jobs.check-and-dispatch.steps[1:][] | .if // "UNGUARDED"' "$WF"
  [ "$status" -eq 0 ]
  [[ "$output" != *"UNGUARDED"* ]]
}
