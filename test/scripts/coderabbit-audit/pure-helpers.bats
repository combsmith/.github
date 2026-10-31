#!/usr/bin/env bats
# Unit tests for the pure helpers in scripts/coderabbit-audit.sh:
#   normalize_severity, severity_rank, severity_priority_label,
#   valid_fingerprint, valid_finding_id, issue_marker, issue_title,
#   stub_callee_repo, route_owner, api_error_hint.
#
# The script's `main` is guarded, so sourcing only defines functions — the real
# helpers are exercised directly in an isolated subshell.

bats_require_minimum_version 1.5.0

SCRIPT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/scripts/coderabbit-audit.sh"
FP="$(printf 'a%.0s' {1..64})"

call() {
  local func="$1"
  shift
  run bash -c 'source "$1" >/dev/null 2>&1; shift; "$@"' _ "$SCRIPT" "$func" "$@"
}

# ── normalize_severity ─────────────────────────────────────────────────────
@test "known severities pass through lowercased" {
  call normalize_severity "HIGH"; [ "$output" = "high" ]
  call normalize_severity "critical"; [ "$output" = "critical" ]
  call normalize_severity "low"; [ "$output" = "low" ]
}
@test "free text from the export never survives as a severity" {
  call normalize_severity "high; see src/auth.ts"; [ "$output" = "unknown" ]
  call normalize_severity ""; [ "$output" = "unknown" ]
}

# ── severity_rank / severity_priority_label ────────────────────────────────
@test "rank orders critical > high > medium > low" {
  call severity_rank critical; [ "$output" = "4" ]
  call severity_rank high; [ "$output" = "3" ]
  call severity_rank medium; [ "$output" = "2" ]
  call severity_rank low; [ "$output" = "1" ]
}
@test "an unknown severity ranks as medium, so it is filed rather than hidden" {
  call severity_rank unknown; [ "$output" = "2" ]
  call severity_priority_label unknown; [ "$output" = "priority:major" ]
}
@test "priority labels match the scale the CodeQL audit uses" {
  call severity_priority_label critical; [ "$output" = "priority:blocker" ]
  call severity_priority_label high; [ "$output" = "priority:critical" ]
  call severity_priority_label medium; [ "$output" = "priority:major" ]
  call severity_priority_label low; [ "$output" = "priority:minor" ]
}

# ── valid_fingerprint / valid_finding_id ───────────────────────────────────
@test "a 64-char lowercase hex fingerprint is valid" {
  call valid_fingerprint "$FP"; [ "$status" -eq 0 ]
}
@test "other fingerprint shapes are rejected" {
  call valid_fingerprint ""; [ "$status" -ne 0 ]
  call valid_fingerprint "abc123"; [ "$status" -ne 0 ]
  call valid_fingerprint "${FP:0:63}Z"; [ "$status" -ne 0 ]
  call valid_fingerprint "${FP} injected"; [ "$status" -ne 0 ]
}
@test "only a UUID is accepted as a finding id" {
  call valid_finding_id "11111111-2222-3333-4444-555555555555"; [ "$status" -eq 0 ]
  call valid_finding_id "not a uuid"; [ "$status" -ne 0 ]
  call valid_finding_id ""; [ "$status" -ne 0 ]
}

# ── issue_marker / issue_title ─────────────────────────────────────────────
@test "the marker holds the fingerprint in an HTML comment" {
  call issue_marker "$FP"
  [[ "$output" == "<!-- coderabbit-audit:"*"$FP -->" ]]
}
@test "the title holds a short fingerprint and no severity" {
  call issue_title "$FP"
  [ "$output" = "CodeRabbit Deep Scan: finding aaaaaaaaaaaa" ]
}

# ── stub_callee_repo ───────────────────────────────────────────────────────
@test "a stub calling one org reusable workflow yields that repo" {
  text=$'jobs:\n  ci:\n    uses: combsmith/.github/.github/workflows/ci-reusable.yml@v1\n'
  call stub_callee_repo combsmith "$text"; [ "$output" = ".github" ]
}
@test "a quoted ref and a stub in .github-private both resolve" {
  text=$'jobs:\n  ci:\n    uses: "combsmith/.github-private/.github/workflows/x.yml@abc"\n'
  call stub_callee_repo combsmith "$text"; [ "$output" = ".github-private" ]
}
@test "a workflow with steps is not a stub, even when it calls a reusable workflow" {
  text=$'jobs:\n  a:\n    uses: combsmith/.github/.github/workflows/x.yml@v1\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - run: make\n'
  call stub_callee_repo combsmith "$text"; [ -z "$output" ]
}
@test "a commented-out uses line does not make a stub" {
  text=$'jobs:\n  a:\n    # uses: combsmith/.github/.github/workflows/x.yml@v1\n    uses: other/repo/.github/workflows/x.yml@v1\n'
  call stub_callee_repo combsmith "$text"; [ -z "$output" ]
}
@test "a reusable workflow from another org is not routed" {
  text=$'jobs:\n  a:\n    uses: other/repo/.github/workflows/x.yml@v1\n'
  call stub_callee_repo combsmith "$text"; [ -z "$output" ]
}
@test "a stub calling two org repos is ambiguous and yields nothing" {
  text=$'jobs:\n  a:\n    uses: combsmith/.github/.github/workflows/x.yml@v1\n  b:\n    uses: combsmith/.github-private/.github/workflows/y.yml@v1\n'
  call stub_callee_repo combsmith "$text"; [ -z "$output" ]
}

# ── route_owner ────────────────────────────────────────────────────────────
@test "a finding in a stub routes to the callee repo" {
  text=$'jobs:\n  a:\n    uses: combsmith/.github/.github/workflows/x.yml@v1\n'
  call route_owner combsmith TalkTerm .github/workflows/x.yml "$text"
  [ "$output" = ".github" ]
}
@test "a finding outside .github/workflows stays with the scanned repo" {
  text=$'jobs:\n  a:\n    uses: combsmith/.github/.github/workflows/x.yml@v1\n'
  call route_owner combsmith TalkTerm src/app.ts "$text"
  [ "$output" = "TalkTerm" ]
}
@test "a finding in a workflow with its own steps stays with the scanned repo" {
  text=$'jobs:\n  b:\n    steps:\n      - run: make\n'
  call route_owner combsmith TalkTerm .github/workflows/x.yml "$text"
  [ "$output" = "TalkTerm" ]
}

# ── api_error_hint ─────────────────────────────────────────────────────────
@test "documented API errors get an operator hint" {
  call api_error_hint 401; [[ "$output" == *"API key"* ]]
  call api_error_hint 403; [[ "$output" == *"security:read"* ]]
  call api_error_hint 410; [[ "$output" == *"legacy"* ]]
  call api_error_hint 413; [[ "$output" == *"TARGET_REPO"* ]]
  call api_error_hint 500; [ "$output" = "unexpected response" ]
}
