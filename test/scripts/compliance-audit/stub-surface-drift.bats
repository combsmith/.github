#!/usr/bin/env bats
# Tests for the caller-stub surface-drift guard in scripts/compliance-audit.sh
# (issue #607): stub_extract_blocks / stub_normalize_surface / stub_surface_drift.
#
# The centralized caller stubs (dev-lead + the RING reusables) are thin: their
# behavior lives in the reusable, so three surfaces are NOT repo-adjustable — the
# `on:` trigger set, the `permissions:` grants, and the (usually absent)
# `concurrency:` block. The field-allowlist pin checks never inspect those
# surfaces, so a stub that trims a trigger, widens/narrows a permission, or
# injects a per-stub concurrency group drifts silently. This guard catches it.
#
# These surfaces carry NO channel pin (the tier pin lives only on the
# jobs.<id>.uses / agent_ref lines), so a stub that differs from the canonical
# ONLY by its correct tier channel pin has identical surfaces and is never
# flagged. The tests below assert both directions.
#
# The script is sourced in an isolated subshell (its `main` is guarded, so
# sourcing only defines functions) and the real pure helpers are exercised.

bats_require_minimum_version 1.5.0

SCRIPT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/scripts/compliance-audit.sh"

# stub_surface_drift returns status 0 when drift IS detected, non-zero when the
# surface is clean.
surface_drift() {
  run bash -c 'source "$1" >/dev/null 2>&1; stub_surface_drift "$2" "$3" "$4"' \
    _ "$SCRIPT" "$1" "$2" "$3"
}

extract_blocks() {
  run bash -c 'source "$1" >/dev/null 2>&1; stub_extract_blocks "$2" "$3"' \
    _ "$SCRIPT" "$1" "$2"
}

# ---------------------------------------------------------------------------
# Fixtures — trimmed but realistic canonical stubs for the guarded surfaces.
# ---------------------------------------------------------------------------

DEV_LEAD_CANONICAL=$(cat <<'EOF'
name: Dev-Lead Agent

on:
  pull_request:
    branches: [main]
    types: [opened, reopened, synchronize]
  issue_comment:
    types: [created]
  issues:
    types: [labeled]

permissions: {}

jobs:
  dev-lead:
    uses: combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/stable  # NOSONAR
    with:
      agent_ref: dev-lead/stable
    secrets: inherit
    permissions:
      contents: write
      issues: write
      statuses: read
EOF
)

AGENT_SHIELD_CANONICAL=$(cat <<'EOF'
name: AgentShield

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: read

jobs:
  agent-shield:
    uses: combsmith/.github/.github/workflows/agent-shield-reusable.yml@agent-shield/stable  # NOSONAR
EOF
)

FEATURE_IDEATION_CANONICAL=$(cat <<'EOF'
name: Feature Research & Ideation

on:
  schedule:
    - cron: '0 7 * * 5' # Friday 07:00 UTC
  workflow_dispatch:
    inputs:
      focus_area:
        required: false
        type: string
  discussion:
    types: [created]

permissions: {}

concurrency:
  group: feature-ideation
  cancel-in-progress: false

jobs:
  ideate:
    permissions:
      contents: read
      discussions: write
    uses: combsmith/.github/.github/workflows/feature-ideation-reusable.yml@feature-ideation/stable  # NOSONAR
    with:
      project_context: |
        TODO: Replace with a description of the project.
EOF
)

# ---------------------------------------------------------------------------
# AC2 — a stub that differs ONLY by its correct tier channel pin is clean on
# every guarded surface (the pin lives outside on:/permissions/concurrency).
# ---------------------------------------------------------------------------

@test "dev-lead: ring1-repinned stub is clean on the on: surface (tier pin only)" {
  local deployed="${DEV_LEAD_CANONICAL//dev-lead\/stable/dev-lead/ring1}"
  surface_drift "$DEV_LEAD_CANONICAL" "$deployed" "on"
  [ "$status" -ne 0 ]
}

@test "agent-shield: ring1-repinned stub is clean on all three surfaces (tier pin only)" {
  local deployed="${AGENT_SHIELD_CANONICAL//agent-shield\/stable/agent-shield/ring1}"
  surface_drift "$AGENT_SHIELD_CANONICAL" "$deployed" "on"
  [ "$status" -ne 0 ]
  surface_drift "$AGENT_SHIELD_CANONICAL" "$deployed" "permissions"
  [ "$status" -ne 0 ]
  surface_drift "$AGENT_SHIELD_CANONICAL" "$deployed" "concurrency"
  [ "$status" -ne 0 ]
}

@test "an unmodified stub is clean on every guarded surface" {
  local s
  for s in on permissions concurrency; do
    surface_drift "$DEV_LEAD_CANONICAL" "$DEV_LEAD_CANONICAL" "$s"
    [ "$status" -ne 0 ]
    surface_drift "$FEATURE_IDEATION_CANONICAL" "$FEATURE_IDEATION_CANONICAL" "$s"
    [ "$status" -ne 0 ]
  done
}

# ---------------------------------------------------------------------------
# AC1 — a trimmed on: trigger surface is flagged.
# ---------------------------------------------------------------------------

@test "dev-lead: dropping the issues: trigger is flagged (trimmed on:)" {
  local deployed
  deployed=$(printf '%s\n' "$DEV_LEAD_CANONICAL" | sed '/^  issues:$/,/^    types: \[labeled\]$/d')
  # sanity: the trigger really was removed
  ! grep -q '^  issues:$' <<< "$deployed"
  surface_drift "$DEV_LEAD_CANONICAL" "$deployed" "on"
  [ "$status" -eq 0 ]
}

@test "dev-lead: narrowing pull_request types is flagged (trimmed on:)" {
  local deployed
  deployed=$(printf '%s\n' "$DEV_LEAD_CANONICAL" | sed 's/\[opened, reopened, synchronize\]/[opened]/')
  # sanity: the types list really was narrowed
  [ "$deployed" != "$DEV_LEAD_CANONICAL" ]
  surface_drift "$DEV_LEAD_CANONICAL" "$deployed" "on"
  [ "$status" -eq 0 ]
}

@test "feature-ideation: dropping the discussion: trigger is flagged (trimmed on:)" {
  local deployed
  deployed=$(printf '%s\n' "$FEATURE_IDEATION_CANONICAL" | sed '/^  discussion:$/,/^    types: \[created\]$/d')
  surface_drift "$FEATURE_IDEATION_CANONICAL" "$deployed" "on"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# feature-ideation's per-repo cron retune is NOT trigger-surface drift — the
# header documents it as an allowed customization, so cron VALUES are normalized.
# ---------------------------------------------------------------------------

@test "feature-ideation: retuning the schedule cron is NOT flagged" {
  local deployed="${FEATURE_IDEATION_CANONICAL/0 7 * * 5/30 13 * * 1}"
  # sanity: the cron value really did change
  [ "$deployed" != "$FEATURE_IDEATION_CANONICAL" ]
  surface_drift "$FEATURE_IDEATION_CANONICAL" "$deployed" "on"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# permissions surface — added or removed permission is flagged.
# ---------------------------------------------------------------------------

@test "agent-shield: adding a permission is flagged" {
  local deployed="${AGENT_SHIELD_CANONICAL/  contents: read/  contents: read
  issues: read}"
  surface_drift "$AGENT_SHIELD_CANONICAL" "$deployed" "permissions"
  [ "$status" -eq 0 ]
}

@test "agent-shield: removing a permission is flagged" {
  local deployed="${AGENT_SHIELD_CANONICAL/permissions:
  contents: read/permissions: {\}}"
  surface_drift "$AGENT_SHIELD_CANONICAL" "$deployed" "permissions"
  [ "$status" -eq 0 ]
}

@test "dev-lead: removing statuses: read from the job permissions is flagged" {
  local deployed
  deployed=$(printf '%s\n' "$DEV_LEAD_CANONICAL" | sed '/^      statuses: read$/d')
  surface_drift "$DEV_LEAD_CANONICAL" "$deployed" "permissions"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# concurrency surface — injecting a per-stub concurrency block is flagged;
# retaining the canonical block (feature-ideation) is clean; changing it drifts.
# ---------------------------------------------------------------------------

@test "agent-shield: injecting a per-stub concurrency block is flagged" {
  local deployed="${AGENT_SHIELD_CANONICAL/permissions:
  contents: read/permissions:
  contents: read

concurrency:
  group: agent-shield-\${{ github.ref \}}
  cancel-in-progress: true}"
  surface_drift "$AGENT_SHIELD_CANONICAL" "$deployed" "concurrency"
  [ "$status" -eq 0 ]
}

@test "feature-ideation: retaining the canonical concurrency block is clean" {
  surface_drift "$FEATURE_IDEATION_CANONICAL" "$FEATURE_IDEATION_CANONICAL" "concurrency"
  [ "$status" -ne 0 ]
}

@test "feature-ideation: changing the concurrency group is flagged" {
  local deployed="${FEATURE_IDEATION_CANONICAL/group: feature-ideation/group: my-custom-group}"
  surface_drift "$FEATURE_IDEATION_CANONICAL" "$deployed" "concurrency"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# stub_extract_blocks — captures every block for a key at any depth, so a stub
# with both a top-level and a nested job-level permissions: block is compared in
# full (dev-lead's shape).
# ---------------------------------------------------------------------------

@test "extract_blocks captures both the top-level and job-level permissions blocks" {
  extract_blocks "$DEV_LEAD_CANONICAL" "permissions"
  [ "$status" -eq 0 ]
  # top-level empty mapping
  grep -q 'permissions: {}' <<< "$output"
  # job-level grants
  grep -q 'contents: write' <<< "$output"
  grep -q 'statuses: read' <<< "$output"
}

@test "extract_blocks returns nothing for a concurrency key that is absent" {
  extract_blocks "$AGENT_SHIELD_CANONICAL" "concurrency"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "extract_blocks does not treat a comment line as the concurrency key" {
  local content
  content=$(cat <<'EOF'
name: X
# concurrency: is centralised in the reusable — see #402
permissions: {}
EOF
)
  extract_blocks "$content" "concurrency"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
