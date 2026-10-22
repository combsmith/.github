#!/usr/bin/env bats
# Regression guard for issue #839: the tooling checkout must track the
# reusable's own commit, never a floating tag.
#
# The reusable checks out combsmith/.github into .feature-ideation-tooling and
# runs scripts from it. When `tooling_ref` defaulted to `v1`, the channel tags
# (feature-ideation/v1-*) advanced the reusable to a version whose pip step
# needs scripts/feature-ideation-requirements.txt, while the tooling checkout
# stayed on the older `v1` tag that lacks it — every fleet run failed. The
# reusable and its tooling must come from the same commit (`job.workflow_sha`).
#
# Not `github.job_workflow_sha`: it evaluates empty at step level, so
# actions/checkout silently falls back to the default branch (`main`) —
# observed in a live run, and in the job-context probe for #839.

load 'helpers/setup'

REUSABLE="${TT_REPO_ROOT}/.github/workflows/feature-ideation-reusable.yml"
STUB="${TT_REPO_ROOT}/standards/workflows/feature-ideation.yml"
SELF_CALLER="${TT_REPO_ROOT}/.github/workflows/feature-ideation.yml"

EXPECTED_REF='${{ inputs.tooling_ref || job.workflow_sha }}'

@test "reusable: tooling_ref defaults to empty (no floating tag)" {
  run yq -r '.on.workflow_call.inputs.tooling_ref.default' "$REUSABLE"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "reusable: every tooling checkout falls back to the reusable's own commit" {
  for job in gather-signals analyze; do
    run yq -r ".jobs.\"${job}\".steps[] | select(.with.path == \".feature-ideation-tooling\") | .with.ref" "$REUSABLE"
    [ "$status" -eq 0 ]
    [ -n "$output" ] || { echo "$job: no tooling checkout step"; return 1; }
    while IFS= read -r ref; do
      [ -n "$ref" ] || { echo "$job: tooling checkout ref is empty"; return 1; }
      [ "$ref" = "$EXPECTED_REF" ] || { echo "$job: tooling checkout ref drifted to $ref (expected $EXPECTED_REF)"; return 1; }
    done <<< "$output"
  done
}

@test "reusable: never relies on github.job_workflow_sha (empty at step level)" {
  run grep -nE '\$\{\{[^}]*github\.job_workflow_sha' "$REUSABLE"
  [ "$status" -eq 1 ]
}

@test "reusable: every tooling checkout targets combsmith/.github" {
  run yq -r '.jobs[].steps[] | select(.with.path == ".feature-ideation-tooling") | .with.repository' "$REUSABLE"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  ! echo "$output" | grep -vxF 'combsmith/.github'
}

@test "reusable: every .feature-ideation-tooling path it reads exists in this commit" {
  # The tooling checkout is this same commit, so each referenced file must be
  # here — a step that reads a file the commit lacks is the #839 failure mode.
  run grep -oE '\.feature-ideation-tooling/[A-Za-z0-9._/-]+\.(sh|py|txt|json)' "$REUSABLE"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  while IFS= read -r p; do
    [ -f "${TT_REPO_ROOT}/${p#.feature-ideation-tooling/}" ] || { echo "missing: $p"; return 1; }
  done <<< "$(echo "$output" | sort -u)"
}

@test "callers: no caller pins tooling_ref to a ref (that would reintroduce skew)" {
  for f in "$STUB" "$SELF_CALLER"; do
    run yq -r '[.jobs[] | select(.with != null) | .with | has("tooling_ref")] | any' "$f"
    [ "$status" -eq 0 ]
    [ "$output" = "false" ] || { echo "$f forwards tooling_ref"; return 1; }
  done
}
