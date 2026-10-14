#!/usr/bin/env bats
# Tests for the agent_ref/uses-channel sync check in check_dev_lead_stub()
# (scripts/compliance-audit.sh).
#
# The audit must enforce that agent_ref passes the *same* channel as the uses:
# pin — not merely any valid channel — to prevent split-brain where the
# reusable workflow and its own script/prompt checkout run on different releases.
#
# The helpers below mirror the extraction and matching logic in the script so
# the check can be exercised without needing live gh API calls.
#
# #657 F5 (#861): the dev-lead stub must now pin the major-scoped v-form
# `dev-lead/v<M>-<tier>` — a bare `dev-lead/<tier>` pin is drift. So the mirror
# helpers extract the FULL `v<M>-<tier>` channel, return empty for a bare pin,
# and match agent_ref against the full v-form channel.

bats_require_minimum_version 1.5.0

# ---------------------------------------------------------------------------
# Pure helpers that mirror the script's logic
#
# _extract_uses_channel: pulls the channel name out of the uses: pin line.
#   Returns the full v-form channel string (e.g. "v3-stable", "v1-ring0") on
#   stdout, or empty string when no matching v-form pin is found (a bare
#   `dev-lead/stable` pin yields empty — it is drift under F5).
#
# _agent_ref_matches_channel: returns 0 when agent_ref pins exactly $channel.
# ---------------------------------------------------------------------------

_extract_uses_channel() {
  local decoded="$1"
  printf '%s\n' "$decoded" | \
    sed -nE 's#^[[:space:]]*uses:[[:space:]]*petry-projects/\.github-private/\.github/workflows/dev-lead-reusable\.yml@dev-lead/(v[0-9]+-(stable|next|ring[0-9]+))([[:space:]]|$).*#\1#p'
}

_agent_ref_matches_channel() {
  local decoded="$1" channel="$2"
  printf '%s\n' "$decoded" | grep -qE "^[[:space:]]*agent_ref:[[:space:]]*dev-lead/$channel([[:space:]]|$)"
}

# ---------------------------------------------------------------------------
# Channel extraction from uses: pin
# ---------------------------------------------------------------------------

@test "extracts 'v3-stable' from a v-form stable pin" {
  decoded="    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v3-stable"
  run _extract_uses_channel "$decoded"
  [ "$status" -eq 0 ]
  [ "$output" = "v3-stable" ]
}

@test "extracts 'v2-next' from a v-form next pin" {
  decoded="    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v2-next"
  run _extract_uses_channel "$decoded"
  [ "$status" -eq 0 ]
  [ "$output" = "v2-next" ]
}

@test "extracts 'v1-ring0' from a v-form ring0 pin" {
  decoded="    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-ring0"
  run _extract_uses_channel "$decoded"
  [ "$status" -eq 0 ]
  [ "$output" = "v1-ring0" ]
}

@test "extracts 'v4-ring1' from a v-form ring1 pin" {
  decoded="    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v4-ring1"
  run _extract_uses_channel "$decoded"
  [ "$status" -eq 0 ]
  [ "$output" = "v4-ring1" ]
}

@test "extraction returns empty for a bare (non-v-form) pin — it is drift under F5" {
  decoded="    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/stable"
  run _extract_uses_channel "$decoded"
  [ "$output" = "" ]
}

@test "extraction ignores a commented-out uses line" {
  decoded="    # uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v3-stable"
  run _extract_uses_channel "$decoded"
  [ "$output" = "" ]
}

@test "extraction returns empty for a SHA pin (not a channel)" {
  decoded="    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@376a4fcb1117444595e3e702fa450873d0e54310"
  run _extract_uses_channel "$decoded"
  [ "$output" = "" ]
}

@test "extraction returns empty for a version-tag pin" {
  decoded="    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@v1.2.3"
  run _extract_uses_channel "$decoded"
  [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# agent_ref channel matching — happy path (no split-brain)
# ---------------------------------------------------------------------------

@test "agent_ref v3-stable matches channel v3-stable" {
  decoded="      agent_ref: dev-lead/v3-stable"
  run _agent_ref_matches_channel "$decoded" "v3-stable"
  [ "$status" -eq 0 ]
}

@test "agent_ref v2-next matches channel v2-next" {
  decoded="      agent_ref: dev-lead/v2-next"
  run _agent_ref_matches_channel "$decoded" "v2-next"
  [ "$status" -eq 0 ]
}

@test "agent_ref v1-ring0 matches channel v1-ring0" {
  decoded="      agent_ref: dev-lead/v1-ring0"
  run _agent_ref_matches_channel "$decoded" "v1-ring0"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Split-brain detection — uses: and agent_ref on different channels. Under F5
# this includes a major mismatch on the same tier (v3-stable vs v2-stable).
# ---------------------------------------------------------------------------

@test "agent_ref v3-stable does NOT match channel v3-ring0 (split-brain)" {
  decoded="      agent_ref: dev-lead/v3-stable"
  run _agent_ref_matches_channel "$decoded" "v3-ring0"
  [ "$status" -ne 0 ]
}

@test "agent_ref v2-next does NOT match channel v2-stable (split-brain)" {
  decoded="      agent_ref: dev-lead/v2-next"
  run _agent_ref_matches_channel "$decoded" "v2-stable"
  [ "$status" -ne 0 ]
}

@test "agent_ref v3-stable does NOT match channel v2-stable (major split-brain)" {
  decoded="      agent_ref: dev-lead/v3-stable"
  run _agent_ref_matches_channel "$decoded" "v2-stable"
  [ "$status" -ne 0 ]
}

@test "agent_ref bare dev-lead/stable does NOT match a v-form channel" {
  decoded="      agent_ref: dev-lead/stable"
  run _agent_ref_matches_channel "$decoded" "v3-stable"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Extraction from a full multi-line YAML stub (realistic fixture)
# ---------------------------------------------------------------------------

@test "extracts channel from multi-line YAML with uses: at the right indent level" {
  decoded=$(cat <<'EOF'
on:
  push:
    branches: [main]
jobs:
  dev-lead:
    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-ring0
    with:
      agent_ref: dev-lead/v1-ring0
    secrets: inherit
EOF
)
  run _extract_uses_channel "$decoded"
  [ "$status" -eq 0 ]
  [ "$output" = "v1-ring0" ]
}

@test "matching agent_ref in a full stub passes when channels agree" {
  decoded=$(cat <<'EOF'
jobs:
  dev-lead:
    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-ring0
    with:
      agent_ref: dev-lead/v1-ring0
EOF
)
  channel=$(_extract_uses_channel "$decoded")
  [ "$channel" = "v1-ring0" ]
  run _agent_ref_matches_channel "$decoded" "$channel"
  [ "$status" -eq 0 ]
}

@test "mismatched agent_ref in a full stub fails when channels differ" {
  decoded=$(cat <<'EOF'
jobs:
  dev-lead:
    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-ring0
    with:
      agent_ref: dev-lead/v1-stable
EOF
)
  channel=$(_extract_uses_channel "$decoded")
  [ "$channel" = "v1-ring0" ]
  run _agent_ref_matches_channel "$decoded" "$channel"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# #1267 — integration: check_dev_lead_stub flags a SUPERSEDED channel major.
# Five consumers sat on dev-lead/v1-stable while promotion moved dev-lead/v139-*;
# the audit accepted any major. The real check is exercised here (script sourced,
# gh_api + gh mocked) so the decision surfaces as a FINDING with its message.
# ---------------------------------------------------------------------------
AUDIT_SCRIPT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/scripts/compliance-audit.sh"
DL_REFS_LIVE="refs/tags/dev-lead/v1-stable
refs/tags/dev-lead/v139.50.2
refs/tags/dev-lead/v139-stable
refs/tags/dev-lead/v139-ring1
refs/tags/dev-lead/v139-ring0
refs/tags/dev-lead/v139-next"

# Args: repo, pinned-channel-ref. Runs check_dev_lead_stub against a stub pinning that ref.
devlead_check() {  # <repo> <pinned-channel-ref> — run check_dev_lead_stub against a stub pinning it
  local body="jobs:
  dev-lead:
    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@$2
    with:
      agent_ref: $2
    secrets: inherit
    permissions:
      statuses: read"
  FIXTURE_B64=$(printf '%s' "$body" | base64 | tr -d '\n'); export FIXTURE_B64
  AUDIT_MATCHING_REFS="${AUDIT_MATCHING_REFS:-$DL_REFS_LIVE}"; export AUDIT_MATCHING_REFS
  run bash -c '
    source "$1" >/dev/null 2>&1
    ORG=petry-projects
    # Fake gh: serves AUDIT_MATCHING_REFS for matching-refs/tags calls (fails if AUDIT_MATCHING_FAIL is set); else returns 1.
    gh() {
      case "$2" in
        *matching-refs/tags/*)
          if [ -n "${AUDIT_MATCHING_FAIL:-}" ]; then echo "HTTP 502" >&2; return 1; fi
          printf "%s\n" "$AUDIT_MATCHING_REFS" ;;
        *) return 1 ;;
      esac
    }
    # Fake gh_api: args are the API path; serves FIXTURE_B64 as the dev-lead.yml contents.
    gh_api() { case "$1" in */contents/.github/workflows/dev-lead.yml) printf "%s" "$FIXTURE_B64" ;; esac; }
    # Fake add_finding: records a finding by printing FLAGGED:<check>:<severity>:<message>.
    add_finding() { printf "FLAGGED:%s:%s:%s\n" "$3" "$4" "$5"; }
    check_dev_lead_stub "$2"
  ' _ "$AUDIT_SCRIPT" "$1"
}

@test "#1267: a stub on the superseded dev-lead/v1-stable is FLAGGED, naming pinned + expected refs" {
  devlead_check broodminder-data dev-lead/v1-stable
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'FLAGGED:dev-lead-stub-pin:error:'
  echo "$output" | grep -qF 'pins `dev-lead/v1-stable`; expected `dev-lead/v139-stable`'
}

@test "#1267: a stub on the current dev-lead/v139-stable raises no finding" {
  devlead_check broodminder-data dev-lead/v139-stable
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "#1267: partial major cut — v1-stable (stable repo) and v1-ring1 (ring1 repo) are current" {
  export AUDIT_MATCHING_REFS="refs/tags/dev-lead/v2-next
refs/tags/dev-lead/v2-ring0
refs/tags/dev-lead/v1-ring1
refs/tags/dev-lead/v1-stable"
  devlead_check broodly dev-lead/v1-stable
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # ring1 repo on v1-ring1 (v2 not cut at ring1) is current too
  devlead_check TalkTerm dev-lead/v1-ring1
  [ -z "$output" ]
}

@test "#1267: a failed tag probe fails closed — the dev-lead stub is not declared compliant" {
  export AUDIT_MATCHING_FAIL=1
  devlead_check broodminder-data dev-lead/v139-stable
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'FLAGGED:dev-lead-stub-pin:warning:'
}
