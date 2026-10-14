#!/usr/bin/env bats
# #1267 — the deploy sweep's verdict (is_pin_compliant in
# scripts/deploy-standard-workflows.sh) and the compliance audit's verdict
# (check_centralized_workflow_stubs / check_dev_lead_stub in
# scripts/compliance-audit.sh) must AGREE on every ring stub pin: both delegate the
# "is this the current per-tier channel major?" decision to ring_pin_current in
# scripts/lib/ring-pins.sh. Each case is run through BOTH real code paths with the
# same faked channel-tag listing; the sweep's compliant/drift must equal the
# audit's no-finding/finding.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

# Fake gh shared by both paths: matching-refs serves MATCHING_REFS (or fails when
# MATCHING_FAIL is set); contents of the stub under test serve FIXTURE_B64.
_GH_FN='
# Fake gh: serves AUDIT_MATCHING_REFS for matching-refs/tags calls (fails if
# AUDIT_MATCHING_FAIL is set); any other call returns 1.
gh() {
  case "$2" in
    *matching-refs/tags/*)
      if [ -n "${MATCHING_FAIL:-}" ]; then echo "HTTP 502" >&2; return 1; fi
      printf "%s\n" "$MATCHING_REFS" ;;
    *) return 1 ;;
  esac
}'

# sweep_verdict <agent> <repo> -> prints compliant|drift
sweep_verdict() {
  bash -c '
    source "$1/scripts/deploy-standard-workflows.sh" >/dev/null 2>&1
    set +e
    eval "$2"
    content="$(printf "%s" "$FIXTURE_B64" | base64 -d)"
    if is_pin_compliant "$content" "$1/standards/workflows/$3.yml" "$4" 2>/dev/null; then
      echo compliant
    else
      echo drift
    fi
  ' _ "$REPO_ROOT" "$_GH_FN" "$1" "$2"
}

# audit_verdict <agent> <repo> -> prints compliant|drift (drift = a pin finding)
audit_verdict() {
  bash -c '
    source "$1/scripts/compliance-audit.sh" >/dev/null 2>&1
    ORG=petry-projects
    eval "$2"
    AGENT="$3"
    # Fake gh_api: args are the API path; lists the stub for AGENT, or serves FIXTURE_B64 as the file body.
    gh_api() {
      case "$1" in
        */contents/.github/workflows) printf "%s.yml\n" "$AGENT" ;;
        */contents/.github/workflows/*) printf "%s" "$FIXTURE_B64" ;;
      esac
    }
    # Fake add_finding: prints FINDING for non-stub-* or dev-lead-stub-pin checks; ignores the rest.
    add_finding() { case "$3" in non-stub-*|dev-lead-stub-pin) echo FINDING ;; esac; }
    if [ "$3" = dev-lead ]; then out="$(check_dev_lead_stub "$4" 2>/dev/null)"
    else out="$(check_centralized_workflow_stubs "$4" 2>/dev/null)"; fi
    if [ -n "$out" ]; then echo drift; else echo compliant; fi
  ' _ "$REPO_ROOT" "$_GH_FN" "$1" "$2"
}

# Args: agent, ref. Prints the base64 of the agents TEMPLATE stub re-pinned to the ref.
stub_b64() {  # <agent> <ref> -> base64 of a stub of the agent's TEMPLATE re-pinned to <ref>
  local agent="$1" ref="$2"
  bash -c 'source "$1/scripts/lib/ring-pins.sh"; ring_repin_uses "$2" "$3" < "$1/standards/workflows/$2.yml"' \
    _ "$REPO_ROOT" "$agent" "$ref" | base64 | tr -d '\n'
}

# assert_agree <agent> <repo> <ref> <expected compliant|drift>
assert_agree() {
  FIXTURE_B64="$(stub_b64 "$1" "$3")"; export FIXTURE_B64
  local s a
  s="$(sweep_verdict "$1" "$2")"
  a="$(audit_verdict "$1" "$2")"
  echo "agent=$1 repo=$2 ref=$3 sweep=$s audit=$a expected=$4"
  [ "$s" = "$a" ]
  [ "$s" = "$4" ]
}

# Args: agent. Prints tag refs: orphaned v1-stable plus the current v139 family on every tier.
live_refs() {  # <agent> — orphaned v1-stable + the current v139 family on every tier
  local t
  for t in v1-stable v139.50.2 v139-stable v139-ring1 v139-ring0 v139-next; do printf 'refs/tags/%s/%s\n' "$1" "$t"; done
}
# Args: agent. Prints tag refs for a v2 cut at the next and ring0 channels only.
partial_refs() {  # <agent> — v2 cut at next/ring0 only
  local t
  for t in v2-next v2-ring0 v1-ring1 v1-stable; do printf 'refs/tags/%s/%s\n' "$1" "$t"; done
}

@test "sweep and audit agree: dev-lead stale major, current major, wrong tier, bare tier" {
  export MATCHING_REFS; MATCHING_REFS="$(live_refs dev-lead)"
  assert_agree dev-lead broodminder-data dev-lead/v1-stable   drift
  assert_agree dev-lead broodminder-data dev-lead/v139-stable compliant
  assert_agree dev-lead broodminder-data dev-lead/v139-ring1  drift
  assert_agree dev-lead broodminder-data dev-lead/stable      drift
}

@test "sweep and audit agree: centralized (agent-shield) stale major, current major, wrong tier, bare tier" {
  export MATCHING_REFS; MATCHING_REFS="$(live_refs agent-shield)"
  assert_agree agent-shield markets agent-shield/v1-stable   drift
  assert_agree agent-shield markets agent-shield/v139-stable compliant
  assert_agree agent-shield markets agent-shield/v139-ring0  drift
  assert_agree agent-shield markets agent-shield/stable      drift
}

@test "sweep and audit agree: partial major cut is resolved per tier" {
  export MATCHING_REFS; MATCHING_REFS="$(partial_refs dev-lead)"
  assert_agree dev-lead broodly   dev-lead/v1-stable compliant
  assert_agree dev-lead broodly   dev-lead/v2-stable drift
  assert_agree dev-lead TalkTerm  dev-lead/v1-ring1  compliant
  MATCHING_REFS="$(partial_refs agent-shield)"
  assert_agree agent-shield markets agent-shield/v1-stable compliant
  assert_agree agent-shield TalkTerm agent-shield/v1-ring1 compliant
}

@test "sweep and audit agree: a failed tag probe declares nothing compliant" {
  export MATCHING_FAIL=1 MATCHING_REFS=""
  assert_agree dev-lead broodminder-data dev-lead/v139-stable drift
  assert_agree agent-shield markets agent-shield/v139-stable drift
}

@test "#1267: sweep and audit agree on bare-pin grace when no channel tags exist" {
  export MATCHING_REFS=""
  assert_agree dev-lead broodminder-data dev-lead/stable compliant
  assert_agree agent-shield markets agent-shield/stable compliant
}
