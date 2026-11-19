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
  step_if() {
    yq -r ".jobs.check-and-dispatch.steps[] | select(.name == \"$1\") | .if // \"UNGUARDED\"" "$WF"
  }
  [ "$(step_if 'Checkout ready-check tooling')" = "steps.pr.outputs.skip != 'true'" ]
  [ "$(step_if 'Check PR readiness criteria')" = "steps.pr.outputs.skip != 'true'" ]
  [ "$(step_if 'Dispatch review agent')" = "steps.criteria.outputs.ready == 'true'" ]
  [ "$(step_if 'decision: dispatched')" = "steps.criteria.outputs.decision == 'dispatched'" ]
  [ "$(step_if 'decision: skip-draft')" = "steps.pr.outputs.decision == 'skip-draft' || steps.criteria.outputs.decision == 'skip-draft'" ]
  [ "$(step_if 'decision: skip-checks-pending')" = "steps.criteria.outputs.decision == 'skip-checks-pending'" ]
  [ "$(step_if 'decision: skip-changes-requested')" = "steps.criteria.outputs.decision == 'skip-changes-requested'" ]
  [ "$(step_if 'decision: skip-unresolved-threads')" = "steps.criteria.outputs.decision == 'skip-unresolved-threads'" ]

  # Verify all steps after "Resolve PR URL" are guarded — no unconditional or always()
  local all_later_guards
  all_later_guards=$(yq -r '.jobs.check-and-dispatch.steps[1:] | .[] | .if // "UNGUARDED"' "$WF")
  while IFS= read -r if_cond; do
    [ "$if_cond" != "UNGUARDED" ] || fail "Found an unguarded step (no if condition)"
    if is_bare_always "$if_cond"; then fail "Found a step guarded only by always(); skips contract violated"; fi
    if is_output_independent "$if_cond"; then fail "Found a step whose if: can run without a skip/decision output: $if_cond"; fi
  done <<< "$all_later_guards"
}

# True when an `if:` value is just always(), bare or wrapped in ${{ }}, ignoring whitespace.
is_bare_always() {
  local norm="${1//[[:space:]]/}"
  norm="${norm#\$\{\{}"
  norm="${norm%\}\}}"
  [ "$norm" = "always()" ]
}

# True when an `if:` value can be true without depending on the skip/decision
# outputs: it never references steps.pr/criteria outputs, or it contains always().
is_output_independent() {
  local norm="${1//[[:space:]]/}"
  [[ "$norm" == *"always()"* ]] && return 0
  [[ "$norm" == *"steps.pr.outputs."* || "$norm" == *"steps.criteria.outputs."* ]] || return 0
  return 1
}

@test "is_output_independent rejects compound and output-free conditions" {
  is_output_independent '${{ always() || true }}'
  is_output_independent 'always() || true'
  is_output_independent "steps.pr.outputs.skip != 'true' || always()"
  is_output_independent 'true'
  is_output_independent "github.event_name == 'pull_request'"
  if is_output_independent "steps.pr.outputs.skip != 'true'"; then false; fi
  if is_output_independent "steps.criteria.outputs.ready == 'true'"; then false; fi
}

@test "is_bare_always rejects bare and expression-wrapped always()" {
  is_bare_always 'always()'
  is_bare_always '${{ always() }}'
  is_bare_always '${{always()}}'
  is_bare_always '  ${{  always()  }}  '
  if is_bare_always "steps.pr.outputs.skip != 'true'"; then false; fi
  if is_bare_always 'UNGUARDED'; then false; fi
}
