#!/usr/bin/env bats
# Unit tests for scripts/lib/safety-checks.sh — the sourceable PR-safety
# signal helpers that back the Layer 1 spam-pr-guard scorer (epic #1200,
# story #1202).
#
# The function under test, sc_description_missing, replaces the naive
# keyword grep in the prior PR-safety path that scored an UNFILLED PR
# template as 0/5 missing. The template's own headings and HTML comments
# contain all five keywords, so the raw-body matcher reported "complete"
# on an empty template — the exact regression that let
# petry-projects/.github-private#1976 ship through automation.
#
# These cases cover:
#   - the #1976 fixture reports a near-max missing count (regression anchor);
#   - a genuinely filled description still reports 0 missing (counterfactual);
#   - an intermediate 2-of-5 case reports 3 (ordering + arithmetic);
#   - an empty body reports 5;
#   - the matcher correctly ignores HTML comment bodies, heading-text keyword
#     echoes, and keyword-as-prefix (e.g. "problematic") false positives.
#
# Pattern follows tests/agents_md_lint.bats: sourceable pure helper + pure
# bats cases over fixtures under tests/fixtures/safety-checks/.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  LIB="$REPO_ROOT/scripts/lib/safety-checks.sh"
  FIX="$REPO_ROOT/tests/fixtures/safety-checks"
  # shellcheck source=/dev/null
  source "$LIB"
}

# --- fixture-level cases --------------------------------------------------

@test "sc_description_missing: the #1976 unfilled-template fixture reports a near-max missing count" {
  # The regression anchor. Pre-fix behaviour was 0 (false 'complete'); after
  # the fix every section is empty-after-stripping, so all five are missing.
  run bash -c "source '$LIB' && sc_description_missing < '$FIX/pr-1976-unfilled-template.md'"
  [ "$status" -eq 0 ]
  [ "$output" = "5" ]
}

@test "sc_description_missing: a genuinely filled description still reports 0 missing (counterfactual)" {
  run bash -c "source '$LIB' && sc_description_missing < '$FIX/filled-description.md'"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "sc_description_missing: 2 of 5 sections filled reports 3 missing" {
  run bash -c "source '$LIB' && sc_description_missing < '$FIX/partial-two-of-five.md'"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

# --- inline, construct-level cases ---------------------------------------

@test "sc_description_missing: empty body reports 5 missing" {
  run bash -c "source '$LIB' && printf '' | sc_description_missing"
  [ "$status" -eq 0 ]
  [ "$output" = "5" ]
}

@test "sc_description_missing: a heading alone with no body text does NOT count as present" {
  # The core #1976 fix: the heading line itself must not satisfy its own section.
  body=$'## Problem\n\n## Risk\n\n## Test Plan\n\n## Rollback\n\n## Monitoring\n'
  run bash -c "source '$LIB'; printf '%s' \"\$1\" | sc_description_missing" _ "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "5" ]
}

@test "sc_description_missing: an HTML comment under a heading does NOT count as present" {
  # Comments carry the template's helper text and must be stripped before the
  # body-text check — otherwise the regression returns.
  body=$'## Problem\n\n<!-- Describe the problem -->\n\n## Risk\n\n## Test Plan\n\n## Rollback\n\n## Monitoring\n'
  run bash -c "source '$LIB'; printf '%s' \"\$1\" | sc_description_missing" _ "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "5" ]
}

@test "sc_description_missing: multi-line HTML comment is stripped across newlines" {
  body=$'## Problem\n\n<!--\n multi\n line\n comment\n-->\n\n## Risk\n## Test Plan\n## Rollback\n## Monitoring\n'
  run bash -c "source '$LIB'; printf '%s' \"\$1\" | sc_description_missing" _ "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "5" ]
}

@test "sc_description_missing: a keyword inside a non-section heading does NOT satisfy that section" {
  # The word 'problem' appears inside H1 'Design Problem Statement' but no
  # H2/H3 opens that section; the Problem section is still missing.
  body=$'# Design Problem Statement\n\nSome prose about scope.\n\n## Risk\n\nreal content\n\n## Test Plan\n\nreal content\n\n## Rollback\n\nreal content\n\n## Monitoring\n\nreal content\n'
  run bash -c "source '$LIB'; printf '%s' \"\$1\" | sc_description_missing" _ "$body"
  [ "$status" -eq 0 ]
  # Problem H1 opens; the prose beneath marks problem as present.
  [ "$output" = "0" ]
}

@test "sc_description_missing: 'problematic' prose does NOT satisfy the Problem section via prefix match" {
  # Whole-word boundary — 'problematic' must not match 'problem'.
  body=$'## Other\n\nThis is problematic behaviour we want to avoid.\n\n## Risk\n\nx\n\n## Test Plan\n\nx\n\n## Rollback\n\nx\n\n## Monitoring\n\nx\n'
  run bash -c "source '$LIB'; printf '%s' \"\$1\" | sc_description_missing" _ "$body"
  [ "$status" -eq 0 ]
  # Problem never opens because no heading contains the whole word 'problem'.
  [ "$output" = "1" ]
}

@test "sc_description_missing: heading variants (Rollback Plan, Test plan / verification) still match" {
  body=$'## Problem\n\nx\n\n## Risks and Mitigations\n\nx\n\n## Test plan / verification\n\nx\n\n## Rollback Plan\n\nx\n\n## Monitoring and alerts\n\nx\n'
  run bash -c "source '$LIB'; printf '%s' \"\$1\" | sc_description_missing" _ "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# --- shellcheck gate ------------------------------------------------------

@test "scripts/lib/safety-checks.sh passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run shellcheck --shell=bash "$LIB"
  [ "$status" -eq 0 ]
}
