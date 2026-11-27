#!/usr/bin/env bats
# Template guards for standards/supply-chain.md (issue #1618):
#
#   • standards/workflows/ci.yml carries a PR-time `dependency-review` job —
#     SHA-pinned, pull_request-only, failing on high severity + denied licenses,
#     and in warn mode (warn-only) for the rollout.
#   • standards/workflows/release-attest.yml generates an SBOM and a build
#     provenance attestation with least-privilege OIDC/attestation grants.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
CI="$REPO_ROOT/standards/workflows/ci.yml"
REL="$REPO_ROOT/standards/workflows/release-attest.yml"
STANDARD="$REPO_ROOT/standards/supply-chain.md"

# Print the JSON form of a YAML file (PyYAML). Note PyYAML reads the bare `on:`
# key as boolean true, so triggers live under ."true" in the JSON.
to_json() {
  python3 -c 'import json,sys,yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))' "$1"
}

@test "supply-chain standard exists and covers all three requirements" {
  [ -f "$STANDARD" ]
  grep -qi 'SBOM' "$STANDARD"
  grep -q 'actions/attest-build-provenance' "$STANDARD"
  grep -q 'actions/dependency-review-action' "$STANDARD"
  grep -qi 'warn' "$STANDARD"
  grep -qi 'enforce' "$STANDARD"
  grep -q 'supply_chain_exemptions' "$STANDARD"
}

# ── ci.yml dependency-review job ────────────────────────────────────────────

@test "ci.yml: has a dependency-review job" {
  run bash -c "$(declare -f to_json); to_json '$CI' | jq -e '.jobs[\"dependency-review\"]'"
  [ "$status" -eq 0 ]
}

@test "ci.yml: dependency-review runs only on pull_request events" {
  run bash -c "$(declare -f to_json); to_json '$CI' | jq -r '.jobs[\"dependency-review\"].if'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"github.event_name == 'pull_request'"* ]]
}

@test "ci.yml: dependency-review has least-privilege contents: read only" {
  run bash -c "$(declare -f to_json); to_json '$CI' | jq -c '.jobs[\"dependency-review\"].permissions'"
  [ "$status" -eq 0 ]
  [ "$output" = '{"contents":"read"}' ]
}

@test "ci.yml: dependency-review-action is SHA-pinned with a version comment" {
  grep -qE '^[[:space:]]+(- )?uses: actions/dependency-review-action@[0-9a-f]{40} # v[0-9]' "$CI"
}

@test "ci.yml: dependency-review fails on high severity and denies licenses, in warn mode" {
  local with
  with="$(bash -c "$(declare -f to_json); to_json '$CI'" | jq -c '.jobs["dependency-review"].steps[] | select(.uses // "" | startswith("actions/dependency-review-action@")) | .with')"
  [ "$(echo "$with" | jq -r '."fail-on-severity"')" = "high" ]
  [ -n "$(echo "$with" | jq -r '."deny-licenses" // empty')" ]
  [ "$(echo "$with" | jq -r '."warn-only"')" = "true" ]
}

# ── release-attest.yml ──────────────────────────────────────────────────────

@test "release-attest.yml: exists with a source-of-truth header" {
  [ -f "$REL" ]
  grep -q 'SOURCE OF TRUTH: combsmith/.github/standards/workflows/release-attest.yml' "$REL"
}

@test "release-attest.yml: triggers on published releases" {
  run bash -c "$(declare -f to_json); to_json '$REL' | jq -c '.[\"true\"].release.types'"
  [ "$status" -eq 0 ]
  [ "$output" = '["published"]' ]
}

@test "release-attest.yml: top-level permissions are empty" {
  run bash -c "$(declare -f to_json); to_json '$REL' | jq -c '.permissions'"
  [ "$output" = '{}' ]
}

@test "release-attest.yml: the attest job grants exactly id-token + attestations write and contents read" {
  run bash -c "$(declare -f to_json); to_json '$REL' | jq -c '.jobs[\"sbom-and-provenance\"].permissions | to_entries | sort_by(.key) | from_entries'"
  [ "$status" -eq 0 ]
  [ "$output" = '{"attestations":"write","contents":"read","id-token":"write"}' ]
}

@test "release-attest.yml: generates an SBOM and a build provenance attestation (SHA-pinned)" {
  grep -qE '^[[:space:]]+(- )?uses: anchore/sbom-action@[0-9a-f]{40} # v[0-9]' "$REL"
  grep -qE '^[[:space:]]+(- )?uses: actions/attest-build-provenance@[0-9a-f]{40} # v[0-9]' "$REL"
}

@test "release-attest.yml: every action is SHA-pinned" {
  local bad
  bad="$(grep -E '^[[:space:]]+(- )?uses:' "$REL" | grep -vE 'uses: [^@]+@[0-9a-f]{40}( |$)' || true)"
  [ -z "$bad" ]
}

@test "release-attest.yml: SBOM is SPDX or CycloneDX" {
  local fmt
  fmt="$(bash -c "$(declare -f to_json); to_json '$REL'" | jq -r '.jobs["sbom-and-provenance"].steps[] | select(.uses // "" | startswith("anchore/sbom-action@")) | .with.format')"
  [[ "$fmt" == spdx-json || "$fmt" == cyclonedx-json ]]
}
