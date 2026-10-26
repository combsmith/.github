#!/usr/bin/env bats
# Unit tests for check_gemini_md in scripts/compliance-audit.sh
# (standards/agent-standards.md).

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

run_check_gemini_md() {
  local repo="$1" gemini_body="$2"
  bash -c '
    set -euo pipefail
    export ORG="combsmith"
    export OUTPUT_DIR="'"$TMPDIR_TEST"'"
    source "'"$SCRIPT"'"
    FINDINGS_FILE="$OUTPUT_DIR/findings.json"
    echo "[]" > "$FINDINGS_FILE"
    findings_count=0
    GEMINI_BODY="$2"
    gh_api() {
      if [ -z "$GEMINI_BODY" ]; then
        return 1
      fi
      printf "%s" "$GEMINI_BODY" | base64 | tr -d "\n"
      printf "\n"
    }
    check_gemini_md "$1"
    cat "$FINDINGS_FILE"
  ' _ "$repo" "$gemini_body"
}

@test "check_gemini_md: compliant GEMINI.md referencing AGENTS.md produces no finding" {
  run run_check_gemini_md "incubator" "# GEMINI.md
See [AGENTS.md](AGENTS.md) and https://github.com/combsmith/.github/blob/main/AGENTS.md"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "check_gemini_md: missing GEMINI.md raises missing-gemini-md error" {
  run run_check_gemini_md "incubator" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *'"check": "missing-gemini-md"'* ]]
  [[ "$output" == *'"severity": "error"'* ]]
}

@test "check_gemini_md: GEMINI.md without AGENTS.md reference raises gemini-md-missing-agents-ref error" {
  run run_check_gemini_md "incubator" "# GEMINI.md
Project instructions without referencing the required file."
  [ "$status" -eq 0 ]
  [[ "$output" == *'"check": "gemini-md-missing-agents-ref"'* ]]
  [[ "$output" == *'"severity": "error"'* ]]
}
