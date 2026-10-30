# shellcheck shell=bash
# scripts/lib/health-alerts.sh — open security-alert counts for the health survey
#
# The `health-survey` job of compliance-audit-and-improvement.yml counts each
# repo's open Dependabot, secret-scanning and code-scanning alerts. Until
# 2026-10-29 it turned ANY read error into a count of 0, so a token without
# code-scanning read reported every repo as clean (#1411 dry run). A failed read
# is now UNKNOWN: the count is `null` and a `*_read_error` flag is set, so the
# report never reads a broken read as "no alerts".
#
# GitHub answers some reads with an error that genuinely means "0 open alerts":
# the feature is off for the repo, or CodeQL has never analysed it. Those stay 0.
# The code-scanning case mirrors alerts_error_kind() in scripts/codeql-audit.sh.
#
#   health_alert_error_kind  — pure: classify a failed read (none | error)
#   health_alert_page_count  — pure: count alerts in `gh api --paginate` output
#   health_alert_count       — the one gh call: echo a count, or `null`
#   health_security_json     — pure: the per-repo `security` object
#   health_findings_score    — pure: the weighted finding score
#
# This library is `set -euo pipefail`-safe and does not call `set` itself.

# health_alert_error_kind <kind> <message>
#   <kind>    — dependabot | secret-scanning | code-scanning
#   <message> — gh's stderr plus the response body of the failed read.
#   Echo `none` when the error means the repo has no alerts of that kind (the
#   feature is disabled, or code scanning has no analysis), else `error`. The
#   match is case-insensitive and scoped to the kind, so a disabled-feature
#   message from one endpoint can never zero another.
health_alert_error_kind() {
  local kind="$1" msg
  msg=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  case "$kind" in
    dependabot)
      case "$msg" in
        *"dependabot alerts are disabled"*) echo "none"; return ;;
      esac ;;
    secret-scanning)
      case "$msg" in
        *"secret scanning is disabled"*) echo "none"; return ;;
      esac ;;
    code-scanning)
      case "$msg" in
        *"no analysis found"*|*"advanced security must be enabled"*|*"code scanning is not enabled"*)
          echo "none"; return ;;
      esac ;;
  esac
  echo "error"
}

# health_alert_page_count <paginated_json>
#   `gh api --paginate` prints one JSON array per page. Echo the total number of
#   alerts across all pages (0 for empty output). Return 1 when any page is not
#   an array (an error object, truncated JSON), so the caller records unknown.
health_alert_page_count() {
  printf '%s' "$1" | jq -se 'if all(.[]; type == "array") then (map(length) | add // 0) else error("not an alert list") end' 2>/dev/null
}

# health_alert_count <owner/repo> <kind>
#   Read every page of the repo's open alerts of <kind> and echo the count, or
#   `null` when the read failed for any reason other than the "no alerts" errors
#   health_alert_error_kind accepts. A failure is logged as a workflow warning on
#   stderr. Always returns 0: an unknown count is data, not a job failure.
health_alert_count() {
  local repo="$1" kind="$2" out err rc=0 count
  err=$(mktemp)
  out=$(gh api --paginate "repos/$repo/$kind/alerts?state=open&per_page=100" 2>"$err") || rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$err"
    if count=$(health_alert_page_count "$out"); then
      echo "$count"
    else
      echo "::warning::$repo: $kind alerts response is not an alert list — count unknown" >&2
      echo "null"
    fi
    return 0
  fi
  local msg
  msg="$(cat "$err") $out"
  rm -f "$err"
  if [ "$(health_alert_error_kind "$kind" "$msg")" = "none" ]; then
    echo "0"
    return 0
  fi
  echo "::warning::$repo: $kind alerts unreadable — count unknown: $(printf '%s' "$msg" | tr '\n' ' ' | cut -c1-200)" >&2
  echo "null"
}

# health_security_json <dependabot> <secret_scanning> <code_scanning>
#   Each argument is a count or `null` (health_alert_count). Echo the per-repo
#   `security` object (compact): the three counts, a `*_read_error` flag per
#   count, and `unknown_counts` — the names of the counts that are unknown, so a
#   consumer can tell "0 alerts" from "could not read" at a glance.
health_security_json() {
  jq -cn --argjson d "$1" --argjson s "$2" --argjson c "$3" '
    {
      dependabot_open: $d,           dependabot_read_error: ($d == null),
      secret_scanning_open: $s,      secret_scanning_read_error: ($s == null),
      code_scanning_open: $c,        code_scanning_read_error: ($c == null),
      unknown_counts: ([["dependabot", $d], ["secret_scanning", $s], ["code_scanning", $c]]
                       | map(select(.[1] == null) | .[0]))
    }'
}

# health_findings_score <failed_runs> <security_json> <stale_prs> <no_branch_protection>
#   Echo the weighted finding score: failed runs + Dependabot + 5 × secret
#   scanning + 3 × code scanning + stale PRs + 5 when branch protection is
#   missing (<no_branch_protection> is `true` or `false`). An unknown (null)
#   alert count adds nothing here — it is reported through `unknown_counts`
#   instead, never as a clean 0.
health_findings_score() {
  jq -n --argjson failed "$1" --argjson sec "$2" --argjson stale "$3" --argjson nobp "$4" '
    $failed + ($sec.dependabot_open // 0) + 5 * ($sec.secret_scanning_open // 0)
      + 3 * ($sec.code_scanning_open // 0) + $stale + (if $nobp then 5 else 0 end)'
}
