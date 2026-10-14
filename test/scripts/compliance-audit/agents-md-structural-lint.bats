#!/usr/bin/env bats
# Tests for the Phase 3 AGENTS.md structural-linter integration in
# scripts/compliance-audit.sh (issue #645, epic #642).
#
# Phase 3 wires the standalone structural linter (scripts/agents-md-lint.sh)
# into the compliance audit as an INFORMATIONAL, non-blocking check: it runs
# over each scanned repo's AGENTS.md when the file exists, records the linter's
# structural findings in a SEPARATE accumulator (never FINDINGS_FILE, so no
# issues are opened, the umbrella is untouched, and the run never fails), and
# surfaces them in a clearly-labelled informational summary section that links
# to the rule-set doc.
#
# The script is sourced in an isolated subshell (its `main` is guarded, so
# sourcing only defines functions / top-level vars) and the real helpers are
# exercised directly. No network / gh access is required — gh_api is stubbed
# where a check function needs it.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/compliance-audit.sh"

setup() {
  TMPDIR_TEST="$(mktemp -d)"
  export TMPDIR_TEST
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

# A minimal, structurally-VALID downstream AGENTS.md: one H1 first, no skipped
# levels, a back-link to the canonical org file, balanced fences, and all three
# recommended sections. Uses only an in-document anchor + an https link so it
# resolves cleanly from any directory (the recorder copies content to a temp
# file, so relative-file links would not resolve).
VALID_DOWNSTREAM=$(cat <<'EOF'
# Example Repo AGENTS.md

Imports the org standards from
[combsmith/.github](https://github.com/combsmith/.github/blob/main/AGENTS.md).
See [the standards](#development-standards).

## Development Standards

Points at the org development standards.

## Security

Never commit secrets.

## Testing

Test-driven development.
EOF
)

# Same as VALID_DOWNSTREAM but jumps H2 -> H4 (a required heading-hierarchy
# violation) so the linter must report heading-hierarchy-valid.
SKIPPED_HEADING=$(cat <<'EOF'
# Example Repo AGENTS.md

Imports [combsmith/.github](https://github.com/combsmith/.github/blob/main/AGENTS.md).

## Section A

#### Deep Sub-heading

A level was skipped (H2 -> H4).
EOF
)

# A downstream AGENTS.md with NO back-link to the canonical org file — must
# trigger org-repo-import-consistency under downstream scope.
NO_IMPORT_LINK=$(cat <<'EOF'
# Standalone AGENTS.md

## Development Standards

No link back to the canonical org file.

## Security

Never commit secrets.

## Testing

Test-driven development.
EOF
)

# ---------------------------------------------------------------------------
# agents_md_lint_scope_for_repo — the canonical file (this .github repo's own
# AGENTS.md) is exempt from downstream-only rules; every other repo is a
# downstream consumer.
# ---------------------------------------------------------------------------

scope_for() {
  run bash -c 'source "$1" >/dev/null 2>&1; agents_md_lint_scope_for_repo "$2"' \
    _ "$SCRIPT" "$1"
}

@test "scope for the .github repo is canonical" {
  scope_for ".github"
  [ "$status" -eq 0 ]
  [ "$output" = "canonical" ]
}

@test "scope for any downstream repo is downstream" {
  scope_for "some-app"
  [ "$status" -eq 0 ]
  [ "$output" = "downstream" ]
}

# ---------------------------------------------------------------------------
# record_agents_md_structural_findings — runs the linter over already-decoded
# AGENTS.md content and appends TSV rows (repo, severity, rule, line, message)
# to STRUCTURAL_FINDINGS_FILE. No gh access.
# ---------------------------------------------------------------------------

# record <repo> <content> — source the script, point the accumulator at a temp
# file, run the recorder, and cat the accumulator. `output` is the file body.
record() {
  local acc="$TMPDIR_TEST/structural.tsv"
  : > "$acc"
  run bash -c '
    source "$1" >/dev/null 2>&1
    STRUCTURAL_FINDINGS_FILE="$2"
    record_agents_md_structural_findings "$3" "$4"
    cat "$2"
  ' _ "$SCRIPT" "$acc" "$1" "$2"
}

@test "a structurally-valid downstream AGENTS.md records no structural findings" {
  record "some-app" "$VALID_DOWNSTREAM"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a skipped-heading AGENTS.md records the heading-hierarchy finding" {
  record "some-app" "$SKIPPED_HEADING"
  [ "$status" -eq 0 ]
  grep -q $'\theading-hierarchy-valid\t' <<< "$output"
  # Every recorded row is keyed by the repo.
  grep -q '^some-app	' <<< "$output"
}

@test "a downstream AGENTS.md with no org back-link records org-repo-import-consistency" {
  record "some-app" "$NO_IMPORT_LINK"
  [ "$status" -eq 0 ]
  grep -q $'\torg-repo-import-consistency\t' <<< "$output"
}

@test "the canonical (.github) scope is exempt from org-repo-import-consistency" {
  # The same no-back-link content, but scanned as the canonical repo, must NOT
  # raise the downstream-only import rule.
  record ".github" "$NO_IMPORT_LINK"
  [ "$status" -eq 0 ]
  run grep -q 'org-repo-import-consistency' <<< "$output"
  [ "$status" -eq 1 ]
}

@test "empty content records nothing (linter runs only when the file exists)" {
  record "some-app" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# check_agents_md integration — presence check must not regress, and the linter
# must run only when the file exists. gh_api is stubbed.
# ---------------------------------------------------------------------------

# run_check <repo> <b64-content-or-EMPTY> — source the script, stub gh_api to
# return the given base64 content for the AGENTS.md contents call (empty = 404),
# point FINDINGS_FILE + STRUCTURAL_FINDINGS_FILE at temp files, run
# check_agents_md, then print a marker line with each file's contents.
run_check() {
  local findings="$TMPDIR_TEST/findings.json"
  local acc="$TMPDIR_TEST/structural.tsv"
  echo "[]" > "$findings"
  : > "$acc"
  run bash -c '
    source "$1" >/dev/null 2>&1
    FINDINGS_FILE="$2"
    STRUCTURAL_FINDINGS_FILE="$3"
    gh_api() { [ -n "$STUB_CONTENT" ] && printf "%s" "$STUB_CONTENT"; return 0; }
    check_agents_md "$4"
    echo "---FINDINGS---"; cat "$FINDINGS_FILE"
    echo "---STRUCTURAL---"; cat "$STRUCTURAL_FINDINGS_FILE"
  ' _ "$SCRIPT" "$findings" "$acc" "$1"
}

@test "a missing AGENTS.md (404) files missing-agents-md and runs no linter" {
  STUB_CONTENT="" run_check "some-app"
  [ "$status" -eq 0 ]
  # Presence finding still filed (no regression).
  grep -q '"check": *"missing-agents-md"' <<< "$output" \
    || grep -q '"check":"missing-agents-md"' <<< "$output"
  # Nothing recorded structurally — the linter never ran on a 404.
  structural="${output##*---STRUCTURAL---}"
  [ -z "$(printf '%s' "$structural" | tr -d '[:space:]')" ]
}

@test "a present-but-invalid AGENTS.md records a structural finding without a blocking finding" {
  local content
  content=$(printf '%s' "$SKIPPED_HEADING" | base64 | tr -d '\n')
  STUB_CONTENT="$content" run_check "some-app"
  [ "$status" -eq 0 ]
  local full_output="$output"
  # No missing-agents-md finding (the file exists).
  run grep -q 'missing-agents-md' <<< "$full_output"
  [ "$status" -eq 1 ]
  # The structural accumulator carries the hierarchy finding.
  structural="${full_output##*---STRUCTURAL---}"
  grep -q 'heading-hierarchy-valid' <<< "$structural"
  # And it is NOT in FINDINGS_FILE (non-blocking — opens no issue).
  findings="${full_output%%---STRUCTURAL---*}"
  run grep -q 'heading-hierarchy-valid' <<< "$findings"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# append_structural_findings_summary — informational, labelled, doc-linked.
# ---------------------------------------------------------------------------

# summary_with <tsv-lines> — source the script, write the given lines to
# STRUCTURAL_FINDINGS_FILE, point SUMMARY_FILE at a temp file, append the
# section, and cat the summary.
summary_with() {
  local acc="$TMPDIR_TEST/structural.tsv"
  local summary="$TMPDIR_TEST/summary.md"
  printf '%b' "$1" > "$acc"
  : > "$summary"
  run bash -c '
    source "$1" >/dev/null 2>&1
    STRUCTURAL_FINDINGS_FILE="$2"
    SUMMARY_FILE="$3"
    append_structural_findings_summary
    cat "$3"
  ' _ "$SCRIPT" "$acc" "$summary"
}

@test "the summary section is labelled informational and links to the rule-set doc" {
  summary_with ""
  [ "$status" -eq 0 ]
  grep -qi 'informational' <<< "$output"
  grep -q 'docs/initiatives/agents-md-validation.md' <<< "$output"
}

@test "with no structural findings the summary states everything is valid" {
  summary_with ""
  [ "$status" -eq 0 ]
  grep -qi 'no structural findings' <<< "$output"
}

@test "structural findings are rendered as a table row keyed by repo and rule" {
  summary_with 'some-app\trequired\theading-hierarchy-valid\t8\theading level jumps from H2 to H4\n'
  [ "$status" -eq 0 ]
  grep -q 'some-app' <<< "$output"
  grep -q 'heading-hierarchy-valid' <<< "$output"
}

@test "a literal pipe in a finding message is escaped so the table cell is not split" {
  # Section-presence rule messages carry an alternation regex like
  # /standard|development standards/ — the '|' must be escaped in the cell.
  summary_with 'some-app\trecommended\tstandards-reference-section-present\t-\tno section heading matching /standard|development standards/ is present\n'
  [ "$status" -eq 0 ]
  grep -q 'standard\\|development standards' <<< "$output"
}
