#!/usr/bin/env bats
# Unit tests for scripts/lib/analysis-inputs.sh — the input check of the
# compliance workflow's `analyze` job (#1616). A missing compliance report or
# health survey must be stated, with the producing job's result, never left
# for the model to discover as an absent directory.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/analysis-inputs.sh"

_ai() { bash -c "set -euo pipefail; source '$LIB'; $*"; }

setup() { TMP="$(mktemp -d)"; }
teardown() { rm -rf "$TMP"; }

@test "input_status: a non-empty file is present" {
  echo '[]' > "$TMP/findings.json"
  run _ai "analysis_input_status '$TMP/findings.json' success"
  [ "$status" -eq 0 ]
  [ "$output" = "present" ]
}

@test "input_status: a missing file names the producing job's result" {
  run _ai "analysis_input_status '$TMP/findings.json' failure"
  [ "$status" -eq 0 ]
  [ "$output" = "missing (producing job result: failure)" ]
}

@test "input_status: an empty file is missing" {
  : > "$TMP/findings.json"
  run _ai "analysis_input_status '$TMP/findings.json' success"
  [ "$output" = "missing (producing job result: success)" ]
}

@test "input_status: a whitespace-only file (empty job output) is missing" {
  printf '\n\n' > "$TMP/health.json"
  run _ai "analysis_input_status '$TMP/health.json' failure"
  [ "$output" = "missing (producing job result: failure)" ]
}

@test "input_status: no job result given → unknown" {
  run _ai "analysis_input_status '$TMP/nope.json' ''"
  [ "$output" = "missing (producing job result: unknown)" ]
}
