#!/usr/bin/env bats
# Unit tests for scripts/lib/scorecard-triage.sh — the pure decision helpers
# behind .github/workflows/org-scorecard.yml. No network; jq only.

setup() {
  # shellcheck source=../../../scripts/lib/scorecard-triage.sh
  source "${BATS_TEST_DIRNAME}/../../../scripts/lib/scorecard-triage.sh"
}

# --- scorecard_pinned_actions_only -------------------------------------------

@test "pinned: suppresses when every 'not pinned' detail is a GitHubAction" {
  row='{"name":"Pinned-Dependencies","score":2,"details":[
    "Warn: third-party GitHubAction not pinned by hash: .github/workflows/a.yml:50: update your workflow",
    "Warn: third-party GitHubAction not pinned by hash: .github/workflows/b.yml:38: update your workflow",
    "Info:   7 out of   7 GitHub-owned GitHubAction dependencies pinned",
    "Info:   2 out of  13 third-party GitHubAction dependencies pinned"]}'
  run scorecard_pinned_actions_only "$row"
  [ "$status" -eq 0 ]
}

@test "pinned: keeps the issue when a non-Actions gap is present (containerImage)" {
  row='{"name":"Pinned-Dependencies","score":2,"details":[
    "Warn: third-party GitHubAction not pinned by hash: .github/workflows/a.yml:50",
    "Warn: containerImage not pinned by hash: Dockerfile:1: pin your Docker image by updating ubuntu:22.04 to ubuntu:22.04@sha256:..."]}'
  run scorecard_pinned_actions_only "$row"
  [ "$status" -eq 1 ]
}

@test "pinned: keeps the issue when a non-Actions gap is present (pipCommand)" {
  row='{"name":"Pinned-Dependencies","score":5,"details":[
    "Warn: pipCommand not pinned by hash: .github/workflows/ci.yml:42"]}'
  run scorecard_pinned_actions_only "$row"
  [ "$status" -eq 1 ]
}

@test "pinned: keeps the issue when details is null (scorecard run without --show-details)" {
  # Regression: this is exactly what `scorecard --format=json` emits without
  # `--show-details`. The exemption must NOT fire, and the workflow must pass
  # the flag — otherwise the #709 exemption is dead code.
  row='{"name":"Pinned-Dependencies","score":2,"details":null}'
  run scorecard_pinned_actions_only "$row"
  [ "$status" -eq 1 ]
}

@test "pinned: keeps the issue when the details key is absent" {
  row='{"name":"Pinned-Dependencies","score":2}'
  run scorecard_pinned_actions_only "$row"
  [ "$status" -eq 1 ]
}

@test "pinned: keeps the issue when no detail matches the expected wording" {
  row='{"name":"Pinned-Dependencies","score":2,"details":[
    "Warn: something we have never seen before: .github/workflows/a.yml:50"]}'
  run scorecard_pinned_actions_only "$row"
  [ "$status" -eq 1 ]
}

@test "pinned: keeps the issue on malformed JSON" {
  run scorecard_pinned_actions_only 'not json'
  [ "$status" -eq 1 ]
}

# --- issue titles -------------------------------------------------------------

@test "title: prefix is the score-free identity used for the startswith search" {
  run scorecard_issue_prefix "Branch-Protection"
  [ "$output" = "Scorecard: Branch-Protection" ]
}

@test "title: full title appends the score as (N/10)" {
  run scorecard_issue_title "Branch-Protection" 8
  [ "$output" = "Scorecard: Branch-Protection (8/10)" ]
}

@test "title: full title starts with the prefix (search invariant)" {
  prefix="$(scorecard_issue_prefix "Security-Policy")"
  title="$(scorecard_issue_title "Security-Policy" 9)"
  [ "${title#"$prefix"}" != "$title" ]
}

@test "title: current when the title already carries this week's score" {
  run scorecard_title_is_current "Scorecard: Security-Policy (9/10)" "Security-Policy" 9
  [ "$status" -eq 0 ]
}

@test "title: stale when the score has moved since the issue was created" {
  run scorecard_title_is_current "Scorecard: Security-Policy (0/10)" "Security-Policy" 9
  [ "$status" -eq 1 ]
}

@test "title: stale when the title has no score suffix at all" {
  run scorecard_title_is_current "Scorecard: Security-Policy" "Security-Policy" 9
  [ "$status" -eq 1 ]
}
