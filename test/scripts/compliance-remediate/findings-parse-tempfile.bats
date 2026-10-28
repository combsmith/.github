#!/usr/bin/env bats
# Tests for FINDINGS_FILE parsing in scripts/compliance-remediate.sh (#1387).
#
# jq's stderr used to be captured through the fixed, shared path
# /tmp/_cr_jq_err, opened with a truncating redirect that follows an existing
# symlink. It must now go to a private mktemp file that is removed afterwards,
# while the jq diagnostic is still surfaced in the error message.

bats_require_minimum_version 1.5.0

load 'helpers/setup'

FIXED_PATH="/tmp/_cr_jq_err"

setup() {
  tt_make_tmpdir
  tt_install_gh_stub
  PRIVATE_TMP="${TT_TMP}/tmpdir"
  mkdir -p "$PRIVATE_TMP"
  PLANTED=""
}

teardown() {
  # Remove the symlink only if this test planted it (never touch anything else).
  if [ -n "$PLANTED" ] && [ -L "$FIXED_PATH" ] \
      && [ "$(readlink "$FIXED_PATH")" = "$PLANTED" ]; then
    rm -f "$FIXED_PATH"
  fi
  tt_cleanup_tmpdir
}

run_remediate_with() {
  printf '%s' "$1" > "${TT_TMP}/findings.json"
  TMPDIR="$PRIVATE_TMP" \
    GH_TOKEN=fake \
    FINDINGS_FILE="${TT_TMP}/findings.json" \
    REPORT_DIR="${TT_TMP}/report" \
    DRY_RUN=true \
    run bash "$TT_SCRIPT"
}

@test "#1387: the script no longer uses the fixed /tmp/_cr_jq_err path" {
  ! grep -qF "$FIXED_PATH" "$TT_SCRIPT"
}

@test "#1387: a malformed findings file still reports jq's diagnostic" {
  run_remediate_with '{not json'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to parse FINDINGS_FILE"* ]]
  [[ "$output" == *"parse error"* ]]
}

@test "#1387: the private stderr file is removed on the failure and success paths" {
  run_remediate_with '{not json'
  [ "$status" -eq 1 ]
  [ -z "$(ls -A "$PRIVATE_TMP")" ]

  run_remediate_with '[]'
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$PRIVATE_TMP")" ]
}

@test "#1387: a pre-planted symlink at the old fixed path is not followed" {
  if [ -e "$FIXED_PATH" ] || [ -L "$FIXED_PATH" ]; then
    skip "$FIXED_PATH already exists on this host; cannot plant a symlink safely"
  fi
  local victim="${TT_TMP}/victim"
  printf 'keep me\n' > "$victim"
  ln -s "$victim" "$FIXED_PATH"
  PLANTED="$victim"

  run_remediate_with '{not json'
  [ "$status" -eq 1 ]
  [ "$(cat "$victim")" = "keep me" ]
}
