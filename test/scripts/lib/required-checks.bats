#!/usr/bin/env bats
# Unit tests for scripts/lib/required-checks.sh — the repo-declared additional
# required checks merged into `code-quality` (combsmith/.github#1410).
#
# A repo may declare extra required status checks in .github/required-checks.json.
# apply-rulesets.sh merges them into the codified code-quality payload instead of
# dropping them on the weekly full-replace, and the compliance audit flags a
# declared check that is missing from the live ruleset. The library is pure:
# JSON in, JSON/TSV out, no gh calls.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/required-checks.sh"
CQ="$REPO_ROOT/standards/rulesets/code-quality.json"

_rc() { bash -c "set -euo pipefail; source '$LIB'; $*"; }

# ── rc_declared_checks: validation + normalisation ──────────────────────────
@test "rc_declared_checks: a valid declaration emits its checks as a compact array" {
  run _rc "rc_declared_checks '{\"version\":1,\"required_status_checks\":[{\"context\":\"mutation (all)\",\"integration_id\":15368}]}'"
  [ "$status" -eq 0 ]
  [ "$output" = '[{"context":"mutation (all)","integration_id":15368}]' ]
}

@test "rc_declared_checks: an empty check list is valid and emits []" {
  run _rc "rc_declared_checks '{\"version\":1,\"required_status_checks\":[]}'"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "rc_declared_checks: an entry without integration_id is rejected (app pinning is mandatory)" {
  run _rc "rc_declared_checks '{\"version\":1,\"required_status_checks\":[{\"context\":\"build\"}]}'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"integration_id"* ]]
}

@test "rc_declared_checks: a non-integer integration_id is rejected" {
  run _rc "rc_declared_checks '{\"version\":1,\"required_status_checks\":[{\"context\":\"build\",\"integration_id\":\"15368\"}]}'"
  [ "$status" -ne 0 ]
}

@test "rc_declared_checks: an empty context is rejected" {
  run _rc "rc_declared_checks '{\"version\":1,\"required_status_checks\":[{\"context\":\"\",\"integration_id\":15368}]}'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"context"* ]]
}

@test "rc_declared_checks: duplicate contexts are rejected" {
  run _rc "rc_declared_checks '{\"version\":1,\"required_status_checks\":[{\"context\":\"a\",\"integration_id\":1},{\"context\":\"a\",\"integration_id\":2}]}'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate"* ]]
}

@test "rc_declared_checks: an unknown version is rejected" {
  run _rc "rc_declared_checks '{\"version\":2,\"required_status_checks\":[]}'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"version"* ]]
}

@test "rc_declared_checks: unknown entry keys are rejected (no silent typos)" {
  run _rc "rc_declared_checks '{\"version\":1,\"required_status_checks\":[{\"context\":\"a\",\"integration_id\":1,\"app\":\"x\"}]}'"
  [ "$status" -ne 0 ]
}

@test "rc_declared_checks: malformed JSON and non-object documents are rejected" {
  run _rc "rc_declared_checks 'not json'"
  [ "$status" -ne 0 ]
  run _rc "rc_declared_checks '[]'"
  [ "$status" -ne 0 ]
  run _rc "rc_declared_checks '{\"version\":1}'"
  [ "$status" -ne 0 ]
}

# ── rc_merge_payload: codified + declared → PUT payload ─────────────────────
@test "rc_merge_payload: appends declared checks after the codified contexts" {
  run _rc "rc_merge_payload \"\$(jq -c . '$CQ')\" '[{\"context\":\"mutation (all)\",\"integration_id\":15368}]' \
    | jq -c '[.rules[] | select(.type==\"required_status_checks\") | .parameters.required_status_checks[]]'"
  [ "$status" -eq 0 ]
  codified="$(jq -c '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[]]' "$CQ")"
  [ "$output" = "$(jq -cn --argjson c "$codified" '$c + [{"context":"mutation (all)","integration_id":15368}]')" ]
}

@test "rc_merge_payload: a declared context that is already codified keeps the codified entry" {
  run _rc "rc_merge_payload \"\$(jq -c . '$CQ')\" '[{\"context\":\"CodeQL\",\"integration_id\":99}]' \
    | jq -c '[.rules[] | select(.type==\"required_status_checks\") | .parameters.required_status_checks[] | select(.context==\"CodeQL\")]'"
  [ "$status" -eq 0 ]
  [ "$output" = "$(jq -c '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[] | select(.context=="CodeQL")]' "$CQ")" ]
}

@test "rc_merge_payload: no declared checks leaves the payload byte-identical" {
  run _rc "rc_merge_payload \"\$(jq -c . '$CQ')\" '[]' | jq -cS ."
  [ "$status" -eq 0 ]
  [ "$output" = "$(jq -cS . "$CQ")" ]
}

@test "rc_merge_payload: rules other than required_status_checks are untouched" {
  run _rc "rc_merge_payload \"\$(jq -c . '$CQ')\" '[{\"context\":\"x\",\"integration_id\":1}]' \
    | jq -cS '[.rules[] | select(.type!=\"required_status_checks\")]'"
  [ "$status" -eq 0 ]
  [ "$output" = "$(jq -cS '[.rules[] | select(.type!="required_status_checks")]' "$CQ")" ]
}

# ── rc_missing_from_live: the audit's reverse check ─────────────────────────
@test "rc_missing_from_live: nothing missing when every declared check is live with its app" {
  live='{"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"CodeQL"},{"context":"mutation (all)","integration_id":15368}]}}]}'
  run _rc "rc_missing_from_live '[{\"context\":\"mutation (all)\",\"integration_id\":15368}]' '$live'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "rc_missing_from_live: a declared check absent from the live ruleset is reported" {
  live='{"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"CodeQL"}]}}]}'
  run _rc "rc_missing_from_live '[{\"context\":\"mutation (all)\",\"integration_id\":15368}]' '$live'"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'mutation (all)\t15368\tmissing')" ]
}

@test "rc_missing_from_live: a live check pinned to a different app (or none) is reported" {
  live='{"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"mutation (all)"}]}}]}'
  run _rc "rc_missing_from_live '[{\"context\":\"mutation (all)\",\"integration_id\":15368}]' '$live'"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'mutation (all)\t15368\tany')" ]
}

@test "rc_missing_from_live: a live ruleset with no required_status_checks rule reports every declared check" {
  run _rc "rc_missing_from_live '[{\"context\":\"a\",\"integration_id\":1},{\"context\":\"b\",\"integration_id\":2}]' '{\"rules\":[]}' | wc -l | tr -d ' '"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

# ── rc_drop_codified: audit and applier agree on codified contexts ──────────
@test "rc_drop_codified: removes a declared context already codified, keeps the rest" {
  run _rc "rc_drop_codified \"\$(jq -c . '$CQ')\" '[{\"context\":\"CodeQL\",\"integration_id\":15368},{\"context\":\"mutation (all)\",\"integration_id\":15368}]'"
  [ "$status" -eq 0 ]
  [ "$output" = '[{"context":"mutation (all)","integration_id":15368}]' ]
}
