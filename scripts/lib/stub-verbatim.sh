#!/usr/bin/env bash
# scripts/lib/stub-verbatim.sh — which standard workflow stubs are compared in
# FULL against their template ("verbatim-managed"), and the full comparison.
#
# Shared by the deploy sweep (is_pin_compliant in deploy-standard-workflows.sh)
# and the compliance audit (check_verbatim_stubs in compliance-audit.sh), so the
# two cannot disagree on whether a verbatim-managed stub has drifted (#1277).
#
# A stub that calls a reusable workflow (a `uses:` naming a file under
# `.github/workflows/`) is pin-managed: only its `uses:` pin is
# compared, so a repo keeps its ring tier channel. Every other stub is
# verbatim-managed. The test is the absence of a REUSABLE `uses:` line, not of
# any `uses:` line: initiative-driver.yml dispatches the central driver directly
# but carries an `actions/checkout` step, and treating that action as the "pin"
# let any stub that kept the one checkout line pass as compliant (#1277).
#
# Pure: no I/O beyond reading the template file. Safe to source repeatedly.

# Deployable workflows whose template is verbatim-managed. The audit checks
# these against their template; a bats test keeps the list equal to the
# DEPLOYABLE_WORKFLOWS whose template has no reusable `uses:` line.
# shellcheck disable=SC2034  # read by callers (audit)
VERBATIM_STUB_WORKFLOWS=(initiative-driver.yml)

# stub_reusable_uses <template> -> the template's first `uses:` value that names a
# reusable workflow (org/repo/.github/workflows/<name>.yml@<ref>), with the
# inline comment and CR stripped. Empty when the template calls no reusable;
# action-step `uses:` lines (e.g. actions/checkout@<sha>) never match.
stub_reusable_uses() {
  local template="$1"
  grep -E '^[[:space:]]*(-[[:space:]]+)?uses:' "$template" \
    | sed -E 's/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*//; s/[[:space:]]*#.*//' \
    | tr -d '\r' \
    | grep -E -- '/\.github/workflows/[^@[:space:]]+\.ya?ml@' | sed -n 1p || true
  return 0
}

# stub_is_verbatim_managed <template> -> 0 when the template calls no reusable,
# so a deployed stub must match it in full.
stub_is_verbatim_managed() {
  local template="$1"
  if [[ -z "$(stub_reusable_uses "$template")" ]]; then
    return 0
  fi
  return 1
}

# stub_verbatim_matches <existing_content> <template> -> 0 when the deployed stub
# equals the template, ignoring CRLF line endings only (a lone CR mid-line is content).
stub_verbatim_matches() {
  local existing="$1" template="$2"
  local template_content normalized_existing
  template_content=$(sed 's/\r$//' < "$template")
  normalized_existing=$(printf '%s' "$existing" | sed 's/\r$//')
  if [[ "$normalized_existing" == "$template_content" ]]; then
    return 0
  fi
  return 1
}
