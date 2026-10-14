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

bats_require_minimum_version 1.5.0

# ---------------------------------------------------------------------------
# Pure helpers that mirror the script's logic
#
# _extract_uses_channel: pulls the channel name out of the uses: pin line.
#   Returns the channel string (e.g. "stable", "ring0") on stdout, or empty
#   string when no matching pin is found.
#
# _agent_ref_matches_channel: returns 0 when agent_ref pins exactly $channel.
# ---------------------------------------------------------------------------

_extract_uses_channel() {
  local decoded="$1"
  printf '%s\n' "$decoded" | \
    sed -nE 's#^[[:space:]]*uses:[[:space:]]*combsmith/\.github-private/\.github/workflows/dev-lead-reusable\.yml@dev-lead/(stable|next|ring[0-9]+)([[:space:]]|$).*#\1#p'
}

_agent_ref_matches_channel() {
  local decoded="$1" channel="$2"
  printf '%s\n' "$decoded" | grep -qE "^[[:space:]]*agent_ref:[[:space:]]*dev-lead/$channel([[:space:]]|$)"
}

# ---------------------------------------------------------------------------
# Channel extraction from uses: pin
# ---------------------------------------------------------------------------

@test "extracts 'stable' from a stable pin" {
  decoded="    uses: combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/stable"
  run _extract_uses_channel "$decoded"
  [ "$status" -eq 0 ]
  [ "$output" = "stable" ]
}

@test "extracts 'next' from a next pin" {
  decoded="    uses: combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/next"
  run _extract_uses_channel "$decoded"
  [ "$status" -eq 0 ]
  [ "$output" = "next" ]
}

@test "extracts 'ring0' from a ring0 pin" {
  decoded="    uses: combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/ring0"
  run _extract_uses_channel "$decoded"
  [ "$status" -eq 0 ]
  [ "$output" = "ring0" ]
}

@test "extracts 'ring1' from a ring1 pin" {
  decoded="    uses: combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/ring1"
  run _extract_uses_channel "$decoded"
  [ "$status" -eq 0 ]
  [ "$output" = "ring1" ]
}

@test "extraction ignores a commented-out uses line" {
  decoded="    # uses: combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/stable"
  run _extract_uses_channel "$decoded"
  [ "$output" = "" ]
}

@test "extraction returns empty for a SHA pin (not a channel)" {
  decoded="    uses: combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@376a4fcb1117444595e3e702fa450873d0e54310"
  run _extract_uses_channel "$decoded"
  [ "$output" = "" ]
}

@test "extraction returns empty for a version-tag pin" {
  decoded="    uses: combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@v1.2.3"
  run _extract_uses_channel "$decoded"
  [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# agent_ref channel matching — happy path (no split-brain)
# ---------------------------------------------------------------------------

@test "agent_ref stable matches channel stable" {
  decoded="      agent_ref: dev-lead/stable"
  run _agent_ref_matches_channel "$decoded" "stable"
  [ "$status" -eq 0 ]
}

@test "agent_ref next matches channel next" {
  decoded="      agent_ref: dev-lead/next"
  run _agent_ref_matches_channel "$decoded" "next"
  [ "$status" -eq 0 ]
}

@test "agent_ref ring0 matches channel ring0" {
  decoded="      agent_ref: dev-lead/ring0"
  run _agent_ref_matches_channel "$decoded" "ring0"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Split-brain detection — uses: and agent_ref on different channels
# ---------------------------------------------------------------------------

@test "agent_ref stable does NOT match channel ring0 (split-brain)" {
  decoded="      agent_ref: dev-lead/stable"
  run _agent_ref_matches_channel "$decoded" "ring0"
  [ "$status" -ne 0 ]
}

@test "agent_ref next does NOT match channel stable (split-brain)" {
  decoded="      agent_ref: dev-lead/next"
  run _agent_ref_matches_channel "$decoded" "stable"
  [ "$status" -ne 0 ]
}

@test "agent_ref ring0 does NOT match channel ring1 (split-brain)" {
  decoded="      agent_ref: dev-lead/ring0"
  run _agent_ref_matches_channel "$decoded" "ring1"
  [ "$status" -ne 0 ]
}

@test "agent_ref ring1 does NOT match channel ring0 (split-brain)" {
  decoded="      agent_ref: dev-lead/ring1"
  run _agent_ref_matches_channel "$decoded" "ring0"
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
    uses: combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/ring0
    with:
      agent_ref: dev-lead/ring0
    secrets: inherit
EOF
)
  run _extract_uses_channel "$decoded"
  [ "$status" -eq 0 ]
  [ "$output" = "ring0" ]
}

@test "matching agent_ref in a full stub passes when channels agree" {
  decoded=$(cat <<'EOF'
jobs:
  dev-lead:
    uses: combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/ring0
    with:
      agent_ref: dev-lead/ring0
EOF
)
  channel=$(_extract_uses_channel "$decoded")
  [ "$channel" = "ring0" ]
  run _agent_ref_matches_channel "$decoded" "$channel"
  [ "$status" -eq 0 ]
}

@test "mismatched agent_ref in a full stub fails when channels differ" {
  decoded=$(cat <<'EOF'
jobs:
  dev-lead:
    uses: combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/ring0
    with:
      agent_ref: dev-lead/stable
EOF
)
  channel=$(_extract_uses_channel "$decoded")
  [ "$channel" = "ring0" ]
  run _agent_ref_matches_channel "$decoded" "$channel"
  [ "$status" -ne 0 ]
}
