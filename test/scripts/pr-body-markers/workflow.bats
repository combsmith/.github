#!/usr/bin/env bats
# Static guards for the reusable pull request body marker check and this repo's caller
# (issue #1571). The reusable is what other repos pin at a channel, so its contract is checked
# here: it reads the scripts of its own commit, passes an event with no pull request (a merge
# queue's merge_group), and never interpolates the title or body into a run block.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  REUSABLE="$REPO_ROOT/.github/workflows/pr-body-markers-reusable.yml"
  CALLER="$REPO_ROOT/.github/workflows/pr-body-markers.yml"
}

@test "reusable: workflow_call is its only trigger, with no inputs or secrets (#1571)" {
  run yq -r '.on | keys | join(",")' "$REUSABLE"
  [ "$status" -eq 0 ]
  [ "$output" = "workflow_call" ]
  run yq -r '.on.workflow_call | (.inputs // {}) + (.secrets // {}) | length' "$REUSABLE"
  [ "$output" = "0" ]
}

@test "reusable: reads only, with no permission at the workflow level (#1571)" {
  run yq -r '.permissions | length' "$REUSABLE"
  [ "$output" = "0" ]
  run yq -r '.jobs.markers.permissions | to_entries | map(.key + "=" + .value) | sort | join(",")' "$REUSABLE"
  [ "$output" = "contents=read,pull-requests=read" ]
}

@test "reusable: the first step passes an event with no pull request, every other step needs one (#1571)" {
  run yq -r '.jobs.markers.steps[0].if' "$REUSABLE"
  [ "$output" = '${{ !github.event.pull_request }}' ]
  run yq -r '.jobs.markers.steps[1:][] | .if' "$REUSABLE"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  while IFS= read -r cond; do
    [ "$cond" = '${{ github.event.pull_request }}' ] || { echo "step condition drifted: $cond"; return 1; }
  done <<< "$output"
}

@test "reusable: the scripts come from combsmith/.github at its own commit, without credentials (#1571)" {
  run yq -r '.jobs.markers.steps[] | select(.with.path == ".pr-body-markers-tooling") | [.with.repository, .with.ref, .with."persist-credentials"] | join(" ")' "$REUSABLE"
  [ "$status" -eq 0 ]
  [ "$output" = 'combsmith/.github ${{ job.workflow_sha }} false' ]
}

@test "reusable: never relies on github.job_workflow_sha, which is empty at step level (#839)" {
  run grep -nE '\$\{\{[^}]*github\.job_workflow_sha' "$REUSABLE"
  [ "$status" -eq 1 ]
}

@test "reusable: every tooling path it runs exists in this commit (#1571)" {
  run grep -oE '\.pr-body-markers-tooling/[A-Za-z0-9._/-]+\.sh' "$REUSABLE"
  [ "$status" -eq 0 ]
  while IFS= read -r p; do
    [ -f "$REPO_ROOT/${p#.pr-body-markers-tooling/}" ] || { echo "missing: $p"; return 1; }
  done <<< "$(echo "$output" | sort -u)"
}

@test "reusable: the title and body reach a run block only through the environment (#1571)" {
  run yq -r '.jobs.markers.steps[] | select(.run != null) | .run' "$REUSABLE"
  [ "$status" -eq 0 ]
  ! grep -qE 'github\.event\.pull_request\.(title|body)' <<< "$output"
}

@test "caller: runs on edited pull requests and on merge_group (#1571)" {
  run yq -r '.on.pull_request.types | join(",")' "$CALLER"
  [ "$output" = "opened,edited,synchronize,reopened" ]
  run yq -r '.on | has("merge_group")' "$CALLER"
  [ "$output" = "true" ]
}

@test "caller: calls the local reusable and grants what the reusable's job needs (#1571)" {
  run yq -r '.jobs."pr-body-markers".uses' "$CALLER"
  [ "$output" = "./.github/workflows/pr-body-markers-reusable.yml" ]
  run yq -r '.jobs."pr-body-markers".permissions | to_entries | map(.key + "=" + .value) | sort | join(",")' "$CALLER"
  [ "$output" = "contents=read,pull-requests=read" ]
}

@test "caller: the concurrency group falls back to the ref, since merge_group has no number (#1571)" {
  run yq -r '.concurrency.group' "$CALLER"
  [ "$output" = 'pr-body-markers-${{ github.event.pull_request.number || github.ref }}' ]
}

@test "reusable: a marker rejection fails its own step, so the canary gate can class it (#1573)" {
  local step="Reject the pull request content that carries a marker"
  run yq -r ".jobs.markers.steps[] | select(.name == \"$step\") | .run" "$REUSABLE"
  [ "$status" -eq 0 ]
  grep -q 'exit 1' <<< "$output"
  # the registry's benign class names exactly that step, and only that one
  run jq -r '.agents."pr-body-markers".gate.benign_failure_classes | map(.step) | join("|")' "$REPO_ROOT/standards/canary-rings.json"
  [ "$output" = "$step" ]
}
