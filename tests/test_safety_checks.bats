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

@test "sc_description_missing: an H1 whose title matches a section keyword, with body text, counts as present" {
  # ATX H1 headings open sections just like H2/H3 (one-to-six hashes per
  # CommonMark). 'Design Problem Statement' is an H1 containing the whole word
  # 'problem', so the prose beneath it marks the Problem section present.
  body=$'# Design Problem Statement\n\nSome prose about scope.\n\n## Risk\n\nreal content\n\n## Test Plan\n\nreal content\n\n## Rollback\n\nreal content\n\n## Monitoring\n\nreal content\n'
  run bash -c "source '$LIB'; printf '%s' \"\$1\" | sc_description_missing" _ "$body"
  [ "$status" -eq 0 ]
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

@test "sc_description_missing: an indented code block containing '# problem' does NOT register as a heading" {
  # CommonMark: four or more leading spaces turn a line into an indented code
  # block, not an ATX heading. The Problem section should still be missing.
  body=$'    # problem (inside a code block)\n\n## Risk\n\nx\n\n## Test Plan\n\nx\n\n## Rollback\n\nx\n\n## Monitoring\n\nx\n'
  run bash -c "source '$LIB'; printf '%s' \"\$1\" | sc_description_missing" _ "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "sc_description_missing: a tab-indented '## problem' does NOT register as a heading" {
  # CommonMark treats a leading tab as four-column indentation (an indented
  # code block), not ATX heading indentation, so only literal spaces count.
  # The Problem section must therefore stay missing.
  body=$'\t## Problem\n\nx\n\n## Risk\n\nx\n\n## Test Plan\n\nx\n\n## Rollback\n\nx\n\n## Monitoring\n\nx\n'
  run bash -c "source '$LIB'; printf '%s' \"\$1\" | sc_description_missing" _ "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "sc_description_missing: a run of seven '#' does NOT register as a heading" {
  # ATX headings are limited to six hashes; seven or more is plain text, so the
  # Problem section stays missing.
  body=$'####### Problem\n\nx\n\n## Risk\n\nx\n\n## Test Plan\n\nx\n\n## Rollback\n\nx\n\n## Monitoring\n\nx\n'
  run bash -c "source '$LIB'; printf '%s' \"\$1\" | sc_description_missing" _ "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "sc_description_missing: a combined heading opens every section it names" {
  # '## Risk and Rollback' matches both the risk and rollback keys; the body
  # beneath must mark BOTH present, leaving only problem/test-plan/monitoring
  # missing (3), not 4.
  body=$'## Risk and Rollback\n\nreal content\n'
  run bash -c "source '$LIB'; printf '%s' \"\$1\" | sc_description_missing" _ "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "sc_description_missing: a bare '## Tests' heading satisfies the test-plan section" {
  # Real PRs use plain verb forms ('Tests', 'Testing') for the test section;
  # the test-plan key accepts them with the 'plan' segment optional.
  body=$'## Problem\n\nx\n\n## Risk\n\nx\n\n## Tests\n\nx\n\n## Rollback\n\nx\n\n## Monitoring\n\nx\n'
  run bash -c "source '$LIB'; printf '%s' \"\$1\" | sc_description_missing" _ "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "sc_description_missing: heading variants (Rollback Plan, Test plan / verification) still match" {
  body=$'## Problem\n\nx\n\n## Risks and Mitigations\n\nx\n\n## Test plan / verification\n\nx\n\n## Rollback Plan\n\nx\n\n## Monitoring and alerts\n\nx\n'
  run bash -c "source '$LIB'; printf '%s' \"\$1\" | sc_description_missing" _ "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# --- non-content filters (fenced code, thematic break, placeholder forms) ---

@test "sc_description_missing: a '# problem' inside a fenced code block does NOT register as a heading" {
  # Same regression class as #1976 — a code snippet in the Test Plan section
  # must not open the Problem section via its own code comment. The Problem
  # section is empty beyond its heading and must still count as missing.
  body=$'## Problem\n\n## Risk\n\nx\n\n## Test Plan\n\n```shell\n# problem: this is a code example, not a heading\necho hi\n```\n\n## Rollback\n\nx\n\n## Monitoring\n\nx\n'
  run bash -c "source '$LIB'; printf '%s' \"\$1\" | sc_description_missing" _ "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "sc_description_missing: a tilde-fenced code block is also tracked" {
  body=$'## Problem\n\n## Risk\n\nx\n\n## Test Plan\n\n~~~\n# problem: tilde-fenced example\n~~~\n\n## Rollback\n\nx\n\n## Monitoring\n\nx\n'
  run bash -c "source '$LIB'; printf '%s' \"\$1\" | sc_description_missing" _ "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "sc_description_missing: a Markdown thematic break under an otherwise empty section does NOT count as body text" {
  # '---' / '***' / '___' are structural rules, not content. The Problem
  # section only carries a horizontal rule and must still count as missing.
  body=$'## Problem\n\n---\n\n## Risk\n\nx\n\n## Test Plan\n\nx\n\n## Rollback\n\nx\n\n## Monitoring\n\nx\n'
  run bash -c "source '$LIB'; printf '%s' \"\$1\" | sc_description_missing" _ "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "sc_description_missing: '_No response_' placeholder lines do NOT count as body text" {
  # GitHub form default: when a contributor leaves an issue-form field empty,
  # the field renders as '_No response_'. Treating it as real content turns a
  # fully-skipped template into 0/5 missing. Three forms covered.
  body=$'## Problem\n\n_No response_\n\n## Risk\n\n*No response*\n\n## Test Plan\n\nNo response\n\n## Rollback\n\nx\n\n## Monitoring\n\nx\n'
  run bash -c "source '$LIB'; printf '%s' \"\$1\" | sc_description_missing" _ "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

# --- fail-closed contract (stdin read failure) ----------------------------

@test "sc_description_missing: a failing stdin reader returns non-zero and emits no numeric score" {
  # Fail-closed contract: if the body cannot be read, the function must exit
  # non-zero so the caller (Phase 2's scorer) escalates to a human rather than
  # scoring the PR 'not spam'. We simulate a hard read failure by shadowing
  # `cat` with a shell function that always exits 1 — the shadow is inherited
  # by the subshell that `$(cat)` spawns inside the function.
  run bash -c "cat() { return 1; }; export -f cat; source '$LIB' && sc_description_missing"
  # Expected: non-zero exit, no numeric stdout. (The function's own stderr
  # message is captured in BATS stderr, not stdout, so stdout stays clean.)
  [ "$status" -ne 0 ]
  # output must not be a plain digit string a caller could mistake for a
  # valid 0..5 score.
  [[ ! "$output" =~ ^[0-9]+$ ]]
}

# --- shellcheck gate ------------------------------------------------------

@test "scripts/lib/safety-checks.sh passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run shellcheck --shell=bash "$LIB"
  [ "$status" -eq 0 ]
}
