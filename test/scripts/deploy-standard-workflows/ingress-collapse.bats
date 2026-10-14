#!/usr/bin/env bats
# Issue #1226 (Gap 1) — the standards sweep must never RESURRECT a per-role stub
# that an ADR-0007 collapse folded into `agent-ingress.yml`.
#
# A collapsed repo (the pilot is petry-projects/markets) deletes its per-role
# Class-1 caller stubs and serves each role from ONE job of agent-ingress.yml.
# `markets` is not a SKIP_REPO, so before this fix the next sweep re-deployed
# dev-lead.yml / pr-review-mention.yml / pr-auto-review.yml from the templates —
# leaving BOTH the ingress job and the stub subscribed to the same events, i.e.
# every event double-dispatched (two racing claims, double token spend).
#
# Detection reads the repo's ACTUAL state (ingress present + role job present),
# never a hardcoded repo list, so incremental fan-out needs no config edit.
#
# All runs are --dry-run with a single --repo (no mutating gh calls, no
# `gh repo list`). The fake `gh` serves agent-ingress.yml separately from the
# per-role stub path so each test models the collapse state explicitly.

setup() {
  TT_TMP="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/deploy-standard-workflows.sh"
  INGRESS_LIB="${REPO_ROOT}/scripts/lib/agent-ingress.sh"
}

teardown() { rm -rf "$TT_TMP"; }

b64() { base64 -w 0 2>/dev/null || base64 -b 0; }

# Fake gh:
#   GH_INGRESS_B64   base64 of .github/workflows/agent-ingress.yml (unset → 404).
#   GH_INGRESS_MODE  `transient` → the ingress probe fails with a non-404 error.
#   GH_CONTENT_B64   base64 of every OTHER contents path (unset → 404 = absent).
#   Everything else (matching-refs, tag probes) succeeds with empty output.
install_gh_stub() {
  local bin="${TT_TMP}/bin"
  mkdir -p "$bin"
  export AGENT_INGRESS_PROBE_BACKOFF=0
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "api" ]; then
  case "$2" in
    *contents/.github/workflows/agent-ingress.yml)
      if [ "${GH_INGRESS_MODE:-}" = "transient" ]; then
        echo "gh: Server Error (HTTP 502)" >&2; exit 1
      fi
      if [ -n "${GH_INGRESS_B64:-}" ]; then
        printf '{"type":"file","encoding":"base64","sha":"ing123","content":"%s"}' "$GH_INGRESS_B64"; exit 0
      fi
      echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    *contents*)
      if [ -n "${GH_CONTENT_B64:-}" ]; then
        printf '{"sha":"abc123","content":"%s"}' "$GH_CONTENT_B64"; exit 0
      fi
      echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  esac
fi
exit 0
STUB
  chmod +x "$bin/gh"
  PATH="${bin}:${PATH}"; export PATH
}

# ingress_with <role…> → base64 of a trimmed agent-ingress.yml with one job per role.
ingress_with() {
  local body role
  body="name: Agent Ingress

on:
  issue_comment:
    types: [created]

permissions: {}

jobs:"
  for role in "$@"; do
    body+="
  # ── ${role} ──
  ${role}:
    if: github.event_name == 'issue_comment'
    uses: petry-projects/.github/.github/workflows/${role}-reusable.yml@${role}/stable  # NOSONAR
    secrets: inherit  # NOSONAR(githubactions:S7635) first-party trusted reusable"
  done
  printf '%s\n' "$body" | b64
}

# ---------------------------------------------------------------------------
# AC #1 / #4 — a collapsed role is NOT re-seeded
# ---------------------------------------------------------------------------

@test "collapsed repo: a role served by an agent-ingress.yml job is not re-seeded" {
  GH_INGRESS_B64="$(ingress_with dev-lead pr-review-mention)"; export GH_INGRESS_B64
  install_gh_stub   # dev-lead.yml itself 404s — the collapse deleted it
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo markets --workflow dev-lead.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "markets/dev-lead.yml (served by agent-ingress.yml job 'dev-lead')"
  run grep -qF 'Would open PR' <<< "$output"
  [ "$status" -eq 1 ]
}

@test "collapsed repo: a full sweep re-seeds none of the three collapsed stubs" {
  GH_INGRESS_B64="$(ingress_with dev-lead pr-review-mention pr-auto-review)"; export GH_INGRESS_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo markets
  [ "$status" -eq 0 ]
  local pr_line
  pr_line="$(echo "$output" | grep -F 'Would open PR for markets')"
  # Non-collapsed standard stubs are still planned …
  [[ "$pr_line" == *"agent-shield.yml"* ]]
  # … but none of the roles the ingress serves.
  [[ "$pr_line" != *"dev-lead.yml"* ]]
  [[ "$pr_line" != *"pr-review-mention.yml"* ]]
  [[ "$pr_line" != *"pr-auto-review.yml"* ]]
  echo "$output" | grep -qF "markets/pr-auto-review.yml (served by agent-ingress.yml job 'pr-auto-review')"
}

@test "collapsed repo: a leftover legacy stub for a served role is not re-pinned either" {
  GH_INGRESS_B64="$(ingress_with dev-lead)"; export GH_INGRESS_B64
  # A drifted (old-pin) dev-lead.yml still present mid-migration.
  GH_CONTENT_B64="$(printf 'jobs:\n  dev-lead:\n    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@v1\n' | b64)"
  export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo markets --workflow dev-lead.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "markets/dev-lead.yml (served by agent-ingress.yml job 'dev-lead')"
  run grep -qF 'Would open PR' <<< "$output"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# AC #4 — non-collapsed repos are unaffected
# ---------------------------------------------------------------------------

@test "non-collapsed repo (no agent-ingress.yml): the stub is still deployed" {
  unset GH_INGRESS_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo markets --workflow dev-lead.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE 'Would open PR for markets .* dev-lead.yml'
  run grep -qF 'served by agent-ingress.yml' <<< "$output"
  [ "$status" -eq 1 ]
}

@test "partial collapse: an ingress lacking a role's job still receives that role's stub" {
  GH_INGRESS_B64="$(ingress_with pr-review-mention)"; export GH_INGRESS_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo markets --workflow dev-lead.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE 'Would open PR for markets .* dev-lead.yml'

  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo markets --workflow pr-review-mention.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "markets/pr-review-mention.yml (served by agent-ingress.yml job 'pr-review-mention')"
  run grep -qF 'Would open PR' <<< "$output"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Fail closed — a transient probe error must not resurrect a stub
# ---------------------------------------------------------------------------

@test "inconclusive ingress probe (non-404 error): the repo is not seeded and the sweep fails" {
  export GH_INGRESS_MODE=transient
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo markets --workflow dev-lead.yml
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF 'agent-ingress.yml'
  run grep -qF 'Would open PR' <<< "$output"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Pure helper — agent_ingress_has_role_job reads only real jobs.<role> keys
# ---------------------------------------------------------------------------

has_role_job() {  # <role> <yaml>
  run bash -c 'source "$1"; agent_ingress_has_role_job "$2" <<< "$3"' _ "$INGRESS_LIB" "$1" "$2"
}

@test "agent_ingress_has_role_job: matches a job key under jobs:" {
  has_role_job dev-lead $'name: X\njobs:\n  pr-review-mention:\n    uses: a\n  dev-lead:   # trailing comment\n    uses: b\n'
  [ "$status" -eq 0 ]
}

@test "agent_ingress_has_role_job: tolerates CRLF line endings" {
  has_role_job dev-lead $'jobs:\r\n  dev-lead:\r\n    uses: b\r\n'
  [ "$status" -eq 0 ]
}

@test "agent_ingress_has_role_job: ignores a same-named key outside jobs:, nested keys, and comments" {
  has_role_job dev-lead $'env:\n  dev-lead: x\njobs:\n  other:\n    dev-lead:\n      a: b\n  # dev-lead:\n'
  [ "$status" -ne 0 ]
}

@test "agent_ingress_has_role_job: a role-name prefix is not a match" {
  has_role_job dev-lead $'jobs:\n  dev-lead-ci:\n    uses: b\n'
  [ "$status" -ne 0 ]
}

@test "agent_ingress_has_role_job: accepts a consistent 4-space job indent" {
  has_role_job dev-lead $'jobs:\n    pr-review-mention:\n        uses: a\n    dev-lead:\n        uses: b\n'
  [ "$status" -eq 0 ]
}

@test "agent_ingress_has_role_job: does not match a nested key at a deeper indent than the job keys" {
  has_role_job dev-lead $'jobs:\n    other:\n        dev-lead:\n            a: b\n'
  [ "$status" -ne 0 ]
}

@test "agent_ingress_has_role_job: accepts double- and single-quoted job keys" {
  has_role_job dev-lead $'jobs:\n  "dev-lead":\n    uses: b\n'
  [ "$status" -eq 0 ]
  has_role_job dev-lead $'jobs:\n  \'dev-lead\':   # c\n    uses: b\n'
  [ "$status" -eq 0 ]
}

@test "agent_ingress_has_role_job: skips leading comments/blank lines under jobs:" {
  has_role_job dev-lead $'jobs:\n\n  # roles\n  dev-lead:\n    uses: b\n'
  [ "$status" -eq 0 ]
}

@test "agent-ingress.yml must never appear in DEPLOYABLE_WORKFLOWS (forward trap)" {
  local script="$BATS_TEST_DIRNAME/../../../scripts/deploy-standard-workflows.sh" block
  block="$(sed -n '/^DEPLOYABLE_WORKFLOWS=(/,/^)/p' "$script")"
  [ -n "$block" ]
  run grep -F "agent-ingress" <<<"$block"
  [ "$status" -ne 0 ]
}

@test "agent_ingress_role_for_workflow: strips the directory and .yml/.yaml suffix" {
  run bash -c 'source "$1"; agent_ingress_role_for_workflow dev-lead.yml; agent_ingress_role_for_workflow .github/workflows/pr-auto-review.yaml; agent_ingress_role_for_workflow dev-lead' _ "$INGRESS_LIB"
  [ "$status" -eq 0 ]
  [ "$output" = $'dev-lead\npr-auto-review\ndev-lead' ]
}
