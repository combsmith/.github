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

# Stubs the `gh` CLI (the real entry point of check_gemini_md) so no network is
# touched. GEMINI_MODE: "ok" returns a Contents API JSON body, "404" fails with
# an HTTP 404, "500" fails with a non-404 error. The sleep between retries is
# stubbed out so the non-404 path is fast.
run_check_gemini_md() {
  local repo="$1" gemini_body="$2" mode="${3:-ok}"
  bash -c '
    set -euo pipefail
    export ORG="combsmith"
    export OUTPUT_DIR="'"$TMPDIR_TEST"'"
    source "'"$SCRIPT"'"
    FINDINGS_FILE="$OUTPUT_DIR/findings.json"
    INCONCLUSIVE_REPOS_FILE="$OUTPUT_DIR/inconclusive.txt"
    echo "[]" > "$FINDINGS_FILE"
    findings_count=0
    GEMINI_BODY="$2"
    GEMINI_MODE="$3"
    sleep() { :; }
    gh() {
      case "$GEMINI_MODE" in
        404) echo "gh: Not Found (HTTP 404)" >&2; return 1 ;;
        500) echo "gh: Server Error (HTTP 500)" >&2; return 1 ;;
      esac
      printf "{\"content\":\"%s\"}" "$(printf "%s" "$GEMINI_BODY" | base64 | tr -d "\n")"
    }
    check_gemini_md "$1"
    cat "$FINDINGS_FILE"
    if [ -f "$INCONCLUSIVE_REPOS_FILE" ]; then echo "INCONCLUSIVE: $(cat "$INCONCLUSIVE_REPOS_FILE")"; fi
  ' _ "$repo" "$gemini_body" "$mode"
}

@test "check_gemini_md: compliant GEMINI.md referencing AGENTS.md produces no finding" {
  run run_check_gemini_md "incubator" "# GEMINI.md
See [AGENTS.md](AGENTS.md) and https://github.com/combsmith/.github/blob/main/AGENTS.md"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "check_gemini_md: missing GEMINI.md raises missing-gemini-md error" {
  run run_check_gemini_md "incubator" "" 404
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

@test "check_gemini_md: empty GEMINI.md raises gemini-md-missing-agents-ref and does not abort" {
  run run_check_gemini_md "incubator" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *'"check": "gemini-md-missing-agents-ref"'* ]]
}

@test "check_gemini_md: non-404 API failure marks the repo inconclusive with no finding" {
  run run_check_gemini_md "incubator" "" 500
  [ "$status" -eq 0 ]
  [[ "$output" == *"INCONCLUSIVE: incubator"* ]]
  [[ "$output" != *"missing-gemini-md"* ]]
}
