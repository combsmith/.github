#!/usr/bin/env bats
# Unit tests for the pure helpers in scripts/codeql-audit.sh:
#   classify_family, family_title, suppression_reason, alert_severity,
#   severity_rank, severity_priority_label, issue_marker, alerts_error_kind.
#
# The script's `main` is guarded, so sourcing only defines functions — the real
# helpers are exercised directly in an isolated subshell.

bats_require_minimum_version 1.5.0

SCRIPT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/scripts/codeql-audit.sh"

call() {
  local func="$1"
  shift
  run bash -c 'source "$1" >/dev/null 2>&1; shift; "$@"' _ "$SCRIPT" "$func" "$@"
}

# ── classify_family ────────────────────────────────────────────────────────
@test "actions/* rule → actions" {
  call classify_family "actions/untrusted-checkout/medium"; [ "$output" = "actions" ]
}
@test "js/* rule → js (covers TypeScript too)" {
  call classify_family "js/polynomial-redos"; [ "$output" = "js" ]
}
@test "py/* rule → py" {
  call classify_family "py/sql-injection"; [ "$output" = "py" ]
}
@test "go/* rule → go" {
  call classify_family "go/path-injection"; [ "$output" = "go" ]
}
@test "java/* rule → java" {
  call classify_family "java/xss"; [ "$output" = "java" ]
}
@test "cs/* rule → csharp" {
  call classify_family "cs/web/xss"; [ "$output" = "csharp" ]
}
@test "cpp/* rule → cpp" {
  call classify_family "cpp/overflow-buffer"; [ "$output" = "cpp" ]
}
@test "rb/* rule → ruby" {
  call classify_family "rb/code-injection"; [ "$output" = "ruby" ]
}
@test "swift/* rule → swift" {
  call classify_family "swift/sql-injection"; [ "$output" = "swift" ]
}
@test "rust/* rule → rust" {
  call classify_family "rust/sql-injection"; [ "$output" = "rust" ]
}
@test "unknown pack → misc" {
  call classify_family "kotlin/something"; [ "$output" = "misc" ]
}
@test "empty rule id → misc" {
  call classify_family ""; [ "$output" = "misc" ]
}

# ── family_title (stable title + body heading) ─────────────────────────────
@test "family_title is non-empty and distinct for every known family" {
  run bash -c 'source "$1" >/dev/null 2>&1;
    for f in actions js py go java csharp cpp ruby swift rust misc; do
      t=$(family_title "$f"); [ -n "$t" ] || exit 1; echo "$t"; done | sort | uniq -d' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
@test "titles never collide with the SonarCloud audit's 'SonarCloud:' prefix" {
  run bash -c 'source "$1" >/dev/null 2>&1; family_title actions' _ "$SCRIPT"
  [[ "$output" != SonarCloud* ]]
}

# ── suppression_reason (no duplicates with other audits / policy) ──────────
@test "first-party channel-tag ref is suppressed as exempt by policy" {
  call suppression_reason "actions/unpinned-tag" \
    "Job Job: dev-lead in 'Dev-Lead Agent' uses reusable workflow 'combsmith/.github-private/.github/workflows/dev-lead-reusable.yml' with ref 'dev-lead/v139-stable', not a pinned commit hash"
  [ "$output" = "first-party channel ref (exempt by ci-standards.md)" ]
}
@test "third-party unpinned action is suppressed as filed by the compliance audit" {
  call suppression_reason "actions/unpinned-tag" \
    "Unpinned 3rd party Action 'CI' step Uses Step uses 'someone/action' with ref 'v1', not a pinned commit hash"
  [ "$output" = "filed by compliance audit (unpinned-actions)" ]
}
@test "an ORG name only as a substring of another owner is not first-party" {
  call suppression_reason "actions/unpinned-tag" "uses 'notcombsmith/x' with ref 'v1'"
  [ "$output" = "filed by compliance audit (unpinned-actions)" ]
}
@test "missing-workflow-permissions is suppressed as filed by the compliance audit" {
  call suppression_reason "actions/missing-workflow-permissions" "Actions job or workflow does not limit the permissions" ".github/workflows/ci.yml"
  [ "$output" = "filed by compliance audit (missing-permissions)" ]
}
@test "missing-workflow-permissions for reusable workflows is NOT suppressed" {
  call suppression_reason "actions/missing-workflow-permissions" "Actions job or workflow does not limit the permissions" ".github/workflows/ci-reusable.yml"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}
@test "missing-workflow-permissions for files outside .github/workflows/ is NOT suppressed" {
  call suppression_reason "actions/missing-workflow-permissions" "Actions job or workflow does not limit the permissions" "src/action.yml"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}
@test "other actions rules are filed (no suppression)" {
  call suppression_reason "actions/untrusted-checkout/medium" "Potential unsafe checkout"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}
@test "code rules are filed (no suppression)" {
  call suppression_reason "js/incomplete-sanitization" "This replaces only the first occurrence"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

# ── alert_severity ─────────────────────────────────────────────────────────
@test "security severity wins over rule severity" {
  call alert_severity "high" "warning"; [ "$output" = "high" ]
}
@test "no security severity → rule severity" {
  call alert_severity "" "error"; [ "$output" = "error" ]
}
@test "unknown security severity falls back to rule severity" {
  call alert_severity "bogus" "warning"; [ "$output" = "warning" ]
}
@test "nothing known → note" {
  call alert_severity "" ""; [ "$output" = "note" ]
}

# ── severity_rank ordering ─────────────────────────────────────────────────
@test "severity ranks: critical>high>medium>error>low>warning>note>unknown" {
  run bash -c 'source "$1" >/dev/null 2>&1; prev=99
    for s in critical high medium error low warning note bogus; do
      r=$(severity_rank "$s"); [ "$r" -lt "$prev" ] || exit 1; prev=$r; done' _ "$SCRIPT"
  [ "$status" -eq 0 ]
}
@test "scan's jq rank table agrees with severity_rank" {
  run bash -c 'source "$1" >/dev/null 2>&1
    for s in critical high medium error low warning note; do
      j=$(jq -rn --arg s "$s" "{\"critical\":7,\"high\":6,\"medium\":5,\"error\":4,\"low\":3,\"warning\":2,\"note\":1}[\$s]")
      grep -qF "\"$s\":$j" "$1" || exit 1
      [ "$j" = "$(severity_rank "$s")" ] || exit 1; done' _ "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ── severity_priority_label (shared scale with the SonarCloud audit) ───────
@test "critical → priority:blocker" {
  call severity_priority_label critical; [ "$output" = "priority:blocker" ]
}
@test "high → priority:critical" {
  call severity_priority_label high; [ "$output" = "priority:critical" ]
}
@test "medium → priority:major" {
  call severity_priority_label medium; [ "$output" = "priority:major" ]
}
@test "error (non-security) → priority:major" {
  call severity_priority_label error; [ "$output" = "priority:major" ]
}
@test "low → priority:minor" {
  call severity_priority_label low; [ "$output" = "priority:minor" ]
}
@test "warning (non-security) → priority:minor" {
  call severity_priority_label warning; [ "$output" = "priority:minor" ]
}
@test "note → priority:info" {
  call severity_priority_label note; [ "$output" = "priority:info" ]
}
@test "unknown severity defaults to priority:minor" {
  call severity_priority_label weird; [ "$output" = "priority:minor" ]
}

# ── issue_marker (hidden idempotency key) ──────────────────────────────────
@test "issue_marker embeds a stable repo/family key as an HTML comment" {
  call issue_marker "incubator" "actions"
  [ "$output" = "<!-- codeql-audit:key=incubator/actions -->" ]
}
@test "issue_marker handles dotted repo names (.github-private)" {
  call issue_marker ".github-private" "js"
  [ "$output" = "<!-- codeql-audit:key=.github-private/js -->" ]
}
@test "close_resolved's marker regex reads back the family" {
  run bash -c 'source "$1" >/dev/null 2>&1; m=$(issue_marker .github-private csharp)
    jq -rn --arg b "body text $m" "\$b | capture(\"codeql-audit:key=[^/]+/(?<fam>[a-z0-9]+)\").fam"' _ "$SCRIPT"
  [ "$output" = "csharp" ]
}
@test "marker never matches the SonarCloud audit's marker" {
  call issue_marker "x" "misc"
  [[ "$output" != *sonarcloud-audit* ]]
}

# ── alerts_error_kind (fail closed on unreadable repos) ────────────────────
@test "'no analysis found' → none (zero alerts, a real result)" {
  call alerts_error_kind 'gh: no analysis found (HTTP 404) {"message":"no analysis found"}'
  [ "$output" = "none" ]
}
@test "403 GHAS-disabled → error (repo inconclusive)" {
  call alerts_error_kind 'gh: Advanced Security must be enabled for this repository to use code scanning. (HTTP 403)'
  [ "$output" = "error" ]
}
@test "resource not accessible by token → error" {
  call alerts_error_kind 'gh: Resource not accessible by personal access token (HTTP 403)'
  [ "$output" = "error" ]
}
@test "empty error text → error (never treated as zero alerts)" {
  call alerts_error_kind ''
  [ "$output" = "error" ]
}
