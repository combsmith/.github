#!/usr/bin/env bats
# Unit tests for is_pin_compliant's handling of SELF-CONTAINED verbatim stubs
# whose first `uses:` is a third-party ACTION step, not a first-party reusable
# workflow call (#1116).
#
# dismiss-stale-bot-reviews.yml is the initiative-driver class: it has no
# `-reusable.yml` call, but it DOES lead with `uses: actions/checkout@<sha>`.
# Before the fix, is_pin_compliant matched only that checkout SHA, so any deployed
# copy that kept the checkout pin was declared compliant even after its triggers,
# permissions, or run step drifted — later template fixes would never propagate.
# The detector must instead treat such a stub verbatim (full-content compare).

setup() {
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/deploy-standard-workflows.sh"
  TEMPLATE="${REPO_ROOT}/standards/workflows/dismiss-stale-bot-reviews.yml"
  # Source the script for its functions; main() is guarded so nothing runs.
  # shellcheck disable=SC1090
  source "$SCRIPT" >/dev/null 2>&1
}

@test "self-contained stub identical to the template is compliant" {
  local existing; existing="$(cat "$TEMPLATE")"
  run is_pin_compliant "$existing" "$TEMPLATE" "somerepo"
  [ "$status" -eq 0 ]
}

@test "self-contained stub with drifted trigger is NOT compliant despite matching checkout SHA" {
  # Drift a NON-checkout part of the stub (the trigger types). The checkout pin is
  # untouched, so the old first-uses-only check would wrongly pass; the full
  # compare must flag it as drift so the fix redeploys.
  local drifted
  drifted="$(sed 's/types: \[synchronize\]/types: [synchronize, opened]/' "$TEMPLATE")"
  run is_pin_compliant "$drifted" "$TEMPLATE" "somerepo"
  [ "$status" -eq 1 ]
}

@test "self-contained stub with drifted permissions is NOT compliant" {
  local drifted
  drifted="$(sed 's/pull-requests: write/pull-requests: read/' "$TEMPLATE")"
  run is_pin_compliant "$drifted" "$TEMPLATE" "somerepo"
  [ "$status" -eq 1 ]
}

@test "CRLF-only differences do not count as drift for a self-contained stub" {
  # is_pin_compliant normalizes CR before comparing, so a stub that differs from
  # the template only by line endings must still be compliant (no churn).
  local crlf
  crlf="$(sed 's/$/\r/' "$TEMPLATE")"
  run is_pin_compliant "$crlf" "$TEMPLATE" "somerepo"
  [ "$status" -eq 0 ]
}
