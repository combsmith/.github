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

C="agent-shield/stable"   # canonical channel for these tests (a stable-tier repo)
# Retained grace = the other ring channels (a repo pinned to a higher tier than
# its own is never flagged). The pre-ring @v1/@v2 grace was dropped in #870.
L="agent-shield/next,agent-shield/ring0,agent-shield/ring1"
R="combsmith/.github/.github/workflows/agent-shield-reusable.yml"

@test "canonical channel pin is accepted" {
  accept "    uses: $R@$C" "$C" "$L"
  [ "$status" -eq 0 ]
}

@test "a higher-tier ring channel is accepted (promotion grace)" {
  accept "    uses: $R@agent-shield/ring1" "$C" "$L"
  [ "$status" -eq 0 ]
}

@test "a pre-ring @v1 pin is now rejected (grace dropped, #870)" {
  accept "    uses: $R@v1" "$C" "$L"
  [ "$status" -ne 0 ]
}

@test "a pre-ring @v2 pin is now rejected (grace dropped, #870)" {
  accept "    uses: $R@v2" "$C" "$L"
  [ "$status" -ne 0 ]
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
  # A fixed-pin entry with an empty legacy CSV: only the exact canonical ref
  # passes. (feature-ideation used this shape before #606 channel-ified it.)
  accept "    uses: $R@v1" "v1" ""
  [ "$status" -eq 0 ]
  accept "    uses: $R@v2" "v1" ""
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# #606 — feature-ideation and pr-auto-review are now RING reusables. Their
# stubs resolve the canonical pin through the same ring model as the others,
# so a `<name>/stable` channel pin on a stable-tier repo is accepted and the
# pre-ring @v1/@v2 pin is rejected (grace dropped, #870).
# ---------------------------------------------------------------------------
accept_reusable() {
  local reusable="$1" line="$2" canonical="$3" legacy="$4"
  run bash -c 'source "$1" >/dev/null 2>&1; stub_pin_acceptable "$2" "$3" "$4" "$5"' \
    _ "$SCRIPT" "$line" "$reusable" "$canonical" "$legacy"
}

@test "feature-ideation stub: @feature-ideation/stable accepted, @v1 rejected (#606)" {
  local reusable="feature-ideation-reusable"
  local ref="combsmith/.github/.github/workflows/${reusable}.yml"
  accept_reusable "$reusable" "    uses: $ref@feature-ideation/stable" "feature-ideation/stable" ""
  [ "$status" -eq 0 ]
  accept_reusable "$reusable" "    uses: $ref@v1" "feature-ideation/stable" ""
  [ "$status" -ne 0 ]
}

@test "pr-auto-review stub: @pr-auto-review/stable accepted, @v2 rejected (#606)" {
  local reusable="pr-auto-review-reusable"
  local ref="combsmith/.github/.github/workflows/${reusable}.yml"
  accept_reusable "$reusable" "    uses: $ref@pr-auto-review/stable" "pr-auto-review/stable" ""
  [ "$status" -eq 0 ]
  accept_reusable "$reusable" "    uses: $ref@v2" "pr-auto-review/stable" ""
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# ring_tier_for_repo() — maps a repo to its canary-ring tier (epic #495).
# ---------------------------------------------------------------------------
tier() {
  run bash -c 'source "$1" >/dev/null 2>&1; ring_tier_for_repo "$2"' _ "$SCRIPT" "$1"
}

@test "ring tier: .github-private is next" {
  tier ".github-private"
  [ "$status" -eq 0 ]
  [ "$output" = "next" ]
}

@test "ring tier: .github is ring0 (dogfood)" {
  tier ".github"
  [ "$output" = "ring0" ]
}

@test "ring tier: TalkTerm and bmad-bgreat-suite are ring1" {
  tier "TalkTerm"
  [ "$output" = "ring1" ]
  tier "bmad-bgreat-suite"
  [ "$output" = "ring1" ]
}

@test "ring tier: any other repo defaults to stable" {
  tier "markets"
  [ "$output" = "stable" ]
  tier "broodly"
  [ "$output" = "stable" ]
}
