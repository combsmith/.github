#!/usr/bin/env bats
# Unit tests for scripts/lib/health-alerts.sh — the open security-alert counts
# of the compliance workflow's `health-survey` job.
#
# A failed alert read must be UNKNOWN (null + *_read_error), never 0: until
# 2026-10-29 ORG_SCORECARD_TOKEN lacked code-scanning read and every repo was
# silently reported as clean. Only GitHub's "feature disabled" / "no analysis
# found" answers count as 0. health_alert_count is exercised against a stub `gh`.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/health-alerts.sh"

_ha() { bash -c "set -euo pipefail; source '$LIB'; $*"; }

setup() {
  STUB_DIR="$(mktemp -d)"
  # Stub gh: prints $GH_STDOUT to stdout and $GH_STDERR to stderr, logs its
  # arguments, and exits $GH_RC.
  cat > "$STUB_DIR/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
printf '%s' "${GH_STDOUT:-}"
printf '%s' "${GH_STDERR:-}" >&2
exit "${GH_RC:-0}"
EOF
  chmod +x "$STUB_DIR/gh"
  export GH_LOG="$STUB_DIR/gh.log"
}

teardown() {
  rm -rf "$STUB_DIR"
}

_count() {
  run --separate-stderr env PATH="$STUB_DIR:$PATH" bash -c "set -euo pipefail; source '$LIB'; health_alert_count $*"
}

# ── health_alert_error_kind ─────────────────────────────────────────────────
@test "error_kind: code-scanning 'no analysis found' → none (mirrors codeql-audit.sh)" {
  run _ha "health_alert_error_kind code-scanning 'gh: no analysis found (HTTP 404)'"
  [ "$output" = "none" ]
}

@test "error_kind: code-scanning 'No analysis found' is matched case-insensitively" {
  run _ha "health_alert_error_kind code-scanning 'gh: No analysis found (HTTP 404)'"
  [ "$output" = "none" ]
}

@test "error_kind: code-scanning without Advanced Security → none" {
  run _ha "health_alert_error_kind code-scanning 'gh: Advanced Security must be enabled for this repository to use code scanning. (HTTP 403)'"
  [ "$output" = "none" ]
}

@test "error_kind: Dependabot alerts disabled → none" {
  run _ha "health_alert_error_kind dependabot 'gh: Dependabot alerts are disabled for this repository. (HTTP 403)'"
  [ "$output" = "none" ]
}

@test "error_kind: secret scanning disabled → none" {
  run _ha "health_alert_error_kind secret-scanning 'gh: Secret scanning is disabled on this repository. (HTTP 404)'"
  [ "$output" = "none" ]
}

@test "error_kind: token without permission (403) → error" {
  run _ha "health_alert_error_kind code-scanning 'gh: Resource not accessible by personal access token (HTTP 403)'"
  [ "$output" = "error" ]
}

@test "error_kind: rate limit → error" {
  run _ha "health_alert_error_kind dependabot 'gh: API rate limit exceeded for user ID 1. (HTTP 403)'"
  [ "$output" = "error" ]
}

@test "error_kind: a disabled message is scoped to its own endpoint" {
  run _ha "health_alert_error_kind code-scanning 'gh: Dependabot alerts are disabled for this repository. (HTTP 403)'"
  [ "$output" = "error" ]
  run _ha "health_alert_error_kind dependabot 'gh: no analysis found (HTTP 404)'"
  [ "$output" = "error" ]
}

@test "error_kind: an unknown kind is always error" {
  run _ha "health_alert_error_kind other 'no analysis found'"
  [ "$output" = "error" ]
}

# ── health_alert_page_count ─────────────────────────────────────────────────
@test "page_count: sums every page of --paginate output (no 30-alert cap)" {
  run _ha "health_alert_page_count '[1,2,3][4,5][6]'"
  [ "$status" -eq 0 ]
  [ "$output" = "6" ]
}

@test "page_count: an empty array is 0" {
  run _ha "health_alert_page_count '[]'"
  [ "$output" = "0" ]
}

@test "page_count: empty output is 0" {
  run _ha "health_alert_page_count ''"
  [ "$output" = "0" ]
}

@test "page_count: an error object is not counted (returns 1)" {
  run _ha "health_alert_page_count '{\"message\":\"Bad credentials\"}'"
  [ "$status" -ne 0 ]
}

@test "page_count: truncated JSON returns 1" {
  run _ha "health_alert_page_count '[1,2'"
  [ "$status" -ne 0 ]
}

# ── health_alert_count (stub gh) ────────────────────────────────────────────
@test "count: success reads every page with per_page=100" {
  export GH_STDOUT='[{"n":1},{"n":2}][{"n":3}]'
  _count combsmith/repo dependabot
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
  grep -qF -- "api --paginate repos/combsmith/repo/dependabot/alerts?state=open&per_page=100" "$GH_LOG"
}

@test "count: permission failure → null with a workflow warning, exit 0" {
  export GH_RC=1 GH_STDOUT='{"message":"Resource not accessible by personal access token"}' \
    GH_STDERR='gh: Resource not accessible by personal access token (HTTP 403)'
  _count combsmith/repo code-scanning
  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
  [[ "$stderr" == *"::warning::combsmith/repo: code-scanning alerts unreadable"* ]]
}

@test "count: no analysis found → 0, no warning" {
  export GH_RC=1 GH_STDOUT='{"message":"no analysis found"}' GH_STDERR='gh: no analysis found (HTTP 404)'
  _count combsmith/repo code-scanning
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
  [ -z "$stderr" ]
}

@test "count: secret scanning disabled → 0" {
  export GH_RC=1 GH_STDERR='gh: Secret scanning is disabled on this repository. (HTTP 404)'
  _count combsmith/repo secret-scanning
  [ "$output" = "0" ]
}

@test "count: a mid-pagination failure is unknown, not a partial count" {
  export GH_RC=1 GH_STDOUT='[1,2,3]' GH_STDERR='gh: API rate limit exceeded (HTTP 403)'
  _count combsmith/repo dependabot
  [ "$output" = "null" ]
}

@test "count: a successful but non-list response is unknown" {
  export GH_STDOUT='{"message":"weird"}'
  _count combsmith/repo dependabot
  [ "$output" = "null" ]
  [[ "$stderr" == *"not an alert list"* ]]
}

# ── health_security_json ────────────────────────────────────────────────────
@test "security_json: all known → counts, no read errors, empty unknown_counts" {
  run _ha "health_security_json 2 0 7"
  [ "$status" -eq 0 ]
  [ "$output" = '{"dependabot_open":2,"dependabot_read_error":false,"secret_scanning_open":0,"secret_scanning_read_error":false,"code_scanning_open":7,"code_scanning_read_error":false,"unknown_counts":[]}' ]
}

@test "security_json: an unknown count is null with its read_error flag set" {
  run _ha "health_security_json 2 0 null"
  [ "$(echo "$output" | jq -c '[.code_scanning_open, .code_scanning_read_error, .unknown_counts]')" = '[null,true,["code_scanning"]]' ]
}

@test "security_json: every count unknown lists all three" {
  run _ha "health_security_json null null null"
  [ "$(echo "$output" | jq -c '.unknown_counts')" = '["dependabot","secret_scanning","code_scanning"]' ]
}

# ── health_findings_score ───────────────────────────────────────────────────
@test "score: weights failures, Dependabot, 5×secrets, 3×code scanning, stale PRs" {
  sec=$(_ha "health_security_json 2 1 3")
  run _ha "health_findings_score 4 '$sec' 1 false"
  [ "$output" = "21" ]   # 4 + 2 + 5 + 9 + 1
}

@test "score: missing branch protection adds 5" {
  sec=$(_ha "health_security_json 0 0 0")
  run _ha "health_findings_score 0 '$sec' 0 true"
  [ "$output" = "5" ]
}

@test "score: unknown counts add nothing (lower bound, flagged elsewhere)" {
  sec=$(_ha "health_security_json null 1 null")
  run _ha "health_findings_score 0 '$sec' 0 false"
  [ "$output" = "5" ]
}
