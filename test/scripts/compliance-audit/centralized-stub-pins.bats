#!/usr/bin/env bats
# Tests for stub_pin_acceptable() in scripts/compliance-audit.sh — the pin-match
# used by check_centralized_workflow_stubs.
#
# During the #482 channel migration a stub is compliant if it pins the reusable
# at the canonical <name>/stable channel OR, transitionally, an accepted legacy
# @vN ref — so the audit neither flags nor reverts a stub mid-migration. A SHA
# pin, a commented-out line, or the wrong reusable must NOT satisfy the check.
#
# The script is sourced in an isolated subshell (its `main` is guarded, so
# sourcing only defines functions) and the real helper is exercised directly.

bats_require_minimum_version 1.5.0

SCRIPT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/scripts/compliance-audit.sh"

# Run the real helper with the given uses-line and (canonical, legacy) spec.
accept() {
  local line="$1" canonical="$2" legacy="$3"
  run bash -c 'source "$1" >/dev/null 2>&1; stub_pin_acceptable "$2" agent-shield-reusable "$3" "$4"' \
    _ "$SCRIPT" "$line" "$canonical" "$legacy"
}

C="agent-shield/stable"   # canonical channel for these tests
L="v1,v2"                 # transitional legacy grace
R="combsmith/.github/.github/workflows/agent-shield-reusable.yml"

@test "canonical channel pin is accepted" {
  accept "    uses: $R@$C" "$C" "$L"
  [ "$status" -eq 0 ]
}

@test "transitional legacy @v1 is accepted" {
  accept "    uses: $R@v1" "$C" "$L"
  [ "$status" -eq 0 ]
}

@test "transitional legacy @v2 is accepted" {
  accept "    uses: $R@v2" "$C" "$L"
  [ "$status" -eq 0 ]
}

@test "a SHA pin is rejected (must move to the channel)" {
  accept "    uses: $R@376a4fcb1117444595e3e702fa450873d0e54310 # v2" "$C" "$L"
  [ "$status" -ne 0 ]
}

@test "a commented-out uses line does not satisfy the check" {
  accept "    # uses: $R@$C" "$C" "$L"
  [ "$status" -ne 0 ]
}

@test "the wrong reusable is rejected" {
  accept "    uses: combsmith/.github/.github/workflows/dependency-audit-reusable.yml@v1" "$C" "$L"
  [ "$status" -ne 0 ]
}

@test "with no legacy grace, only the canonical ref is accepted" {
  # mirrors the feature-ideation entry (canonical @v1, empty legacy)
  accept "    uses: $R@v1" "v1" ""
  [ "$status" -eq 0 ]
  accept "    uses: $R@v2" "v1" ""
  [ "$status" -ne 0 ]
}
